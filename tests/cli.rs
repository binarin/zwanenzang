//! The CLI's JSON contract, driven through the built binary.

mod common;

use common::*;
use serde_json::{Value, json};

/// A bare remote and destination for init-based tests.
struct InitNet {
    dir: tempfile::TempDir,
}

impl InitNet {
    fn new() -> InitNet {
        let dir = disposable_dir();
        git(
            dir.path(),
            &["init", "--quiet", "--bare", "-b", "main", "remote.git"],
        );
        InitNet { dir }
    }

    /// The remote's URL.
    fn url(&self) -> String {
        self.dir
            .path()
            .join("remote.git")
            .to_str()
            .unwrap()
            .to_string()
    }

    /// The remote's locator, selecting a branch named after the
    /// destination, so each init in one test publishes its own branch.
    fn locator(&self, dest: &str) -> String {
        format!("{}?ref={dest}", self.url())
    }

    fn init(&self, dest: &str, extra: &[&str]) -> Out {
        let dir = self.dir.path().join(dest);
        run_in(
            self.dir.path(),
            &[
                "init",
                dir.to_str().unwrap(),
                "--remote",
                &self.locator(dest),
            ]
            .iter()
            .chain(extra.iter())
            .copied()
            .collect::<Vec<_>>(),
            "",
        )
    }
}

#[test]
fn init_writes_tracker_files() {
    let net = InitNet::new();
    let out = net.init("tracker-test-repo", &["--prefix", "ZZ", "--name", "Test"]);
    assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);
    let out = &out.json;
    let d = net.dir.path().join("tracker-test-repo");
    assert_eq!(out["tracker"]["prefix"], "ZZ");
    assert_eq!(out["tracker"]["name"], "Test");
    assert_eq!(out["tracker"]["statuses"][0], "todo");
    assert_eq!(out["tracker"]["retired_statuses"], json!([]));
    assert_eq!(read(&d, ".gitattributes"), "events/*.jsonl merge=union\n");
    assert!(!d.join(".gitignore").exists());
    assert_eq!(actor_of(&d), out["actor"]);
    assert_eq!(out["identity"], TESTER);
    assert_eq!(git(&d, &["log", "--format=%s"]), "init\n");
    assert_eq!(out["sync"]["upstream"], "origin/tracker-test-repo");
    assert_eq!(out["sync"]["pushed"], true);
    assert_eq!(out["remote"]["branch"], "tracker-test-repo");
    let toml = read(&d, "zwanenzang.toml");
    assert!(toml.contains(&format!(
        "id = \"{}\"",
        out["tracker"]["id"].as_str().unwrap()
    )));
    assert!(d.join("events").is_dir());
    assert!(d.join("blobs").is_dir());
    // The name defaults to the destination's directory name.
    let out = net.init("named-test-repo", &["--prefix", "ZZ"]);
    assert_eq!(out.code, 0, "{}", out.json);
    assert_eq!(out.json["tracker"]["name"], "named-test-repo");
    let d = net.dir.path().join("named-test-repo");
    // Nothing else may be initialized in or below a tracker.
    err(
        &d,
        &[
            "init",
            d.to_str().unwrap(),
            "--remote",
            &net.url(),
            "--prefix",
            "ZZ",
        ],
        "already-initialized",
    );
    let sub = d.join("sub-test-repo");
    std::fs::create_dir(&sub).unwrap();
    err(
        &sub,
        &[
            "init",
            sub.to_str().unwrap(),
            "--remote",
            &net.url(),
            "--prefix",
            "QQ",
        ],
        "already-initialized",
    );
    assert!(!sub.join("zwanenzang.toml").exists());
    let e = net.init("badprefix-test-repo", &["--prefix", "zz"]);
    assert_eq!(e.code, 1, "{}", e.json);
    assert_eq!(e.json["error"]["code"], "config");
}

#[test]
fn concurrent_inits_one_wins_and_reports_what_is_on_disk() {
    for _ in 0..10 {
        let net = InitNet::new();
        let p = net.dir.path().join("race-test-repo");
        let locator = net.locator("race-test-repo");
        let outs: Vec<Out> = std::thread::scope(|s| {
            let handles: Vec<_> = (0..6)
                .map(|_| {
                    s.spawn(|| {
                        run_in(
                            net.dir.path(),
                            &[
                                "init",
                                p.to_str().unwrap(),
                                "--remote",
                                &locator,
                                "--prefix",
                                "ZZ",
                            ],
                            "",
                        )
                    })
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        let winners: Vec<&Out> = outs.iter().filter(|o| o.code == 0).collect();
        assert_eq!(winners.len(), 1, "exactly one init succeeds");
        for o in outs.iter().filter(|o| o.code != 0) {
            // A loser reports what it found: a finished or in-flight
            // tracker in the destination, or a branch taken first.
            assert_eq!(o.code, 1, "{}", o.json);
            assert!(
                matches!(
                    o.json["error"]["code"].as_str(),
                    Some("already-initialized") | Some("invalid-argument") | Some("branch-exists")
                ),
                "{}",
                o.json
            );
        }
        let won = &winners[0].json;
        let toml = read(&p, "zwanenzang.toml");
        assert!(
            toml.contains(&format!(
                "id = \"{}\"",
                won["tracker"]["id"].as_str().unwrap()
            )),
            "reported tracker id is the one on disk: {toml}"
        );
        assert_eq!(actor_of(&p), won["actor"]);
    }
}

#[test]
fn commands_outside_a_tracker_fail() {
    let d = disposable_dir();
    // Otherwise the binary would open, and `create` write, that tracker.
    assert_eq!(tracker_above(d.path()), None, "a tracker encloses {d:?}");
    err(d.path(), &["list"], "not-a-tracker");
    err(d.path(), &["create", "x"], "not-a-tracker");
}

#[test]
#[should_panic(expected = "would open the tracker at")]
fn helper_refuses_an_enclosing_tracker_without_markers() {
    // The enclosing directory lacks the name marker; only its marker file
    // is written, and the helper must refuse before the binary runs.
    let outer = tempfile::Builder::new()
        .prefix("zwanenzang-guard-")
        .tempdir_in(std::env::temp_dir())
        .unwrap();
    std::fs::write(outer.path().join("zwanenzang.toml"), "").unwrap();
    let inner = outer.path().join("inner-test-repo");
    std::fs::create_dir(&inner).unwrap();
    run_in(&inner, &["list"], "");
}

#[test]
fn create_show_and_list() {
    let d = tracker();
    let p = d.path();
    let out = ok(
        p,
        &[
            "create",
            "First ticket",
            "--kind",
            "bug",
            "--tag",
            "alpha",
            "--tag",
            "beta",
        ],
    );
    assert_eq!(out["written"], true);
    assert_eq!(out["event"]["op"], "create");
    assert_eq!(
        out["event"]["data"],
        json!({"title": "First ticket", "status": "todo", "kind": "bug"})
    );
    let ops: Vec<&str> = out["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["op"].as_str().unwrap())
        .collect();
    assert_eq!(ops, vec!["actor", "create", "tag", "tag"]);
    assert_eq!(out["events"][0]["data"]["name"], "tester");
    let t1 = id(&out);
    assert_eq!(out["ticket"]["id"], out["event"]["entity"]);
    assert_eq!(out["ticket"]["status"], "todo");
    assert_eq!(out["ticket"]["number"], 1);
    assert_eq!(out["ticket"]["display"], "ZZ-1");
    assert_eq!(out["ticket"]["tags"], json!(["alpha", "beta"]));

    let out2 = ok(
        p,
        &["create", "Child", "--status", "agnt", "--parent", &t1[..12]],
    );
    let t2 = id(&out2);
    assert_eq!(out2["ticket"]["parent"], t1.as_str());
    let ops: Vec<&str> = out2["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["op"].as_str().unwrap())
        .collect();
    assert_eq!(ops, vec!["create", "parent"], "the actor is declared once");

    let show = ok(p, &["show", &t1.to_lowercase()]);
    assert_eq!(show["children"], json!([t2]));
    assert_eq!(show["title"], "First ticket");
    assert_eq!(show["created"]["id"], t1.as_str());
    assert_eq!(show["documents"], json!({}));
    assert_eq!(show["comments"], json!([]));
    // Numbering is the ticket's latest event.
    assert_eq!(show["last_event"], out["sync"]["numbered"][0]["event"]);
    for key in [
        "id",
        "short_id",
        "number",
        "display",
        "title",
        "status",
        "kind",
        "parent",
        "children",
        "related",
        "tags",
        "branches",
        "mrs",
        "archived",
        "tombstoned",
        "created",
        "last_event",
        "documents",
        "comments",
    ] {
        assert!(show.get(key).is_some(), "show lacks {key}");
    }

    let list = ok(p, &["list"]);
    assert_eq!(list["tickets"].as_array().unwrap().len(), 2);
    assert_eq!(
        ok(p, &["list", "--status", "agnt"])["tickets"][0]["id"],
        t2.as_str()
    );
    assert_eq!(
        ok(p, &["list", "--tag", "alpha", "--tag", "beta"])["tickets"][0]["id"],
        t1.as_str()
    );
    assert_eq!(
        ok(p, &["list", "--tag", "alpha", "--tag", "gamma"])["tickets"],
        json!([])
    );
    assert_eq!(
        ok(p, &["list", "--kind", "bug"])["tickets"][0]["id"],
        t1.as_str()
    );
    assert_eq!(
        ok(p, &["list", "--status", "todo", "--status", "agnt"])["tickets"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn field_commands_and_removal_forms() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let b = id(&ok(p, &["create", "B"]));
    assert_eq!(ok(p, &["status", &a, "agnt"])["ticket"]["status"], "agnt");
    assert_eq!(
        ok(p, &["title", &a, "A renamed"])["ticket"]["title"],
        "A renamed"
    );
    assert_eq!(ok(p, &["kind", &a, "feature"])["ticket"]["kind"], "feature");
    assert_eq!(
        ok(p, &["kind", &a, "--clear"])["ticket"]["kind"],
        Value::Null
    );
    assert_eq!(ok(p, &["parent", &a, &b])["ticket"]["parent"], b.as_str());
    let cleared = ok(p, &["parent", &a, "--clear"]);
    assert_eq!(cleared["ticket"]["parent"], Value::Null);
    assert_eq!(cleared["event"]["data"], json!({"to": null}));
    assert_eq!(ok(p, &["relate", &a, &b])["ticket"]["related"], json!([b]));
    assert_eq!(ok(p, &["show", &b])["related"], json!([a]));
    let un = ok(p, &["relate", &a, &b, "--remove"]);
    assert_eq!(un["event"]["op"], "unrelate");
    assert_eq!(un["ticket"]["related"], json!([]));
    ok(p, &["tag", &a, "x"]);
    let untag = ok(p, &["tag", &a, "x", "--remove"]);
    assert_eq!(untag["event"]["op"], "untag");
    assert_eq!(untag["ticket"]["tags"], json!([]));
    let br = ok(p, &["branch", &a, "app", "feature/x"]);
    assert_eq!(
        br["ticket"]["branches"],
        json!([{"repo": "app", "name": "feature/x"}])
    );
    let mr = ok(p, &["mr", &a, "app", "https://forge.example/app/pulls/1"]);
    assert_eq!(
        mr["ticket"]["mrs"],
        json!([{"repo": "app", "url": "https://forge.example/app/pulls/1"}])
    );
}

#[test]
fn errors_are_json_and_write_nothing() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let before = logs(p);
    err(p, &["status", &a, "nope"], "status-not-in-vocabulary");
    err(p, &["kind", &a, "epic"], "kind-not-in-vocabulary");
    err(p, &["tag", &a, "has space"], "invalid-tag");
    err(p, &["title", &a, " "], "invalid-title");
    err(p, &["parent", &a, &a], "parent-cycle");
    err(p, &["relate", &a, &a], "self-relation");
    err(
        p,
        &["create", "x", "--status", "nope"],
        "status-not-in-vocabulary",
    );
    err(p, &["create", "x", "--tag", "bad tag"], "invalid-tag");
    err(p, &["status", "ZZZZZZ", "agnt"], "unknown-ticket");
    err(p, &["status", "ZZ-2", "agnt"], "unknown-ticket");
    err(p, &["doc", "get", &a, "description"], "unknown-document");
    assert_eq!(logs(p), before);
    // Usage errors stay clap's: stderr and exit status 2.
    let o = run_in(p, &["doc", "set", &a, "description"], "text");
    assert_eq!(o.code, 2);
    assert!(o.stderr.contains("--base"));
}

#[test]
fn no_op_writes_report_not_written() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A", "--tag", "x"]));
    let before = logs(p);
    for args in [
        vec!["status", &a, "todo"],
        vec!["title", &a, "A"],
        vec!["tag", &a, "x"],
        vec!["tag", &a, "y", "--remove"],
        vec!["parent", &a, "--clear"],
    ] {
        let out = ok(p, &args);
        assert_eq!(out["written"], false, "{args:?}");
        assert_eq!(out["event"], Value::Null);
        assert_eq!(out["events"], json!([]));
        assert_eq!(out["ticket"]["id"], a.as_str());
    }
    assert_eq!(logs(p), before);
}

#[test]
fn comments_inline_and_as_blob() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let c1 = ok(p, &["comment", &a, "short note", "--link", "docs/plan.md"]);
    assert_eq!(
        c1["event"]["data"],
        json!({"text": "short note", "link": "docs/plan.md"})
    );
    let long = "x".repeat(3000);
    let c2 = ok_stdin(p, &["comment", &a], &long);
    let blob = c2["event"]["data"]["blob"].as_str().unwrap().to_string();
    assert!(c2["event"]["data"].get("text").is_none());
    assert_eq!(read(p, &format!("blobs/{blob}")), long);
    let comments = ok(p, &["show", &a])["comments"].clone();
    assert_eq!(comments[0]["text"], "short note");
    assert_eq!(comments[0]["blob"], Value::Null);
    assert_eq!(comments[1]["text"], long.as_str());
    assert_eq!(comments[1]["blob"], blob.as_str());
    err(p, &["comment", &a, "   "], "invalid-comment");
    // Whitespace long enough to go to a blob is refused the same way, and
    // nothing is stored.
    let before = logs(p);
    let blobs_before = std::fs::read_dir(p.join("blobs")).unwrap().count();
    let spaces = " ".repeat(3000);
    let o = run_in(p, &["comment", &a], &spaces);
    assert_eq!(o.code, 1, "{}", o.json);
    assert_eq!(o.json["error"]["code"], "invalid-comment");
    assert_eq!(logs(p), before);
    assert_eq!(
        std::fs::read_dir(p.join("blobs")).unwrap().count(),
        blobs_before
    );
}

#[test]
fn comments_with_heading_lines_are_refused_every_way_they_are_given() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let before = logs(p);
    let blobs_before = std::fs::read_dir(p.join("blobs")).unwrap().count();
    let e = err(p, &["comment", &a, "* Review: fine"], "invalid-comment");
    let message = e["error"]["message"].as_str().unwrap();
    assert!(message.contains("line 1"), "{message}");
    assert!(message.contains("\"* Review: fine\""), "{message}");
    let input = disposable_dir();
    let file = input.path().join("comment.org");
    std::fs::write(&file, "Review: fine\n\n** Details\n").unwrap();
    let e = err(
        p,
        &["comment", &a, "--file", file.to_str().unwrap()],
        "invalid-comment",
    );
    assert!(e["error"]["message"].as_str().unwrap().contains("line 3"));
    let o = run_in(p, &["comment", &a], "Plain\n*\n");
    assert_eq!(o.code, 1, "{}", o.json);
    assert_eq!(o.json["error"]["code"], "invalid-comment");
    // Text long enough for a blob is checked the same way.
    let long = format!("{}\n* Late heading\n", "x".repeat(3000));
    let o = run_in(p, &["comment", &a], &long);
    assert_eq!(o.code, 1, "{}", o.json);
    assert_eq!(o.json["error"]["code"], "invalid-comment");
    assert_eq!(logs(p), before);
    assert_eq!(
        std::fs::read_dir(p.join("blobs")).unwrap().count(),
        blobs_before
    );
    // Indented stars, bold at line start and lists are not headings;
    // documents may keep their headings.
    ok_stdin(
        p,
        &["comment", &a],
        "Review: fine\n  * sub-item\n*bold* start\n- item\n",
    );
    ok_stdin(
        p,
        &["doc", "set", &a, "brief", "--base", "none"],
        "* Goal\nText\n",
    );
}

#[test]
fn documents_compare_and_set() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let v1 = ok_stdin(
        p,
        &["doc", "set", &a, "description", "--base", "none"],
        "first\n",
    );
    let v1_id = v1["event"]["id"].as_str().unwrap().to_string();
    assert_eq!(v1["event"]["data"]["base"], Value::Null);
    let got = ok(p, &["doc", "get", &a, "description"]);
    assert_eq!(got["text"], "first\n");
    assert_eq!(got["version"], v1_id.as_str());

    // Somebody who read nothing, or an old version, is refused.
    let before = logs(p);
    let o = run_in(
        p,
        &["doc", "set", &a, "description", "--base", "none"],
        "mine\n",
    );
    assert_eq!(o.code, 1);
    assert_eq!(o.json["error"]["code"], "stale-doc-base");
    assert_eq!(logs(p), before);

    let file = p.join("docs-input.txt");
    std::fs::write(&file, "second\n").unwrap();
    let v2 = ok(
        p,
        &[
            "doc",
            "set",
            &a,
            "description",
            "--base",
            &v1_id,
            "--file",
            file.to_str().unwrap(),
        ],
    );
    let v2_id = v2["event"]["id"].as_str().unwrap().to_string();
    let o = run_in(
        p,
        &["doc", "set", &a, "description", "--base", &v1_id],
        "third\n",
    );
    assert_eq!(o.json["error"]["code"], "stale-doc-base");
    err(
        p,
        &["doc", "set", &a, "description", "--base", "nonsense"],
        "invalid-argument",
    );
    // Same text against the current version: nothing to write.
    let same = ok_stdin(
        p,
        &["doc", "set", &a, "description", "--base", &v2_id],
        "second\n",
    );
    assert_eq!(same["written"], false);

    let show = ok(p, &["show", &a]);
    let doc = &show["documents"]["description"];
    assert_eq!(doc["current"], v2_id.as_str());
    assert_eq!(doc["blob"], v2["event"]["data"]["blob"]);
    assert_eq!(doc["versions"].as_array().unwrap().len(), 2);
    assert_eq!(doc["versions"][1]["base"], v1_id.as_str());
    assert_eq!(doc["versions"][1]["lost"], false);
    assert_eq!(
        ok(p, &["doc", "get", &a, "description"])["text"],
        "second\n"
    );
}

#[test]
fn query_filters_derived_state() {
    let d = tracker();
    let p = d.path();
    let root = id(&ok(p, &["create", "Root epic", "--kind", "feature"]));
    let mid = id(&ok(
        p,
        &["create", "Middle", "--parent", &root, "--tag", "x"],
    ));
    let leaf = id(&ok(
        p,
        &["create", "Leaf BUG here", "--parent", &mid, "--tag", "x"],
    ));
    let other = id(&ok(p, &["create", "Other", "--status", "agnt"]));
    ok(p, &["branch", &leaf, "app", "feature/leaf"]);
    ok(
        p,
        &["mr", &other, "lib", "https://forge.example/lib/pulls/2"],
    );
    ok(p, &["archive", &other]);
    let ids = |args: &[&str]| -> Vec<String> {
        let mut full = vec!["query"];
        full.extend_from_slice(args);
        ok(p, &full)["tickets"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(ids(&[]), vec![root.clone(), mid.clone(), leaf.clone()]);
    assert_eq!(ids(&["--parent", "none"]), vec![root.clone()]);
    assert_eq!(ids(&["--parent", &mid]), vec![leaf.clone()]);
    assert_eq!(ids(&["--under", &root]), vec![mid.clone(), leaf.clone()]);
    assert_eq!(
        ids(&["--under", &root, "--tag", "x", "--title", "bug"]),
        vec![leaf.clone()]
    );
    assert_eq!(ids(&["--kind", "feature"]), vec![root.clone()]);
    assert_eq!(ids(&["--repo", "app"]), vec![leaf.clone()]);
    // Archived tickets need --all, unless they are named.
    assert!(ids(&["--repo", "lib"]).is_empty());
    assert_eq!(ids(&["--repo", "lib", "--all"]), vec![other.clone()]);
    assert_eq!(
        ids(&[&other, &root, &other]),
        vec![root.clone(), other.clone()]
    );
    assert_eq!(
        ids(&[&other, &root, "--status", "agnt"]),
        vec![other.clone()]
    );
    // Full objects by default, summaries on request.
    let full = ok(p, &["query", &leaf]);
    assert_eq!(full["tickets"][0], ok(p, &["show", &leaf]));
    let short = ok(p, &["query", &leaf, "--summary"]);
    assert!(short["tickets"][0].get("comments").is_none());
    assert_eq!(short["tickets"][0]["title"], "Leaf BUG here");
    err(p, &["query", "ZZZZ"], "unknown-ticket");
    err(p, &["query", "--under", "ZZZZ"], "unknown-ticket");
}

#[test]
fn archive_and_tombstone_leave_the_default_list() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let b = id(&ok(p, &["create", "B"]));
    let c = id(&ok(p, &["create", "C"]));
    ok(p, &["relate", &a, &c]);
    ok(p, &["archive", &a]);
    assert_eq!(ok(p, &["archive", &a])["written"], false);
    ok(p, &["tombstone", &c]);
    let ids = |v: &Value| -> Vec<String> {
        v["tickets"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(ids(&ok(p, &["list"])), vec![b.clone()]);
    assert_eq!(
        ids(&ok(p, &["list", "--all"])),
        vec![a.clone(), b.clone(), c.clone()]
    );
    let shown = ok(p, &["show", &c]);
    assert_eq!(shown["tombstoned"], true);
    // A tombstoned ticket is hidden from relations and refuses changes.
    assert_eq!(ok(p, &["show", &a])["related"], json!([]));
    err(p, &["status", &c, "done"], "tombstoned");
    err(p, &["relate", &b, &c], "target-tombstoned");
    err(p, &["parent", &b, &c], "target-tombstoned");
}

#[test]
fn unarchive_returns_a_ticket_to_the_default_list_with_its_status() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let c = id(&ok(p, &["create", "C"]));
    // Not archived: nothing changes, as with archiving an archived ticket.
    let unchanged = logs(p);
    let noop = ok(p, &["unarchive", &a]);
    assert_eq!(noop["written"], false);
    assert_eq!(noop["ticket"]["archived"], false);
    assert_eq!(logs(p), unchanged);

    ok(p, &["status", &a, "done"]);
    ok(p, &["archive", &a]);
    let listed = |v: &Value, id: &str| {
        v["tickets"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["id"] == id)
    };
    assert!(!listed(&ok(p, &["list"]), &a));
    let back = ok(p, &["unarchive", &a]);
    assert_eq!(back["written"], true);
    assert_eq!(back["event"]["op"], "unarchive");
    assert_eq!(back["event"]["data"], json!({}));
    assert_eq!(back["ticket"]["archived"], false);
    assert_eq!(back["ticket"]["status"], "done");
    assert!(listed(&ok(p, &["list"]), &a));
    assert_eq!(ok(p, &["unarchive", &a])["written"], false);

    ok(p, &["tombstone", &c]);
    err(p, &["archive", &c], "tombstoned");
    err(p, &["unarchive", &c], "tombstoned");
    assert_eq!(run_in(p, &["lint"], "").code, 0);
}

fn line(id: &str, actor: &str, parent: &str, entity: &str, op: &str, data: Value) -> String {
    serde_json::to_string(&json!({
        "id": id, "actor": actor, "parent": parent, "ts": "2026-11-07T00:00:00Z",
        "entity": entity, "op": op, "data": data
    }))
    .unwrap()
}

#[test]
fn lint_clean_then_reporting_issues() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let first = ok(p, &["status", &a, "agnt"]);
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 0, "{}", lint.json);
    assert_eq!(lint.json["ok"], true);
    assert_eq!(lint.json["events"], 4, "with the number");

    // Another actor that had seen only the create sets a different status,
    // with an id after ours: a concurrent change. It also never named itself,
    // and it references a repository alias that is not configured.
    let other = "01ZZZZZZZZZZZZZZZZZZZZZZZB";
    let doing_id = first["event"]["id"].as_str().unwrap();
    let create_id = a.as_str();
    let later = "0GZZZZZZZZZZZZZZZZZZZZZZZ0";
    let later2 = "0GZZZZZZZZZZZZZZZZZZZZZZZ1";
    let later3 = "0GZZZZZZZZZZZZZZZZZZZZZZZ2";
    append_raw(
        p,
        other,
        &[
            line(later, other, create_id, &a, "status", json!({"to": "wait"})),
            line(
                later2,
                other,
                later,
                &a,
                "branch",
                json!({"repo": "app", "name": "x"}),
            ),
            line(later3, other, later2, &a, "estimate", json!({"hours": 2})),
        ],
    );
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 1);
    let r = &lint.json;
    assert_eq!(r["ok"], false);
    assert_eq!(r["concurrent"][0]["entity"], a.as_str());
    assert_eq!(r["concurrent"][0]["field"], "status");
    assert_eq!(r["concurrent"][0]["earlier"], doing_id);
    assert_eq!(r["concurrent"][0]["later"], later);
    assert_eq!(r["concurrent"][0]["won"], later);
    assert_eq!(r["dangling_repos"][0]["repo"], "app");
    assert_eq!(r["unnamed_actors"][0]["actor"], other);
    assert_eq!(r["skipped"][0]["code"], "unknown-op");
    assert_eq!(r["skipped"][0]["id"], later3);
    assert!(
        r["skipped"][0]["raw"]
            .as_str()
            .unwrap()
            .contains("estimate")
    );
    assert_eq!(ok(p, &["show", &a])["status"], "wait");

    // Our next event sorts after everything this clone has seen.
    let next = ok(p, &["status", &a, "done"]);
    let next_id = next["event"]["id"].as_str().unwrap();
    assert!(next_id > later3);
    assert_eq!(next["event"]["parent"], later3);
    // A lost document edit shows up too.
    let v1 = ok_stdin(p, &["doc", "set", &a, "notes", "--base", "none"], "one")["event"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let blob = ok(p, &["show", &a])["documents"]["notes"]["blob"]
        .as_str()
        .unwrap()
        .to_string();
    let v2 = ok_stdin(p, &["doc", "set", &a, "notes", "--base", &v1], "two")["event"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let stale = "0GZZZZZZZZZZZZZZZZZZZZZZZZ";
    append_raw(
        p,
        other,
        &[line(
            stale,
            other,
            &v1,
            &a,
            "doc",
            json!({"name": "notes", "blob": blob, "base": v1}),
        )],
    );
    let r = run_in(p, &["lint"], "").json;
    assert_eq!(r["lost_documents"][0]["event"], stale);
    assert_eq!(r["lost_documents"][0]["current"], v2.as_str());
    let doc = &ok(p, &["show", &a])["documents"]["notes"];
    assert_eq!(doc["current"], v2.as_str());
    assert_eq!(doc["versions"][2]["lost"], true);
}

#[test]
fn a_line_with_the_last_possible_id_does_not_block_writes() {
    let d = tracker();
    let p = d.path();
    let created = ok(p, &["create", "A"]);
    let a = id(&created);
    let parent = created["event"]["id"].as_str().unwrap().to_string();
    let actor = actor_of(p);
    let toml = read(p, "zwanenzang.toml");
    let root = toml
        .lines()
        .find_map(|l| l.strip_prefix("id = \""))
        .and_then(|l| l.strip_suffix('"'))
        .unwrap()
        .to_string();
    append_raw(
        p,
        &actor,
        &[line(
            "7ZZZZZZZZZZZZZZZZZZZZZZZZZ",
            &actor,
            &parent,
            &root,
            "future-op",
            json!({}),
        )],
    );
    // And the last id of the millisecond before, as a valid change.
    append_raw(
        p,
        &actor,
        &[line(
            "7ZZZZZZZZYZZZZZZZZZZZZZZZZ",
            &actor,
            &parent,
            &a,
            "title",
            json!({"to": "far future"}),
        )],
    );
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 1);
    let codes: Vec<&str> = lint.json["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["code"].as_str().unwrap())
        .collect();
    assert_eq!(codes, ["id-out-of-range", "id-out-of-range"]);
    assert_eq!(ok(p, &["show", &a])["title"], "A");
    let b = ok(p, &["create", "B"]);
    assert_eq!(b["written"], true);
    ok(p, &["status", &a, "done"]);
    assert_eq!(ok(p, &["show", &a])["status"], "done");
}

#[test]
fn numbers_resolve_and_display() {
    // Without an upstream the clone is the whole tracker: every write is
    // published at once, and new tickets are numbered in id order.
    let d = tracker();
    let p = d.path();
    without_upstream(p);
    let first = ok(p, &["create", "A"]);
    let a = id(&first);
    assert_eq!(first["ticket"]["number"], 1);
    assert_eq!(first["ticket"]["display"], "ZZ-1");
    let n_event = first["sync"]["numbered"][0]["event"].clone();
    assert_eq!(
        first["sync"],
        json!({"upstream": null, "pushed": false, "error": null,
               "checkouts": {"target": git(p, &["rev-parse", "HEAD"]).trim(), "error": null, "results": []},
               "numbered": [{"id": a, "number": 1, "display": "ZZ-1", "event": n_event}]})
    );
    assert_eq!(first["ticket"]["last_event"], n_event);
    // The number events are not the command's own.
    assert!(
        first["events"]
            .as_array()
            .unwrap()
            .iter()
            .all(|e| e["op"] != "number")
    );
    let b = id(&ok(p, &["create", "B"]));
    // Padded input keeps resolving; output is unpadded.
    let shown = ok(p, &["show", "ZZ-0002"]);
    assert_eq!(shown["id"], b.as_str());
    assert_eq!(shown["number"], 2);
    assert_eq!(shown["display"], "ZZ-2");
    assert_eq!(ok(p, &["show", "zz-1"])["id"], a.as_str());
    // A write that numbers nothing new says so.
    assert_eq!(
        ok(p, &["status", &a, "agnt"])["sync"]["numbered"],
        json!([])
    );
    // Each command is one commit, numbering another.
    // A ticket is committed before it has a number, under its short id.
    let short = |t: &str| {
        ok(p, &["show", t])["short_id"]
            .as_str()
            .unwrap()
            .to_string()
    };
    assert_eq!(
        git(p, &["log", "--format=%s"]),
        format!(
            "status ZZ-1\npublish ZZ-2\ncreate {}\n\
             publish ZZ-1\ncreate {} (+1 events)\ninit\n",
            short(&b),
            short(&a)
        )
    );
    assert_eq!(git(p, &["status", "--porcelain"]), "");
}

#[test]
#[should_panic(expected = "directory name does not end in -test-repo")]
fn helper_refuses_an_unmarked_configured_checkout() {
    let source = tracker();
    let unmarked = tempfile::Builder::new()
        .prefix("zwanenzang-guard-")
        .tempdir_in(std::env::temp_dir())
        .unwrap();
    git(
        source.path(),
        &[
            "config",
            "--local",
            "--add",
            "zwanenzang.checkout",
            unmarked.path().to_str().unwrap(),
        ],
    );
    // The guard must stop this before the CLI opens a configured checkout.
    run_in(source.path(), &["sync"], "");
}

/// Replaces the line of `zwanenzang.toml` starting with `key = ` by
/// `key = value`, adding it after `prefix` when absent.
fn set_config_key(p: &std::path::Path, key: &str, value: &str) {
    assert_disposable(p);
    let toml = read(p, "zwanenzang.toml");
    let start = format!("{key} = ");
    let new_line = format!("{key} = {value}");
    let toml = match toml.lines().find(|l| l.starts_with(&start)) {
        Some(old) => toml.replace(old, &new_line),
        None => {
            let prefix = toml.lines().find(|l| l.starts_with("prefix = ")).unwrap();
            toml.replace(prefix, &format!("{prefix}\n{new_line}"))
        }
    };
    std::fs::write(p.join("zwanenzang.toml"), toml).unwrap();
}

#[test]
fn retired_statuses_replay_but_refuse_new_writes() {
    let d = tracker();
    let p = d.path();
    let fresh = ok(p, &["create", "Fresh"]);
    let b = id(&fresh);
    set_config_key(p, "retired_statuses", "[\"draft\", \"doing\"]");
    // Old events by this clone's writer, from before the names retired;
    // no new write can use them any more.
    let actor = actor_of(p);
    let a = "0GZZZZZZZZZZZZZZZZZZZZZZZ0";
    let parent = fresh["event"]["id"].as_str().unwrap();
    append_raw(
        p,
        &actor,
        &[
            line(
                a,
                &actor,
                parent,
                a,
                "create",
                json!({"title": "Old", "status": "draft"}),
            ),
            line(
                "0GZZZZZZZZZZZZZZZZZZZZZZZ1",
                &actor,
                a,
                a,
                "status",
                json!({"to": "doing"}),
            ),
        ],
    );
    // Replay keeps the old events and their meaning, with no new issues.
    assert_eq!(ok(p, &["show", a])["status"], "doing");
    assert_eq!(ok(p, &["lint"])["ok"], true);
    let read = ok_stdin(p, &["read"], "{}");
    assert_eq!(
        read["tracker"]["retired_statuses"],
        json!(["draft", "doing"])
    );
    assert_eq!(
        read["tracker"]["statuses"],
        json!([
            "todo", "next", "wait", "agnt", "revw", "done", "cncl", "draft", "doing"
        ])
    );

    let logs_before = logs(p);
    let e = err(p, &["status", a, "draft"], "retired-status");
    assert!(e["error"]["message"].as_str().unwrap().contains("todo"));
    // Even naming the current status again is refused.
    err(p, &["status", a, "doing"], "retired-status");
    err(p, &["create", "New", "--status", "doing"], "retired-status");
    let o = run_in(
        p,
        &["apply"],
        &json!({"changes": [
            {"op": "status", "ticket": a, "data": {"to": "next"}},
            {"op": "create", "data": {"title": "New", "status": "draft"}},
        ]})
        .to_string(),
    );
    assert_eq!(o.json["error"]["code"], "retired-status", "{}", o.json);
    assert_eq!(logs(p), logs_before);

    // Every fixed status is accepted.
    assert_eq!(ok(p, &["show", &b])["status"], "todo");
    for s in ["next", "wait", "agnt", "revw", "done", "cncl", "todo"] {
        assert_eq!(ok(p, &["status", &b, s])["ticket"]["status"], s);
    }
    let created = ok_stdin(
        p,
        &["apply"],
        &json!({"changes": [{"op": "create", "data": {"title": "Batch", "status": "agnt"}}]})
            .to_string(),
    );
    assert_eq!(created["tickets"][0]["status"], "agnt");
}

#[test]
fn a_new_tracker_has_the_default_vocabulary() {
    let d = tracker();
    let p = d.path();
    let scope = ok_stdin(p, &["read"], "{}");
    assert_eq!(
        scope["tracker"]["statuses"],
        json!(["todo", "next", "wait", "agnt", "revw", "done", "cncl"])
    );
    assert_eq!(scope["tracker"]["retired_statuses"], json!([]));
    let toml = read(p, "zwanenzang.toml");
    assert!(toml.contains("\nretired_statuses = []\n"), "{toml}");
    // The statuses are fixed in code, not written to the configuration.
    assert!(!toml.contains("\nstatuses ="), "{toml}");
}

#[test]
fn an_obsolete_statuses_key_is_ignored_and_reported_by_lint() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    set_config_key(p, "retired_statuses", "[\"doing\"]");
    // As an older `init` wrote it, with a retired name; the order does not
    // matter any more.
    set_config_key(
        p,
        "statuses",
        "[\"next\", \"todo\", \"wait\", \"agnt\", \"revw\", \"done\", \"cncl\", \"doing\"]",
    );
    assert_eq!(ok(p, &["status", &a, "next"])["ticket"]["status"], "next");
    assert_eq!(
        ok(p, &["show", &id(&ok(p, &["create", "B"]))])["status"],
        "todo"
    );
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 1, "{}", lint.json);
    assert_eq!(lint.json["ok"], false);
    assert_eq!(lint.json["obsolete_config_keys"], json!(["statuses"]));
    assert_eq!(lint.json["skipped"], json!([]));

    // Without the key lint is clean again.
    assert_disposable(p);
    let toml = read(p, "zwanenzang.toml");
    let line = toml.lines().find(|l| l.starts_with("statuses = ")).unwrap();
    std::fs::write(
        p.join("zwanenzang.toml"),
        toml.replace(&format!("{line}\n"), ""),
    )
    .unwrap();
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 0, "{}", lint.json);
    assert_eq!(lint.json["obsolete_config_keys"], json!([]));
}

#[test]
fn an_obsolete_statuses_key_with_an_unknown_name_is_a_config_error() {
    let d = tracker();
    let p = d.path();
    set_config_key(p, "retired_statuses", "[\"doing\"]");
    set_config_key(p, "statuses", "[\"todo\", \"doing\", \"parked\"]");
    for args in [&["list"][..], &["lint"], &["create", "A"]] {
        let e = err(p, args, "config");
        let message = e["error"]["message"].as_str().unwrap();
        assert!(message.contains("\"parked\""), "{message}");
        assert!(message.contains("retired_statuses"), "{message}");
    }
}

#[test]
fn a_fixed_status_cannot_be_retired() {
    let d = tracker();
    let p = d.path();
    set_config_key(p, "retired_statuses", "[\"draft\", \"wait\"]");
    let e = err(p, &["list"], "config");
    let message = e["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("\"wait\" is one of the fixed statuses"),
        "{message}"
    );
}

#[test]
fn review_without_needs_human_is_warned_about_but_written() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let o = run_in(p, &["status", &a, "revw"], "");
    assert_eq!(o.code, 0, "{}", o.json);
    assert_eq!(o.json["ticket"]["status"], "revw");
    assert!(o.json.get("warnings").is_none(), "{}", o.json);
    assert_eq!(
        o.stderr,
        "warning: ZZ-1: status revw without tag needs_human \
         (see `zz agent-hooks show-document tickets/statuses`)\n"
    );
    // A write that leaves the pairing missing warns again; one that does
    // not touch status or tags does not.
    let o = run_in(p, &["tag", &a, "ui"], "");
    assert!(
        o.stderr
            .contains("ZZ-1: status revw without tag needs_human"),
        "{}",
        o.stderr
    );
    let o = run_in(p, &["comment", &a, "Looked at it"], "");
    assert_eq!(o.stderr, "");
    let o = run_in(p, &["tag", &a, "needs_human"], "");
    assert_eq!(o.stderr, "");
    // Removing the tag from a ticket in review, as an Org edit may.
    let o = run_in(
        p,
        &["apply"],
        &json!({"changes": [{"op": "untag", "ticket": a, "data": {"tag": "needs_human"}}]})
            .to_string(),
    );
    assert_eq!(o.code, 0, "{}", o.json);
    assert!(
        o.stderr
            .contains("ZZ-1: status revw without tag needs_human"),
        "{}",
        o.stderr
    );
    // The pairing is judged after the whole write.
    let o = run_in(
        p,
        &["apply"],
        &json!({"changes": [
            {"op": "status", "ticket": a, "data": {"to": "agnt"}},
            {"op": "status", "ticket": a, "data": {"to": "revw"}},
            {"op": "tag", "ticket": a, "data": {"tag": "needs_human"}},
        ]})
        .to_string(),
    );
    assert_eq!(o.code, 0, "{}", o.json);
    assert_eq!(o.stderr, "");
    // Statuses other than revw pair with nothing.
    let o = run_in(p, &["create", "B", "--status", "wait"], "");
    assert_eq!(o.code, 0, "{}", o.json);
    assert_eq!(o.stderr, "");
}

fn run_actor(p: &std::path::Path, actor: Option<&str>, args: &[&str]) -> Out {
    run_as(p, actor, args, "", &[])
}

#[test]
fn init_lists_its_actor_name_and_agent() {
    let net = InitNet::new();
    let out = net.init("named-test-repo", &["--prefix", "ZZ"]);
    assert_eq!(out.code, 0, "{}", out.json);
    let d = net.dir.path().join("named-test-repo");
    assert!(
        read(&d, "zwanenzang.toml").contains("\nactors = [\"tester\", \"agent\"]\n"),
        "{}",
        read(&d, "zwanenzang.toml")
    );
    // A name that is not a vocabulary entry cannot be listed.
    let out = net.init(
        "spaced-test-repo",
        &["--prefix", "ZZ", "--actor-name", "two words"],
    );
    assert_eq!(out.json["error"]["code"], "config", "{}", out.json);
    assert!(!net.dir.path().join("spaced-test-repo").exists());
}

#[test]
fn identity_comes_from_the_flag_then_the_clone_default_else_refused() {
    let d = tracker();
    let p = d.path();
    let before = logs(p);
    let refused = run_actor(p, None, &["create", "nobody"]);
    assert_eq!(refused.code, 1);
    assert_eq!(refused.json["error"]["code"], "actor-required");
    assert!(
        refused.json["error"]["message"]
            .as_str()
            .unwrap()
            .contains("zwanenzang.defaultActor")
    );
    let unknown = run_actor(p, Some("stranger"), &["create", "nobody"]);
    assert_eq!(unknown.json["error"]["code"], "unknown-actor");
    assert!(
        unknown.json["error"]["message"]
            .as_str()
            .unwrap()
            .contains("tester, agent")
    );
    assert_eq!(logs(p), before);
    // Read-only commands and dry runs need no identity.
    assert_eq!(run_actor(p, None, &["list"]).code, 0);
    assert_eq!(run_actor(p, None, &["lint"]).code, 0);
    assert_eq!(run_as(p, None, &["read"], "{}", &[]).code, 0);
    assert_eq!(run_actor(p, None, &["sync"]).code, 0);

    let t = id(&ok(p, &["create", "flagged"]));
    git(
        p,
        &["config", "--local", "zwanenzang.defaultActor", "agent"],
    );
    let by_default = run_actor(p, None, &["comment", &t, "from the default"]);
    assert_eq!(by_default.code, 0, "{}", by_default.json);
    assert_eq!(by_default.json["event"]["as"], "agent");
    // The flag wins over the default.
    let flagged = run_actor(p, Some("tester"), &["tag", &t, "x"]);
    assert_eq!(flagged.json["event"]["as"], "tester");
    git(
        p,
        &["config", "--local", "zwanenzang.defaultActor", "nobody"],
    );
    let bad_default = run_actor(p, None, &["tag", &t, "y"]);
    assert_eq!(bad_default.json["error"]["code"], "unknown-actor");
    assert_eq!(run_in(p, &["lint"], "").code, 0);
}

#[test]
fn a_tracker_without_an_actors_list_refuses_named_writes() {
    let d = tracker();
    let p = d.path();
    let config = read(p, "zwanenzang.toml");
    let without: String = config
        .lines()
        .filter(|l| !l.starts_with("actors = "))
        .map(|l| format!("{l}\n"))
        .collect();
    assert_ne!(without, config);
    std::fs::write(p.join("zwanenzang.toml"), without).unwrap();
    let before = logs(p);
    let refused = run_actor(p, Some("tester"), &["create", "nobody"]);
    assert_eq!(refused.code, 1);
    assert_eq!(refused.json["error"]["code"], "actors-not-configured");
    assert!(
        refused.json["error"]["message"]
            .as_str()
            .unwrap()
            .contains(r#"actors = ["tester", "agent"]"#),
        "{}",
        refused.json
    );
    assert_eq!(logs(p), before);
    // Reads, and a sync with nothing to number, still work.
    assert_eq!(run_as(p, None, &["read"], "{}", &[]).code, 0);
    assert_eq!(run_actor(p, Some("tester"), &["sync"]).code, 0);
}

#[test]
fn outputs_show_the_identity_next_to_the_writer() {
    let d = tracker();
    let p = d.path();
    let t = id(&ok(p, &["create", "shown", "--tag", "seen"]));
    let writer = actor_of(p);
    run_ok_as(p, "agent", &["comment", &t, "agent note"]);
    let v1 = run_as(
        p,
        Some("agent"),
        &["doc", "set", &t, "plan", "--base", "none"],
        "the plan",
        &[],
    );
    assert_eq!(v1.code, 0, "{}", v1.json);
    let show = ok(p, &["show", &t]);
    assert_eq!(show["created"]["actor"], writer.as_str());
    assert_eq!(show["created"]["identity"], TESTER);
    assert_eq!(show["tag_since"]["seen"]["identity"], TESTER);
    assert_eq!(show["activity"]["identity"], "agent");
    assert_eq!(show["comments"][0]["actor"], writer.as_str());
    assert_eq!(show["comments"][0]["identity"], "agent");
    assert_eq!(
        show["documents"]["plan"]["versions"][0]["identity"],
        "agent"
    );
    assert_eq!(
        show["documents"]["plan"]["versions"][0]["actor"],
        writer.as_str()
    );
    let listed = &ok(p, &["list"])["tickets"][0];
    assert_eq!(listed["activity"]["identity"], "agent");
    let queried = &ok(p, &["query", &t])["tickets"][0];
    assert_eq!(queried["comments"][0]["identity"], "agent");
    let doc = ok(p, &["doc", "get", &t, "plan"]);
    assert_eq!(doc["actor"], writer.as_str());
    assert_eq!(doc["identity"], "agent");
    let read = ok_stdin(p, &["read"], "{}");
    let events = read["tickets"][0]["events"].as_array().unwrap();
    assert!(events.iter().all(|e| e["identity"] == e["as"]));
    assert_eq!(read["tracker"]["actors"], json!({&writer: TESTER}));
}

fn run_ok_as(p: &std::path::Path, actor: &str, args: &[&str]) -> Value {
    let o = run_actor(p, Some(actor), args);
    assert_eq!(o.code, 0, "{args:?} failed: {} {}", o.json, o.stderr);
    o.json
}

#[test]
fn events_without_as_resolve_to_the_writers_declared_name() {
    let d = tracker();
    let p = d.path();
    let t = id(&ok(p, &["create", "old"]));
    let writer = actor_of(p);
    let base = ok(p, &["show", &t])["last_event"]
        .as_str()
        .unwrap()
        .to_string();
    let next = |n: u128| {
        let b = zwanenzang::ulid::Ulid::parse_canonical(&base).unwrap();
        zwanenzang::ulid::Ulid(b.0 + n).to_canonical()
    };
    // As written before identities: no `as`, by the declared writer and by
    // a writer that never declared a name.
    let undeclared = "00000000000000000000000001";
    append_raw(
        p,
        &writer,
        &[line(
            &next(1),
            &writer,
            &base,
            &t,
            "comment",
            json!({"text": "old note"}),
        )],
    );
    append_raw(
        p,
        undeclared,
        &[line(
            &next(2),
            undeclared,
            &next(1),
            &t,
            "tag",
            json!({"tag": "stray"}),
        )],
    );
    let show = ok(p, &["show", &t]);
    assert_eq!(show["comments"][0]["identity"], TESTER);
    assert_eq!(show["tag_since"]["stray"]["identity"], Value::Null);
    let read = ok_stdin(p, &["read"], "{}");
    let events = read["tickets"][0]["events"].as_array().unwrap();
    let old = events.iter().find(|e| e["id"] == next(1).as_str()).unwrap();
    assert_eq!(old.get("as"), None);
    assert_eq!(old["identity"], TESTER);
    // Lint reports the writer whose events resolve to no identity, and an
    // event naming an identity the tracker does not list.
    let mut stranger: Value = serde_json::from_str(&line(
        &next(3),
        &writer,
        &next(2),
        &t,
        "tag",
        json!({"tag": "z"}),
    ))
    .unwrap();
    stranger["as"] = json!("stranger");
    append_raw(p, &writer, &[stranger.to_string()]);
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 1);
    assert_eq!(
        lint.json["unnamed_actors"],
        json!([{"actor": undeclared, "events": 1}])
    );
    assert_eq!(
        lint.json["unknown_identities"],
        json!([{"event": next(3), "actor": writer, "as": "stranger", "op": "tag"}])
    );
}

#[test]
fn schedule_echoes_shows_lists_reads_and_clears() {
    let d = tracker();
    let p = d.path();
    let t = id(&ok(p, &["create", "Check back later"]));
    // Several arguments are one value; a delay starting with `-` is a value.
    let out = ok(
        p,
        &["schedule", "ZZ-1", "<2026-12-03", "Thu", "10:00", "-2d>"],
    );
    assert_eq!(out["written"], true);
    assert_eq!(out["message"], "ZZ-1 scheduled 2026-12-03 Thu 10:00 -2d");
    assert_eq!(out["event"]["op"], "scheduled");
    assert_eq!(out["event"]["data"], json!({"to": "2026-12-03 10:00 -2d"}));
    assert_eq!(out["ticket"]["scheduled"], "2026-12-03 10:00 -2d");
    assert_eq!(ok(p, &["show", &t])["scheduled"], "2026-12-03 10:00 -2d");
    assert_eq!(
        ok(p, &["list"])["tickets"][0]["scheduled"],
        "2026-12-03 10:00 -2d"
    );
    let read = ok_stdin(p, &["read"], "{}");
    assert_eq!(
        read["tickets"][0]["ticket"]["scheduled"],
        "2026-12-03 10:00 -2d"
    );
    // The same date again writes nothing, and still says what it is.
    let again = ok(p, &["schedule", &t, "2026-12-03 10:00 -2d"]);
    assert_eq!(again["written"], false);
    assert_eq!(again["message"], "ZZ-1 scheduled 2026-12-03 Thu 10:00 -2d");
    let before = logs(p);
    let refused = err(p, &["schedule", &t, "2026-02-29"], "invalid-timestamp");
    assert!(
        refused["error"]["message"]
            .as_str()
            .unwrap()
            .contains("2026-02-29"),
        "{refused}"
    );
    err(
        p,
        &["schedule", &t, "[2026-12-03 Thu]"],
        "invalid-timestamp",
    );
    assert_eq!(logs(p), before);
    // Finishing the ticket keeps the date.
    ok(p, &["status", &t, "done"]);
    assert_eq!(ok(p, &["show", &t])["scheduled"], "2026-12-03 10:00 -2d");
    let cleared = ok(p, &["schedule", &t, "--clear"]);
    assert_eq!(cleared["message"], "ZZ-1 not scheduled");
    assert_eq!(cleared["ticket"]["scheduled"], Value::Null);
    let usage = run_in(p, &["schedule", &t], "");
    assert_eq!(usage.code, 2, "{}", usage.stderr);
}

#[test]
fn relative_schedule_uses_the_local_date_of_tz() {
    use zwanenzang::planning::Date;
    let d = tracker();
    let p = d.path();
    let t = id(&ok(p, &["create", "Relative"]));
    // Fourteen hours east and twelve west of UTC are always on different
    // days; each must be that zone's date at the time of the command.
    for (tz, offset_s) in [("UTC-14", 14 * 3600), ("UTC+12", -12 * 3600)] {
        let local_date = || {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64;
            Date::from_days((now + offset_s).div_euclid(86_400)).to_string()
        };
        let before = local_date();
        let out = run_in_env(p, &["schedule", &t, "today"], "", &[("TZ", tz)]);
        let after = local_date();
        assert_eq!(out.code, 0, "{}", out.json);
        let got = out.json["ticket"]["scheduled"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(got == before || got == after, "{tz}: {got}, not {before}");
    }
}
