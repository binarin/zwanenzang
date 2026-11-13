//! Project-local tracker selection and durable locator-keyed clone
//! provisioning. No registry: the locator's exact bytes determine its
//! storage location.

use std::fs::{self, File};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::error::{Error, Result};
use crate::git::{self, Repo};
use crate::store::{Tracker, find_root};

pub const URL_KEY: &str = "zwanenzang.trackerUrl";

/// A tracker locator: an origin URL plus an optional branch selector.
///
/// One spelling everywhere a tracker is named: `init --remote`,
/// `--tracker-url` and project-local `zwanenzang.trackerUrl`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Locator {
    /// The origin URL exactly as written, without its selector.
    pub url: String,
    /// The selected branch: a plain branch name, never a tag or a commit
    /// revision. `None` uses the remote's advertised default branch.
    pub branch: Option<String>,
}

impl Locator {
    /// The locator's canonical spelling: the URL, `?ref=BRANCH` appended
    /// when a branch is selected.
    pub fn display(&self) -> String {
        match &self.branch {
            None => self.url.clone(),
            Some(branch) => format!("{}?ref={branch}", self.url),
        }
    }
}

/// Parses a locator, `URL[?ref=BRANCH]`. The URL keeps the shape rules of
/// every origin: no leading `-`, and a local path must be absolute (or a
/// `file://` URL), so identity cannot depend on the invoking directory.
/// The selector names a plain branch; anything else after `?` is refused.
pub fn parse_locator(locator: &str) -> Result<Locator> {
    let (url, query) = match locator.split_once('?') {
        Some((url, query)) => (url, Some(query)),
        None => (locator, None),
    };
    let branch = match query {
        None => None,
        Some(query) => {
            let name = query.strip_prefix("ref=").ok_or_else(|| {
                Error::InvalidArgument("locator supports only a ?ref=BRANCH selector".into())
            })?;
            if !git::valid_branch_name(name)? {
                return Err(Error::InvalidArgument(format!(
                    "{name:?} is not a plain branch name; tags and commit revisions \
                     are not selectors"
                )));
            }
            Some(name.to_string())
        }
    };
    if url.is_empty()
        || url.starts_with('-')
        || (!url.contains(':') && !Path::new(url).is_absolute())
    {
        return Err(Error::InvalidArgument(
            "tracker URL must be a URL, scp-style address or absolute path".into(),
        ));
    }
    Ok(Locator {
        url: url.to_string(),
        branch,
    })
}

pub fn open(dir: Option<&Path>, url: Option<&str>) -> Result<Tracker> {
    if let Some(dir) = dir {
        return Tracker::open(&find_root(dir)?);
    }
    if let Some(url) = url {
        return from_url(url);
    }
    let cwd = std::env::current_dir().map_err(Error::io("."))?;
    match find_root(&cwd) {
        Ok(root) => return Tracker::open(&root),
        Err(Error::NotATracker(_)) => {}
        Err(e) => return Err(e),
    }
    if let Some(root) = git::toplevel(&cwd)? {
        let repo = Repo::open(&root)?;
        let urls = repo.config_get_all(URL_KEY)?;
        match urls.as_slice() {
            [] => {}
            [url] => return from_url(url),
            _ => {
                return Err(Error::InvalidArgument(format!(
                    "set exactly one local {URL_KEY}"
                )));
            }
        }
    }
    Err(Error::NotATracker(cwd))
}

fn from_url(locator: &str) -> Result<Tracker> {
    let locator = parse_locator(locator)?;
    let data = std::env::var_os("XDG_DATA_HOME")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .filter(|s| !s.is_empty())
                .map(|h| PathBuf::from(h).join(".local/share"))
        })
        .ok_or_else(|| {
            Error::InvalidArgument("set XDG_DATA_HOME or HOME for tracker storage".into())
        })?;
    if !data.is_absolute() {
        return Err(Error::InvalidArgument(
            "tracker data directory must be absolute".into(),
        ));
    }
    let root = data.join("zwanenzang/trackers");
    // The whole locator, selector included, keys the storage: different
    // selected branches are different trackers' checkouts and never share
    // or re-target one clone. A locator without a selector keeps hashing
    // its plain URL bytes, as storage written before selectors did.
    let dir = root.join(format!(
        "{:x}",
        Sha256::digest(locator.display().as_bytes())
    ));
    provision(&root, &dir, &locator)
}

/// The separate directory arguments let tests exercise provisioning using
/// marked disposable repository names, without a CLI test mode or override.
pub(crate) fn provision(root: &Path, dir: &Path, locator: &Locator) -> Result<Tracker> {
    fs::create_dir_all(root).map_err(Error::io(root))?;
    let lock = File::open(root).map_err(Error::io(root))?;
    lock.lock().map_err(Error::io(root))?;
    match fs::symlink_metadata(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let mut clone: Vec<&str> = vec!["-c", "core.hooksPath=/dev/null", "clone"];
            if let Some(branch) = &locator.branch {
                clone.extend(["--branch", branch]);
            }
            clone.push("--");
            let out = git::command(root)
                .args(&clone)
                .arg(&locator.url)
                .arg(dir)
                .output()
                .map_err(Error::io(dir))?;
            if !out.status.success() {
                return Err(Error::Git(format!(
                    "tracker clone failed; inspect {} before retrying: {}",
                    dir.display(),
                    String::from_utf8_lossy(&out.stderr).trim()
                )));
            }
        }
        Err(e) => return Err(Error::io(dir)(e)),
        Ok(_) => {}
    }
    // Never remove, reset or replace existing storage, even after a failed clone.
    if !dir.join(".git").is_dir() || !dir.join("zwanenzang.toml").is_file() {
        return Err(Error::InvalidArgument(format!(
            "{} is not a complete standalone tracker clone; inspect it manually",
            dir.display()
        )));
    }
    let canonical = fs::canonicalize(dir).map_err(Error::io(dir))?;
    let repo = Repo::open(&canonical)?;
    if repo.config_get_all("remote.origin.url")? != [locator.url.as_str()] {
        return Err(Error::InvalidArgument(format!(
            "{} has a different origin; inspect it manually",
            dir.display()
        )));
    }
    // A selected branch pins this clone to it; the clone is never switched
    // to another selector's branch.
    if let Some(branch) = &locator.branch
        && repo.branch()? != Some(format!("refs/heads/{branch}"))
    {
        return Err(Error::InvalidArgument(format!(
            "{} is not on branch {branch}; inspect it manually",
            dir.display()
        )));
    }
    Tracker::open(&canonical)
}
