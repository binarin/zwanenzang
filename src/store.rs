//! The tracker directory: configuration, per-actor logs, blobs, and the
//! clone's actor id and lock, both kept in its git directory.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::clock::{Clock, next_id};
use crate::config::{CONFIG_FILE, Config};
use crate::error::{Error, Result};
use crate::git::{self, Repo};
use crate::names::valid_blob_name;
use crate::ulid::Ulid;

pub const GITATTRIBUTES_LINE: &str = "events/*.jsonl merge=union";
/// The git configuration key holding this clone's actor id.
pub const ACTOR_KEY: &str = "zwanenzang.actor";
/// The lock file, in the clone's git directory.
pub const LOCK_FILE: &str = "zwanenzang.lock";

/// One line read from a log file.
#[derive(Debug, Clone)]
pub struct LogLine {
    /// File stem of the log, which must be the writing actor.
    pub log: String,
    /// 1-based line number.
    pub line_no: usize,
    /// The line's text. For a line that is not valid UTF-8 this is a lossy
    /// rendering for display only, and `utf8` is false.
    pub text: String,
    /// Whether the line's bytes are valid UTF-8. Replay skips a line that
    /// is not as malformed.
    pub utf8: bool,
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

/// The tracker holding `dir` or its nearest existing ancestor, if any.
pub(crate) fn enclosing_tracker(dir: &Path) -> Option<PathBuf> {
    let mut probe = dir;
    while !probe.exists() {
        probe = match probe.parent() {
            Some(p) if !p.as_os_str().is_empty() => p,
            _ => Path::new("."),
        };
    }
    find_root(probe).ok()
}

/// Adds `line` to a text file unless the file already has it.
///
/// The new content is written to a temporary file, synced and renamed into
/// place, then the directory is synced: a crash leaves either the old file
/// or the complete new one, and the file is durable before anything written
/// after it.
fn ensure_line(path: &Path, line: &str) -> Result<()> {
    let (existing, permissions) = match fs::read_to_string(path) {
        Ok(s) => {
            let perms = fs::metadata(path).map_err(Error::io(path))?.permissions();
            (s, Some(perms))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (String::new(), None),
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
    let dir = path.parent().unwrap_or(Path::new("."));
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dir.join(format!(
        ".{file_name}.zwanenzang-tmp-{}",
        std::process::id()
    ));
    let mut f = File::create(&tmp).map_err(Error::io(&tmp))?;
    f.write_all(text.as_bytes()).map_err(Error::io(&tmp))?;
    if let Some(perms) = permissions {
        f.set_permissions(perms).map_err(Error::io(&tmp))?;
    }
    f.sync_all().map_err(Error::io(&tmp))?;
    drop(f);
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return Err(Error::io(path)(e));
    }
    sync_dir(dir)
}

/// Syncs a directory, so entries created or renamed in it survive a crash.
/// Syncing a file covers its data, not its name in the directory.
fn sync_dir(dir: &Path) -> Result<()> {
    File::open(dir)
        .and_then(|d| d.sync_all())
        .map_err(Error::io(dir))
}

/// Creates `dir` if missing; a newly created one is made durable in its
/// parent.
fn ensure_dir(dir: &Path) -> Result<()> {
    if dir.is_dir() {
        return Ok(());
    }
    fs::create_dir_all(dir).map_err(Error::io(dir))?;
    match dir.parent() {
        Some(p) => sync_dir(p),
        None => Ok(()),
    }
}

/// Writes a file and syncs both it and its directory entry.
fn write_file_synced(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut f = File::create(path).map_err(Error::io(path))?;
    f.write_all(bytes).map_err(Error::io(path))?;
    f.sync_all().map_err(Error::io(path))?;
    match path.parent() {
        Some(p) => sync_dir(p),
        None => Ok(()),
    }
}

/// Takes the exclusive lock file in the repository's git directory,
/// blocking until it is free.
pub fn lock_repo(repo: &Repo) -> Result<LockGuard> {
    let path = repo.git_dir.join(LOCK_FILE);
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(Error::io(&path))?;
    file.lock().map_err(Error::io(&path))?;
    Ok(LockGuard { file })
}

impl Tracker {
    /// Creates the local half of a tracker in `dir`: the repository on
    /// `branch`, the storage directories, `boilerplate` files (relative
    /// names with their contents), the configuration and the first commit.
    /// Publishing to a remote is [`crate::init`]'s half.
    ///
    /// Refused when `dir` is a tracker or lies inside one: a nested
    /// tracker would capture the upward search of every command run below
    /// it. `dir` becomes a git repository unless it already is the top of
    /// one; inside some other work tree it is refused, since a tracker is
    /// always its own repository.
    pub fn create_local(
        dir: &Path,
        name: &str,
        prefix: &str,
        branch: &str,
        boilerplate: &[(&str, String)],
        actor_name: Option<&str>,
        clock: &mut dyn Clock,
    ) -> Result<Tracker> {
        if let Some(existing) = enclosing_tracker(dir) {
            return Err(Error::AlreadyInitialized(existing));
        }
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
        // init is a mutating command and takes the lock like the others.
        // The checks above only spare a refused init from creating
        // anything; they are repeated under the lock, so of two concurrent
        // inits exactly one writes and the other is refused.
        let repo = match git::toplevel(&root)? {
            Some(top) if top == root => Repo::open(&root)?,
            Some(top) => return Err(Error::InsideRepository(root, top)),
            None => git::init(&root, branch)?,
        };
        let _lock = lock_repo(&repo)?;
        if let Some(existing) = enclosing_tracker(&root) {
            return Err(Error::AlreadyInitialized(existing));
        }
        for sub in ["events", "blobs"] {
            ensure_dir(&root.join(sub))?;
        }
        ensure_line(&root.join(".gitattributes"), GITATTRIBUTES_LINE)?;
        for (name, text) in boilerplate {
            write_file_synced(&root.join(name), text.as_bytes())?;
        }
        let tracker = Tracker { root, config };
        let actor = tracker.actor_in(&repo, true, clock)?.expect("created");
        // The configuration goes last: its presence is what marks the
        // directory as a tracker.
        write_file_synced(&config_path, tracker.config.to_toml().as_bytes())?;
        let identity = crate::sync::identity(actor, actor_name.map(str::to_string));
        let mut files = vec![PathBuf::from(CONFIG_FILE), PathBuf::from(".gitattributes")];
        files.extend(boilerplate.iter().map(|(name, _)| PathBuf::from(*name)));
        repo.commit(&files, "init", &identity)?;
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

    /// The tracker's repository; its root must be the top of a work tree.
    pub fn repo(&self) -> Result<Repo> {
        Repo::open(&self.root)
    }

    pub fn log_path(&self, actor: Ulid) -> PathBuf {
        self.events_dir().join(format!("{actor}.jsonl"))
    }

    /// Takes the exclusive tracker lock, blocking until it is free.
    pub fn lock(&self) -> Result<LockGuard> {
        lock_repo(&self.repo()?)
    }

    /// This clone's actor id, from the repository's local git
    /// configuration. With `create`, a missing id is generated and stored;
    /// without it, a missing id is `None`.
    pub fn actor_in(
        &self,
        repo: &Repo,
        create: bool,
        clock: &mut dyn Clock,
    ) -> Result<Option<Ulid>> {
        match repo.config_get(ACTOR_KEY)? {
            Some(text) => Ulid::parse_canonical(text.trim())
                .map(Some)
                .map_err(|e| Error::Config {
                    path: repo.git_dir.join("config"),
                    message: format!("{ACTOR_KEY}: {e}"),
                }),
            None if create => {
                let id = next_id(clock, None);
                repo.config_set(ACTOR_KEY, &id.to_string())?;
                Ok(Some(id))
            }
            None => Ok(None),
        }
    }

    /// This clone's actor id, or `None` when it has none yet or the tracker
    /// is not a repository (a copy, say). Creates nothing.
    pub fn actor_id_opt(&self, clock: &mut dyn Clock) -> Result<Option<Ulid>> {
        match self.repo() {
            Ok(repo) => self.actor_in(&repo, false, clock),
            Err(Error::NotARepository(_)) => Ok(None),
            Err(e) => Err(e),
        }
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
            // Decoded line by line and strictly, so distinct byte sequences
            // stay distinct text and an invalid line cannot pass as valid.
            for (i, line) in bytes.split(|&b| b == b'\n').enumerate() {
                let (text, utf8) = match std::str::from_utf8(line) {
                    Ok(t) => (t.to_string(), true),
                    Err(_) => (String::from_utf8_lossy(line).into_owned(), false),
                };
                if utf8 && text.trim().is_empty() {
                    continue;
                }
                out.push(LogLine {
                    log: log.clone(),
                    line_no: i + 1,
                    text,
                    utf8,
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
        ensure_dir(&dir)?;
        let path = self.log_path(actor);
        let is_new = !path.exists();
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
        f.sync_all().map_err(Error::io(&path))?;
        if is_new {
            // An actor's first write creates its log; its name in events/
            // must be durable too.
            sync_dir(&dir)?;
        }
        Ok(())
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
        ensure_dir(&dir)?;
        let path = dir.join(&name);
        if path.exists() {
            return Ok(name);
        }
        let tmp = dir.join(format!(".tmp-{}", next_id(clock, None)));
        write_file_synced(&tmp, text.as_bytes())?;
        fs::rename(&tmp, &path).map_err(Error::io(&path))?;
        // The rename must be durable before the event naming the blob is
        // appended, or a crash could leave the event without its blob.
        sync_dir(&dir)?;
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
