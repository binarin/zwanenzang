//! The PROJ rule: a ticket tagged PROJ changes status only once its whole
//! subtree is finished, and then only to done or cncl.

mod common;

use common::*;
use serde_json::{Value, json};
use std::path::Path;

fn create(p: &Path, args: &[&str]) -> String {
    let mut all = vec!["create"];
    all.extend_from_slice(args);
    id(&ok(p, &all))
}

fn status(p: &Path, t: &str) -> String {
    ok(p, &["show", t])["status"].as_str().unwrap().to_string()
}

/// Refused with `proj-hierarchy`, writing nothing.
fn refused(p: &Path, args: &[&str], stdin: &str) -> String {
    let before = logs(p);
    let head = git(p, &["rev-parse", "HEAD"]);
    let out = run_in(p, args, stdin);
    assert_eq!(out.code, 1, "{args:?}: {}", out.json);
    assert_eq!(out.json["error"]["code"], "proj-hierarchy", "{}", out.json);
    assert_eq!(logs(p), before);
    assert_eq!(git(p, &["rev-parse", "HEAD"]), head);
    out.json["error"]["message"].as_str().unwrap().to_string()
}

fn apply_stdin(changes: Value) -> String {
    json!({ "changes": changes }).to_string()
}

#[test]
fn an_open_descendant_refuses_every_status_change() {
    let d = tracker();
    let p = d.path();
    let proj = create(p, &["Project", "--tag", "PROJ"]);
    let child = create(p, &["Child", "--parent", &proj]);
    let grandchild = create(p, &["Grandchild", "--parent", &child, "--status", "next"]);
    for to in ["next", "wait", "agnt", "revw", "done", "cncl"] {
        let message = refused(p, &["status", &proj, to], "");
        assert!(message.contains("ZZ-1"), "{message}");
        assert!(message.contains("ZZ-2, ZZ-3"), "{message}");
    }
    // The same status again changes nothing and is no refusal.
    assert_eq!(ok(p, &["status", &proj, "todo"])["written"], false);
    // A finished child does not finish the open grandchild below it.
    ok(p, &["status", &child, "done"]);
    let message = refused(p, &["status", &proj, "done"], "");
    assert!(message.contains("(ZZ-3)"), "{message}");
    ok(p, &["status", &grandchild, "cncl"]);
    ok(p, &["status", &proj, "done"]);
    assert_eq!(status(p, &proj), "done");
}

#[test]
fn a_finished_subtree_allows_only_done_or_cncl() {
    let d = tracker();
    let p = d.path();
    let proj = create(p, &["Project", "--tag", "PROJ"]);
    create(p, &["Child", "--parent", &proj, "--status", "done"]);
    for to in ["next", "wait", "agnt", "revw"] {
        let message = refused(p, &["status", &proj, to], "");
        assert!(message.contains("only become done or cncl"), "{message}");
    }
    ok(p, &["status", &proj, "cncl"]);
    ok(p, &["status", &proj, "done"]);
    // Reopening a finished project is always allowed; then the rule
    // applies again.
    ok(p, &["status", &proj, "todo"]);
    refused(p, &["status", &proj, "next"], "");
    ok(p, &["status", &proj, "done"]);
    // A project without children has a finished subtree too.
    let empty = create(p, &["Empty project", "--tag", "PROJ"]);
    refused(p, &["status", &empty, "next"], "");
    ok(p, &["status", &empty, "done"]);
}

#[test]
fn tombstoned_descendants_are_ignored_and_archived_ones_count_by_status() {
    let d = tracker();
    let p = d.path();
    let proj = create(p, &["Project", "--tag", "PROJ"]);
    let mistake = create(p, &["Mistake", "--parent", &proj]);
    let below = create(
        p,
        &[
            "Below the mistake",
            "--parent",
            &mistake,
            "--status",
            "done",
        ],
    );
    let archived = create(p, &["Archived", "--parent", &proj]);
    ok(p, &["archive", &archived]);
    ok(p, &["tombstone", &mistake]);
    // Archiving does not finish a ticket.
    let message = refused(p, &["status", &proj, "done"], "");
    assert!(message.contains("(ZZ-4)"), "{message}");
    ok(p, &["status", &archived, "done"]);
    // A live child below the tombstoned one still counts.
    ok(p, &["status", &below, "todo"]);
    let message = refused(p, &["status", &proj, "done"], "");
    assert!(message.contains("(ZZ-3)"), "{message}");
    ok(p, &["status", &below, "done"]);
    ok(p, &["status", &proj, "done"]);
}

#[test]
fn other_parents_and_untagged_tickets_are_unaffected() {
    let d = tracker();
    let p = d.path();
    let parent = create(p, &["Plain parent", "--tag", "proj"]);
    create(p, &["Open child", "--parent", &parent]);
    for to in ["next", "done", "todo", "cncl"] {
        ok(p, &["status", &parent, to]);
    }
    let lone = create(p, &["Lone"]);
    ok(p, &["status", &lone, "agnt"]);
}

#[test]
fn create_and_batches_are_judged_as_a_whole_write() {
    let d = tracker();
    let p = d.path();
    // A new PROJ ticket starts from the default status; another one is a
    // change, here to an unfinished status of a childless project.
    refused(
        p,
        &["create", "Project", "--tag", "PROJ", "--status", "next"],
        "",
    );
    create(
        p,
        &["Finished project", "--tag", "PROJ", "--status", "done"],
    );
    let proj = create(p, &["Project", "--tag", "PROJ"]);
    let child = create(p, &["Child", "--parent", &proj]);
    // Parent first, as the Org client sends it: the write as a whole
    // finishes the subtree, so it is accepted.
    ok_stdin(
        p,
        &["apply"],
        &apply_stdin(json!([
            {"op": "status", "ticket": proj, "data": {"to": "done"}},
            {"op": "status", "ticket": child, "data": {"to": "done"}}
        ])),
    );
    assert_eq!(status(p, &proj), "done");
    // A batch adding the tag and changing the status is a PROJ change.
    let other = create(p, &["Other"]);
    create(p, &["Its child", "--parent", &other]);
    refused(
        p,
        &["apply"],
        &apply_stdin(json!([
            {"op": "tag", "ticket": other, "data": {"tag": "PROJ"}},
            {"op": "status", "ticket": other, "data": {"to": "done"}}
        ])),
    );
    // A refusal anywhere rolls back the whole batch, creates included.
    refused(
        p,
        &["apply"],
        &apply_stdin(json!([
            {"op": "create", "data": {"title": "Must not survive"}},
            {"op": "status", "ticket": other, "data": {"to": "next"}},
            {"op": "tag", "ticket": other, "data": {"tag": "PROJ"}}
        ])),
    );
    // Removing the tag is not refused, and then the status is free.
    ok(p, &["tag", &proj, "PROJ", "--remove"]);
    ok(p, &["status", &proj, "todo"]);
}

#[test]
fn lint_reports_unfinished_tickets_under_a_finished_project() {
    let d = tracker();
    let p = d.path();
    let proj = create(p, &["Project", "--tag", "PROJ"]);
    let child = create(p, &["Child", "--parent", &proj, "--status", "done"]);
    ok(p, &["status", &proj, "done"]);
    assert_eq!(run_in(p, &["lint"], "").code, 0);
    // Reopening a child and adding an open one are not refused.
    ok(p, &["status", &child, "next"]);
    let added = create(p, &["Added later", "--parent", &proj]);
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 1, "{}", lint.json);
    assert_eq!(
        lint.json["proj_open_descendants"],
        json!([{"ticket": proj, "status": "done", "unfinished": [child, added]}])
    );
    // Reopening the project, despite its open descendants, also clears it.
    ok(p, &["status", &proj, "next"]);
    assert_eq!(run_in(p, &["lint"], "").code, 0);
    refused(p, &["status", &proj, "done"], "");
    // And from one finished status to the other is still a change.
    ok(p, &["status", &child, "done"]);
    ok(p, &["status", &added, "cncl"]);
    ok(p, &["status", &proj, "done"]);
    ok(p, &["status", &added, "todo"]);
    refused(p, &["status", &proj, "cncl"], "");
    assert_eq!(run_in(p, &["lint"], "").code, 1);
}
