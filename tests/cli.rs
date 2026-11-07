//! The CLI's JSON contract, driven through the built binary.

mod common;

use common::*;
use serde_json::{Value, json};

#[test]
fn init_writes_tracker_files() {
    let d = disposable_dir();
    let out = ok(d.path(), &["init", "--prefix", "ZZ"]);
    assert_eq!(out["tracker"]["prefix"], "ZZ");
    assert!(
        out["tracker"]["name"]
            .as_str()
            .unwrap()
            .ends_with("-test-repo")
    );
    assert_eq!(out["tracker"]["statuses"][0], "draft");
    assert_eq!(
        read(d.path(), ".gitattributes"),
        "events/*.jsonl merge=union\n"
    );
    assert_eq!(read(d.path(), ".gitignore"), "/.zwanenzang/\n");
    assert_eq!(read(d.path(), ".zwanenzang/actor").trim(), out["actor"]);
    let toml = read(d.path(), "zwanenzang.toml");
    assert!(toml.contains(&format!(
        "id = \"{}\"",
        out["tracker"]["id"].as_str().unwrap()
    )));
    assert!(d.path().join("events").is_dir());
    assert!(d.path().join("blobs").is_dir());
    err(d.path(), &["init", "--prefix", "ZZ"], "already-initialized");
    // Nor anywhere inside the tracker.
    let sub = d.path().join("sub-test-repo");
    std::fs::create_dir(&sub).unwrap();
    err(&sub, &["init", "--prefix", "QQ"], "already-initialized");
    assert!(!sub.join("zwanenzang.toml").exists());
    let e = disposable_dir();
    err(e.path(), &["init", "--prefix", "zz"], "config");
}

#[test]
fn concurrent_inits_one_wins_and_reports_what_is_on_disk() {
    for _ in 0..10 {
        let d = disposable_dir();
        let p = d.path();
        let outs: Vec<Out> = std::thread::scope(|s| {
            let handles: Vec<_> = (0..6)
                .map(|_| s.spawn(|| run_in(p, &["init", "--prefix", "ZZ"], "")))
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        let winners: Vec<&Out> = outs.iter().filter(|o| o.code == 0).collect();
        assert_eq!(winners.len(), 1, "exactly one init succeeds");
        for o in outs.iter().filter(|o| o.code != 0) {
            assert_eq!(o.code, 1);
            assert_eq!(o.json["error"]["code"], "already-initialized");
        }
        let won = &winners[0].json;
        let toml = read(p, "zwanenzang.toml");
        assert!(
            toml.contains(&format!(
                "id = \"{}\"",
                won["tracker"]["id"].as_str().unwrap()
            )),
            "reported tracker id is the one on disk: {toml}"
        );
        assert_eq!(read(p, ".zwanenzang/actor").trim(), won["actor"]);
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
        json!({"title": "First ticket", "status": "draft", "kind": "bug"})
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
    assert_eq!(out["ticket"]["status"], "draft");
    assert_eq!(out["ticket"]["number"], Value::Null);
    assert_eq!(out["ticket"]["display"], out["ticket"]["short_id"]);
    assert_eq!(out["ticket"]["tags"], json!(["alpha", "beta"]));

    let out2 = ok(
        p,
        &[
            "create",
            "Child",
            "--status",
            "doing",
            "--parent",
            &t1[..12],
        ],
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
    assert_eq!(show["last_event"], out["events"][3]["id"]);
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
        ok(p, &["list", "--status", "doing"])["tickets"][0]["id"],
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
        ok(p, &["list", "--status", "draft", "--status", "doing"])["tickets"]
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
    assert_eq!(ok(p, &["status", &a, "doing"])["ticket"]["status"], "doing");
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
    err(p, &["status", "ZZZZZZ", "doing"], "unknown-ticket");
    err(p, &["status", "ZZ-0001", "doing"], "unknown-ticket");
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
        vec!["status", &a, "draft"],
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
    let first = ok(p, &["status", &a, "doing"]);
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 0, "{}", lint.json);
    assert_eq!(lint.json["ok"], true);
    assert_eq!(lint.json["events"], 3);

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
            line(
                later,
                other,
                create_id,
                &a,
                "status",
                json!({"to": "blocked"}),
            ),
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
    assert_eq!(ok(p, &["show", &a])["status"], "blocked");

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
    let actor = read(p, ".zwanenzang/actor").trim().to_string();
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
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "A"]));
    let actor = read(p, ".zwanenzang/actor").trim().to_string();
    // No CLI command writes numbers in this slice; publish will.
    let last = ok(p, &["show", &a])["last_event"]
        .as_str()
        .unwrap()
        .to_string();
    let n_id = "0GZZZZZZZZZZZZZZZZZZZZZZZZ";
    append_raw(
        p,
        &actor,
        &[line(
            n_id,
            &actor,
            &last,
            &a,
            "number",
            json!({"number": 42}),
        )],
    );
    let shown = ok(p, &["show", "ZZ-0042"]);
    assert_eq!(shown["id"], a.as_str());
    assert_eq!(shown["number"], 42);
    assert_eq!(shown["display"], "ZZ-0042");
    assert_eq!(ok(p, &["show", "zz-42"])["id"], a.as_str());
}
