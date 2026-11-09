//! Project-local tracker selection and durable URL-keyed clone provisioning.
//! No registry: the origin's exact bytes determine its storage location.

use std::fs::{self, File};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::error::{Error, Result};
use crate::git::{self, Repo};
use crate::store::{Tracker, find_root};

pub const URL_KEY: &str = "zwanenzang.trackerUrl";

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

fn from_url(url: &str) -> Result<Tracker> {
    // Relative paths would acquire different meanings in different projects.
    // Local transports must use absolute paths (or file:// URLs).
    if url.is_empty()
        || url.starts_with('-')
        || (!url.contains(':') && !Path::new(url).is_absolute())
    {
        return Err(Error::InvalidArgument(
            "tracker URL must be a URL, scp-style address or absolute path".into(),
        ));
    }
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
    let dir = root.join(format!("{:x}", Sha256::digest(url.as_bytes())));
    provision(&root, &dir, url)
}

/// The separate directory argument lets tests exercise provisioning using
/// marked disposable repository names, without a CLI test mode or override.
pub(crate) fn provision(root: &Path, dir: &Path, url: &str) -> Result<Tracker> {
    fs::create_dir_all(root).map_err(Error::io(root))?;
    let lock = File::open(root).map_err(Error::io(root))?;
    lock.lock().map_err(Error::io(root))?;
    match fs::symlink_metadata(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let out = git::command(root)
                .args(["-c", "core.hooksPath=/dev/null", "clone", "--", url])
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
    if repo.config_get_all("remote.origin.url")? != [url] {
        return Err(Error::InvalidArgument(format!(
            "{} has a different origin; inspect it manually",
            dir.display()
        )));
    }
    Tracker::open(&canonical)
}
