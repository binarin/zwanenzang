//! Import from the frozen ai-workflow tracker: a flat `tickets/` directory
//! of `PREFIX-NNNN-slug.md` files with YAML frontmatter, and a `docs/`
//! directory of supporting files beside it.
//!
//! The import is one live write through [`Tracker::write_with`], so every
//! event passes the same validation replay uses and the whole import is
//! written or none of it is. Which tickets to leave out is the caller's
//! decision, passed in; nothing here classifies tickets. The mapping is
//! recorded in the data model's list of milestone 2 choices.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use serde::Serialize;
use serde_json::{Value, json};

use crate::cli::INLINE_COMMENT_LIMIT;
use crate::clock::Clock;
use crate::config::IMPORT_IDENTITY;
use crate::error::{Error, Result};
use crate::event::{
    BranchData, CommentData, CreateData, DocData, MrData, Op, ParentData, RelateData, TagData,
};
use crate::frontmatter::{self, Field};
use crate::names::{valid_name, valid_title};
use crate::replay::Replay;
use crate::store::{Tracker, blob_name};
use crate::ulid::Ulid;
use crate::workflow::NEEDS_HUMAN_TAG;
use crate::write::{Plan, Target, WriteOptions};

/// First line of the provenance comment on every imported ticket, followed
/// by the original id. Re-runs find already imported tickets by it.
pub const MARKER: &str = "Imported from the ai-workflow tracker: ";

/// The document the ticket body after its title becomes.
pub const DESCRIPTION: &str = "description";

/// Status mapping from the frozen tracker's vocabulary, with the tag a
/// ticket also gets: a ticket waiting on the human or ready for their
/// review carries `needs_human`. Anything else is imported as `todo`, with
/// a warning.
pub const STATUS_MAP: &[(&str, &str, Option<&str>)] = &[
    ("draft", "todo", None),
    ("needs-triage", "todo", None),
    ("needs-plan", "todo", None),
    ("ready-for-implementation", "todo", None),
    ("ready-for-review", "revw", Some(NEEDS_HUMAN_TAG)),
    ("needs-human-input", "wait", Some(NEEDS_HUMAN_TAG)),
    ("done", "done", None),
];
const UNKNOWN_STATUS: &str = "todo";

/// Fields with no zwanenzang counterpart that are expected, so kept
/// verbatim in the provenance comment without a warning. Other unmapped
/// keys are kept the same way, with a warning.
const KEPT: &[&str] = &["handoff"];

#[derive(Debug, Clone, Default)]
pub struct Options {
    /// A tracker checkout (holding `tickets/`) or its `tickets/` directory.
    pub source: PathBuf,
    /// Original ids to leave out.
    pub exclude: BTreeSet<String>,
    /// Patterns of supporting files under `docs/` not to copy.
    pub exclude_docs: BTreeSet<String>,
    /// Repository alias renames, source alias to tracker alias.
    pub repo_aliases: BTreeMap<String, String>,
    pub dry_run: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Warning {
    pub source: Option<String>,
    pub code: &'static str,
    pub message: String,
}

fn warn(source: Option<&str>, code: &'static str, message: impl Into<String>) -> Warning {
    Warning {
        source: source.map(str::to_string),
        code,
        message: message.into(),
    }
}

/// One ticket file of the source tracker, read and mapped.
#[derive(Debug, Clone)]
pub struct SourceTicket {
    pub id: String,
    /// Path relative to the source root, such as `tickets/AB-0001-x.md`.
    pub file: String,
    pub title: String,
    pub title_from_heading: bool,
    pub source_status: Option<String>,
    pub status: String,
    /// A tag the mapped status implies.
    pub tag: Option<String>,
    pub description: String,
    pub related: Vec<String>,
    pub original: Option<String>,
    pub parent: Option<String>,
    /// (source repository alias, branch name)
    pub branches: Vec<(String, String)>,
    /// (source repository alias taken from the URL, URL)
    pub mrs: Vec<(String, String)>,
    /// Keys kept verbatim and their raw lines.
    pub kept: Vec<(String, String)>,
    /// Supporting files the description links to, relative to the source
    /// root, each under `docs/`.
    pub doc_links: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Source {
    pub root: PathBuf,
    pub tickets_dir: PathBuf,
    /// The source checkout's commit, when it is a git checkout.
    pub revision: Option<String>,
    pub tickets: Vec<SourceTicket>,
    pub warnings: Vec<Warning>,
}

/// `PREFIX-NNNN`: uppercase letters, a dash, four digits.
pub fn valid_ticket_id(s: &str) -> bool {
    match s.split_once('-') {
        Some((p, n)) => {
            !p.is_empty()
                && p.bytes().all(|b| b.is_ascii_uppercase())
                && n.len() == 4
                && n.bytes().all(|b| b.is_ascii_digit())
        }
        None => false,
    }
}

/// Splits `PREFIX-NNNN-slug.md` into id and slug.
fn parse_file_name(name: &str) -> Option<(&str, &str)> {
    let stem = name.strip_suffix(".md")?;
    let dash = stem.find('-')?;
    let id_end = dash + 5;
    if stem.len() <= id_end + 1 || stem.as_bytes()[id_end] != b'-' {
        return None;
    }
    let (id, slug) = (&stem[..id_end], &stem[id_end + 1..]);
    (valid_ticket_id(id) && slug.chars().any(char::is_alphanumeric)).then_some((id, slug))
}

/// The repository name in a forge merge request URL,
/// `https://HOST/OWNER/REPO/pulls/N`.
fn mr_repo(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    let parts: Vec<&str> = rest.split('/').collect();
    match parts.as_slice() {
        [host, owner, repo, "pulls", n]
            if !host.is_empty()
                && !owner.is_empty()
                && !repo.is_empty()
                && !n.is_empty()
                && n.bytes().all(|b| b.is_ascii_digit())
                && !n.starts_with('0') =>
        {
            Some(repo)
        }
        _ => None,
    }
}

fn map_status(s: Option<&str>) -> Option<(&'static str, Option<&'static str>)> {
    let s = s?;
    STATUS_MAP
        .iter()
        .find(|(from, ..)| *from == s)
        .map(|&(_, to, tag)| (to, tag))
}

/// The first `# ` heading outside fenced code: its line index and text.
fn find_title(body: &str) -> Option<(usize, String)> {
    let mut fence: Option<&str> = None;
    for (i, line) in body.lines().enumerate() {
        let t = line.trim_start();
        if let Some(f) = fence {
            if t.starts_with(f) {
                fence = None;
            }
            continue;
        }
        if t.starts_with("```") {
            fence = Some("```");
            continue;
        }
        if t.starts_with("~~~") {
            fence = Some("~~~");
            continue;
        }
        if let Some(rest) = line.strip_prefix("# ") {
            let title = rest.trim().trim_end_matches('#').trim_end();
            if !title.is_empty() {
                return Some((i, title.to_string()));
            }
        }
    }
    None
}

/// The body without the title line, trimmed of blank lines at both ends.
fn description(body: &str, title_line: Option<usize>) -> String {
    let lines: Vec<&str> = body
        .lines()
        .enumerate()
        .filter(|(i, _)| Some(*i) != title_line)
        .map(|(_, l)| l)
        .collect();
    let text = lines.join("\n");
    let text = text.trim_end();
    let text = text.trim_start_matches(['\n', '\r']);
    if text.trim().is_empty() {
        String::new()
    } else {
        format!("{text}\n")
    }
}

/// Link targets in markdown text: inline `](target)` and reference
/// definitions `[label]: target`.
fn link_targets(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(p) = rest.find("](") {
        rest = &rest[p + 2..];
        if let Some(end) = rest.find(')') {
            out.push(rest[..end].to_string());
        }
    }
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with('[')
            && let Some(p) = t.find("]:")
        {
            out.push(t[p + 2..].trim().to_string());
        }
    }
    out.into_iter()
        .filter_map(|t| {
            let t = t.trim();
            let t = match t.strip_prefix('<') {
                Some(rest) => rest.split('>').next()?,
                None => t.split_whitespace().next()?,
            };
            let t = t.split('#').next()?;
            (!t.is_empty() && !t.contains("://") && !t.starts_with("mailto:"))
                .then(|| t.to_string())
        })
        .collect()
}

/// Lexically normalizes `p`, resolving `.` and `..`.
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// Resolves a link in a ticket body to a supporting file under the
/// source's `docs/`: `Ok(Some(rel))` for an existing file, `Ok(None)` for a
/// link that does not point into `docs/`, `Err` for one into `docs/` that
/// is missing or escapes it.
fn resolve_doc_link(
    root: &Path,
    tickets_dir: &Path,
    target: &str,
) -> std::result::Result<Option<String>, String> {
    let resolved = normalize(&tickets_dir.join(target));
    let Ok(rel) = resolved.strip_prefix(root) else {
        return Ok(None);
    };
    if rel.components().next() != Some(Component::Normal("docs".as_ref())) {
        return Ok(None);
    }
    let rel_text = rel
        .to_str()
        .ok_or_else(|| format!("{target}: not a UTF-8 path"))?
        .to_string();
    let docs = fs::canonicalize(root.join("docs")).map_err(|e| format!("{rel_text}: {e}"))?;
    match fs::canonicalize(&resolved) {
        Ok(real) if real.starts_with(&docs) && real.is_file() => Ok(Some(rel_text)),
        Ok(_) => Err(format!("{rel_text} is not a file inside docs/")),
        Err(e) => Err(format!("{rel_text}: {e}")),
    }
}

fn list_of_ids(field: &Field, file: &str) -> Result<Vec<String>> {
    let items = match &field.value {
        frontmatter::Value::Null => Vec::new(),
        frontmatter::Value::List(v) => v.clone(),
        _ => {
            return Err(Error::InvalidSource(format!(
                "{file}: `{}` must be a list of ticket ids",
                field.key
            )));
        }
    };
    for id in &items {
        if !valid_ticket_id(id) {
            return Err(Error::InvalidSource(format!(
                "{file}: `{}` holds {id:?}, not a ticket id",
                field.key
            )));
        }
    }
    Ok(items)
}

fn one_id(field: &Field, file: &str) -> Result<Option<String>> {
    match &field.value {
        frontmatter::Value::Null => Ok(None),
        frontmatter::Value::Str(s) if valid_ticket_id(s) => Ok(Some(s.clone())),
        _ => Err(Error::InvalidSource(format!(
            "{file}: `{}` must be one ticket id",
            field.key
        ))),
    }
}

fn read_ticket(
    root: &Path,
    tickets_dir: &Path,
    path: &Path,
    id: &str,
    slug: &str,
    warnings: &mut Vec<Warning>,
) -> Result<SourceTicket> {
    let file = path
        .strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .into_owned();
    let text = fs::read(path).map_err(Error::io(path))?;
    let text = String::from_utf8(text)
        .map_err(|_| Error::InvalidSource(format!("{file}: not valid UTF-8")))?;
    let parsed =
        frontmatter::parse(&text).map_err(|e| Error::InvalidSource(format!("{file}: {e}")))?;
    let src = Some(id);
    if !parsed.has_frontmatter {
        warnings.push(warn(
            src,
            "no-frontmatter",
            format!("{file} has no frontmatter"),
        ));
    }

    let mut source_status = None;
    let mut related = Vec::new();
    let mut original = None;
    let mut parent = None;
    let mut branches = Vec::new();
    let mut mrs = Vec::new();
    let mut kept = Vec::new();
    for f in &parsed.fields {
        match f.key.as_str() {
            "status" => match &f.value {
                frontmatter::Value::Null => {}
                frontmatter::Value::Str(s) => source_status = Some(s.clone()),
                _ => {
                    return Err(Error::InvalidSource(format!(
                        "{file}: `status` must be a scalar"
                    )));
                }
            },
            "related" => related = list_of_ids(f, &file)?,
            "original-ticket" => original = one_id(f, &file)?,
            "parent" => parent = one_id(f, &file)?,
            "branches" => match &f.value {
                frontmatter::Value::Null => {}
                frontmatter::Value::Map(entries) => {
                    for (repo, name) in entries {
                        let Some(name) = name else {
                            return Err(Error::InvalidSource(format!(
                                "{file}: branch for repository {repo:?} is empty"
                            )));
                        };
                        branches.push((repo.clone(), name.clone()));
                    }
                }
                _ => {
                    return Err(Error::InvalidSource(format!(
                        "{file}: `branches` must map repositories to branch names"
                    )));
                }
            },
            "merge-requests" => {
                let urls = match &f.value {
                    frontmatter::Value::Null => Vec::new(),
                    frontmatter::Value::List(v) => v.clone(),
                    _ => {
                        return Err(Error::InvalidSource(format!(
                            "{file}: `merge-requests` must be a list of URLs"
                        )));
                    }
                };
                for url in urls {
                    let repo = mr_repo(&url).ok_or_else(|| {
                        Error::InvalidSource(format!(
                            "{file}: {url:?} is not a merge request URL \
                             https://HOST/OWNER/REPO/pulls/N"
                        ))
                    })?;
                    mrs.push((repo.to_string(), url.clone()));
                }
            }
            key => {
                if !KEPT.contains(&key) {
                    warnings.push(warn(
                        src,
                        "unknown-field",
                        format!("{file}: field `{key}` has no mapping; kept as text"),
                    ));
                }
                kept.push((key.to_string(), f.raw.clone()));
            }
        }
    }

    let (status, tag) = match map_status(source_status.as_deref()) {
        Some((s, tag)) => (s.to_string(), tag.map(str::to_string)),
        None => {
            let what = match &source_status {
                Some(s) => format!("status {s:?} is not in the ai-workflow vocabulary"),
                None => "no status".to_string(),
            };
            warnings.push(warn(
                src,
                "unknown-status",
                format!("{file}: {what}; imported as {UNKNOWN_STATUS}"),
            ));
            (UNKNOWN_STATUS.to_string(), None)
        }
    };

    let heading = find_title(&parsed.body);
    let (title, title_from_heading) = match &heading {
        Some((_, t)) => (t.clone(), true),
        None => {
            let t = slug.replace(['-', '_'], " ");
            warnings.push(warn(
                src,
                "no-title",
                format!("{file}: no `# ` heading; title taken from the file name"),
            ));
            (t, false)
        }
    };
    if !valid_title(&title) {
        return Err(Error::InvalidSource(format!(
            "{file}: title {title:?} is not a valid title"
        )));
    }
    let description = description(&parsed.body, heading.as_ref().map(|(i, _)| *i));

    let mut doc_links = Vec::new();
    for target in link_targets(&description) {
        match resolve_doc_link(root, tickets_dir, &target) {
            Ok(Some(rel)) => {
                if !doc_links.contains(&rel) {
                    doc_links.push(rel);
                }
            }
            Ok(None) => {}
            Err(e) => warnings.push(warn(
                src,
                "missing-doc-file",
                format!("{file} links to {e}; not copied"),
            )),
        }
    }

    Ok(SourceTicket {
        id: id.to_string(),
        file,
        title,
        title_from_heading,
        source_status,
        status,
        tag,
        description,
        related,
        original,
        parent,
        branches,
        mrs,
        kept,
        doc_links,
    })
}

/// Reads a tracker checkout or its tickets directory. Read-only.
pub fn read_source(path: &Path) -> Result<Source> {
    let path = fs::canonicalize(path).map_err(Error::io(path))?;
    let (root, tickets_dir) = if path.join("tickets").is_dir() {
        (path.clone(), path.join("tickets"))
    } else if path.is_dir() {
        let root = path.parent().map(Path::to_path_buf).unwrap_or(path.clone());
        (root, path.clone())
    } else {
        return Err(Error::InvalidSource(format!(
            "{} is not a directory",
            path.display()
        )));
    };
    let mut warnings = Vec::new();
    let mut entries: Vec<PathBuf> = fs::read_dir(&tickets_dir)
        .map_err(Error::io(&tickets_dir))?
        .map(|e| e.map(|e| e.path()).map_err(Error::io(&tickets_dir)))
        .collect::<Result<_>>()?;
    entries.sort();
    let mut tickets: Vec<SourceTicket> = Vec::new();
    for p in entries {
        let name = p
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let parsed = parse_file_name(&name);
        let Some((id, slug)) = parsed.filter(|_| p.is_file()) else {
            warnings.push(warn(
                None,
                "skipped-file",
                format!("tickets/{name} is not a PREFIX-NNNN-slug.md ticket file"),
            ));
            continue;
        };
        if let Some(other) = tickets.iter().find(|t| t.id == id) {
            return Err(Error::InvalidSource(format!(
                "{id} is both {} and tickets/{name}",
                other.file
            )));
        }
        let t = read_ticket(&root, &tickets_dir, &p, id, slug, &mut warnings)?;
        tickets.push(t);
    }
    tickets.sort_by(|a, b| a.id.cmp(&b.id));
    let revision = source_revision(&root, &mut warnings);
    Ok(Source {
        root,
        tickets_dir,
        revision,
        tickets,
        warnings,
    })
}

/// The commit of a source that is itself a git checkout, recorded as
/// provenance. Only read-only git commands run, and only when the source
/// root holds `.git`, so a source inside some other repository is never
/// attributed to that repository's history.
fn source_revision(root: &Path, warnings: &mut Vec<Warning>) -> Option<String> {
    if !root.join(".git").exists() {
        return None;
    }
    let git = |args: &[&str]| -> Option<String> {
        let out = Command::new("git")
            .arg("--no-optional-locks")
            .arg("-C")
            .arg(root)
            .args(args)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .output()
            .ok()?;
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    };
    let Some(rev) = git(&["rev-parse", "--verify", "HEAD"]) else {
        warnings.push(warn(
            None,
            "no-revision",
            "the source is a git checkout but its revision could not be read",
        ));
        return None;
    };
    match git(&["status", "--porcelain", "--", "tickets", "docs"]) {
        Some(s) if s.is_empty() => {}
        Some(_) => warnings.push(warn(
            None,
            "dirty-source",
            format!("tickets/ or docs/ differ from the recorded revision {rev}"),
        )),
        None => warnings.push(warn(None, "no-revision", "git status failed on the source")),
    }
    Some(rev)
}

/// A `docs/` path pattern: starts with `docs/`, no empty, `.` or `..`
/// segments.
fn valid_doc_pattern(s: &str) -> bool {
    s.starts_with("docs/")
        && s.split('/')
            .all(|seg| !seg.is_empty() && seg != "." && seg != "..")
}

/// Matches a path against a pattern where `*` stands for any run of
/// characters and `?` for one character, neither crossing a `/`.
pub fn doc_pattern_matches(pattern: &str, path: &str) -> bool {
    fn go(p: &[char], s: &[char]) -> bool {
        match p.split_first() {
            None => s.is_empty(),
            Some(('*', rest)) => {
                let mut i = 0;
                loop {
                    if go(rest, &s[i..]) {
                        return true;
                    }
                    if i == s.len() || s[i] == '/' {
                        return false;
                    }
                    i += 1;
                }
            }
            Some(('?', rest)) => matches!(s.first(), Some(c) if *c != '/') && go(rest, &s[1..]),
            Some((c, rest)) => s.first() == Some(c) && go(rest, &s[1..]),
        }
    }
    let p: Vec<char> = pattern.chars().collect();
    let s: Vec<char> = path.chars().collect();
    go(&p, &s)
}

impl Options {
    /// Adds one exclude entry: a ticket id such as `AIWF-0005`, or a
    /// pattern of supporting files such as `docs/*-review.md`.
    pub fn add_exclude(&mut self, entry: &str) -> Result<()> {
        let e = entry.trim();
        if e.is_empty() {
            return Ok(());
        }
        if e.starts_with("docs/") {
            if !valid_doc_pattern(e) {
                return Err(Error::InvalidArgument(format!(
                    "{e:?} is not a docs/ path pattern"
                )));
            }
            self.exclude_docs.insert(e.to_string());
        } else if valid_ticket_id(e) {
            self.exclude.insert(e.to_string());
        } else {
            return Err(Error::InvalidArgument(format!(
                "{e:?} is neither a ticket id nor a docs/ path pattern"
            )));
        }
        Ok(())
    }
}

/// Parses an exclude file: one entry per line (a ticket id or a `docs/`
/// pattern), `#` starts a comment.
pub fn parse_exclude_file(text: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let mut check = Options::default();
    for (i, line) in text.lines().enumerate() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        check
            .add_exclude(line)
            .map_err(|e| Error::InvalidArgument(format!("exclude file line {}: {e}", i + 1)))?;
        out.push(line.to_string());
    }
    Ok(out)
}

/// The provenance comment of a ticket.
fn provenance(t: &SourceTicket, revision: Option<&str>) -> String {
    let mut s = format!("{MARKER}{}\nSource file: {}\n", t.id, t.file);
    if let Some(r) = revision {
        s.push_str(&format!("Source revision: {r}\n"));
    }
    let tagged = t
        .tag
        .as_ref()
        .map_or(String::new(), |tag| format!(", tagged {tag}"));
    match &t.source_status {
        Some(st) => s.push_str(&format!(
            "Status there: {st} (imported as {}{tagged})\n",
            t.status
        )),
        None => s.push_str(&format!(
            "Status there: none (imported as {}{tagged})\n",
            t.status
        )),
    }
    if let Some(o) = &t.original {
        s.push_str(&format!("Original ticket: {o}\n"));
    }
    if !t.title_from_heading {
        s.push_str("Title: the file has no heading; taken from the file name\n");
    }
    if !t.kept.is_empty() {
        s.push_str("\nFrontmatter kept as text:\n\n");
        for (_, raw) in &t.kept {
            s.push_str(raw);
        }
    }
    s
}

/// Already imported tickets by original id, found by their provenance
/// comment. Tombstoned tickets do not count, so tombstoning an import is a
/// way to redo it.
fn already_imported(
    tracker: &Tracker,
    rp: &Replay,
    warnings: &mut Vec<Warning>,
) -> BTreeMap<String, Ulid> {
    let mut out: BTreeMap<String, Ulid> = BTreeMap::new();
    for t in rp.state.tickets.values().filter(|t| !t.tombstoned) {
        for c in &t.comments {
            let text = match (&c.text, &c.blob) {
                (Some(text), _) => Some(text.clone()),
                (None, Some(b)) => tracker.get_blob(b).ok(),
                _ => None,
            };
            let Some(text) = text else { continue };
            let Some(id) = text.lines().next().and_then(|l| l.strip_prefix(MARKER)) else {
                continue;
            };
            let id = id.trim().to_string();
            match out.get(&id) {
                Some(&other) if other != t.id => warnings.push(warn(
                    Some(&id),
                    "imported-twice",
                    format!(
                        "tickets {other} and {} both carry the import of {id}; using {other}",
                        t.id
                    ),
                )),
                Some(_) => {}
                None => {
                    out.insert(id, t.id);
                }
            }
        }
    }
    out
}

/// A clock that moves at least one millisecond per reading, so every
/// imported event, and so every imported ticket's id, has its own time
/// part and short ids stay at their 10-character minimum. Ids run ahead of
/// the wall clock by a few milliseconds per event at most.
struct Stepping<'a> {
    inner: &'a mut dyn Clock,
    last: u64,
}

impl Clock for Stepping<'_> {
    fn now_ms(&mut self) -> u64 {
        let n = self.inner.now_ms().max(self.last.saturating_add(1));
        self.last = n;
        n
    }

    fn random80(&mut self) -> u128 {
        self.inner.random80()
    }

    fn utc_offset_s(&mut self, ms: u64) -> i64 {
        self.inner.utc_offset_s(ms)
    }
}

#[derive(Debug, Default)]
struct Planned {
    new: Vec<usize>,
    already: Vec<(String, Ulid)>,
    excluded: Vec<String>,
    dropped: Vec<Value>,
    /// Supporting files to copy, by path relative to both roots: the
    /// tickets linking to each, and whether the tracker already holds the
    /// same content.
    docs: BTreeMap<String, (Vec<String>, bool)>,
    /// Linked supporting files left out by a pattern: the tickets linking
    /// to each and the first pattern that matched.
    dropped_docs: BTreeMap<String, (Vec<String>, String)>,
    warnings: Vec<Warning>,
}

fn copy_doc(src: &Path, dst: &Path) -> Result<()> {
    if let Some(dir) = dst.parent() {
        fs::create_dir_all(dir).map_err(Error::io(dir))?;
    }
    let bytes = fs::read(src).map_err(Error::io(src))?;
    let tmp = dst.with_extension("zwanenzang-import-tmp");
    fs::write(&tmp, &bytes).map_err(Error::io(&tmp))?;
    fs::rename(&tmp, dst).map_err(Error::io(dst))
}

/// Runs an import into `tracker` and returns its JSON report.
pub fn import(tracker: &Tracker, clock: &mut dyn Clock, opts: &Options) -> Result<Value> {
    let source = read_source(&opts.source)?;
    let mut check = Options::default();
    for e in opts.exclude.iter().chain(&opts.exclude_docs) {
        check.add_exclude(e)?;
    }
    let doc_excluded = |rel: &str| {
        opts.exclude_docs
            .iter()
            .find(|pat| doc_pattern_matches(pat, rel))
            .cloned()
    };
    let by_id: BTreeMap<&str, usize> = source
        .tickets
        .iter()
        .enumerate()
        .map(|(i, t)| (t.id.as_str(), i))
        .collect();
    let alias = |a: &str| {
        opts.repo_aliases
            .get(a)
            .cloned()
            .unwrap_or_else(|| a.to_string())
    };

    let planned = RefCell::new(Planned::default());
    let mut stepping = Stepping {
        inner: clock,
        last: 0,
    };
    let write_opts = WriteOptions {
        // Every run writes as a fresh writer with the reserved identity,
        // which also numbers the imported tickets; the tracker's `actors`
        // list need not name it.
        actor_name: Some(IMPORT_IDENTITY),
        new_actor: true,
        dry_run: opts.dry_run,
        message: Some("import from the ai-workflow tracker"),
    };
    let written = tracker.write_with(
        &mut stepping,
        write_opts,
        |rp| {
            let mut p = planned.borrow_mut();
            p.warnings = source.warnings.clone();
            for id in &opts.exclude {
                if !by_id.contains_key(id.as_str()) {
                    p.warnings.push(warn(
                        Some(id),
                        "unknown-exclude",
                        format!("{id} is excluded but not in the source"),
                    ));
                }
            }
            let mut already_warnings = Vec::new();
            let existing = already_imported(tracker, rp, &mut already_warnings);
            p.warnings.extend(already_warnings);

            // Where each original id ends up: a new ticket (by its create
            // index) or one imported earlier.
            let mut place: BTreeMap<&str, Target> = BTreeMap::new();
            for (i, t) in source.tickets.iter().enumerate() {
                if opts.exclude.contains(&t.id) {
                    p.excluded.push(t.id.clone());
                    if let Some(u) = existing.get(&t.id) {
                        p.warnings.push(warn(
                            Some(&t.id),
                            "excluded-but-imported",
                            format!(
                                "{} is excluded but was imported earlier as {u}; left as it is",
                                t.id
                            ),
                        ));
                    }
                } else if let Some(&u) = existing.get(&t.id) {
                    p.already.push((t.id.clone(), u));
                    place.insert(&t.id, Target::Entity(u));
                } else {
                    place.insert(&t.id, Target::Nth(p.new.len()));
                    p.new.push(i);
                }
            }

            // Every repository alias must be declared, so lint stays clean.
            let mut undeclared = BTreeSet::new();
            for &i in &p.new {
                let t = &source.tickets[i];
                for a in t
                    .branches
                    .iter()
                    .map(|b| &b.0)
                    .chain(t.mrs.iter().map(|m| &m.0))
                {
                    let a = alias(a);
                    if !valid_name(&a) || !tracker.config.repos.contains_key(&a) {
                        undeclared.insert(a);
                    }
                }
            }
            if !undeclared.is_empty() {
                return Err(Error::UndeclaredRepo(
                    undeclared.into_iter().collect::<Vec<_>>().join(", "),
                ));
            }

            // Supporting files: refuse to overwrite different content.
            let mut docs: BTreeMap<String, (Vec<String>, bool)> = BTreeMap::new();
            let mut dropped_docs: BTreeMap<String, (Vec<String>, String)> = BTreeMap::new();
            for &i in &p.new {
                let t = &source.tickets[i];
                for rel in &t.doc_links {
                    if let Some(pat) = doc_excluded(rel) {
                        dropped_docs
                            .entry(rel.clone())
                            .or_insert_with(|| (Vec::new(), pat))
                            .0
                            .push(t.id.clone());
                        continue;
                    }
                    if let Some((from, _)) = docs.get_mut(rel) {
                        from.push(t.id.clone());
                        continue;
                    }
                    let dst = tracker.root.join(rel);
                    let src = source.root.join(rel);
                    let existing = match fs::symlink_metadata(&dst) {
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
                        Err(e) => return Err(Error::io(&dst)(e)),
                        Ok(m) if !m.is_file() => return Err(Error::DocConflict(dst)),
                        Ok(_) => {
                            let ours = fs::read(&dst).map_err(Error::io(&dst))?;
                            let theirs = fs::read(&src).map_err(Error::io(&src))?;
                            if ours != theirs {
                                return Err(Error::DocConflict(dst));
                            }
                            true
                        }
                    };
                    docs.insert(rel.clone(), (vec![t.id.clone()], existing));
                }
            }
            p.docs = docs;
            p.dropped_docs = dropped_docs;
            if !p.new.is_empty() {
                let linked: Vec<&String> = p
                    .new
                    .iter()
                    .flat_map(|&i| &source.tickets[i].doc_links)
                    .collect();
                for pat in &opts.exclude_docs {
                    if !linked.iter().any(|rel| doc_pattern_matches(pat, rel)) {
                        p.warnings.push(warn(
                            None,
                            "unknown-exclude",
                            format!("{pat} matches no file linked from an imported ticket"),
                        ));
                    }
                }
            }

            let mut plan = Plan::default();
            let revision = source.revision.as_deref();
            for (k, &i) in p.new.iter().enumerate() {
                let t = &source.tickets[i];
                let me = Target::Nth(k);
                plan.ops.push((
                    Target::Created,
                    Op::Create(CreateData {
                        title: t.title.clone(),
                        status: t.status.clone(),
                        kind: None,
                    }),
                ));
                if let Some(tag) = &t.tag {
                    plan.ops.push((me, Op::Tag(TagData { tag: tag.clone() })));
                }
                if !t.description.is_empty() {
                    plan.ops.push((
                        me,
                        Op::Doc(DocData {
                            name: DESCRIPTION.into(),
                            blob: blob_name(&t.description),
                            base: None,
                        }),
                    ));
                    plan.blobs.push(t.description.clone());
                }
                let prov = provenance(t, revision);
                let comment = if prov.len() > INLINE_COMMENT_LIMIT {
                    let c = CommentData {
                        text: None,
                        blob: Some(blob_name(&prov)),
                        link: None,
                    };
                    plan.blobs.push(prov);
                    c
                } else {
                    CommentData {
                        text: Some(prov),
                        blob: None,
                        link: None,
                    }
                };
                plan.ops.push((me, Op::Comment(comment)));
                for rel in t.doc_links.iter().filter(|r| doc_excluded(r).is_none()) {
                    plan.ops.push((
                        me,
                        Op::Comment(CommentData {
                            text: Some(format!(
                                "Supporting file linked from the imported description: {rel}"
                            )),
                            blob: None,
                            link: Some(rel.clone()),
                        }),
                    ));
                }
                for (repo, name) in &t.branches {
                    plan.ops.push((
                        me,
                        Op::Branch(BranchData {
                            repo: alias(repo),
                            name: name.clone(),
                        }),
                    ));
                }
                for (repo, url) in &t.mrs {
                    plan.ops.push((
                        me,
                        Op::Mr(MrData {
                            repo: alias(repo),
                            url: url.clone(),
                        }),
                    ));
                }
            }

            // Relations among imported tickets, new or earlier, written
            // when at least one end is new; references that leave the
            // imported set are dropped and reported.
            let mut pairs: BTreeSet<(&str, &str)> = BTreeSet::new();
            let new_ids: BTreeSet<&str> = p
                .new
                .iter()
                .map(|&i| source.tickets[i].id.as_str())
                .collect();
            let mut dropped = Vec::new();
            for t in &source.tickets {
                if !place.contains_key(t.id.as_str()) {
                    continue;
                }
                let refs = t
                    .related
                    .iter()
                    .map(|r| ("related", r))
                    .chain(t.original.iter().map(|r| ("original-ticket", r)));
                for (field, r) in refs {
                    let reason = if *r == t.id {
                        Some("self")
                    } else if opts.exclude.contains(r) {
                        Some("excluded")
                    } else if !by_id.contains_key(r.as_str()) {
                        Some("missing")
                    } else {
                        None
                    };
                    match reason {
                        Some(reason) => {
                            if new_ids.contains(t.id.as_str()) {
                                dropped.push(json!({"source": t.id, "field": field,
                                                    "target": r, "reason": reason}));
                            }
                        }
                        None => {
                            let (a, b) = if t.id.as_str() < r.as_str() {
                                (t.id.as_str(), r.as_str())
                            } else {
                                (r.as_str(), t.id.as_str())
                            };
                            if new_ids.contains(a) || new_ids.contains(b) {
                                pairs.insert((a, b));
                            }
                        }
                    }
                }
            }
            for (a, b) in pairs {
                // Name the new end as the entity, so earlier imports are
                // only touched through the relation's other side.
                let (from, to) = if new_ids.contains(a) { (a, b) } else { (b, a) };
                plan.refs.push((plan.ops.len(), place[to]));
                plan.ops
                    .push((place[from], Op::Relate(RelateData { to: Ulid(0) })));
            }
            for t in &source.tickets {
                let Some(r) = &t.parent else { continue };
                let Some(&me) = place.get(t.id.as_str()) else {
                    continue;
                };
                let reason = if *r == t.id {
                    Some("self")
                } else if opts.exclude.contains(r) {
                    Some("excluded")
                } else if !by_id.contains_key(r.as_str()) {
                    Some("missing")
                } else {
                    None
                };
                let is_new = new_ids.contains(t.id.as_str());
                match reason {
                    Some(reason) => {
                        if is_new {
                            dropped.push(json!({"source": t.id, "field": "parent",
                                                "target": r, "reason": reason}));
                        }
                    }
                    None => {
                        // An earlier import keeps whatever parent it has
                        // now; it only gains one it could not have before.
                        let parent_new = new_ids.contains(r.as_str());
                        let unset = match me {
                            Target::Entity(u) => rp.state.tickets[&u].parent.is_none(),
                            _ => true,
                        };
                        if (is_new || parent_new) && unset {
                            plan.refs.push((plan.ops.len(), place[r.as_str()]));
                            plan.ops.push((me, Op::Parent(ParentData { to: None })));
                        }
                    }
                }
            }
            p.dropped = dropped;
            Ok(plan)
        },
        |_| {
            let p = planned.borrow();
            let mut copied = Vec::new();
            for (rel, (_, existing)) in &p.docs {
                if !existing {
                    copy_doc(&source.root.join(rel), &tracker.root.join(rel))?;
                    copied.push(PathBuf::from(rel));
                }
            }
            Ok(copied)
        },
    )?;

    let p = planned.into_inner();
    let created: Vec<Ulid> = written
        .events
        .iter()
        .filter(|e| matches!(e.op, Op::Create(_)))
        .map(|e| e.id)
        .collect();
    let imported: Vec<Value> = p
        .new
        .iter()
        .enumerate()
        .map(|(k, &i)| {
            let t = &source.tickets[i];
            let id = (!opts.dry_run).then(|| created.get(k).copied()).flatten();
            json!({
                "source": t.id,
                "file": t.file,
                "id": id,
                "title": t.title,
                "status": t.status,
                "tags": t.tag.iter().collect::<Vec<_>>(),
                "source_status": t.source_status,
                "kept_fields": t.kept.iter().map(|(k, _)| k).collect::<Vec<_>>(),
            })
        })
        .collect();
    let excluded: Vec<Value> = p
        .excluded
        .iter()
        .map(|id| json!({"source": id, "file": source.tickets[by_id[id.as_str()]].file}))
        .collect();
    let already: Vec<Value> = p
        .already
        .iter()
        .map(|(s, u)| json!({"source": s, "id": u}))
        .collect();
    let docs: Vec<Value> = p
        .docs
        .iter()
        .map(|(rel, (from, existing))| json!({"path": rel, "linked_from": from, "existing": existing}))
        .collect();
    let dropped_docs: Vec<Value> = p
        .dropped_docs
        .iter()
        .map(|(rel, (from, pat))| json!({"path": rel, "linked_from": from, "pattern": pat}))
        .collect();
    let actor = written
        .events
        .first()
        .map(|e| e.actor)
        .filter(|_| !opts.dry_run);
    Ok(json!({
        "dry_run": opts.dry_run,
        "source": {
            "root": source.root,
            "tickets": source.tickets_dir,
            "revision": source.revision,
        },
        "actor": actor,
        "identity": actor.map(|_| IMPORT_IDENTITY),
        "events": written.events.len(),
        "imported": imported,
        "already_imported": already,
        "excluded": excluded,
        "dropped_references": p.dropped,
        "docs": docs,
        "dropped_docs": dropped_docs,
        "warnings": p.warnings,
        "sync": written.sync,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_names() {
        assert_eq!(parse_file_name("AB-0001-x.md"), Some(("AB-0001", "x")));
        assert_eq!(parse_file_name("AB-0001-x!.md"), Some(("AB-0001", "x!")));
        for bad in [
            "AB-0001.md",
            "AB-001-x.md",
            "AB-00010-x.md",
            "AB-0001---.md",
            "ab-0001-x.md",
            "AB-0001-x.txt",
        ] {
            assert_eq!(parse_file_name(bad), None, "{bad}");
        }
    }

    #[test]
    fn merge_request_urls() {
        assert_eq!(mr_repo("https://forge.example/o/app/pulls/7"), Some("app"));
        for bad in [
            "http://forge.example/o/app/pulls/7",
            "https://forge.example/o/app/pulls/07",
            "https://forge.example/o/app/issues/7",
            "https://forge.example/app/pulls/7",
            "https://forge.example/o/app/pulls/7/files",
        ] {
            assert_eq!(mr_repo(bad), None, "{bad}");
        }
    }

    #[test]
    fn titles_skip_fenced_code() {
        let body = "\n```\n# not a title\n```\n# Real title #\n\ntext\n";
        assert_eq!(find_title(body), Some((4, "Real title".into())));
        assert_eq!(
            description(body, Some(4)),
            "```\n# not a title\n```\n\ntext\n"
        );
        assert_eq!(find_title("## only a subheading\n"), None);
    }

    #[test]
    fn links() {
        let t = "See [a](../docs/a.md#x) and [b](<../docs/b c.md> \"t\"), [w](https://x/y), [s](#sec)\n[r]: ../docs/r.md\n";
        assert_eq!(
            link_targets(t),
            vec!["../docs/a.md", "../docs/b c.md", "../docs/r.md"]
        );
    }

    #[test]
    fn exclude_files() {
        let ids = parse_exclude_file("# leave out\nAB-0001\n\n  AB-0002  # why\n").unwrap();
        assert_eq!(ids, vec!["AB-0001", "AB-0002"]);
        assert!(parse_exclude_file("AB-1\n").is_err());
        let mixed = parse_exclude_file("AB-0001\ndocs/*-review.md # reviews\n").unwrap();
        assert_eq!(mixed, vec!["AB-0001", "docs/*-review.md"]);
        for bad in ["docs/../x", "docs//x", "docs/", "other/x.md"] {
            assert!(parse_exclude_file(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn doc_patterns() {
        assert!(doc_pattern_matches("docs/a.md", "docs/a.md"));
        assert!(doc_pattern_matches(
            "docs/*-review.md",
            "docs/X-1-code-review.md"
        ));
        assert!(doc_pattern_matches("docs/X-000?-*", "docs/X-0003-plan.md"));
        assert!(doc_pattern_matches("docs/*/*.md", "docs/sub/a.md"));
        assert!(!doc_pattern_matches("docs/*.md", "docs/sub/a.md"));
        assert!(!doc_pattern_matches("docs/a.md", "docs/a.md.bak"));
        assert!(!doc_pattern_matches("docs/?", "docs/ab"));
    }
}
