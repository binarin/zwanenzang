//! `render DIR`: a static, self-contained HTML site of a tracker.
//!
//! The page itself (`index.html`, `style.css`, `app.js`) is hand-written
//! under `site/` and embedded at build time; `--assets SRC` takes those
//! three files from a directory instead, so the page can be iterated on
//! without a rebuild. The tracker's content goes into `data.js`, one
//! script assignment, so the site opens from `file://` without a server.
//! Supporting files linked from comments are copied under `files/`.
//!
//! The output is a function of the replayed log and the assets alone: no
//! clock, no paths of this machine, every collection in a fixed order.
//! The tracker is only read. The output directory records the files it
//! generated in a manifest; a later run replaces and removes only those and
//! refuses to overwrite anything else.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::org::{self, LinkResolver};
use crate::replay::Replay;
use crate::state::Ticket;
use crate::store::Tracker;
use crate::ulid::Ulid;
use crate::view::View;

/// The page files, in the order a run writes them.
pub const ASSETS: &[(&str, &str)] = &[
    (
        "index.html",
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/site/index.html")),
    ),
    (
        "style.css",
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/site/style.css")),
    ),
    (
        "app.js",
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/site/app.js")),
    ),
];

/// The list of files a run generated, kept in the output directory.
pub const MANIFEST: &str = ".zwanenzang-render.json";
const GENERATOR: &str = "zwanenzang render";

/// Statuses whose chips start switched off, when the vocabulary has them.
const HIDDEN_BY_DEFAULT: &[&str] = &["done", "cancelled", "cncl"];

#[derive(Debug, Clone)]
pub struct Options {
    pub dir: PathBuf,
    /// A directory holding `index.html`, `style.css` and `app.js` to use
    /// instead of the embedded copies.
    pub assets: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    generator: String,
    files: Vec<String>,
}

/// Renders the site and returns the JSON result.
pub fn render(tracker: &Tracker, opts: &Options) -> Result<Value> {
    let dir = target_dir(&opts.dir)?;
    if dir.starts_with(&tracker.root) {
        return Err(Error::InsideTracker(dir));
    }
    let mut files: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for (name, text) in ASSETS {
        let bytes = match &opts.assets {
            None => text.as_bytes().to_vec(),
            Some(src) => {
                let p = src.join(name);
                fs::read(&p).map_err(Error::io(p))?
            }
        };
        files.insert(name.to_string(), bytes);
    }
    let rp = tracker.load()?;
    let site = Site::build(tracker, &rp)?;
    let mut script = String::from("window.ZWANENZANG_DATA = ");
    script.push_str(&script_json(&site.data));
    script.push_str(";\n");
    files.insert("data.js".into(), script.into_bytes());
    for (rel, bytes) in site.attachments {
        files.insert(rel, bytes);
    }
    let removed = write_output(&dir, &files)?;
    Ok(json!({
        "render": {
            "dir": dir,
            "assets": opts.assets.as_ref().map(|p| p.display().to_string()),
            "files": files.keys().collect::<Vec<_>>(),
            "removed": removed,
            "counts": site.counts,
        }
    }))
}

/// `dir` made absolute and canonical: the longest existing prefix resolved
/// through symlinks, the missing rest appended. A missing rest may only
/// name plain directories, so `..` cannot reach back into the tracker.
fn target_dir(dir: &Path) -> Result<PathBuf> {
    let abs = if dir.is_absolute() {
        dir.to_path_buf()
    } else {
        std::env::current_dir().map_err(Error::io("."))?.join(dir)
    };
    let mut missing: Vec<&std::ffi::OsStr> = Vec::new();
    let mut cur = abs.as_path();
    loop {
        match fs::canonicalize(cur) {
            Ok(real) => {
                let mut out = real;
                for part in missing.iter().rev() {
                    out.push(part);
                }
                return Ok(out);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let Some(name) = cur
                    .file_name()
                    .filter(|_| matches!(cur.components().next_back(), Some(Component::Normal(_))))
                else {
                    return Err(Error::InvalidArgument(format!(
                        "render directory {} must not use .. below a missing directory",
                        dir.display()
                    )));
                };
                missing.push(name);
                cur = cur.parent().expect("a missing path has a parent");
            }
            Err(e) => return Err(Error::io(cur)(e)),
        }
    }
}

/// JSON safe inside a `<script>`-loaded file and in any JavaScript parser:
/// no `<` (so no `</script>` or `<!--`), no raw line or paragraph
/// separators.
fn script_json(v: &Value) -> String {
    serde_json::to_string(v)
        .expect("JSON values serialize")
        .replace('<', "\\u003c")
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}

/// A relative output path: plain components joined by `/`.
fn valid_rel(rel: &str) -> bool {
    !rel.is_empty()
        && rel
            .split('/')
            .all(|c| !c.is_empty() && c != "." && c != "..")
        && Path::new(rel)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}

fn conflict(path: PathBuf, why: &str) -> Error {
    Error::RenderConflict(path, why.to_string())
}

/// Every existing component of `rel` below `dir` must be a real directory
/// (or, for the last, a regular file), never a symlink, so no write or
/// removal leaves `dir`.
fn check_no_symlinks(dir: &Path, rel: &str) -> Result<()> {
    let mut p = dir.to_path_buf();
    let parts: Vec<&str> = rel.split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        p.push(part);
        match fs::symlink_metadata(&p) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(Error::io(&p)(e)),
            Ok(m) if m.file_type().is_symlink() => {
                return Err(conflict(p, "is a symlink"));
            }
            Ok(m) if i + 1 < parts.len() && !m.is_dir() => {
                return Err(conflict(p, "is not a directory"));
            }
            Ok(m) if i + 1 == parts.len() && !m.is_file() => {
                return Err(conflict(p, "is not a regular file"));
            }
            Ok(_) => {}
        }
    }
    Ok(())
}

fn read_manifest(dir: &Path) -> Result<BTreeSet<String>> {
    let path = dir.join(MANIFEST);
    check_no_symlinks(dir, MANIFEST)?;
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeSet::new()),
        Err(e) => return Err(Error::io(path)(e)),
    };
    let m: Manifest = serde_json::from_str(&text)
        .map_err(|_| conflict(path.clone(), "is not a render manifest"))?;
    if m.generator != GENERATOR || !m.files.iter().all(|f| valid_rel(f) && f != MANIFEST) {
        return Err(conflict(path, "is not a render manifest"));
    }
    Ok(m.files.into_iter().collect())
}

fn write_manifest(dir: &Path, files: &BTreeSet<&str>) -> Result<()> {
    let text = serde_json::to_string_pretty(&json!({"generator": GENERATOR, "files": files}))
        .expect("JSON values serialize")
        + "\n";
    let path = dir.join(MANIFEST);
    fs::write(&path, text).map_err(Error::io(path))
}

/// Writes `files` into `dir` and removes files an earlier run generated
/// that are no longer part of the output. Returns the removed paths.
///
/// Every check runs before the first write. The manifest is written first
/// listing old and new files together, so an interrupted run leaves
/// nothing behind that the next run would take for someone else's file.
fn write_output(dir: &Path, files: &BTreeMap<String, Vec<u8>>) -> Result<Vec<String>> {
    if dir.exists() && !dir.is_dir() {
        return Err(conflict(dir.to_path_buf(), "is not a directory"));
    }
    let previous = if dir.exists() {
        read_manifest(dir)?
    } else {
        BTreeSet::new()
    };
    for rel in files.keys() {
        debug_assert!(valid_rel(rel), "{rel}");
        check_no_symlinks(dir, rel)?;
        if !previous.contains(rel) && fs::symlink_metadata(dir.join(rel)).is_ok() {
            return Err(conflict(
                dir.join(rel),
                "exists and was not generated by render",
            ));
        }
    }
    let stale: Vec<&String> = previous
        .iter()
        .filter(|rel| !files.contains_key(*rel))
        .collect();
    for rel in &stale {
        check_no_symlinks(dir, rel)?;
    }
    fs::create_dir_all(dir).map_err(Error::io(dir))?;
    let union: BTreeSet<&str> = files
        .keys()
        .map(String::as_str)
        .chain(previous.iter().map(String::as_str))
        .collect();
    write_manifest(dir, &union)?;
    for (rel, bytes) in files {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(Error::io(parent))?;
        }
        if fs::read(&path).ok().as_deref() != Some(bytes.as_slice()) {
            fs::write(&path, bytes).map_err(Error::io(&path))?;
        }
    }
    let mut removed = Vec::new();
    for rel in stale {
        let path = dir.join(rel);
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(Error::io(path)(e)),
        }
        // Directories only render created, emptied by this removal.
        let mut parent = path.parent();
        while let Some(p) = parent.filter(|p| *p != dir) {
            if fs::remove_dir(p).is_err() {
                break;
            }
            parent = p.parent();
        }
        removed.push(rel.clone());
    }
    write_manifest(dir, &files.keys().map(String::as_str).collect())?;
    Ok(removed)
}

/// Percent-encodes each segment of a relative path for an href.
fn href_path(rel: &str) -> String {
    let mut out = String::new();
    for b in rel.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

struct Site {
    data: Value,
    attachments: BTreeMap<String, Vec<u8>>,
    counts: Value,
}

struct Links<'a> {
    prefix: &'a str,
    /// Number to the ticket's display, for tickets in the output.
    tickets: &'a BTreeMap<u64, String>,
    /// `docs/...` path to its href.
    files: &'a BTreeMap<String, String>,
}

impl LinkResolver for Links<'_> {
    /// A number in any padding, `ZZ-12` or `ZZ-0012`, as `resolve` takes it.
    fn ticket(&self, reference: &str) -> Option<String> {
        let (p, digits) = reference.rsplit_once('-')?;
        if !p.eq_ignore_ascii_case(self.prefix) || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let n: u64 = digits.parse().ok()?;
        self.tickets.get(&n).map(|d| format!("#{d}"))
    }
    fn file(&self, path: &str) -> Option<String> {
        self.files.get(path).cloned()
    }
}

/// The supporting file a comment link names: the link's text and the
/// path below the tracker's `docs/`, when it is a file there.
fn attachment(root: &Path, link: &str) -> Option<String> {
    if link.contains("://") || link.starts_with('/') {
        return None;
    }
    let rel = link.strip_prefix("./").unwrap_or(link);
    let docs = fs::canonicalize(root.join("docs")).ok()?;
    let real = fs::canonicalize(root.join(rel)).ok()?;
    if !real.is_file() {
        return None;
    }
    let below = real.strip_prefix(&docs).ok()?;
    let parts: Option<Vec<&str>> = below.components().map(|c| c.as_os_str().to_str()).collect();
    let rel = parts?.join("/");
    valid_rel(&rel).then_some(rel)
}

fn priority_text(p: u8) -> String {
    if p.is_ascii_uppercase() {
        (p as char).to_string()
    } else {
        p.to_string()
    }
}

impl Site {
    fn build(tracker: &Tracker, rp: &Replay) -> Result<Site> {
        let view = View::new(tracker, rp);
        let state = &rp.state;
        let mut tickets: Vec<&Ticket> = state.tickets.values().filter(|t| !t.tombstoned).collect();
        // Published tickets by number, then unpublished ones by id.
        tickets.sort_by_key(|t| (t.number.is_none(), t.number, t.id));
        let order: BTreeMap<Ulid, usize> =
            tickets.iter().enumerate().map(|(i, t)| (t.id, i)).collect();
        let included = |id: &Ulid| order.contains_key(id);
        let ordered = |ids: &mut Vec<Ulid>| ids.sort_by_key(|id| order[id]);

        // Who wrote an event: its identity, else the writer's short id.
        let actor = |id: Ulid, identity: Option<&str>| -> String {
            match state.identity_of(id, identity) {
                Some(n) => n,
                None => id.to_canonical()[..10].to_string(),
            }
        };

        // Attachments first, so prose links to them resolve.
        let mut attachments: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        let mut file_links: BTreeMap<String, String> = BTreeMap::new();
        for t in &tickets {
            for c in &t.comments {
                let Some(link) = &c.link else { continue };
                if let Some(rel) = attachment(&tracker.root, link) {
                    let out = format!("files/{rel}");
                    if !attachments.contains_key(&out) {
                        let src = tracker.root.join("docs").join(&rel);
                        attachments.insert(out.clone(), fs::read(&src).map_err(Error::io(src))?);
                    }
                    let href = href_path(&out);
                    file_links.insert(link.clone(), href.clone());
                    file_links.insert(format!("docs/{rel}"), href);
                }
            }
        }
        let ticket_links: BTreeMap<u64, String> = tickets
            .iter()
            .filter_map(|t| t.number.map(|n| (n, view.display(t))))
            .collect();
        let links = Links {
            prefix: &tracker.config.prefix,
            tickets: &ticket_links,
            files: &file_links,
        };

        let mut documents = 0usize;
        let mut comments = 0usize;
        let mut tags: BTreeSet<&str> = BTreeSet::new();
        let mut used_statuses: BTreeSet<&str> = BTreeSet::new();
        let mut out = Vec::new();
        for t in &tickets {
            tags.extend(t.tags.iter().map(String::as_str));
            used_statuses.insert(&t.status);
            let mut children: Vec<Ulid> = tickets
                .iter()
                .filter(|c| c.parent == Some(t.id))
                .map(|c| c.id)
                .collect();
            ordered(&mut children);
            let mut depends_on: Vec<Ulid> = t.depends_on.iter().copied().filter(included).collect();
            ordered(&mut depends_on);
            let mut blocks: Vec<Ulid> = tickets
                .iter()
                .filter(|o| o.depends_on.contains(&t.id))
                .map(|o| o.id)
                .collect();
            ordered(&mut blocks);
            let mut related: Vec<Ulid> = t.related.iter().copied().filter(included).collect();
            ordered(&mut related);

            // The description first, the others by name.
            let mut docs: Vec<(&String, _)> = t
                .documents
                .iter()
                .filter_map(|(n, d)| d.current_version().map(|v| (n, v)))
                .collect();
            docs.sort_by_key(|(n, _)| (n.as_str() != "description", n.as_str()));
            let mut doc_values = Vec::new();
            for (name, v) in docs {
                let text = tracker.get_blob(&v.blob)?;
                doc_values.push(json!({
                    "name": name,
                    "actor": actor(v.actor, v.identity.as_deref()),
                    "ts": v.ts,
                    "html": org::to_html(&text, &links),
                    "text": text,
                }));
                documents += 1;
            }
            let mut comment_values = Vec::new();
            for c in &t.comments {
                let text = match (&c.text, &c.blob) {
                    (Some(text), _) => Some(text.clone()),
                    (None, Some(b)) => tracker.get_blob(b).ok(),
                    (None, None) => None,
                };
                let link = c.link.as_ref().map(|l| {
                    let href = file_links.get(l).cloned().or_else(|| {
                        let lower = l.to_ascii_lowercase();
                        (lower.starts_with("http://") || lower.starts_with("https://"))
                            .then(|| l.clone())
                    });
                    json!({"label": l, "href": href})
                });
                comment_values.push(json!({
                    "actor": actor(c.actor, c.identity.as_deref()),
                    "ts": c.ts,
                    "html": text.as_deref().map(|s| org::to_html(s, &links)),
                    "text": text,
                    "link": link,
                }));
                comments += 1;
            }
            let repo_url = |repo: &str| tracker.config.repos.get(repo).map(|r| r.url.clone());
            out.push(json!({
                "id": t.id,
                "display": view.display(t),
                "number": t.number,
                "title": t.title,
                "status": t.status,
                "kind": t.kind,
                "priority": t.priority.map(priority_text),
                "scheduled": t.scheduled.as_deref().map(crate::planning::display),
                "tags": t.tags,
                "parent": t.parent.filter(included),
                "children": children,
                "depends_on": depends_on,
                "blocks": blocks,
                "related": related,
                "archived": t.archived,
                "created": t.created.ts,
                "activity": t.activity.ts,
                "branches": t.branches.iter().map(|(repo, name)| json!({
                    "repo": repo, "name": name, "repo_url": repo_url(repo),
                })).collect::<Vec<_>>(),
                "mrs": t.mrs.iter().map(|(repo, url)| json!({
                    "repo": repo, "url": url,
                })).collect::<Vec<_>>(),
                "documents": doc_values,
                "comments": comment_values,
            }));
        }
        // One chip per current status, then the retired and unlisted ones
        // that tickets still have; a retired name nobody has gets no chip.
        let config = &tracker.config;
        let mut statuses: Vec<&str> = state
            .statuses
            .iter()
            .map(String::as_str)
            .filter(|s| !config.is_retired(s))
            .collect();
        for s in state.statuses.iter().map(String::as_str) {
            if config.is_retired(s) && used_statuses.contains(s) {
                statuses.push(s);
            }
        }
        for s in used_statuses {
            if !statuses.contains(&s) {
                statuses.push(s);
            }
        }
        let hidden: Vec<&str> = statuses
            .iter()
            .copied()
            .filter(|s| HIDDEN_BY_DEFAULT.contains(s))
            .collect();
        let counts = json!({
            "tickets": tickets.len(),
            "archived": tickets.iter().filter(|t| t.archived).count(),
            "documents": documents,
            "comments": comments,
            "attachments": attachments.len(),
        });
        let data = json!({
            "format": 1,
            "tracker": {
                "name": tracker.config.name,
                "prefix": tracker.config.prefix,
                "statuses": statuses,
                "hidden_statuses": hidden,
                "tags": tags,
            },
            "tickets": out,
        });
        Ok(Site {
            data,
            attachments,
            counts,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_json_cannot_end_a_script() {
        let s = script_json(&json!({"t": "</script><!-- \u{2028}"}));
        assert!(!s.contains('<'), "{s}");
        assert!(!s.contains('\u{2028}'));
        let back: Value = serde_json::from_str(&s).unwrap();
        assert_eq!(back["t"], "</script><!-- \u{2028}");
    }

    #[test]
    fn relative_output_paths() {
        assert!(valid_rel("files/a b/c.org"));
        for bad in ["", "/abs", "a/../b", "./a", "a//b", "a/"] {
            assert!(!valid_rel(bad), "{bad}");
        }
        assert_eq!(href_path("files/a b/ü#.org"), "files/a%20b/%C3%BC%23.org");
    }
}
