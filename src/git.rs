//! The tracker's git repository, driven through the `git` binary. Every
//! command runs with the repository named explicitly and without the
//! caller's `GIT_DIR`, `GIT_WORK_TREE` or `GIT_INDEX_FILE`, so a CLI started
//! from inside some other git operation still acts on its own clone.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use crate::error::{Error, Result};

/// The identity commits are made with: the actor, not the user's git
/// configuration, which an agent's environment may not have.
#[derive(Debug, Clone)]
pub struct Identity {
    pub name: String,
    pub email: String,
}

/// What `push` reported.
#[derive(Debug)]
pub enum Push {
    Done,
    /// The remote has commits this clone has not fetched.
    Rejected,
    Failed(String),
}

/// The current branch's upstream.
#[derive(Debug, Clone)]
pub struct Upstream {
    pub remote: String,
    /// The branch on the remote, `refs/heads/...`.
    pub merge: String,
}

impl Upstream {
    pub fn display(&self) -> String {
        let short = self
            .merge
            .strip_prefix("refs/heads/")
            .unwrap_or(&self.merge);
        format!("{}/{short}", self.remote)
    }
}

#[derive(Debug, Clone)]
pub struct Repo {
    pub root: PathBuf,
    pub git_dir: PathBuf,
}

fn command(dir: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("-C")
        .arg(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        // Never ask for credentials on a terminal; a remote that needs them
        // counts as unreachable.
        .env("GIT_TERMINAL_PROMPT", "0");
    c
}

fn output(dir: &Path, args: &[&str], c: &mut Command) -> Result<Output> {
    c.output().map_err(|e| {
        Error::Git(format!(
            "cannot run git {} in {}: {e}",
            args.join(" "),
            dir.display()
        ))
    })
}

fn failure(args: &[&str], out: &Output) -> Error {
    Error::Git(format!(
        "git {} failed: {}",
        args.join(" "),
        String::from_utf8_lossy(&out.stderr).trim()
    ))
}

/// The top of the work tree holding `dir`, if it is in one.
pub fn toplevel(dir: &Path) -> Result<Option<PathBuf>> {
    let args = ["rev-parse", "--show-toplevel"];
    let out = output(dir, &args, command(dir).args(args))?;
    if !out.status.success() {
        return Ok(None);
    }
    let top = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
    Ok(Some(std::fs::canonicalize(&top).map_err(Error::io(&top))?))
}

/// Makes `dir` a repository. Run only where [`toplevel`] found none.
///
/// `git init` in place is not atomic: several at once in one directory
/// fail on each other's half-written files. The repository is made in a
/// temporary directory and its `.git` renamed into place, which succeeds
/// for exactly one of them; the others find a complete repository.
pub fn init(dir: &Path) -> Result<Repo> {
    let tmp = dir.join(format!(".zwanenzang-init-{}", std::process::id()));
    let made = (|| {
        std::fs::create_dir(&tmp).map_err(Error::io(&tmp))?;
        let args = ["init", "--quiet"];
        let out = output(&tmp, &args, command(&tmp).args(args))?;
        if !out.status.success() {
            return Err(failure(&args, &out));
        }
        Ok(())
    })();
    if made.is_ok() {
        // Fails when another init got there first, which is fine.
        let _ = std::fs::rename(tmp.join(".git"), dir.join(".git"));
    }
    let _ = std::fs::remove_dir_all(&tmp);
    made?;
    Repo::open(dir)
}

impl Repo {
    /// The repository whose work tree top is exactly `root`.
    pub fn open(root: &Path) -> Result<Repo> {
        match toplevel(root)? {
            Some(top) if top == root => {}
            _ => return Err(Error::NotARepository(root.to_path_buf())),
        }
        let repo = Repo {
            root: root.to_path_buf(),
            git_dir: PathBuf::new(),
        };
        let dir = repo.read(&["rev-parse", "--absolute-git-dir"])?;
        Ok(Repo {
            git_dir: PathBuf::from(dir),
            ..repo
        })
    }

    fn run(&self, args: &[&str], identity: Option<&Identity>) -> Result<Output> {
        let mut c = command(&self.root);
        // Owned clone: no signing prompt and no hooks may stand between a
        // write and its commit.
        c.args(["-c", "commit.gpgsign=false"]).args(args);
        if let Some(id) = identity {
            c.env("GIT_AUTHOR_NAME", &id.name)
                .env("GIT_AUTHOR_EMAIL", &id.email)
                .env("GIT_COMMITTER_NAME", &id.name)
                .env("GIT_COMMITTER_EMAIL", &id.email);
        }
        output(&self.root, args, &mut c)
    }

    /// Runs and returns trimmed stdout, failing on a non-zero exit.
    fn read(&self, args: &[&str]) -> Result<String> {
        let out = self.run(args, None)?;
        if !out.status.success() {
            return Err(failure(args, &out));
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    /// Runs, failing on a non-zero exit.
    fn ok(&self, args: &[&str], identity: Option<&Identity>) -> Result<()> {
        let out = self.run(args, identity)?;
        if !out.status.success() {
            return Err(failure(args, &out));
        }
        Ok(())
    }

    pub fn config_get(&self, key: &str) -> Result<Option<String>> {
        let args = ["config", "--local", "--get", key];
        let out = self.run(&args, None)?;
        match out.status.code() {
            Some(0) => Ok(Some(
                String::from_utf8_lossy(&out.stdout).trim().to_string(),
            )),
            // 1: the key is not set.
            Some(1) => Ok(None),
            _ => Err(failure(&args, &out)),
        }
    }

    pub fn config_set(&self, key: &str, value: &str) -> Result<()> {
        self.ok(&["config", "--local", key, value], None)
    }

    /// Commits the current content of `paths` (relative to the root) and
    /// nothing else, whatever else is staged or modified. Returns false when
    /// none of them changed.
    pub fn commit(&self, paths: &[PathBuf], message: &str, identity: &Identity) -> Result<bool> {
        let existing: Vec<String> = paths
            .iter()
            .filter(|p| self.root.join(p).exists())
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        if existing.is_empty() {
            return Ok(false);
        }
        let mut add = vec!["add", "--all", "--"];
        add.extend(existing.iter().map(String::as_str));
        self.ok(&add, None)?;
        let mut diff = vec!["diff", "--cached", "--name-only", "-z", "--"];
        diff.extend(existing.iter().map(String::as_str));
        let changed = self.read(&diff)?;
        let changed: Vec<&str> = changed.split('\0').filter(|s| !s.is_empty()).collect();
        if changed.is_empty() {
            return Ok(false);
        }
        let mut commit = vec![
            "commit",
            "--quiet",
            "--no-verify",
            "-m",
            message,
            "--only",
            "--",
        ];
        commit.extend(changed);
        self.ok(&commit, Some(identity))?;
        Ok(true)
    }

    pub fn head(&self) -> Result<String> {
        self.read(&["rev-parse", "--verify", "HEAD"])
    }

    /// Drops the latest commit, restoring the files it changed. Refused by
    /// git if one of them has changes of its own, so nothing unrelated is
    /// lost.
    pub fn undo_last_commit(&self) -> Result<()> {
        self.ok(&["reset", "--quiet", "--keep", "HEAD~1"], None)
    }

    /// The current branch's upstream, if it has one. A detached head has
    /// none.
    pub fn upstream(&self) -> Result<Option<Upstream>> {
        let out = self.run(&["symbolic-ref", "--quiet", "--short", "HEAD"], None)?;
        if !out.status.success() {
            return Ok(None);
        }
        let branch = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let remote = self.config_get(&format!("branch.{branch}.remote"))?;
        let merge = self.config_get(&format!("branch.{branch}.merge"))?;
        Ok(match (remote, merge) {
            (Some(remote), Some(merge)) if remote != "." => Some(Upstream { remote, merge }),
            _ => None,
        })
    }

    /// Fetches the upstream branch. Returns the fetched commit, or `None`
    /// when the remote does not have the branch yet. A failure (an
    /// unreachable remote, say) is returned as its message.
    pub fn fetch(&self, up: &Upstream) -> Result<std::result::Result<Option<String>, String>> {
        let args = ["fetch", "--quiet", "--no-tags", &up.remote, &up.merge];
        let out = self.run(&args, None)?;
        if out.status.success() {
            return Ok(Ok(Some(self.read(&[
                "rev-parse",
                "--verify",
                "FETCH_HEAD",
            ])?)));
        }
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if stderr.contains("couldn't find remote ref") {
            return Ok(Ok(None));
        }
        Ok(Err(stderr))
    }

    /// Rebases the current branch onto `onto`. On a conflict the rebase is
    /// aborted, leaving the branch as it was, and the message returned.
    pub fn rebase(
        &self,
        onto: &str,
        identity: &Identity,
    ) -> Result<std::result::Result<(), String>> {
        let args = ["rebase", "--quiet", "--autostash", "--no-verify", onto];
        let out = self.run(&args, Some(identity))?;
        if out.status.success() {
            return Ok(Ok(()));
        }
        let message = String::from_utf8_lossy(&out.stderr).trim().to_string();
        let _ = self.run(&["rebase", "--abort"], None);
        Ok(Err(message))
    }

    /// A plain, non-force push of `HEAD` to the upstream branch.
    pub fn push(&self, up: &Upstream) -> Result<Push> {
        let refspec = format!("HEAD:{}", up.merge);
        let args = ["push", "--porcelain", "--no-verify", &up.remote, &refspec];
        let out = self.run(&args, None)?;
        if out.status.success() {
            return Ok(Push::Done);
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        // Not a fast-forward; or another push updated the branch between
        // the remote's check and its ref update, which git reports as an
        // incorrect old value and a lock failure. Both are a race lost to
        // another writer.
        let lost = stdout.lines().any(|l| {
            l.starts_with('!')
                && (l.contains("[rejected]")
                    || (l.contains("[remote rejected]")
                        && (l.contains("incorrect old value")
                            || stderr.contains("cannot lock ref"))))
        });
        if lost {
            return Ok(Push::Rejected);
        }
        let mut message = stderr.trim().to_string();
        if message.is_empty() {
            message = stdout.trim().to_string();
        }
        Ok(Push::Failed(message))
    }
}
