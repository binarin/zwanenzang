//! The tracker directory: configuration, per-actor logs, blobs, the local
//! actor id and the lock.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::clock::{Clock, next_id};
use crate::config::{CONFIG_FILE, Config};
use crate::error::{Error, Result};
use crate::names::valid_blob_name;
use crate::ulid::Ulid;

pub const GITATTRIBUTES_LINE: &str = "events/*.jsonl merge=union";
pub const GITIGNORE_LINE: &str = "/.zwanenzang/";
pub const LOCAL_DIR: &str = ".zwanenzang";

/// One line read from a log file.
#[derive(Debug, Clone)]
pub struct LogLine {
    /// File stem of the log, which must be the writing actor.
    pub log: String,
    /// 1-based line number.
    pub line_no: usize,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct Tracker {
    pub root: PathBuf,
    pub config: Config,
}

/// Holds the tracker's exclusive write lock until dropped.
#[derive(Debug)]
pub struct LockGuard {
    file: File,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

/// Finds the tracker containing `start`: the nearest directory, upward,
/// holding `zwanenzang.toml`.
pub fn find_root(start: &Path) -> Result<PathBuf> {
    let start = fs::canonicalize(start).map_err(Error::io(start))?;
    let mut dir: &Path = &start;
    loop {
        if dir.join(CONFIG_FILE).is_file() {
            return Ok(dir.to_path_buf());
        }
        match dir.parent() {
            Some(p) => dir = p,
            None => return Err(Error::NotATracker(start)),
        }
    }
}

/// Appends `line` to a text file unless the file already has it.
fn ensure_line(path: &Path, line: &str) -> Result<()> {
    let existing = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(Error::io(path)(e)),
    };
    if existing.lines().any(|l| l.trim() == line) {
        return Ok(());
    }
    let mut text = existing;
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text.push_str(line);
    text.push('\n');
    fs::write(path, text).map_err(Error::io(path))
}

fn write_file_synced(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut f = File::create(path).map_err(Error::io(path))?;
    f.write_all(bytes).map_err(Error::io(path))?;
    f.sync_all().map_err(Error::io(path))
}

impl Tracker {
    /// Creates a tracker in `dir`, which is created if missing.
    pub fn init(dir: &Path, name: &str, prefix: &str, clock: &mut dyn Clock) -> Result<Tracker> {
        fs::create_dir_all(dir).map_err(Error::io(dir))?;
        let root = fs::canonicalize(dir).map_err(Error::io(dir))?;
        let config_path = root.join(CONFIG_FILE);
        if config_path.exists() {
            return Err(Error::AlreadyInitialized(root));
        }
        let config = Config::new(next_id(clock, None), name, prefix);
        config.validate().map_err(|message| Error::Config {
            path: config_path.clone(),
            message,
        })?;
        for sub in ["events", "blobs", LOCAL_DIR] {
            let p = root.join(sub);
            fs::create_dir_all(&p).map_err(Error::io(p))?;
        }
        ensure_line(&root.join(".gitattributes"), GITATTRIBUTES_LINE)?;
        ensure_line(&root.join(".gitignore"), GITIGNORE_LINE)?;
        let tracker = Tracker { root, config };
        tracker.actor_id(true, clock)?;
        // The configuration goes last: its presence is what marks the
        // directory as a tracker.
        write_file_synced(&config_path, tracker.config.to_toml().as_bytes())?;
        Ok(tracker)
    }

    /// Opens the tracker rooted exactly at `root`.
    pub fn open(root: &Path) -> Result<Tracker> {
        let root = fs::canonicalize(root).map_err(Error::io(root))?;
        let path = root.join(CONFIG_FILE);
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(Error::NotATracker(root));
            }
            Err(e) => return Err(Error::io(path)(e)),
        };
        let config = Config::parse(&text).map_err(|message| Error::Config { path, message })?;
        Ok(Tracker { root, config })
    }

    pub fn events_dir(&self) -> PathBuf {
        self.root.join("events")
    }

    pub fn blobs_dir(&self) -> PathBuf {
        self.root.join("blobs")
    }

    fn local_dir(&self) -> Result<PathBuf> {
        let p = self.root.join(LOCAL_DIR);
        fs::create_dir_all(&p).map_err(Error::io(&p))?;
        Ok(p)
    }

    pub fn log_path(&self, actor: Ulid) -> PathBuf {
        self.events_dir().join(format!("{actor}.jsonl"))
    }

    /// Takes the exclusive tracker lock, blocking until it is free.
    pub fn lock(&self) -> Result<LockGuard> {
        let path = self.local_dir()?.join("lock");
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .map_err(Error::io(&path))?;
        file.lock().map_err(Error::io(&path))?;
        Ok(LockGuard { file })
    }

    /// This clone's actor id. With `create`, a missing id is generated and
    /// stored; without it, a missing id is `None`.
    pub fn actor_id_opt(&self, create: bool, clock: &mut dyn Clock) -> Result<Option<Ulid>> {
        let path = self.root.join(LOCAL_DIR).join("actor");
        match fs::read_to_string(&path) {
            Ok(text) => Ulid::parse_canonical(text.trim())
                .map(Some)
                .map_err(|e| Error::Config {
                    path,
                    message: e.to_string(),
                }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if !create {
                    return Ok(None);
                }
                let id = next_id(clock, None);
                self.local_dir()?;
                write_file_synced(&path, format!("{id}\n").as_bytes())?;
                Ok(Some(id))
            }
            Err(e) => Err(Error::io(path)(e)),
        }
    }

    pub fn actor_id(&self, create: bool, clock: &mut dyn Clock) -> Result<Ulid> {
        Ok(self
            .actor_id_opt(create, clock)?
            .expect("created when missing"))
    }

    /// Reads every line of every `events/*.jsonl` file, in file name order.
    /// Empty lines are dropped.
    pub fn read_logs(&self) -> Result<Vec<LogLine>> {
        let dir = self.events_dir();
        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(Error::io(dir)(e)),
        };
        let mut files = Vec::new();
        for entry in entries {
            let entry = entry.map_err(Error::io(&dir))?;
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "jsonl") && path.is_file() {
                files.push(path);
            }
        }
        files.sort();
        let mut out = Vec::new();
        for path in files {
            let log = path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let bytes = fs::read(&path).map_err(Error::io(&path))?;
            let text = String::from_utf8_lossy(&bytes);
            for (i, line) in text.split('\n').enumerate() {
                if line.trim().is_empty() {
                    continue;
                }
                out.push(LogLine {
                    log: log.clone(),
                    line_no: i + 1,
                    text: line.to_string(),
                });
            }
        }
        Ok(out)
    }

    /// Appends complete lines to an actor's log with a single write, then
    /// syncs. A missing final newline left by an interrupted write is
    /// repaired first so lines never run together.
    pub fn append_lines(&self, actor: Ulid, lines: &[String]) -> Result<()> {
        if lines.is_empty() {
            return Ok(());
        }
        let dir = self.events_dir();
        fs::create_dir_all(&dir).map_err(Error::io(&dir))?;
        let path = self.log_path(actor);
        let mut f = OpenOptions::new()
            .create(true)
            .read(true)
            .append(true)
            .open(&path)
            .map_err(Error::io(&path))?;
        let mut buf = String::new();
        let len = f.metadata().map_err(Error::io(&path))?.len();
        if len > 0 {
            let mut last = [0u8; 1];
            f.seek(SeekFrom::End(-1)).map_err(Error::io(&path))?;
            f.read_exact(&mut last).map_err(Error::io(&path))?;
            if last[0] != b'\n' {
                buf.push('\n');
            }
        }
        for l in lines {
            debug_assert!(!l.contains('\n'));
            buf.push_str(l);
            buf.push('\n');
        }
        f.write_all(buf.as_bytes()).map_err(Error::io(&path))?;
        f.sync_all().map_err(Error::io(&path))
    }

    /// The names of all blobs present.
    pub fn blob_names(&self) -> Result<std::collections::BTreeSet<String>> {
        let dir = self.blobs_dir();
        let mut out = std::collections::BTreeSet::new();
        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
            Err(e) => return Err(Error::io(dir)(e)),
        };
        for entry in entries {
            let entry = entry.map_err(Error::io(&dir))?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if valid_blob_name(&name) {
                out.insert(name);
            }
        }
        Ok(out)
    }

    /// Stores `text` and returns its name. Existing blobs are not rewritten.
    pub fn put_blob(&self, text: &str, clock: &mut dyn Clock) -> Result<String> {
        let name = blob_name(text);
        let dir = self.blobs_dir();
        fs::create_dir_all(&dir).map_err(Error::io(&dir))?;
        let path = dir.join(&name);
        if path.exists() {
            return Ok(name);
        }
        let tmp = dir.join(format!(".tmp-{}", next_id(clock, None)));
        write_file_synced(&tmp, text.as_bytes())?;
        fs::rename(&tmp, &path).map_err(Error::io(&path))?;
        Ok(name)
    }

    pub fn get_blob(&self, name: &str) -> Result<String> {
        if !valid_blob_name(name) {
            return Err(Error::MissingBlob(name.to_string()));
        }
        let bytes =
            fs::read(self.blobs_dir().join(name)).map_err(|_| Error::MissingBlob(name.into()))?;
        String::from_utf8(bytes).map_err(|_| Error::MissingBlob(name.into()))
    }
}

/// The content address of a text: lowercase hex SHA-256 of its UTF-8 bytes.
pub fn blob_name(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}
