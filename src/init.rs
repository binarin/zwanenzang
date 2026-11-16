//! `zz init`: creating a standalone tracker checkout and publishing it as
//! a new branch of an existing remote. The remote must already exist; the
//! branch must not.

use std::fs;
use std::path::Path;

use crate::clock::{Clock, next_id};
use crate::config::Config;
use crate::error::{Error, Result};
use crate::git::{self, Push, Repo, Upstream};
use crate::locator::Locator;
use crate::store::{Tracker, enclosing_tracker};
use crate::sync::SyncReport;
use crate::ulid::Ulid;

/// What a successful `init` did.
pub struct Started {
    pub tracker: Tracker,
    /// The clone's actor, already created and named in its first commit.
    pub actor: Ulid,
    /// The locator's URL half, as the clone's origin.
    pub url: String,
    /// The branch the tracker publishes.
    pub branch: String,
    pub report: SyncReport,
}

/// Creates a tracker in `dir` and publishes it on a new branch of the
/// locator's remote. Succeeds only after the initial push: a failure
/// keeps the local checkout and its commit and says how to retry.
pub fn run(
    dir: &Path,
    locator: &Locator,
    name: &str,
    prefix: &str,
    actor_name: Option<&str>,
    clock: &mut dyn Clock,
) -> Result<Started> {
    // The configuration is validated first: a bad prefix or name is
    // refused before the destination or the remote is touched.
    Config::new_with_actor(next_id(clock, None), name, prefix, actor_name)
        .validate()
        .map_err(|message| Error::Config {
            path: dir.join(crate::config::CONFIG_FILE),
            message,
        })?;
    check_destination(dir)?;
    let branch = resolve_branch(locator)?;
    let tracker = Tracker::create_local(
        dir,
        name,
        prefix,
        &branch,
        &[("AGENTS.md", agents_md(prefix))],
        actor_name,
        clock,
    )?;
    let repo = tracker.repo()?;
    let actor = tracker
        .actor_in(&repo, false, clock)?
        .expect("created with the tracker");
    publish(&tracker, &repo, locator, &branch).map(|report| Started {
        tracker,
        actor,
        url: locator.url.clone(),
        branch: branch.clone(),
        report,
    })
}

/// The destination must be nonexistent or empty, and outside every tracker
/// and other work tree. Checked before the remote is read, so a refusal
/// creates nothing.
fn check_destination(dir: &Path) -> Result<()> {
    if let Some(existing) = enclosing_tracker(dir) {
        return Err(Error::AlreadyInitialized(existing));
    }
    match fs::symlink_metadata(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(Error::io(dir)(e)),
        Ok(meta) if meta.is_dir() => match fs::read_dir(dir).map_err(Error::io(dir))?.next() {
            None => Ok(()),
            Some(_) => Err(Error::InvalidArgument(format!(
                "destination {} exists and is not empty; a tracker is initialized in a \
                 nonexistent or empty directory",
                dir.display()
            ))),
        },
        Ok(_) => Err(Error::InvalidArgument(format!(
            "destination {} exists and is not an empty directory",
            dir.display()
        ))),
    }
}

/// The branch this tracker will publish. A selector names it directly; a
/// locator without one takes the remote's advertised default branch, or
/// git's configured initial branch on a remote that advertises nothing.
/// An existing branch, however found, ends the init: opening an existing
/// tracker is `--tracker-url` or `-C`, not `init`.
fn resolve_branch(locator: &Locator) -> Result<String> {
    let remote = match git::ls_remote(&locator.url)? {
        Ok(remote) => remote,
        Err(message) => {
            return Err(Error::Sync {
                code: "fetch-failed",
                message: format!("cannot read remote {}: {message}", locator.url),
            });
        }
    };
    let head = |branch: &str| format!("refs/heads/{branch}");
    match &locator.branch {
        Some(branch) => {
            if remote.refs.contains(&head(branch)) {
                return Err(Error::BranchExists(format!(
                    "the remote {} already has branch {branch}; open it with \
                     --tracker-url, or select a free branch with ?ref=",
                    locator.url
                )));
            }
            Ok(branch.clone())
        }
        None => {
            let target = remote
                .head
                .as_deref()
                .and_then(|t| t.strip_prefix("refs/heads/").map(str::to_string));
            match target {
                // An advertised default names the branch even before the
                // first commit makes it real.
                Some(branch) if !remote.head_resolves => Ok(branch),
                Some(branch) => Err(Error::BranchExists(format!(
                    "the remote {} already has its default branch {branch}; open it \
                     with --tracker-url, or select a free branch with ?ref=",
                    locator.url
                ))),
                // A remote with refs but no usable default branch: which
                // branch to publish is not ours to guess.
                None if !remote.refs.is_empty() => Err(Error::InvalidArgument(format!(
                    "the remote {} has refs but advertises no default branch; \
                     select one with ?ref=BRANCH",
                    locator.url
                ))),
                // An empty remote: git's configured initial branch.
                None => git::initial_branch(),
            }
        }
    }
}

/// Configures the origin and the branch's upstream, pushes the initial
/// commit creating the branch, and reports the published state.
fn publish(tracker: &Tracker, repo: &Repo, locator: &Locator, branch: &str) -> Result<SyncReport> {
    let upstream = Upstream {
        remote: "origin".into(),
        merge: format!("refs/heads/{branch}"),
    };
    repo.config_set("remote.origin.url", &locator.url)?;
    repo.config_set("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")?;
    repo.config_set(&format!("branch.{branch}.remote"), "origin")?;
    repo.config_set(&format!("branch.{branch}.merge"), &upstream.merge)?;
    match repo.push(&upstream)? {
        Push::Done => {
            let target = repo.head()?;
            Ok(SyncReport {
                upstream: Some(upstream.display()),
                pushed: true,
                numbered: Vec::new(),
                error: None,
                checkouts: crate::checkout::update(repo, Some(target)),
            })
        }
        // The unrelated history of a fresh tracker can never fast-forward
        // an existing branch, so a rejected push is a branch that exists,
        // including one created while this init ran.
        Push::Rejected => Err(Error::BranchExists(format!(
            "the remote {} already has branch {branch}, or another init created it \
             while this one ran; the initialized tracker is kept at {}",
            locator.url,
            tracker.root.display()
        ))),
        Push::Failed(message) => Err(Error::Sync {
            code: "push-failed",
            message: format!(
                "initial push of {} to {} failed: {message}; the initialized tracker \
                 and its commit are kept at {}; retry with `git -C {} push origin HEAD:{}` \
                 or `zz -C {} sync`",
                branch,
                locator.url,
                tracker.root.display(),
                tracker.root.display(),
                upstream.merge,
                tracker.root.display(),
            ),
        }),
    }
}

/// The tracker's own agent instructions: the bundled bootstrap paragraph,
/// which names the prefix and points agents at `agent-hooks
/// show-document overview`, under a human-editable heading.
fn agents_md(prefix: &str) -> String {
    let mut out = String::from(
        "# Agent instructions\n\n\
         Written by `zz init`; this file is human-editable.\n\n",
    );
    out.push_str(&crate::agent_hooks::bootstrap(prefix));
    out
}
