//! Best-effort updates of explicitly configured human work trees. Publication
//! supplies an immutable commit id; this module never infers one from HEAD.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::{Error, Result};
use crate::git::Repo;
use crate::sync::SyncError;

#[derive(Debug, Clone, Default, Serialize)]
pub struct CheckoutUpdates {
    pub target: Option<String>,
    /// Failure to enumerate checkouts or inspect the source repository.
    pub error: Option<SyncError>,
    pub results: Vec<CheckoutResult>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CheckoutResult {
    /// The configured value, not its canonicalized spelling.
    pub path: String,
    #[serde(flatten)]
    pub outcome: CheckoutOutcome,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "status", rename_all = "kebab-case")]
pub enum CheckoutOutcome {
    Updated,
    UpToDate,
    Skipped {
        reason: &'static str,
        message: String,
    },
}

fn skip(reason: &'static str, message: impl Into<String>) -> CheckoutOutcome {
    CheckoutOutcome::Skipped {
        reason,
        message: message.into(),
    }
}

fn canonical(path: &Path) -> Result<PathBuf> {
    fs::canonicalize(path).map_err(Error::io(path))
}

fn common_dir(repo: &Repo) -> Result<PathBuf> {
    canonical(&PathBuf::from(repo.read(&[
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    ])?))
}

/// No checkout error is allowed to change the mutation/publication outcome.
/// Values are processed in configuration order, including duplicates.
pub(crate) fn update(source: &Repo, target: Option<String>) -> CheckoutUpdates {
    let mut report = CheckoutUpdates {
        target,
        ..CheckoutUpdates::default()
    };
    let result = (|| {
        let paths = source.config_get_all("zwanenzang.checkout")?;
        if paths.is_empty() {
            return Ok(());
        }
        let branch = source.branch()?;
        let common = common_dir(source)?;
        for path in paths {
            let outcome = match report.target.as_deref() {
                None => skip(
                    "no-published-target",
                    "no published commit observed during this sync",
                ),
                Some(_) if branch.is_none() => {
                    skip("source-detached", "the owned clone has no current branch")
                }
                Some(target) => match update_one(
                    source,
                    &common,
                    branch.as_deref().expect("checked above"),
                    target,
                    &path,
                ) {
                    Ok(outcome) => outcome,
                    Err(e) => skip("update-failed", e.to_string()),
                },
            };
            report.results.push(CheckoutResult { path, outcome });
        }
        Ok::<_, Error>(())
    })();
    if let Err(e) = result {
        report.error = Some(SyncError {
            code: "checkout-inspection-failed",
            message: e.to_string(),
        });
    }
    report
}

fn update_one(
    source: &Repo,
    source_common: &Path,
    branch: &str,
    target: &str,
    configured: &str,
) -> Result<CheckoutOutcome> {
    if configured.is_empty() {
        return Ok(skip("not-a-repository", "empty checkout path"));
    }
    // Relative paths are always relative to the owned clone, not the CLI cwd.
    let path = match canonical(&source.root.join(configured)) {
        Ok(p) => p,
        Err(e) => return Ok(skip("not-a-repository", e.to_string())),
    };
    let checkout = match Repo::open(&path) {
        Ok(r) => r,
        Err(e) => return Ok(skip("not-a-repository", e.to_string())),
    };
    // Reject aliases and linked worktrees of the source: a shared branch
    // ref could otherwise move while the source work tree remains behind.
    if checkout.root == source.root || common_dir(&checkout)? == source_common {
        return Ok(skip(
            "source-repository",
            "checkout shares the owned repository",
        ));
    }
    match checkout.branch()? {
        None => return Ok(skip("detached-head", "checkout has no current branch")),
        Some(b) if b != branch => {
            return Ok(skip("wrong-branch", "checkout is on a different branch"));
        }
        _ => {}
    }
    // A clean status does not imply an idle repository (e.g. rebase edit).
    for name in [
        "rebase-merge",
        "rebase-apply",
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "sequencer",
        "BISECT_LOG",
    ] {
        if checkout.git_dir.join(name).exists() {
            return Ok(skip(
                "operation-in-progress",
                "checkout has an unfinished git operation",
            ));
        }
    }
    let status = checkout.run_checkout(&[
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignored=matching",
        "--ignore-submodules=none",
    ])?;
    if !status.status.success() {
        return Ok(skip(
            "update-failed",
            String::from_utf8_lossy(&status.stderr).trim(),
        ));
    }
    if !status.stdout.is_empty() {
        return Ok(skip(
            "dirty",
            "checkout has staged, modified, untracked or ignored files",
        ));
    }
    let head = match checkout.head() {
        Ok(h) => h,
        Err(_) => return Ok(skip("unborn-head", "checkout has no HEAD commit")),
    };
    if head == target {
        return Ok(CheckoutOutcome::UpToDate);
    }
    // Fetch just the immutable target from an absolute local path, without
    // touching FETCH_HEAD, remote refs, tags, submodules, or the network.
    let fetched = checkout.run_checkout(&[
        "fetch",
        "--quiet",
        "--no-tags",
        "--no-write-fetch-head",
        "--no-recurse-submodules",
        "--no-auto-maintenance",
        "--",
        source
            .root
            .to_str()
            .ok_or_else(|| Error::Git("source path is not UTF-8".into()))?,
        target,
    ])?;
    if !fetched.status.success() {
        return Ok(skip(
            "update-failed",
            String::from_utf8_lossy(&fetched.stderr).trim(),
        ));
    }
    let ancestor = checkout.run_checkout(&["merge-base", "--is-ancestor", &head, target])?;
    match ancestor.status.code() {
        Some(0) => {}
        Some(1) => {
            return Ok(skip(
                "not-fast-forward",
                "checkout HEAD is not an ancestor of the published target",
            ));
        }
        _ => {
            return Ok(skip(
                "update-failed",
                String::from_utf8_lossy(&ancestor.stderr).trim(),
            ));
        }
    }
    // Git performs its own work tree/index and ref locking. Disable stash,
    // hooks and submodule recursion: human state must never be moved aside.
    let merged = checkout.run_checkout(&[
        "merge",
        "--quiet",
        "--ff-only",
        "--no-autostash",
        "--no-edit",
        target,
    ])?;
    if !merged.status.success() {
        return Ok(skip(
            "update-failed",
            String::from_utf8_lossy(&merged.stderr).trim(),
        ));
    }
    Ok(CheckoutOutcome::Updated)
}
