mod common;

use common::*;
use serde_json::{Value, json};
use std::path::Path;

fn apply(p: &Path, changes: Value) -> Value {
    ok_stdin(p, &["apply"], &json!({"changes": changes}).to_string())
}

fn refuses(p: &Path, request: Value, code: &str) {
    let before = logs(p);
    let head = git(p, &["rev-parse", "HEAD"]);
    let blobs: Vec<_> = std::fs::read_dir(p.join("blobs"))
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    let out = run_in(p, &["apply"], &request.to_string());
    assert_eq!(out.code, 1, "{}", out.json);
    assert_eq!(out.json["error"]["code"], code, "{}", out.json);
    assert_eq!(logs(p), before);
    assert_eq!(git(p, &["rev-parse", "HEAD"]), head);
    let after: Vec<_> = std::fs::read_dir(p.join("blobs"))
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(after, blobs, "validation must not leave blobs");
}

#[test]
fn native_priority_is_nullable_batched_and_range_configurable() {
    let d = tracker();
    let p = d.path();
    let out = apply(
        p,
        json!([
            {"op":"create", "data":{"title":"Synthetic priority"}},
            {"op":"priority", "ticket":{"created":0}, "data":{"to":65}}
        ]),
    );
    let id = out["created"]["0"].as_str().unwrap();
    assert_eq!(out["tickets"][0]["priority"], 65);
    let unchanged = ok(p, &["priority", id, "65"]);
    assert_eq!(unchanged["written"], false);
    refuses(
        p,
        json!({"changes":[
            {"op":"title","ticket":id,"data":{"to":"Must not land"}},
            {"op":"priority","ticket":id,"data":{"to":10}}
        ]}),
        "invalid-priority",
    );
    assert_eq!(ok(p, &["show", id])["title"], "Synthetic priority");
    assert_eq!(
        ok(p, &["priority", id, "--clear"])["ticket"]["priority"],
        Value::Null
    );
    assert_disposable(p);
    let config = std::fs::read_to_string(p.join("zwanenzang.toml"))
        .unwrap()
        .replace("highest = 65", "highest = 1")
        .replace("lowest = 67", "lowest = 12")
        .replace("default = 66", "default = 5");
    std::fs::write(p.join("zwanenzang.toml"), config).unwrap();
    assert_eq!(ok(p, &["priority", id, "12"])["ticket"]["priority"], 12);
    // Narrowing the live range never retroactively rejects old priority events.
    assert_eq!(ok(p, &["show", id])["priority"], 12);
    assert_eq!(
        ok_stdin(p, &["read"], "{}")["tracker"]["priority"]["default"],
        5
    );
}

#[test]
fn creations_references_and_results_survive_interleaved_noops() {
    let d = tracker();
    let p = d.path();
    let before = git(p, &["rev-parse", "HEAD"]);
    let out = apply(
        p,
        json!([
            {"op":"create", "data":{"title":"Synthetic parent"}},
            {"op":"status", "ticket":{"created":0}, "data":{"to":"draft"}},
            {"op":"create", "data":{"title":"Synthetic child", "kind":"task", "status":"todo"}},
            {"op":"parent", "ticket":{"created":2}, "data":{"to":{"created":0}}},
            {"op":"relate", "ticket":{"created":0}, "data":{"to":{"created":2}}},
            {"op":"doc", "ticket":{"created":2}, "data":{"name":"description", "text":"Synthetic text", "base":null}},
            {"op":"tag", "ticket":{"created":2}, "data":{"tag":"example"}}
        ]),
    );
    let parent = out["created"]["0"].as_str().unwrap();
    let child = out["created"]["2"].as_str().unwrap();
    assert_eq!(out["created"].as_object().unwrap().len(), 2);
    assert_eq!(out["results"].as_array().unwrap().len(), 7);
    assert_eq!(
        out["results"][1],
        json!({"ticket":parent,"written":false,"event":null})
    );
    for (i, result) in out["results"].as_array().unwrap().iter().enumerate() {
        if i != 1 {
            let event = out["events"]
                .as_array()
                .unwrap()
                .iter()
                .find(|e| e["id"] == result["event"])
                .unwrap();
            assert_eq!(event["entity"], result["ticket"]);
        }
    }
    let t = ok(p, &["show", child]);
    assert_eq!(t["parent"], parent);
    assert_eq!(t["related"], json!([parent]));
    assert_eq!(t["tags"], json!(["example"]));
    assert_eq!(
        ok(p, &["doc", "get", child, "description"])["text"],
        "Synthetic text"
    );
    assert_eq!(out["tickets"][0]["number"], 1);
    assert_eq!(out["tickets"][1]["number"], 2);
    assert_eq!(
        git(
            p,
            &["rev-list", "--count", &format!("{}..HEAD", before.trim())]
        )
        .trim(),
        "2",
        "one mutation plus publish"
    );
    assert_eq!(
        git(p, &["log", "--format=%s", "-2"]),
        "publish ZZ-1, ZZ-2\napply client batch\n"
    );
    assert_eq!(run_in(p, &["lint"], "").code, 0);
}

#[test]
fn validation_rolls_back_every_change_and_pending_blob() {
    let d = tracker();
    let p = d.path();
    refuses(
        p,
        json!({"changes":[
            {"op":"create","data":{"title":"Synthetic ticket"}},
            {"op":"doc","ticket":{"created":0},"data":{"name":"description","text":"Pending text","base":null}},
            {"op":"status","ticket":{"created":0},"data":{"to":"not-configured"}}
        ]}),
        "status-not-in-vocabulary",
    );
    assert_eq!(ok(p, &["list"])["tickets"], json!([]));
    refuses(
        p,
        json!({"changes":[
            {"op":"create","data":{"title":"Synthetic ticket"}},
            {"op":"parent","ticket":{"created":0},"data":{"to":{"created":0}}}
        ]}),
        "parent-cycle",
    );
}

#[test]
fn document_bases_are_explicit_and_checked_even_for_identical_text() {
    let d = tracker();
    let p = d.path();
    let id = id(&ok(p, &["create", "Synthetic ticket"]));
    let first = apply(
        p,
        json!([
            {"op":"doc","ticket":id,"data":{"name":"description","text":"First","base":null}}
        ]),
    );
    let base = first["results"][0]["event"].clone();
    for data in [
        json!({"name":"description","text":"First"}),
        json!({"name":"description","text":"First","base":null}),
        json!({"name":"description","text":"First","base":"bad"}),
    ] {
        let code = if data.get("base").is_some_and(Value::is_null) {
            "stale-doc-base"
        } else {
            "invalid-argument"
        };
        refuses(
            p,
            json!({"changes":[
                {"op":"tag","ticket":id,"data":{"tag":"pending"}},
                {"op":"doc","ticket":id,"data":data}
            ]}),
            code,
        );
    }
    let head = git(p, &["rev-parse", "HEAD"]);
    let noop = apply(
        p,
        json!([
            {"op":"doc","ticket":id,"data":{"name":"description","text":"First","base":base}}
        ]),
    );
    assert_eq!(noop["written"], false);
    assert_eq!(noop["sync"], Value::Null);
    assert_eq!(noop["results"][0]["event"], Value::Null);
    assert_eq!(
        noop["tickets"][0]["documents"]["description"]["current"],
        base
    );
    assert_eq!(git(p, &["rev-parse", "HEAD"]), head);
    let update = apply(
        p,
        json!([
            {"op":"doc","ticket":id,"data":{"name":"description","text":"Second","base":base}}
        ]),
    );
    assert_eq!(update["written"], true);
    assert_eq!(ok(p, &["doc", "get", &id, "description"])["text"], "Second");
    let empty = apply(
        p,
        json!([
            {"op":"doc","ticket":id,"data":{"name":"description","text":"","base":update["results"][0]["event"]}}
        ]),
    );
    assert_eq!(empty["written"], true);
    assert_eq!(ok(p, &["doc", "get", &id, "description"])["text"], "");
    // A second write in a batch observes the first version, so its old base fails.
    refuses(
        p,
        json!({"changes":[
            {"op":"doc","ticket":id,"data":{"name":"notes","text":"One","base":null}},
            {"op":"doc","ticket":id,"data":{"name":"notes","text":"Two","base":null}}
        ]}),
        "stale-doc-base",
    );
}

#[test]
fn empty_and_all_noop_batches_do_not_commit_or_sync() {
    let d = tracker();
    let p = d.path();
    let ticket = ok(p, &["create", "Synthetic ticket"]);
    let head = git(p, &["rev-parse", "HEAD"]);
    let empty = apply(p, json!([]));
    assert_eq!(
        empty,
        json!({"written":false,"results":[],"created":{},"tickets":[],"events":[],"sync":null})
    );
    let out = apply(
        p,
        json!([
            {"op":"status","ticket":"zz-1","data":{"to":"draft"}},
            {"op":"title","ticket":id(&ticket),"data":{"to":"Synthetic ticket"}},
            {"op":"status","ticket":ticket["ticket"]["short_id"].as_str().unwrap().to_ascii_lowercase(),"data":{"to":"draft"}}
        ]),
    );
    assert_eq!(out["written"], false);
    assert_eq!(out["tickets"].as_array().unwrap().len(), 1);
    assert_eq!(out["sync"], Value::Null);
    assert_eq!(out["events"], json!([]));
    assert_eq!(git(p, &["rev-parse", "HEAD"]), head);
}

#[test]
fn malformed_requests_references_and_unsupported_operations_fail_atomically() {
    let d = tracker();
    let p = d.path();
    for request in [
        json!({}),
        json!({"changes":[],"extra":true}),
        json!({"changes":[{"op":"create","ticket":"ZZ-1","data":{"title":"Synthetic"}}]}),
        json!({"changes":[{"op":"status","data":{"to":"todo"}}]}),
        json!({"changes":[{"op":"create","data":{"title":"Synthetic","extra":1}}]}),
        json!({"changes":[{"op":"create","data":{"title":"Synthetic"},"extra":1}]}),
        json!({"changes":[{"op":"number","ticket":"ZZ-1","data":{"number":2}}]}),
        json!({"changes":[{"op":"status","ticket":{"created":0},"data":{"to":"todo"}},{"op":"create","data":{"title":"Later"}}]}),
        json!({"changes":[{"op":"create","data":{"title":"Synthetic"}},{"op":"parent","ticket":{"created":0},"data":{}}]}),
        json!({"changes":[{"op":"create","data":{"title":"Synthetic"}},{"op":"kind","ticket":{"created":0},"data":{}}]}),
    ] {
        refuses(p, request, "invalid-argument");
    }
    refuses(
        p,
        json!({"changes":[{"op":"create","data":{"title":"Synthetic"}},{"op":"relate","ticket":{"created":0},"data":{"to":"ZZ-9999"}}]}),
        "unknown-ticket",
    );
}

#[test]
fn metadata_comments_and_lifecycle_use_the_shared_rules() {
    let d = tracker();
    let p = d.path();
    append_config(
        p,
        "\n[repos.example]\nurl = \"https://example.invalid/repo\"\n",
    );
    let a = id(&ok(p, &["create", "Synthetic A"]));
    let b = id(&ok(p, &["create", "Synthetic B"]));
    let long = "Long synthetic comment. ".repeat(120);
    let out = apply(
        p,
        json!([
            {"op":"kind","ticket":a,"data":{"to":"bug"}},
            {"op":"kind","ticket":a,"data":{"to":null}},
            {"op":"parent","ticket":a,"data":{"to":b}},
            {"op":"parent","ticket":a,"data":{"to":null}},
            {"op":"relate","ticket":a,"data":{"to":b}},
            {"op":"unrelate","ticket":b,"data":{"to":a}},
            {"op":"tag","ticket":a,"data":{"tag":"sample"}},
            {"op":"untag","ticket":a,"data":{"tag":"sample"}},
            {"op":"branch","ticket":a,"data":{"repo":"example","name":"sample"}},
            {"op":"mr","ticket":a,"data":{"repo":"example","url":"https://example.invalid/pulls/1"}},
            {"op":"comment","ticket":a,"data":{"text":"Short comment","link":"https://example.invalid"}},
            {"op":"comment","ticket":a,"data":{"text":long}},
            {"op":"archive","ticket":a,"data":{}},
            {"op":"tombstone","ticket":b,"data":{}}
        ]),
    );
    assert!(
        out["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["written"] == true)
    );
    let t = ok(p, &["show", &a]);
    assert_eq!(t["comments"][1]["text"], long);
    assert!(t["comments"][1]["blob"].is_string());
    assert!(t["comments"][0]["blob"].is_null());
    assert_eq!(t["archived"], true);
    assert_eq!(t["kind"], Value::Null);
    assert_eq!(t["parent"], Value::Null);
    assert_eq!(t["related"], json!([]));
    assert_eq!(t["tags"], json!([]));
    refuses(
        p,
        json!({"changes":[{"op":"title","ticket":b,"data":{"to":"After tombstone"}}]}),
        "tombstoned",
    );
    refuses(
        p,
        json!({"changes":[{"op":"comment","ticket":a,"data":{"text":" ".repeat(3000)}}]}),
        "invalid-comment",
    );
    assert_eq!(run_in(p, &["lint"], "").code, 0);
}

#[test]
fn unarchive_in_a_batch_keeps_positions_for_noops_and_refuses_tombstones() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "Synthetic A"]));
    let b = id(&ok(p, &["create", "Synthetic B"]));
    ok(p, &["status", &a, "doing"]);
    ok(p, &["archive", &a]);
    let out = apply(
        p,
        json!([
            {"op":"unarchive","ticket":b,"data":{}},
            {"op":"unarchive","ticket":a,"data":{}},
            {"op":"unarchive","ticket":a,"data":{}},
            {"op":"archive","ticket":b,"data":{}},
            {"op":"unarchive","ticket":b,"data":{}}
        ]),
    );
    let written: Vec<_> = out["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["written"].as_bool().unwrap())
        .collect();
    assert_eq!(written, vec![false, true, false, true, true]);
    let shown = ok(p, &["show", &a]);
    assert_eq!(shown["archived"], false);
    assert_eq!(shown["status"], "doing");
    assert_eq!(ok(p, &["show", &b])["archived"], false);

    refuses(
        p,
        json!({"changes":[{"op":"unarchive","ticket":a,"data":{"to":"x"}}]}),
        "invalid-argument",
    );
    ok(p, &["tombstone", &b]);
    refuses(
        p,
        json!({"changes":[
            {"op":"archive","ticket":a,"data":{}},
            {"op":"unarchive","ticket":b,"data":{}}
        ]}),
        "tombstoned",
    );
}
