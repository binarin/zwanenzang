//! Scope reads use only synthetic disposable trackers.
mod common;

use common::*;
use serde_json::{Value, json};

fn scope(p: &std::path::Path, request: Value) -> Value {
    ok_stdin(p, &["read"], &request.to_string())
}

fn entry<'a>(v: &'a Value, id: &str) -> &'a Value {
    v["tickets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["ticket"]["id"] == id)
        .unwrap()
}

#[test]
fn scope_discovery_documents_and_incremental_history() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "first"]));
    ok_stdin(
        p,
        &["doc", "set", &a, "description", "--base", "none"],
        "Human prose",
    );
    let before_logs = logs(p);
    let before_head = git(p, &["rev-parse", "HEAD"]);
    let first = scope(p, json!({}));
    assert_eq!(entry(&first, &a)["documents"]["description"], "Human prose");
    assert_eq!(first["tracker"]["statuses"][0], "draft");
    assert_eq!(entry(&first, &a)["events"][0]["op"], "create");
    assert_eq!(logs(p), before_logs);
    assert_eq!(git(p, &["rev-parse", "HEAD"]), before_head);
    let cursor = entry(&first, &a)["cursor"].clone();
    let request = json!({"cursors": {&a: cursor}, "since": first["cursor"]});
    let unchanged = scope(p, request.clone());
    assert_eq!(entry(&unchanged, &a)["events"], json!([]));
    assert_eq!(entry(&unchanged, &a)["cursor"], cursor);
    assert_eq!(entry(&unchanged, &a)["reset"], false);
    let status = ok(p, &["status", &a, "doing"]);
    let b = id(&ok(p, &["create", "second"]));
    let changed = scope(p, request);
    assert_eq!(changed["tickets"].as_array().unwrap().len(), 2);
    assert_eq!(entry(&changed, &a)["events"], json!([status["event"]]));
    assert_eq!(entry(&changed, &b)["ticket"]["title"], "second");
}

#[test]
fn absent_tickets_need_new_events_and_must_be_live() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "absent"]));
    let b = id(&ok(p, &["create", "archived"]));
    let c = id(&ok(p, &["create", "mistake"]));
    let first = scope(p, json!({}));
    ok(p, &["archive", &b]);
    ok(p, &["tombstone", &c]);
    assert_eq!(
        scope(p, json!({"since": first["cursor"]}))["tickets"],
        json!([])
    );
    ok(p, &["comment", &a, "new information"]);
    let found = scope(p, json!({"since": first["cursor"]}));
    assert_eq!(found["tickets"].as_array().unwrap().len(), 1);
    assert_eq!(found["tickets"][0]["ticket"]["id"], a);
    let known = scope(
        p,
        json!({"cursors": {&b: null, &c: null}, "since": found["cursor"]}),
    );
    assert_eq!(known["tickets"].as_array().unwrap().len(), 2);
    assert_eq!(entry(&known, &b)["ticket"]["archived"], true);
    assert_eq!(entry(&known, &c)["ticket"]["tombstoned"], true);
}

#[test]
fn indirect_events_cover_old_and_new_parents_relations_and_tombstones() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "parent one"]));
    let b = id(&ok(p, &["create", "parent two"]));
    let c = id(&ok(p, &["create", "child", "--parent", &a]));
    let first = scope(p, json!({}));
    let request = json!({"cursors": {
        &a: entry(&first, &a)["cursor"], &b: entry(&first, &b)["cursor"]
    }, "since": first["cursor"]});
    let moved = ok(p, &["parent", &c, &b]);
    let related = ok(p, &["relate", &c, &a]);
    let dead = ok(p, &["tombstone", &c]);
    let out = scope(p, request);
    assert_eq!(
        entry(&out, &a)["events"],
        json!([moved["event"], related["event"], dead["event"]])
    );
    assert_eq!(
        entry(&out, &b)["events"],
        json!([moved["event"], dead["event"]])
    );
    assert_eq!(entry(&out, &a)["ticket"]["children"], json!([]));
    assert_eq!(entry(&out, &a)["ticket"]["related"], json!([]));
    assert_eq!(entry(&out, &b)["ticket"]["children"], json!([]));
}

#[test]
fn late_earlier_event_resets_cursors_instead_of_silently_missing_it() {
    let d = tracker();
    let p = d.path();
    let created = ok(p, &["create", "concurrent"]);
    let a = id(&created);
    let base = created["sync"]["numbered"][0]["event"].as_str().unwrap();
    // Choose both ids explicitly so delivery order never depends on timing.
    let earlier = zwanenzang::ulid::Ulid::parse_canonical(base).unwrap();
    let event_id = zwanenzang::ulid::Ulid(earlier.0 + 1).to_canonical();
    let later_id = zwanenzang::ulid::Ulid(earlier.0 + 2).to_canonical();
    let writer = actor_of(p);
    append_raw(
        p,
        &writer,
        &[json!({"id": later_id, "actor": writer, "parent": base,
        "ts": "2026-11-07T00:00:00Z", "entity": a, "op": "title", "data": {"to": "later"}})
        .to_string()],
    );
    let first = scope(p, json!({}));
    let actor = "00000000000000000000000001";
    append_raw(
        p,
        actor,
        &[json!({"id": event_id, "actor": actor, "parent": base,
        "ts": "2026-11-07T00:00:00Z", "entity": a, "op": "tag", "data": {"tag": "late"}})
        .to_string()],
    );
    let out = scope(
        p,
        json!({"cursors": {&a: entry(&first, &a)["cursor"]}, "since": first["cursor"]}),
    );
    assert_eq!(out["reset"], true);
    assert_eq!(entry(&out, &a)["reset"], true);
    assert!(
        entry(&out, &a)["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["id"] == event_id)
    );
    assert_eq!(entry(&out, &a)["ticket"]["tags"], json!(["late"]));
}

#[test]
fn tracker_lists_declared_actor_names_only() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "named"]));
    let writer = actor_of(p);
    // An actor with an accepted event but no declaration has no name.
    let undeclared = "00000000000000000000000001";
    let base = ok(p, &["show", &a])["last_event"]
        .as_str()
        .unwrap()
        .to_string();
    let next =
        zwanenzang::ulid::Ulid(zwanenzang::ulid::Ulid::parse_canonical(&base).unwrap().0 + 1);
    append_raw(
        p,
        undeclared,
        &[
            json!({"id": next.to_canonical(), "actor": undeclared, "parent": base,
        "ts": "2026-11-07T00:00:00Z", "entity": a, "op": "tag", "data": {"tag": "x"}})
            .to_string(),
        ],
    );
    let out = scope(p, json!({}));
    assert_eq!(out["tracker"]["actors"], json!({&writer: "tester"}));
    assert_eq!(entry(&out, &a)["ticket"]["tags"], json!(["x"]));
}

#[test]
fn actor_declared_twice_has_its_latest_name() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "named"]));
    let writer = actor_of(p);
    let tracker_id = scope(p, json!({}))["tracker"]["id"].clone();
    // The writer's latest event is the number event of the create.
    let base = ok(p, &["show", &a])["last_event"]
        .as_str()
        .unwrap()
        .to_string();
    let next =
        zwanenzang::ulid::Ulid(zwanenzang::ulid::Ulid::parse_canonical(&base).unwrap().0 + 1);
    append_raw(
        p,
        &writer,
        &[
            json!({"id": next.to_canonical(), "actor": writer, "parent": base,
        "ts": "2026-11-07T00:00:00Z", "entity": tracker_id, "op": "actor",
        "data": {"name": "renamed"}})
            .to_string(),
        ],
    );
    assert_eq!(
        scope(p, json!({}))["tracker"]["actors"],
        json!({&writer: "renamed"})
    );
}

#[test]
fn invalid_requests_fail_without_writing_and_read_needs_no_git() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "readable"]));
    let before = logs(p);
    for request in [
        json!({"since": "bad"}),
        json!({"cursors": {&a: "bad"}}),
        json!({"unexpected": true}),
        json!({"cursors": {&a: null, "ZZ-0001": null}}),
    ] {
        let o = run_in(p, &["read"], &request.to_string());
        assert_eq!(o.code, 1);
        assert_eq!(o.json["error"]["code"], "invalid-argument");
    }
    let o = run_in(p, &["read"], r#"{"cursors":{"ZZ-9999":null}}"#);
    assert_eq!(o.json["error"]["code"], "unknown-ticket");
    assert_eq!(logs(p), before);
    assert_disposable(p);
    std::fs::remove_dir_all(p.join(".git")).unwrap();
    assert_eq!(scope(p, json!({}))["tickets"].as_array().unwrap().len(), 1);
}

#[test]
fn unarchive_is_in_history_and_brings_an_absent_ticket_back() {
    let d = tracker();
    let p = d.path();
    let a = id(&ok(p, &["create", "revived"]));
    let archived = ok(p, &["archive", &a]);
    let first = scope(p, json!({"cursors": {&a: null}}));
    let cursor = entry(&first, &a)["cursor"].clone();
    assert_eq!(
        entry(&first, &a)["events"].as_array().unwrap().last(),
        Some(&archived["event"])
    );
    // Archived and absent from the scope: not discovered, even from the start.
    assert_eq!(scope(p, json!({}))["tickets"], json!([]));

    let revived = ok(p, &["unarchive", &a]);
    assert_eq!(revived["event"]["op"], "unarchive");
    let known = scope(
        p,
        json!({"cursors": {&a: cursor}, "since": first["cursor"]}),
    );
    assert_eq!(entry(&known, &a)["events"], json!([revived["event"]]));
    assert_eq!(entry(&known, &a)["ticket"]["archived"], false);
    let absent = scope(p, json!({"since": first["cursor"]}));
    assert_eq!(absent["tickets"].as_array().unwrap().len(), 1);
    assert_eq!(entry(&absent, &a)["ticket"]["archived"], false);
}
