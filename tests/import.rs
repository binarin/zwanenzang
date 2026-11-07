//! `import ai-workflow` against the synthetic fixture, through the built
//! binary. Every tracker and every source copy is a disposable directory.

mod common;

use std::path::{Path, PathBuf};

use common::*;
use serde_json::{Value, json};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ai-workflow")
}

const REPOS: &str = "\n[repos.app]\nurl = \"https://forge.example/owner/app\"\n\
                     [repos.site]\nurl = \"https://forge.example/owner/docs-site\"\n";

/// A tracker that declares the fixture's repositories, with `docs-site`
/// imported as `site`.
fn target() -> tempfile::TempDir {
    let d = tracker();
    append_config(d.path(), REPOS);
    d
}

fn import(dir: &Path, source: &Path, extra: &[&str]) -> Value {
    let src = source.to_str().unwrap();
    let mut args = vec![
        "import",
        "ai-workflow",
        src,
        "--repo-alias",
        "docs-site=site",
    ];
    args.extend_from_slice(extra);
    ok(dir, &args)
}

fn by_source(report: &Value) -> std::collections::BTreeMap<String, Value> {
    report["imported"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| (t["source"].as_str().unwrap().to_string(), t.clone()))
        .collect()
}

fn codes(report: &Value) -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = report["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| {
            (
                w["source"].as_str().unwrap_or("-").to_string(),
                w["code"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    v.sort();
    v
}

fn comment_texts(ticket: &Value) -> Vec<String> {
    ticket["comments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["text"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn imports_every_frontmatter_shape() {
    let d = target();
    let p = d.path();
    let report = import(p, &fixture(), &["--exclude", "AIWF-0004"]);
    assert_eq!(report["dry_run"], false);
    assert_eq!(report["source"]["revision"], Value::Null);
    let t = by_source(&report);
    assert_eq!(
        t.keys().collect::<Vec<_>>(),
        [
            "AIWF-0001",
            "AIWF-0002",
            "AIWF-0003",
            "AIWF-0005",
            "AIWF-0006",
            "AIWF-0007",
            "AIWF-0008",
            "AIWF-0010"
        ]
    );
    assert_eq!(
        report["excluded"],
        json!([{"source": "AIWF-0004", "file": "tickets/AIWF-0004-process-only-ticket.md"}])
    );
    assert_eq!(report["already_imported"], json!([]));

    // Status mapping, including unknown and missing statuses.
    let statuses: Vec<(&str, &str)> = t
        .iter()
        .map(|(k, v)| (k.as_str(), v["status"].as_str().unwrap()))
        .collect();
    assert_eq!(
        statuses,
        [
            ("AIWF-0001", "done"),
            ("AIWF-0002", "todo"),
            ("AIWF-0003", "todo"),
            ("AIWF-0005", "draft"),
            ("AIWF-0006", "draft"),
            ("AIWF-0007", "review"),
            ("AIWF-0008", "blocked"),
            ("AIWF-0010", "draft"),
        ]
    );
    assert_eq!(t["AIWF-0002"]["source_status"], "needs-triage");
    assert_eq!(t["AIWF-0006"]["source_status"], Value::Null);

    assert_eq!(
        codes(&report),
        [
            ("-".into(), "skipped-file".into()),
            ("AIWF-0001".into(), "missing-doc-file".into()),
            ("AIWF-0002".into(), "unknown-field".into()),
            ("AIWF-0005".into(), "no-title".into()),
            ("AIWF-0005".into(), "unknown-status".into()),
            ("AIWF-0006".into(), "no-frontmatter".into()),
            ("AIWF-0006".into(), "unknown-status".into()),
        ]
    );
    let mut dropped: Vec<Value> = report["dropped_references"].as_array().unwrap().clone();
    dropped.sort_by_key(|v| v.to_string());
    let mut want = vec![
        json!({"source": "AIWF-0001", "field": "related", "target": "AIWF-0004", "reason": "excluded"}),
        json!({"source": "AIWF-0001", "field": "related", "target": "AIWF-0099", "reason": "missing"}),
        json!({"source": "AIWF-0007", "field": "original-ticket", "target": "AIWF-0004", "reason": "excluded"}),
        json!({"source": "AIWF-0007", "field": "parent", "target": "AIWF-0004", "reason": "excluded"}),
        json!({"source": "AIWF-0007", "field": "related", "target": "AIWF-0007", "reason": "self"}),
    ];
    want.sort_by_key(|v| v.to_string());
    assert_eq!(dropped, want);

    let id = |s: &str| t[s]["id"].as_str().unwrap().to_string();
    let show = |s: &str| ok(p, &["show", &id(s)]);

    // Title, description, branches, merge requests, kept fields.
    let one = show("AIWF-0001");
    assert_eq!(one["title"], "Build the sample widget tool");
    assert_eq!(one["number"], Value::Null);
    assert_eq!(one["short_id"].as_str().unwrap().len(), 10);
    assert_eq!(
        one["branches"],
        json!([{"repo": "app", "name": "aiwf-0001-widgets"}])
    );
    assert_eq!(
        one["mrs"],
        json!([
            {"repo": "app", "url": "https://forge.example/owner/app/pulls/1"},
            {"repo": "app", "url": "https://forge.example/owner/app/pulls/2"}
        ])
    );
    assert_eq!(one["related"], json!([id("AIWF-0002")]));
    assert_eq!(one["children"], json!([id("AIWF-0002")]));
    let desc = ok(p, &["doc", "get", &id("AIWF-0001"), "description"]);
    let text = desc["text"].as_str().unwrap();
    assert!(
        text.starts_with("## Current\n\nThe widget tool counts widgets."),
        "{text}"
    );
    assert!(text.ends_with("[glossary]: ../docs/shared.md\n"), "{text}");
    assert!(!text.contains("# Build"), "the title is not repeated");
    let comments = comment_texts(&one);
    assert_eq!(
        comments[0],
        "Imported from the ai-workflow tracker: AIWF-0001\n\
         Source file: tickets/AIWF-0001-sample-widget-tooling.md\n\
         Status there: done (imported as done)\n\
         \n\
         Frontmatter kept as text:\n\
         \n\
         handoff:\n  stage: ready-for-review\n  kind: code-review\n  outcome: complete\n\
         \x20 proposed-status: done\n  checkpoint:\n"
    );
    let links: Vec<&Value> = one["comments"].as_array().unwrap()[1..]
        .iter()
        .map(|c| &c["link"])
        .collect();
    assert_eq!(
        links,
        [&json!("docs/AIWF-0001-notes.md"), &json!("docs/shared.md")]
    );

    // Quoted status, non-ASCII, parent, original-ticket as a relation,
    // an unknown field kept as text.
    let two = show("AIWF-0002");
    assert_eq!(two["title"], "Gadgets für Ünïcode — naïve café 雪");
    assert_eq!(two["parent"], json!(id("AIWF-0001")));
    assert_eq!(two["related"], json!([id("AIWF-0001")]));
    let prov = &comment_texts(&two)[0];
    assert!(prov.contains("Original ticket: AIWF-0001\n"), "{prov}");
    assert!(
        prov.ends_with("Frontmatter kept as text:\n\nblocked-by: AIWF-0003\n"),
        "{prov}"
    );
    let desc = ok(p, &["doc", "get", &id("AIWF-0002"), "description"]);
    assert_eq!(
        desc["text"],
        "Text with non-ASCII: Grüße, ½, ✓ and 雪.\nUses the [glossary](../docs/shared.md) as well.\n"
    );

    // A heading inside a fence is not the title.
    let three = show("AIWF-0003");
    assert_eq!(three["title"], "Sprockets after a fenced block");
    assert_eq!(three["related"], json!([id("AIWF-0007")]));

    // No heading: the title comes from the file name, the whole body is
    // the description.
    let five = show("AIWF-0005");
    assert_eq!(five["title"], "no title heading");
    assert!(comment_texts(&five)[0].contains("Status there: in-limbo (imported as draft)\n"));
    let desc = ok(p, &["doc", "get", &id("AIWF-0005"), "description"]);
    assert_eq!(
        desc["text"],
        "A body without any level-one heading.\n\n## Only a subheading\n"
    );

    // References into the excluded ticket leave nothing behind.
    let seven = show("AIWF-0007");
    assert_eq!(seven["parent"], Value::Null);
    assert_eq!(seven["related"], json!([id("AIWF-0003")]));

    // Two repositories, one renamed.
    let eight = show("AIWF-0008");
    assert_eq!(
        eight["branches"],
        json!([{"repo": "app", "name": "aiwf-0008-both"}, {"repo": "site", "name": "aiwf-0008-pages"}])
    );
    assert_eq!(eight["mrs"][0]["repo"], "site");

    // An empty body leaves no description.
    let ten = show("AIWF-0010");
    assert_eq!(ten["documents"], json!({}));

    // Supporting files: copied when linked from an imported ticket only.
    assert_eq!(
        report["docs"],
        json!([
            {"path": "docs/AIWF-0001-notes.md", "linked_from": ["AIWF-0001"], "existing": false},
            {"path": "docs/AIWF-0003-plan.md", "linked_from": ["AIWF-0003"], "existing": false},
            {"path": "docs/AIWF-0003-review.md", "linked_from": ["AIWF-0003"], "existing": false},
            {"path": "docs/shared.md", "linked_from": ["AIWF-0001", "AIWF-0002"], "existing": false}
        ])
    );
    assert_eq!(
        read(p, "docs/shared.md"),
        std::fs::read_to_string(fixture().join("docs/shared.md")).unwrap()
    );
    assert!(!p.join("docs/process-only.md").exists());

    // One new actor wrote everything and declared itself.
    let actor = report["actor"].as_str().unwrap();
    let own = read(p, ".zwanenzang/actor");
    assert_ne!(own.trim(), actor);
    let log_names: Vec<String> = logs(p).into_iter().map(|(n, _)| n).collect();
    assert_eq!(log_names, [format!("{actor}.jsonl")]);
    let first: Value = serde_json::from_str(
        read(p, &format!("events/{actor}.jsonl"))
            .lines()
            .next()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(first["op"], "actor");
    assert_eq!(first["data"]["name"], "ai-workflow import");

    // Replay accepts every event and lint finds nothing.
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 0, "{}", lint.json);
    assert_eq!(lint.json["events"], report["events"]);
    let list = ok(p, &["list"]);
    assert_eq!(list["tickets"].as_array().unwrap().len(), 8);
}

#[test]
fn dry_run_reports_and_writes_nothing() {
    let d = target();
    let p = d.path();
    let before = logs(p);
    let report = import(p, &fixture(), &["--exclude", "AIWF-0004", "--dry-run"]);
    assert_eq!(report["dry_run"], true);
    assert_eq!(report["actor"], Value::Null);
    assert_eq!(report["imported"].as_array().unwrap().len(), 8);
    assert!(
        report["imported"]
            .as_array()
            .unwrap()
            .iter()
            .all(|t| t["id"].is_null())
    );
    assert!(report["events"].as_u64().unwrap() > 8);
    assert_eq!(logs(p), before);
    assert!(!p.join("docs").exists());
    assert!(std::fs::read_dir(p.join("blobs")).unwrap().next().is_none());
}

#[test]
fn rerun_skips_imported_tickets_and_adds_newly_included_ones() {
    let d = target();
    let p = d.path();
    let exclude = disposable_dir();
    write_file(
        exclude.path(),
        "exclude.txt",
        "# leave out for now\nAIWF-0004  # process\n\n",
    );
    let ex = exclude.path().join("exclude.txt");
    let first = import(p, &fixture(), &["--exclude-file", ex.to_str().unwrap()]);
    let ids = by_source(&first);

    // The same run again changes nothing.
    let again = import(p, &fixture(), &["--exclude-file", ex.to_str().unwrap()]);
    assert_eq!(again["imported"], json!([]));
    assert_eq!(again["events"], 0);
    assert_eq!(again["actor"], Value::Null);
    assert_eq!(again["already_imported"].as_array().unwrap().len(), 8);
    assert_eq!(again["dropped_references"], json!([]));

    // Including the excluded ticket imports it alone and restores the
    // references that pointed at it.
    let more = import(p, &fixture(), &[]);
    let added = by_source(&more);
    assert_eq!(added.keys().collect::<Vec<_>>(), ["AIWF-0004"]);
    let four = added["AIWF-0004"]["id"].as_str().unwrap().to_string();
    let seven = ok(p, &["show", ids["AIWF-0007"]["id"].as_str().unwrap()]);
    assert_eq!(seven["parent"], json!(four));
    let mut related: Vec<String> = seven["related"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    related.sort();
    let mut want = vec![
        ids["AIWF-0003"]["id"].as_str().unwrap().to_string(),
        four.clone(),
    ];
    want.sort();
    assert_eq!(related, want);
    let one = ok(p, &["show", ids["AIWF-0001"]["id"].as_str().unwrap()]);
    assert!(one["related"].as_array().unwrap().contains(&json!(four)));
    assert!(p.join("docs/process-only.md").exists());
    // The second run wrote as an actor of its own.
    assert_ne!(more["actor"], first["actor"]);
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 0, "{}", lint.json);

    // Excluding an imported ticket later leaves it alone, with a warning.
    let late = import(p, &fixture(), &["--exclude", "AIWF-0001"]);
    assert_eq!(late["events"], 0);
    assert!(codes(&late).contains(&("AIWF-0001".into(), "excluded-but-imported".into())));
}

#[test]
fn undeclared_repositories_refuse_the_whole_import() {
    let d = tracker();
    let p = d.path();
    let src = fixture();
    let src = src.to_str().unwrap();
    let before = logs(p);
    let e = err(p, &["import", "ai-workflow", src], "undeclared-repo");
    let msg = e["error"]["message"].as_str().unwrap();
    assert!(msg.contains("app") && msg.contains("docs-site"), "{msg}");
    assert_eq!(logs(p), before);
    append_config(p, REPOS);
    // Without the rename, docs-site is still undeclared.
    err(p, &["import", "ai-workflow", src], "undeclared-repo");
    assert_eq!(logs(p), before);
    assert!(!p.join("docs").exists());
}

#[test]
fn a_different_supporting_file_refuses_the_import() {
    let d = target();
    let p = d.path();
    write_file(p, "docs/shared.md", "someone else's glossary\n");
    let before = logs(p);
    let src = fixture();
    let args = [
        "import",
        "ai-workflow",
        src.to_str().unwrap(),
        "--repo-alias",
        "docs-site=site",
        "--exclude",
        "AIWF-0004",
    ];
    err(p, &args, "doc-conflict");
    assert_eq!(logs(p), before);
    assert!(!p.join("docs/AIWF-0001-notes.md").exists());
    // The same content is fine and reported as existing.
    let same = std::fs::read_to_string(fixture().join("docs/shared.md")).unwrap();
    write_file(p, "docs/shared.md", &same);
    let report = ok(p, &args);
    assert_eq!(
        report["docs"][3],
        json!({"path": "docs/shared.md", "linked_from": ["AIWF-0001", "AIWF-0002"], "existing": true})
    );
}

#[test]
fn malformed_sources_refuse_the_import() {
    let d = target();
    let p = d.path();
    let before = logs(p);
    let cases: &[(&str, &str)] = &[
        (
            "tickets/AIWF-0050-x.md",
            "---\nstatus: draft\nrelated:\n  - AIWF-0001\n    - nested\n---\n# T\n",
        ),
        (
            "tickets/AIWF-0050-x.md",
            "---\nstatus: draft\nmerge-requests:\n  - https://forge.example/o/app/issues/1\n---\n# T\n",
        ),
        (
            "tickets/AIWF-0050-x.md",
            "---\nstatus: draft\nrelated: AIWF-0001\n---\n# T\n",
        ),
        (
            "tickets/AIWF-0050-x.md",
            "---\nstatus: draft\nbranches:\n  - app\n---\n# T\n",
        ),
        ("tickets/AIWF-0050-x.md", "---\nstatus: [draft]\n---\n# T\n"),
        ("tickets/AIWF-0050-x.md", "---\nstatus: draft\n# T\n"),
        (
            "tickets/AIWF-0001-again.md",
            "---\nstatus: draft\n---\n# Duplicate id\n",
        ),
    ];
    for (rel, text) in cases {
        let src = disposable_dir();
        copy_tree(&fixture(), src.path());
        write_file(src.path(), rel, text);
        let e = err(
            p,
            &[
                "import",
                "ai-workflow",
                src.path().to_str().unwrap(),
                "--repo-alias",
                "docs-site=site",
            ],
            "invalid-source",
        );
        assert!(e["error"]["message"].is_string());
        assert_eq!(logs(p), before, "{text}");
    }
    err(
        p,
        &["import", "ai-workflow", "/nonexistent-test-repo"],
        "io",
    );
    err(
        p,
        &[
            "import",
            "ai-workflow",
            fixture().to_str().unwrap(),
            "--exclude",
            "aiwf-4",
        ],
        "invalid-argument",
    );
    err(
        p,
        &[
            "import",
            "ai-workflow",
            fixture().to_str().unwrap(),
            "--repo-alias",
            "nope",
        ],
        "invalid-argument",
    );
}

#[test]
fn the_tickets_directory_works_as_the_source() {
    let d = target();
    let report = import(
        d.path(),
        &fixture().join("tickets"),
        &["--exclude", "AIWF-0004,AIWF-0005", "--exclude", "AIWF-0098"],
    );
    assert_eq!(report["imported"].as_array().unwrap().len(), 7);
    assert_eq!(report["docs"].as_array().unwrap().len(), 4);
    assert!(codes(&report).contains(&("AIWF-0098".into(), "unknown-exclude".into())));
}

#[test]
fn a_git_checkout_records_its_revision() {
    let d = target();
    let p = d.path();
    let src = disposable_dir();
    let s = src.path();
    copy_tree(&fixture(), s);
    git(s, &["init", "-q"]);
    git(s, &["add", "-A"]);
    git(s, &["commit", "-q", "-m", "fixture"]);
    let head = git(s, &["rev-parse", "HEAD"]).trim().to_string();
    write_file(
        s,
        "tickets/AIWF-0010-empty-body.md",
        "---\nstatus: done\n---\n\n# Changed after the commit\n",
    );
    let report = import(p, s, &["--exclude", "AIWF-0004"]);
    assert_eq!(report["source"]["revision"], json!(head));
    assert!(codes(&report).contains(&("-".into(), "dirty-source".into())));
    let one = ok(
        p,
        &[
            "show",
            by_source(&report)["AIWF-0001"]["id"].as_str().unwrap(),
        ],
    );
    assert!(comment_texts(&one)[0].contains(&format!("Source revision: {head}\n")));
    // Only read: the checkout is as it was.
    assert_eq!(
        git(s, &["status", "--porcelain"]).trim(),
        "M tickets/AIWF-0010-empty-body.md"
    );
}

#[test]
fn doc_patterns_leave_supporting_files_out() {
    let d = target();
    let p = d.path();
    let exclude = disposable_dir();
    write_file(
        exclude.path(),
        "exclude.txt",
        "AIWF-0004\ndocs/*-review.md  # review records\ndocs/nothing-*.md\n",
    );
    let ex = exclude.path().join("exclude.txt");
    let report = import(
        p,
        &fixture(),
        &[
            "--exclude-file",
            ex.to_str().unwrap(),
            "--exclude",
            "docs/shared.md",
        ],
    );
    assert_eq!(
        report["docs"],
        json!([
            {"path": "docs/AIWF-0001-notes.md", "linked_from": ["AIWF-0001"], "existing": false},
            {"path": "docs/AIWF-0003-plan.md", "linked_from": ["AIWF-0003"], "existing": false}
        ])
    );
    assert_eq!(
        report["dropped_docs"],
        json!([
            {"path": "docs/AIWF-0003-review.md", "linked_from": ["AIWF-0003"], "pattern": "docs/*-review.md"},
            {"path": "docs/shared.md", "linked_from": ["AIWF-0001", "AIWF-0002"], "pattern": "docs/shared.md"}
        ])
    );
    assert!(codes(&report).contains(&("-".into(), "unknown-exclude".into())));
    assert!(p.join("docs/AIWF-0003-plan.md").exists());
    assert!(!p.join("docs/AIWF-0003-review.md").exists());
    assert!(!p.join("docs/shared.md").exists());

    // No comment links to a left-out file; the description is as written.
    let t = by_source(&report);
    let three_id = t["AIWF-0003"]["id"].as_str().unwrap().to_string();
    let three = ok(p, &["show", &three_id]);
    let links: Vec<&Value> = three["comments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| &c["link"])
        .filter(|l| !l.is_null())
        .collect();
    assert_eq!(links, [&json!("docs/AIWF-0003-plan.md")]);
    let desc = ok(p, &["doc", "get", &three_id, "description"]);
    assert!(
        desc["text"]
            .as_str()
            .unwrap()
            .contains("(../docs/AIWF-0003-review.md)")
    );
    let two = ok(p, &["show", t["AIWF-0002"]["id"].as_str().unwrap()]);
    assert!(
        two["comments"]
            .as_array()
            .unwrap()
            .iter()
            .all(|c| c["link"].is_null())
    );
    let lint = run_in(p, &["lint"], "");
    assert_eq!(lint.code, 0, "{}", lint.json);

    err(
        p,
        &[
            "import",
            "ai-workflow",
            fixture().to_str().unwrap(),
            "--exclude",
            "docs/../x",
        ],
        "invalid-argument",
    );
    err(
        p,
        &[
            "import",
            "ai-workflow",
            fixture().to_str().unwrap(),
            "--exclude",
            "notes/x.md",
        ],
        "invalid-argument",
    );
}
