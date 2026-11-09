mod common;

use common::*;
use serde_json::{Value, json};

#[test]
fn directed_edges_validate_atomically_but_never_veto_status() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "Prerequisite"]));
    let b = id(&ok(p, &["create", "Dependent"]));
    let c = id(&ok(p, &["create", "Third"]));
    ok(p, &["depend", &b, &a]);
    assert_eq!(ok(p, &["show", &b])["depends_on"], json!([a]));
    assert_eq!(ok(p, &["list"])["tickets"][0]["blocks"], json!([b]));
    assert_eq!(ok(p, &["depend", &b, &a])["written"], false);
    ok(p, &["depend", &c, &b]);
    for target in [&a, &c] {
        let before = logs(p);
        let out = run_in(p, &["depend", &a, target], "");
        assert_eq!(out.json["error"]["code"], "dependency-cycle");
        assert_eq!(logs(p), before);
    }
    // Batch rollback includes earlier valid changes and newly created tickets.
    let before = logs(p);
    let out = run_in(
        p,
        &["apply"],
        &json!({"changes":[
            {"op":"create", "data":{"title":"Must not survive"}},
            {"op":"depend", "ticket":{"created":0}, "data":{"to":c}},
            {"op":"depend", "ticket":a, "data":{"to":{"created":0}}}
        ]})
        .to_string(),
    );
    assert_eq!(out.json["error"]["code"], "dependency-cycle");
    assert_eq!(logs(p), before);
    ok(p, &["status", &c, "done"]);
    ok(p, &["archive", &a]);
    assert_eq!(ok(p, &["show", &b])["depends_on"], json!([a]));
    ok(p, &["tombstone", &a]);
    assert_eq!(ok(p, &["show", &b])["depends_on"], json!([a]));
    // Tombstoning is not silently deleting the relationship; removal still works.
    ok(p, &["depend", &b, &a, "--remove"]);
    assert_eq!(ok(p, &["show", &b])["depends_on"], json!([]));
    let out = run_in(p, &["depend", &b, &a], "");
    assert_eq!(out.json["error"]["code"], "target-tombstoned");
}

#[test]
fn batch_created_references_and_reverse_read_cursors() {
    let d = tracker();
    let p = d.path();
    let out = ok_stdin(
        p,
        &["apply"],
        &json!({"changes":[
            {"op":"create", "data":{"title":"A"}},
            {"op":"create", "data":{"title":"B"}},
            {"op":"depend", "ticket":{"created":1}, "data":{"to":{"created":0}}}
        ]})
        .to_string(),
    );
    let a = out["created"]["0"].as_str().unwrap();
    let b = out["created"]["1"].as_str().unwrap();
    let read = ok_stdin(
        p,
        &["read"],
        &json!({"cursors":{a:Value::Null,b:Value::Null},"since":null}).to_string(),
    );
    let entries = read["tickets"].as_array().unwrap();
    let cursor = &entries.iter().find(|e| e["ticket"]["id"] == a).unwrap()["cursor"];
    ok(p, &["depend", b, a, "--remove"]);
    let next = ok_stdin(
        p,
        &["read"],
        &json!({"cursors":{a:cursor},"since":read["cursor"]}).to_string(),
    );
    let entry = next["tickets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["ticket"]["id"] == a)
        .unwrap();
    assert_eq!(entry["ticket"]["blocks"], json!([]));
    assert_eq!(entry["events"].as_array().unwrap().len(), 1);
    assert_eq!(entry["events"][0]["op"], "undepend");
}
