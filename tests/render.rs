//! `render` over synthetic disposable trackers only. Output goes to
//! separate disposable directories, never into a tracker.
mod common;

use std::collections::BTreeMap;
use std::path::Path;

use common::*;
use serde_json::Value;

fn render(tracker: &Path, out: &Path, extra: &[&str]) -> Value {
    let mut args = vec!["render", out.to_str().unwrap()];
    args.extend_from_slice(extra);
    ok(tracker, &args)
}

/// The value data.js assigns.
fn data(out: &Path) -> Value {
    let text = std::fs::read_to_string(out.join("data.js")).unwrap();
    let json = text
        .strip_prefix("window.ZWANENZANG_DATA = ")
        .and_then(|t| t.strip_suffix(";\n"))
        .expect("data.js is one assignment");
    serde_json::from_str(json).unwrap()
}

fn ticket<'a>(data: &'a Value, id: &str) -> &'a Value {
    data["tickets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == id)
        .unwrap_or_else(|| panic!("{id} not in data.js"))
}

/// Every file below `dir`, by relative path.
fn tree(dir: &Path) -> BTreeMap<String, Vec<u8>> {
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<String, Vec<u8>>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                walk(root, &p, out);
            } else {
                let rel = p.strip_prefix(root).unwrap().to_str().unwrap().to_string();
                out.insert(rel, std::fs::read(&p).unwrap());
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, dir, &mut out);
    out
}

/// A tracker with a parent and child, an archived and a tombstoned
/// ticket, documents, comments and a linked supporting file.
struct Fixture {
    dir: tempfile::TempDir,
    parent: String,
    child: String,
    archived: String,
    gone: String,
}

fn fixture() -> Fixture {
    let dir = tracker();
    let p = dir.path();
    let parent = id(&ok(p, &["create", "Parent <ticket>", "--kind", "feature"]));
    let child = id(&ok(
        p,
        &["create", "Child", "--parent", &parent, "--tag", "ui"],
    ));
    let archived = id(&ok(p, &["create", "Old one"]));
    let gone = id(&ok(p, &["create", "Mistake"]));
    ok_stdin(
        p,
        &["doc", "set", &parent, "description", "--base", "none"],
        "* Goal\nSee ZZ-0002, ZZ-3, ZZ-0004 and *this*.\n",
    );
    // Written as another identity through the same clone's writer.
    let plan = run_as(
        p,
        Some("agent"),
        &["doc", "set", &parent, "plan", "--base", "none"],
        "- step one\n- step two\n",
        &[],
    );
    assert_eq!(plan.code, 0, "{}", plan.json);
    write_file(p, "docs/notes.org", "* Supporting notes\n");
    git(p, &["add", "docs/notes.org"]);
    git(p, &["commit", "-q", "-m", "notes"]);
    ok(
        p,
        &[
            "comment",
            &parent,
            "Notes attached",
            "--link",
            "docs/notes.org",
        ],
    );
    let upstream = run_as(
        p,
        Some("agent"),
        &[
            "comment",
            &parent,
            "Upstream",
            "--link",
            "https://example.invalid/x",
        ],
        "",
        &[],
    );
    assert_eq!(upstream.code, 0, "{}", upstream.json);
    ok(p, &["comment", &gone, "Linked from a tombstoned ticket"]);
    ok(p, &["depend", &child, &parent]);
    ok(p, &["schedule", &child, "2026-12-03", "10:00", "+1w"]);
    ok(p, &["status", &archived, "done"]);
    ok(p, &["archive", &archived]);
    ok(p, &["tombstone", &gone]);
    Fixture {
        dir,
        parent,
        child,
        archived,
        gone,
    }
}

#[test]
fn writes_the_site_with_tickets_documents_and_comments() {
    let f = fixture();
    let p = f.dir.path();
    let out = disposable_dir();
    let logs_before = logs(p);
    let head_before = git(p, &["rev-parse", "HEAD"]);
    let result = render(p, out.path(), &[]);
    // Read-only on the tracker.
    assert_eq!(logs(p), logs_before);
    assert_eq!(git(p, &["rev-parse", "HEAD"]), head_before);
    assert_eq!(git(p, &["status", "--porcelain"]), "");

    let r = &result["render"];
    assert_eq!(
        r["files"],
        serde_json::json!([
            "app.js",
            "data.js",
            "files/notes.org",
            "index.html",
            "style.css"
        ])
    );
    assert_eq!(r["counts"]["tickets"], 3);
    assert_eq!(r["counts"]["archived"], 1);
    assert_eq!(r["counts"]["documents"], 2);
    assert_eq!(r["counts"]["comments"], 2);
    assert_eq!(r["counts"]["attachments"], 1);
    assert_eq!(r["removed"], serde_json::json!([]));
    for name in ["index.html", "style.css", "app.js"] {
        assert!(out.path().join(name).is_file(), "{name}");
    }
    assert_eq!(
        std::fs::read_to_string(out.path().join("files/notes.org")).unwrap(),
        "* Supporting notes\n"
    );

    let d = data(out.path());
    assert_eq!(d["tracker"]["name"], "Test");
    assert_eq!(
        d["tracker"]["statuses"],
        serde_json::json!(["todo", "next", "wait", "agnt", "revw", "done", "cncl"])
    );
    assert_eq!(
        d["tracker"]["hidden_statuses"],
        serde_json::json!(["done", "cncl"])
    );
    assert_eq!(d["tracker"]["tags"], serde_json::json!(["ui"]));
    let ids: Vec<&str> = d["tickets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, [&f.parent, &f.child, &f.archived]);
    assert!(!ids.contains(&f.gone.as_str()));

    let parent = ticket(&d, &f.parent);
    assert_eq!(parent["display"], "ZZ-1");
    assert_eq!(parent["title"], "Parent <ticket>");
    assert_eq!(parent["kind"], "feature");
    assert_eq!(parent["children"], serde_json::json!([f.child]));
    assert_eq!(parent["blocks"], serde_json::json!([f.child]));
    let docs = parent["documents"].as_array().unwrap();
    assert_eq!(docs[0]["name"], "description");
    assert_eq!(docs[0]["actor"], "tester");
    // Ticket numbers link in any padding to the unpadded display; a
    // tombstoned ticket's does not.
    assert_eq!(
        docs[0]["html"],
        "<h3>Goal</h3>\n<p>See <a class=\"ticket-ref\" href=\"#ZZ-2\">ZZ-0002</a>, \
         <a class=\"ticket-ref\" href=\"#ZZ-3\">ZZ-3</a>, ZZ-0004 \
         and <strong>this</strong>.</p>\n"
    );
    assert_eq!(docs[1]["name"], "plan");
    // The identity of the write, not the writer's declared name.
    assert_eq!(docs[1]["actor"], "agent");
    let comments = parent["comments"].as_array().unwrap();
    assert_eq!(comments[0]["actor"], "tester");
    assert_eq!(comments[0]["text"], "Notes attached");
    assert_eq!(comments[0]["link"]["label"], "docs/notes.org");
    assert_eq!(comments[0]["link"]["href"], "files/notes.org");
    assert_eq!(comments[1]["link"]["href"], "https://example.invalid/x");
    assert_eq!(comments[1]["actor"], "agent");

    let child = ticket(&d, &f.child);
    assert_eq!(child["parent"], f.parent.as_str());
    assert_eq!(child["depends_on"], serde_json::json!([f.parent]));
    assert_eq!(child["tags"], serde_json::json!(["ui"]));
    // The date as Org shows it, with an English weekday.
    assert_eq!(child["scheduled"], "2026-12-03 Thu 10:00 +1w");
    assert_eq!(parent["scheduled"], Value::Null);
    assert_eq!(ticket(&d, &f.archived)["archived"], true);
    assert_eq!(ticket(&d, &f.archived)["status"], "done");

    // Nothing in data.js can close a script element.
    let raw = std::fs::read_to_string(out.path().join("data.js")).unwrap();
    assert!(!raw.contains('<'));
}

#[test]
fn the_same_log_gives_byte_identical_output() {
    let f = fixture();
    let p = f.dir.path();
    let a = disposable_dir();
    let b = disposable_dir();
    render(p, a.path(), &[]);
    render(p, &b.path().join("nested/site"), &[]);
    let first = tree(a.path());
    assert_eq!(first, tree(&b.path().join("nested/site")));
    // Rendering again over its own output changes nothing.
    let again = render(p, a.path(), &[]);
    assert_eq!(again["render"]["removed"], serde_json::json!([]));
    assert_eq!(tree(a.path()), first);
}

#[test]
fn refuses_a_directory_inside_the_tracker() {
    let f = fixture();
    let p = f.dir.path();
    for target in [p.join("site"), p.join("docs"), p.to_path_buf()] {
        let o = run_in(p, &["render", target.to_str().unwrap()], "");
        assert_eq!(o.code, 1, "{}", o.json);
        assert_eq!(o.json["error"]["code"], "inside-tracker");
    }
    assert!(!p.join("site").exists());
    assert!(!p.join("docs/index.html").exists());
    assert_eq!(git(p, &["status", "--porcelain"]), "");
    // `..` below a missing directory is refused rather than resolved.
    let out = disposable_dir();
    let sneaky = out.path().join("missing/..").join(p.file_name().unwrap());
    let o = run_in(p, &["render", sneaky.to_str().unwrap()], "");
    assert_eq!(o.json["error"]["code"], "invalid-argument", "{}", o.json);
}

#[test]
fn replaces_only_files_it_generated() {
    let f = fixture();
    let p = f.dir.path();
    let out = disposable_dir();
    write_file(out.path(), "index.html", "mine");
    let o = run_in(p, &["render", out.path().to_str().unwrap()], "");
    assert_eq!(o.json["error"]["code"], "render-conflict", "{}", o.json);
    assert_eq!(read(out.path(), "index.html"), "mine");
    assert!(!out.path().join("data.js").exists());

    // Unrelated files beside the output are left alone.
    let out = disposable_dir();
    write_file(out.path(), "README", "keep");
    render(p, out.path(), &[]);
    assert_eq!(read(out.path(), "README"), "keep");

    // A generated file that is no longer part of the output is removed:
    // here the only comment linking it is on a ticket tombstoned since.
    let t = id(&ok(p, &["create", "Has an attachment"]));
    write_file(p, "docs/sub/extra.txt", "extra");
    ok(
        p,
        &["comment", &t, "see file", "--link", "docs/sub/extra.txt"],
    );
    render(p, out.path(), &[]);
    assert_eq!(read(out.path(), "files/sub/extra.txt"), "extra");
    ok(p, &["tombstone", &t]);
    let r = render(p, out.path(), &[]);
    assert_eq!(
        r["render"]["removed"],
        serde_json::json!(["files/sub/extra.txt"])
    );
    assert!(!out.path().join("files/sub").exists());
    assert!(out.path().join("files/notes.org").exists());
    assert_eq!(read(out.path(), "README"), "keep");
}

#[test]
fn assets_come_from_the_given_directory() {
    let f = fixture();
    let p = f.dir.path();
    let src = disposable_dir();
    write_file(src.path(), "index.html", "<p>custom page</p>\n");
    write_file(src.path(), "style.css", "p { color: red }\n");
    write_file(src.path(), "app.js", "// custom\n");
    let out = disposable_dir();
    let r = render(p, out.path(), &["--assets", src.path().to_str().unwrap()]);
    assert_eq!(r["render"]["assets"], src.path().to_str().unwrap());
    assert_eq!(read(out.path(), "index.html"), "<p>custom page</p>\n");
    assert_eq!(read(out.path(), "style.css"), "p { color: red }\n");
    assert_eq!(read(out.path(), "app.js"), "// custom\n");
    // The embedded copies are the default again on the next run.
    render(p, out.path(), &[]);
    let page = read(out.path(), "index.html");
    assert!(page.contains("<script src=\"data.js\"></script>"), "{page}");

    std::fs::remove_file(src.path().join("app.js")).unwrap();
    let o = run_in(
        p,
        &[
            "render",
            out.path().to_str().unwrap(),
            "--assets",
            src.path().to_str().unwrap(),
        ],
        "",
    );
    assert_eq!(o.json["error"]["code"], "io", "{}", o.json);
}

#[test]
fn retired_statuses_get_chips_only_while_tickets_have_them() {
    let d = tracker();
    let p = d.path();
    let first = ok(p, &["create", "Current"]);
    assert_disposable(p);
    let toml = read(p, "zwanenzang.toml");
    let old = toml
        .lines()
        .find(|l| l.starts_with("retired_statuses = "))
        .unwrap();
    let toml = toml.replace(
        old,
        "retired_statuses = [\"draft\", \"doing\", \"cancelled\"]",
    );
    std::fs::write(p.join("zwanenzang.toml"), toml).unwrap();
    // Tickets created with two of the names before they retired, by this
    // clone's writer.
    let actor = actor_of(p);
    let mut parent = first["event"]["id"].as_str().unwrap().to_string();
    let mut lines = Vec::new();
    for (id, title, status) in [
        ("0GZZZZZZZZZZZZZZZZZZZZZZZ0", "Old draft", "draft"),
        ("0GZZZZZZZZZZZZZZZZZZZZZZZ1", "Old cancel", "cancelled"),
    ] {
        lines.push(
            serde_json::json!({
                "id": id, "actor": actor, "parent": parent, "ts": "2026-11-07T00:00:00Z",
                "entity": id, "op": "create", "data": {"title": title, "status": status}
            })
            .to_string(),
        );
        parent = id.to_string();
    }
    append_raw(p, &actor, &lines);
    let out = disposable_dir();
    render(p, out.path(), &[]);
    let d = data(out.path());
    assert_eq!(
        d["tracker"]["statuses"],
        serde_json::json!([
            "todo",
            "next",
            "wait",
            "agnt",
            "revw",
            "done",
            "cncl",
            "draft",
            "cancelled"
        ])
    );
    assert_eq!(
        d["tracker"]["hidden_statuses"],
        serde_json::json!(["done", "cncl", "cancelled"])
    );
}
