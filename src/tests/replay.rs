use serde_json::json;

use super::util::*;
use crate::event::{
    ActorData, CommentData, ConfigData, CreateData, DocData, KindData, NumberData, Op, ParentData,
    RelateData, TagData, TextTo,
};
use crate::lint::lint;
use crate::state::{Causal, is_concurrent};
use crate::store::Tracker;
use crate::ulid::Ulid;
use crate::view::View;

fn status(to: &str) -> Op {
    Op::Status(TextTo { to: to.into() })
}

fn based(dir: &tempfile::TempDir) -> Tracker {
    let t = new_tracker(dir);
    append_events(&t, &base_events(t.config.id));
    t
}

#[test]
fn activity_and_tag_intervals_follow_accepted_replay_not_wall_time() {
    let dir = disposable_dir();
    let t = based(&dir);
    let tag = || TagData {
        tag: "needs_human".into(),
    };
    let mut add = ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), Op::Tag(tag()));
    add.ts = "2026-11-08T00:00:00Z".into();
    let mut duplicate = ev(u(22), ACTOR_B, Some(u(BASE_LAST)), u(T1), Op::Tag(tag()));
    duplicate.ts = "2026-11-06T00:00:00Z".into();
    append_events(&t, &[duplicate.clone(), add.clone()]);
    let rp = load(&t);
    let ticket = &rp.state.tickets[&u(T1)];
    assert_eq!(ticket.activity.id, duplicate.id);
    assert_eq!(ticket.activity.ts, duplicate.ts);
    assert_eq!(ticket.tag_since["needs_human"].id, add.id);
    // A newly arrived event sorting before the duplicate must recompute the interval.
    let remove = ev(u(21), ACTOR_A, Some(u(20)), u(T1), Op::Untag(tag()));
    append_events(&t, &[remove]);
    let rp = load(&t);
    assert_eq!(
        rp.state.tickets[&u(T1)].tag_since["needs_human"].id,
        duplicate.id
    );
    // Rejected own-ticket changes and accepted other-side changes do not advance activity.
    append_events(
        &t,
        &[
            ev(u(23), ACTOR_A, Some(u(22)), u(T1), status("invalid")),
            ev(
                u(24),
                ACTOR_A,
                Some(u(23)),
                u(T2),
                Op::Relate(RelateData { to: u(T1) }),
            ),
        ],
    );
    let rp = load(&t);
    assert_eq!(rp.state.tickets[&u(T1)].activity.id, duplicate.id);
    assert_eq!(rp.state.tickets[&u(T2)].activity.id, u(24));
    let view = View::new(&t, &rp);
    let summary = view.summary(&rp.state.tickets[&u(T1)]);
    assert_eq!(summary["activity"]["id"], json!(duplicate.id));
    assert_eq!(
        summary["tag_since"]["needs_human"]["ts"],
        json!(duplicate.ts)
    );
    append_events(
        &t,
        &[ev(u(25), ACTOR_A, Some(u(24)), u(T1), Op::Untag(tag()))],
    );
    let rp = load(&t);
    assert!(rp.state.tickets[&u(T1)].tag_since.is_empty());
    assert_eq!(rp.state.tickets[&u(T1)].activity.id, u(25));
}

#[test]
fn priority_replay_reports_concurrent_changes_and_preserves_native_values() {
    let dir = disposable_dir();
    let t = based(&dir);
    let priority = |to| Op::Priority(crate::event::PriorityData { to });
    append_events(
        &t,
        &[
            ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), priority(Some(1))),
            ev(
                u(21),
                ACTOR_B,
                Some(u(BASE_LAST)),
                u(T1),
                priority(Some(90)),
            ),
            ev(u(22), ACTOR_A, Some(u(21)), u(T1), priority(Some(91))),
        ],
    );
    let rp = load(&t);
    assert_eq!(rp.state.tickets[&u(T1)].priority, Some(90));
    assert_eq!(rp.state.tickets[&u(T1)].activity.id, u(21));
    assert_eq!(rp.state.concurrent.len(), 1);
    assert_eq!(rp.state.concurrent[0].field, "priority");
    assert_eq!(skipped_codes(&rp), vec!["invalid-priority"]);
    append_events(
        &t,
        &[ev(u(23), ACTOR_A, Some(u(22)), u(T1), priority(None))],
    );
    assert_eq!(load(&t).state.tickets[&u(T1)].priority, None);
}

#[test]
fn base_fixture_replays_cleanly() {
    let dir = disposable_dir();
    let t = based(&dir);
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "{:?}", rp.skipped);
    assert_eq!(rp.events.len(), 6);
    assert_eq!(rp.state.tickets.len(), 3);
    assert!(rp.state.tickets[&u(T3)].tombstoned);
    assert_eq!(rp.state.tickets[&u(T1)].number, Some(5));
    assert_eq!(rp.state.actors[&ACTOR_A].name.as_deref(), Some("alice"));
    assert_eq!(rp.highest_seen, Some(u(BASE_LAST)));
    let (_, issues) = lint(&t.config, &rp);
    assert!(!issues);
}

#[test]
fn ulid_order_across_logs_not_file_order() {
    let dir = disposable_dir();
    let t = based(&dir);
    let p = Some(u(BASE_LAST));
    // Written out of order within and across logs. Actor B is declared too.
    append_events(
        &t,
        &[
            ev(u(40), ACTOR_A, Some(u(30)), u(T1), status("done")),
            ev(u(20), ACTOR_A, p, u(T1), status("next")),
        ],
    );
    append_events(
        &t,
        &[
            ev(u(30), ACTOR_B, Some(u(20)), u(T1), status("agnt")),
            ev(
                u(25),
                ACTOR_B,
                Some(u(20)),
                t.config.id,
                Op::Actor(ActorData { name: "bob".into() }),
            ),
        ],
    );
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "{:?}", rp.skipped);
    let ids: Vec<Ulid> = rp.events.iter().map(|e| e.id).collect();
    let mut sorted = ids.clone();
    sorted.sort();
    assert_eq!(ids, sorted);
    assert_eq!(rp.state.tickets[&u(T1)].status, "done");
    assert_eq!(rp.state.tickets[&u(T1)].last_event, u(40));
    assert!(rp.state.concurrent.is_empty());
}

#[test]
fn same_event_set_same_output() {
    let mk = |reverse: bool| {
        let dir = disposable_dir();
        let t = new_tracker(&dir);
        let mut evs = base_events(t.config.id);
        evs.push(ev(
            u(20),
            ACTOR_B,
            Some(u(BASE_LAST)),
            u(T1),
            status("agnt"),
        ));
        evs.push(ev(
            u(21),
            ACTOR_A,
            Some(u(BASE_LAST)),
            u(T1),
            status("wait"),
        ));
        evs.push(ev(
            u(22),
            ACTOR_B,
            Some(u(21)),
            u(T2),
            Op::Tag(TagData { tag: "z".into() }),
        ));
        if reverse {
            evs.reverse();
        }
        append_events(&t, &evs);
        let rp = load(&t);
        let view = View::new(&t, &rp);
        let tickets: Vec<_> = rp.state.tickets.values().map(|x| view.ticket(x)).collect();
        (json!(tickets), lint(&t.config, &rp).0, dir)
    };
    let (a, la, _d1) = mk(false);
    let (b, lb, _d2) = mk(true);
    assert_eq!(a, b);
    // Skipped lines name their log line, which differs; the rest must match.
    assert_eq!(la["concurrent"], lb["concurrent"]);
    assert_eq!(la["events"], lb["events"]);
}

#[test]
fn identical_duplicate_lines_count_once() {
    let dir = disposable_dir();
    let t = based(&dir);
    let e = ev(
        u(20),
        ACTOR_A,
        Some(u(BASE_LAST)),
        u(T1),
        Op::Tag(TagData { tag: "x".into() }),
    );
    append_events(&t, &[e.clone(), e]);
    let rp = load(&t);
    assert!(rp.skipped.is_empty());
    assert_eq!(rp.events.len(), 7);
}

#[test]
fn conflicting_lines_with_one_id_are_all_skipped() {
    let dir = disposable_dir();
    let t = based(&dir);
    append_events(
        &t,
        &[
            ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), status("agnt")),
            ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), status("done")),
        ],
    );
    let rp = load(&t);
    assert_eq!(skipped_codes(&rp), vec!["duplicate-id", "duplicate-id"]);
    assert_eq!(rp.state.tickets[&u(T1)].status, "todo");
}

#[test]
fn lines_that_are_not_utf8_are_malformed() {
    let dir = disposable_dir();
    let t = based(&dir);
    // Two lines with one id that differ only in an invalid byte: a lossy
    // decoding would make them one identical line and apply it.
    let line = ev(
        u(20),
        ACTOR_A,
        Some(u(BASE_LAST)),
        u(T1),
        Op::Title(TextTo {
            to: "hello @".into(),
        }),
    )
    .to_line();
    let mut bytes = Vec::new();
    for bad in [0xFFu8, 0xFE] {
        bytes.extend(line.bytes().map(|b| if b == b'@' { bad } else { b }));
        bytes.push(b'\n');
    }
    append_bytes(&t, &ACTOR_A.to_canonical(), &bytes);
    let rp = load(&t);
    assert_eq!(skipped_codes(&rp), vec!["malformed", "malformed"]);
    assert_eq!(rp.state.tickets[&u(T1)].title, "one");
    assert_eq!(rp.events.len(), 6);
    let lines: Vec<usize> = rp.skipped.iter().map(|s| s.line).collect();
    assert_eq!(lines, vec![7, 8]);
    assert!(rp.skipped[0].raw.contains("hello \u{FFFD}"));
}

#[test]
fn unknown_op_skipped_with_raw_line() {
    let dir = disposable_dir();
    let t = based(&dir);
    let raw = format!(
        r#"{{"id":"{}","actor":"{}","parent":"{}","ts":"x","entity":"{}","op":"estimate","data":{{"hours":3}}}}"#,
        u(20),
        ACTOR_A,
        u(BASE_LAST),
        u(T1)
    );
    append_raw(&t, &ACTOR_A.to_canonical(), std::slice::from_ref(&raw));
    let rp = load(&t);
    assert_eq!(skipped_codes(&rp), vec!["unknown-op"]);
    assert_eq!(rp.skipped[0].raw, raw);
    assert_eq!(rp.skipped[0].op.as_deref(), Some("estimate"));
    // It still counts as seen: the next id must sort after it.
    assert_eq!(rp.highest_seen, Some(u(20)));
}

#[test]
fn unknown_data_fields_are_tolerated() {
    let dir = disposable_dir();
    let t = based(&dir);
    let raw = format!(
        r#"{{"id":"{}","actor":"{}","parent":"{}","ts":"x","entity":"{}","op":"status","data":{{"to":"agnt","reason":"later field"}},"sig":"later envelope field"}}"#,
        u(20),
        ACTOR_A,
        u(BASE_LAST),
        u(T1)
    );
    append_raw(&t, &ACTOR_A.to_canonical(), &[raw]);
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "{:?}", rp.skipped);
    assert_eq!(rp.state.tickets[&u(T1)].status, "agnt");
}

#[test]
fn config_with_only_unknown_fields_is_accepted() {
    let dir = disposable_dir();
    let t = based(&dir);
    let raw = format!(
        r#"{{"id":"{}","actor":"{}","parent":"{}","ts":"x","entity":"{}","op":"config","data":{{"rename_status":{{"todo":"idea"}}}}}}"#,
        u(20),
        ACTOR_A,
        u(BASE_LAST),
        t.config.id
    );
    append_raw(&t, &ACTOR_A.to_canonical(), &[raw]);
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "{:?}", rp.skipped);
    assert_eq!(rp.events.len(), 7);
    assert_eq!(rp.state.statuses, t.config.statuses);
    let (_, issues) = lint(&t.config, &rp);
    assert!(!issues);
}

#[test]
fn malformed_and_invalid_lines_skipped() {
    let dir = disposable_dir();
    let t = based(&dir);
    let a = ACTOR_A.to_canonical();
    append_raw(
        &t,
        &a,
        &[
            "not json".into(),
            format!(r#"{{"id":"{}","actor":"{a}"}}"#, u(21)),
            format!(
                r#"{{"id":"{}","actor":"{a}","parent":null,"ts":"x","entity":"{}","op":"status","data":{{"too":"x"}}}}"#,
                u(22),
                u(T1)
            ),
            format!(
                r#"{{"id":"01jc3v7k9qz8m4r2t6w0xnpb5a","actor":"{a}","parent":null,"ts":"x","entity":"{}","op":"archive","data":{{}}}}"#,
                u(T1)
            ),
        ],
    );
    let rp = load(&t);
    let mut codes = skipped_codes(&rp);
    codes.sort();
    assert_eq!(
        codes,
        vec!["invalid-data", "malformed", "malformed", "malformed"]
    );
    let salvaged = rp.skipped.iter().find(|s| s.id == Some(u(21))).unwrap();
    assert_eq!(salvaged.code.as_str(), "malformed");
    assert_eq!(rp.events.len(), 6);
}

#[test]
fn actor_must_match_log_name() {
    let dir = disposable_dir();
    let t = based(&dir);
    let e = ev(u(20), ACTOR_B, Some(u(BASE_LAST)), u(T1), status("agnt"));
    append_raw(&t, &ACTOR_A.to_canonical(), &[e.to_line()]);
    append_raw(
        &t,
        "not-an-actor",
        &[ev(u(21), ACTOR_B, Some(u(BASE_LAST)), u(T1), status("done")).to_line()],
    );
    let rp = load(&t);
    assert_eq!(skipped_codes(&rp), vec!["actor-mismatch", "actor-mismatch"]);
    assert_eq!(rp.state.tickets[&u(T1)].status, "todo");
}

/// Events that every rule refuses, against the base fixture, with the code
/// expected. Replay skips each; the write tests refuse the same operations.
pub fn invalid_ticket_ops(root: Ulid) -> Vec<(Ulid, Op, &'static str)> {
    let t1 = u(T1);
    let t2 = u(T2);
    let t3 = u(T3);
    let missing_blob = "0".repeat(64);
    vec![
        (t1, status("nope"), "status-not-in-vocabulary"),
        (
            t1,
            Op::Kind(KindData {
                to: Some("epic".into()),
            }),
            "kind-not-in-vocabulary",
        ),
        (
            t1,
            Op::Tag(TagData {
                tag: "has-dash".into(),
            }),
            "invalid-tag",
        ),
        (t1, Op::Untag(TagData { tag: "".into() }), "invalid-tag"),
        (t1, Op::Title(TextTo { to: "  ".into() }), "invalid-title"),
        (t1, Op::Title(TextTo { to: "a\nb".into() }), "invalid-title"),
        (
            t1,
            Op::Parent(ParentData { to: Some(u(99)) }),
            "unknown-target",
        ),
        (t1, Op::Parent(ParentData { to: Some(t1) }), "parent-cycle"),
        (
            t1,
            Op::Parent(ParentData { to: Some(t3) }),
            "target-tombstoned",
        ),
        (t1, Op::Relate(RelateData { to: t1 }), "self-relation"),
        (t1, Op::Relate(RelateData { to: t3 }), "target-tombstoned"),
        (t1, Op::Relate(RelateData { to: u(99) }), "unknown-target"),
        (t1, Op::Unrelate(RelateData { to: u(99) }), "unknown-target"),
        (t3, status("agnt"), "tombstoned"),
        (t3, Op::Tombstone(crate::event::Empty {}), "tombstoned"),
        (t3, Op::Archive(crate::event::Empty {}), "tombstoned"),
        (t3, Op::Unarchive(crate::event::Empty {}), "tombstoned"),
        (root, Op::Archive(crate::event::Empty {}), "wrong-entity"),
        (root, Op::Unarchive(crate::event::Empty {}), "wrong-entity"),
        (u(99), status("agnt"), "unknown-entity"),
        (root, status("agnt"), "wrong-entity"),
        (
            t1,
            Op::Actor(ActorData { name: "x".into() }),
            "wrong-entity",
        ),
        (
            root,
            Op::Actor(ActorData { name: " ".into() }),
            "invalid-name",
        ),
        (
            root,
            Op::Config(ConfigData {
                add_statuses: vec!["has space".into()],
                add_kinds: vec![],
            }),
            "invalid-name",
        ),
        (
            t1,
            Op::Comment(CommentData {
                text: Some("a".into()),
                blob: Some(missing_blob.clone()),
                link: None,
            }),
            "invalid-comment",
        ),
        (
            t1,
            Op::Comment(CommentData {
                text: None,
                blob: None,
                link: None,
            }),
            "invalid-comment",
        ),
        (
            t1,
            Op::Comment(CommentData {
                text: Some(" ".into()),
                blob: None,
                link: None,
            }),
            "invalid-comment",
        ),
        (
            t1,
            Op::Comment(CommentData {
                text: None,
                blob: Some(missing_blob.clone()),
                link: None,
            }),
            "missing-blob",
        ),
        (
            t1,
            Op::Doc(DocData {
                name: "description".into(),
                blob: missing_blob.clone(),
                base: None,
            }),
            "missing-blob",
        ),
        (
            t1,
            Op::Doc(DocData {
                name: "bad name".into(),
                blob: missing_blob,
                base: None,
            }),
            "invalid-name",
        ),
        (t1, Op::Number(NumberData { number: 7 }), "already-numbered"),
        (
            t2,
            Op::Number(NumberData { number: 5 }),
            "number-not-unique",
        ),
        (
            t2,
            Op::Number(NumberData { number: 3 }),
            "number-not-greater",
        ),
        (t2, Op::Number(NumberData { number: 0 }), "invalid-data"),
        (
            t2,
            Op::Branch(crate::event::BranchData {
                repo: "no alias".into(),
                name: "b".into(),
            }),
            "invalid-name",
        ),
        (
            t2,
            Op::Mr(crate::event::MrData {
                repo: "app".into(),
                url: "".into(),
            }),
            "invalid-data",
        ),
    ]
}

#[test]
fn every_rule_skips_and_reports_at_replay() {
    let probe = disposable_dir();
    let root = new_tracker(&probe).config.id;
    for (entity, op, code) in invalid_ticket_ops(root) {
        let dir = disposable_dir();
        let t = based(&dir);
        assert_eq!(t.config.id, root);
        let e = ev(u(20), ACTOR_A, Some(u(BASE_LAST)), entity, op.clone());
        append_events(&t, &[e]);
        let rp = load(&t);
        assert_eq!(skipped_codes(&rp), vec![code], "{op:?}");
        assert_eq!(rp.skipped[0].id, Some(u(20)));
        assert_eq!(rp.events.len(), 6, "{op:?} must not apply");
        let (report, issues) = lint(&t.config, &rp);
        assert!(issues);
        assert_eq!(report["skipped"][0]["code"], code);
    }
}

#[test]
fn replay_only_rules() {
    let dir = disposable_dir();
    let t = based(&dir);
    let root = t.config.id;
    let a = ACTOR_A;
    let p = Some(u(BASE_LAST));
    append_events(
        &t,
        &[
            // A create whose entity is not its own id.
            ev(u(20), a, p, u(21), create("x")),
            // A second create of an existing entity cannot have its own id,
            // so it is a mismatch too; a create of the root is wrong-entity.
            ev(u(22), a, Some(u(20)), root, create("x")),
            // An id that does not sort after its parent.
            ev(u(23), a, Some(u(24)), u(T1), status("agnt")),
            // A create with a status outside the vocabulary.
            ev(
                u(25),
                a,
                Some(u(23)),
                u(25),
                Op::Create(CreateData {
                    title: "y".into(),
                    status: "nope".into(),
                    kind: None,
                }),
            ),
        ],
    );
    let rp = load(&t);
    assert_eq!(
        skipped_codes(&rp),
        vec![
            "create-id-mismatch",
            "wrong-entity",
            "id-not-after-parent",
            "status-not-in-vocabulary"
        ]
    );
}

#[test]
fn parent_cycles_rejected() {
    let dir = disposable_dir();
    let t = based(&dir);
    let a = ACTOR_A;
    let par = |to: u64| Op::Parent(ParentData { to: Some(u(to)) });
    append_events(
        &t,
        &[
            ev(u(20), a, Some(u(BASE_LAST)), u(20), create("four")),
            ev(u(21), a, Some(u(20)), u(T1), par(T2)),
            ev(u(22), a, Some(u(21)), u(T2), par(20)),
            ev(u(23), a, Some(u(22)), u(20), par(T1)),
            ev(u(24), a, Some(u(23)), u(T2), par(T1)),
        ],
    );
    let rp = load(&t);
    assert_eq!(skipped_codes(&rp), vec!["parent-cycle", "parent-cycle"]);
    assert_eq!(rp.state.tickets[&u(T1)].parent, Some(u(T2)));
    assert_eq!(rp.state.tickets[&u(T2)].parent, Some(u(20)));
    assert_eq!(rp.state.tickets[&u(20)].parent, None);
}

#[test]
fn vocabulary_grows_through_config_events() {
    let dir = disposable_dir();
    let t = based(&dir);
    append_events(
        &t,
        &[
            ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), status("parked")),
            ev(
                u(21),
                ACTOR_A,
                Some(u(20)),
                t.config.id,
                Op::Config(ConfigData {
                    add_statuses: vec!["parked".into()],
                    add_kinds: vec![],
                }),
            ),
            ev(u(22), ACTOR_A, Some(u(21)), u(T1), status("parked")),
        ],
    );
    let rp = load(&t);
    // Only the change before the config event is refused.
    assert_eq!(skipped_codes(&rp), vec!["status-not-in-vocabulary"]);
    assert_eq!(rp.skipped[0].id, Some(u(20)));
    assert_eq!(rp.state.tickets[&u(T1)].status, "parked");
}

#[test]
fn concurrency_rule() {
    let c = |id: u64, actor: Ulid, parent: Option<u64>| Causal {
        id: u(id),
        actor,
        parent: parent.map(u),
    };
    let a = c(20, ACTOR_A, Some(10));
    // B had not seen A.
    assert!(is_concurrent(&a, &c(21, ACTOR_B, Some(19))));
    assert!(is_concurrent(&a, &c(21, ACTOR_B, None)));
    // B had seen A, or something after A.
    assert!(!is_concurrent(&a, &c(21, ACTOR_B, Some(20))));
    // Same writer: never concurrent, even with a stale parent.
    assert!(!is_concurrent(&a, &c(21, ACTOR_A, Some(10))));
}

#[test]
fn unarchive_clears_the_flag_and_leaves_status_alone() {
    let dir = disposable_dir();
    let t = based(&dir);
    let archive = || Op::Archive(crate::event::Empty {});
    let unarchive = || Op::Unarchive(crate::event::Empty {});
    append_events(
        &t,
        &[
            // Replay accepts what a live write would not have written.
            ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), unarchive()),
            ev(u(21), ACTOR_A, Some(u(20)), u(T1), status("done")),
            ev(u(22), ACTOR_A, Some(u(21)), u(T1), archive()),
            ev(u(23), ACTOR_A, Some(u(22)), u(T1), archive()),
        ],
    );
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "{:?}", rp.skipped);
    assert!(rp.state.tickets[&u(T1)].archived);
    append_events(&t, &[ev(u(24), ACTOR_A, Some(u(23)), u(T1), unarchive())]);
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "{:?}", rp.skipped);
    let ticket = &rp.state.tickets[&u(T1)];
    assert!(!ticket.archived);
    assert_eq!(ticket.status, "done");
    assert_eq!(ticket.last_event, u(24));
}

#[test]
fn concurrent_archive_and_unarchive_take_the_later_id_unreported() {
    let dir = disposable_dir();
    let t = based(&dir);
    let p = Some(u(BASE_LAST));
    append_events(
        &t,
        &[
            ev(
                u(20),
                ACTOR_A,
                p,
                u(T1),
                Op::Archive(crate::event::Empty {}),
            ),
            ev(
                u(21),
                ACTOR_B,
                p,
                u(T1),
                Op::Unarchive(crate::event::Empty {}),
            ),
            ev(
                u(22),
                ACTOR_A,
                Some(u(21)),
                u(T2),
                Op::Unarchive(crate::event::Empty {}),
            ),
            ev(
                u(23),
                ACTOR_B,
                Some(u(21)),
                u(T2),
                Op::Archive(crate::event::Empty {}),
            ),
        ],
    );
    let rp = load(&t);
    assert!(!rp.state.tickets[&u(T1)].archived);
    assert!(rp.state.tickets[&u(T2)].archived);
    assert!(rp.state.concurrent.is_empty());
}

#[test]
fn concurrent_field_changes_reported() {
    let dir = disposable_dir();
    let t = based(&dir);
    let p = Some(u(BASE_LAST));
    append_events(
        &t,
        &[
            // Concurrent, different values: reported.
            ev(u(20), ACTOR_A, p, u(T1), status("agnt")),
            ev(u(21), ACTOR_B, p, u(T1), status("done")),
            // Concurrent but the same value: nobody chose differently.
            ev(u(22), ACTOR_A, Some(u(21)), u(T2), status("revw")),
            ev(u(23), ACTOR_B, Some(u(21)), u(T2), status("revw")),
            // Causally ordered: B saw A's title.
            ev(
                u(24),
                ACTOR_A,
                Some(u(23)),
                u(T2),
                Op::Title(TextTo { to: "A".into() }),
            ),
            ev(
                u(25),
                ACTOR_B,
                Some(u(24)),
                u(T2),
                Op::Title(TextTo { to: "B".into() }),
            ),
            // Same actor with a stale parent: never concurrent.
            ev(
                u(26),
                ACTOR_A,
                Some(u(25)),
                u(T2),
                Op::Kind(KindData {
                    to: Some("bug".into()),
                }),
            ),
            ev(
                u(27),
                ACTOR_A,
                Some(u(25)),
                u(T2),
                Op::Kind(KindData {
                    to: Some("task".into()),
                }),
            ),
            // Concurrent on different fields: not a conflict.
            ev(
                u(28),
                ACTOR_A,
                Some(u(27)),
                u(T1),
                Op::Title(TextTo { to: "x".into() }),
            ),
            ev(
                u(29),
                ACTOR_B,
                Some(u(27)),
                u(T1),
                Op::Kind(KindData {
                    to: Some("bug".into()),
                }),
            ),
            // Parent is a scalar field too.
            ev(
                u(30),
                ACTOR_A,
                Some(u(29)),
                u(T2),
                Op::Parent(ParentData { to: Some(u(T1)) }),
            ),
            ev(
                u(31),
                ACTOR_B,
                Some(u(29)),
                u(T2),
                Op::Parent(ParentData { to: None }),
            ),
        ],
    );
    append_events(
        &t,
        &[ev(
            u(19),
            ACTOR_B,
            Some(u(BASE_LAST)),
            t.config.id,
            Op::Actor(ActorData { name: "bob".into() }),
        )],
    );
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "{:?}", rp.skipped);
    let got: Vec<_> = rp
        .state
        .concurrent
        .iter()
        .map(|c| (c.field, c.earlier, c.later, c.won))
        .collect();
    assert_eq!(
        got,
        vec![
            ("status", u(20), u(21), u(21)),
            ("parent", u(30), u(31), u(31))
        ]
    );
    assert_eq!(rp.state.tickets[&u(T1)].status, "done");
    let (report, issues) = lint(&t.config, &rp);
    assert!(issues);
    assert_eq!(report["concurrent"][0]["earlier_value"], "agnt");
    assert_eq!(report["concurrent"][0]["later_value"], "done");
    assert_eq!(
        report["concurrent"][1]["later_value"],
        serde_json::Value::Null
    );
}

#[test]
fn stale_document_base_is_lost_at_replay() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = crate::clock::FixedClock::new(1);
    let b1 = t.put_blob("v1", &mut c).unwrap();
    let b2 = t.put_blob("v2 by A", &mut c).unwrap();
    let b3 = t.put_blob("v2 by B", &mut c).unwrap();
    let doc = |blob: &str, base: Option<u64>| {
        Op::Doc(DocData {
            name: "summary".into(),
            blob: blob.into(),
            base: base.map(u),
        })
    };
    append_events(
        &t,
        &[
            ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), doc(&b1, None)),
            ev(u(21), ACTOR_A, Some(u(20)), u(T1), doc(&b2, Some(20))),
            ev(u(22), ACTOR_B, Some(u(20)), u(T1), doc(&b3, Some(20))),
            ev(
                u(19),
                ACTOR_B,
                Some(u(BASE_LAST)),
                t.config.id,
                Op::Actor(ActorData { name: "bob".into() }),
            ),
        ],
    );
    let rp = load(&t);
    assert!(rp.skipped.is_empty(), "lost edits are not skipped");
    let d = &rp.state.tickets[&u(T1)].documents["summary"];
    assert_eq!(d.current, Some(u(21)));
    assert_eq!(d.current_version().unwrap().blob, b2);
    let lost: Vec<_> = d.versions.iter().map(|v| (v.id, v.lost)).collect();
    assert_eq!(lost, vec![(u(20), false), (u(21), false), (u(22), true)]);
    assert_eq!(rp.state.lost_docs.len(), 1);
    assert_eq!(rp.state.lost_docs[0].event, u(22));
    assert_eq!(rp.state.tickets[&u(T1)].activity.id, u(22));
    assert_eq!(rp.state.lost_docs[0].current, Some(u(21)));
    let (report, issues) = lint(&t.config, &rp);
    assert!(issues);
    assert_eq!(report["lost_documents"][0]["event"], json(u(22)));
    // A first version written concurrently with another first version.
    append_events(
        &t,
        &[
            ev(u(40), ACTOR_B, Some(u(22)), u(T2), doc(&b1, None)),
            ev(u(41), ACTOR_A, Some(u(22)), u(T2), doc(&b2, None)),
        ],
    );
    let rp = load(&t);
    let d = &rp.state.tickets[&u(T2)].documents["summary"];
    assert_eq!(d.current, Some(u(40)));
    assert!(d.versions[1].lost);
}

#[test]
fn lint_reports_dangling_repos_and_unnamed_actors() {
    let dir = disposable_dir();
    let t = based(&dir);
    append_events(
        &t,
        &[ev(
            u(20),
            ACTOR_B,
            Some(u(BASE_LAST)),
            u(T1),
            Op::Branch(crate::event::BranchData {
                repo: "app".into(),
                name: "feature".into(),
            }),
        )],
    );
    let rp = load(&t);
    assert!(rp.skipped.is_empty());
    let (report, issues) = lint(&t.config, &rp);
    assert!(issues);
    assert_eq!(report["dangling_repos"][0]["repo"], "app");
    assert_eq!(report["dangling_repos"][0]["event"], json(u(20)));
    assert_eq!(report["unnamed_actors"][0]["actor"], json(ACTOR_B));
    assert_eq!(report["unnamed_actors"].as_array().unwrap().len(), 1);
}

#[test]
fn short_ids_and_references() {
    let dir = disposable_dir();
    let t = based(&dir);
    let rp = load(&t);
    let view = View::new(&t, &rp);
    let t1 = &rp.state.tickets[&u(T1)];
    let t2 = &rp.state.tickets[&u(T2)];
    // Ids differing in the time part need only the 10 time characters.
    assert_eq!(view.short_id(u(T2)), "000000000C");
    // Numbers display unpadded; padded input still resolves.
    assert_eq!(view.display(t1), "ZZ-5");
    assert_eq!(view.number_text(1234), "ZZ-1234");
    assert_eq!(view.display(t2), "000000000C");
    for r in [
        "ZZ-5",
        "zz-5",
        "ZZ-0005",
        "zz-005",
        "ZZ-00000000000000000005",
    ] {
        assert_eq!(view.resolve(r).unwrap(), u(T1), "{r}");
    }
    assert!(matches!(
        view.resolve("5"),
        Err(crate::error::Error::UnknownTicket(_))
    ));
    assert_eq!(view.resolve(&u(T2).to_canonical()).unwrap(), u(T2));
    assert_eq!(
        view.resolve(&u(T2).to_canonical().to_lowercase()).unwrap(),
        u(T2)
    );
    assert!(matches!(
        view.resolve("0000"),
        Err(crate::error::Error::AmbiguousTicket(..))
    ));
    assert!(matches!(
        view.resolve("000"),
        Err(crate::error::Error::UnknownTicket(_))
    ));
    assert!(matches!(
        view.resolve("ZZ-6"),
        Err(crate::error::Error::UnknownTicket(_))
    ));
    assert!(matches!(
        view.resolve("7ZZZ"),
        Err(crate::error::Error::UnknownTicket(_))
    ));
}

#[test]
fn short_ids_grow_until_unique() {
    let ids = [
        Ulid::from_parts(5, 1),
        Ulid::from_parts(5, 2),
        Ulid::from_parts(900_000, 0),
    ];
    let s = crate::view::short_ids(ids);
    assert_eq!(s[&ids[0]].len(), 26);
    assert_eq!(s[&ids[2]].len(), 10);
    assert!(ids[0].to_canonical().starts_with(&s[&ids[0]]));
}

#[test]
fn events_without_as_resolve_to_the_declared_name() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut tagged = ev(
        u(20),
        ACTOR_A,
        Some(u(BASE_LAST)),
        u(T1),
        Op::Tag(TagData { tag: "x".into() }),
    );
    tagged.identity = Some("agent".into());
    append_events(&t, &[tagged]);
    let rp = load(&t);
    assert!(rp.skipped.is_empty());
    // A's old events carry no `as` and resolve to its declared name; its
    // new one carries `as`.
    let ticket = &rp.state.tickets[&u(T1)];
    assert_eq!(ticket.created.identity, None);
    assert_eq!(
        rp.state.identity_of(ticket.created.actor, None).as_deref(),
        Some("alice")
    );
    let view = View::new(&t, &rp);
    let shown = view.ticket(ticket);
    assert_eq!(shown["created"]["actor"], json!(ACTOR_A));
    assert_eq!(shown["created"]["identity"], "alice");
    assert_eq!(shown["activity"]["identity"], "agent");
    assert_eq!(shown["tag_since"]["x"]["identity"], "agent");
    // An undeclared writer's events without `as` resolve to nothing.
    assert_eq!(rp.state.identity_of(ACTOR_B, None), None);
    assert_eq!(
        rp.state.identity_of(ACTOR_B, Some("agent")).as_deref(),
        Some("agent")
    );
}

#[test]
fn writers_sharing_an_identity_are_still_concurrent() {
    let dir = disposable_dir();
    let t = based(&dir);
    // Two clones of one identity, neither having seen the other's change.
    let mut a = ev(u(20), ACTOR_A, Some(u(BASE_LAST)), u(T1), status("next"));
    let mut b = ev(u(21), ACTOR_B, Some(u(BASE_LAST)), u(T1), status("wait"));
    a.identity = Some("agent".into());
    b.identity = Some("agent".into());
    append_events(&t, &[a, b]);
    let rp = load(&t);
    assert_eq!(rp.state.concurrent.len(), 1);
    assert_eq!(rp.state.concurrent[0].earlier, u(20));
    assert_eq!(rp.state.concurrent[0].later, u(21));
    let (report, issues) = lint(&t.config, &rp);
    assert!(issues);
    assert_eq!(report["concurrent"].as_array().unwrap().len(), 1);
    // B never declared a name, but every event of it has an identity.
    assert_eq!(report["unnamed_actors"], json!([]));
}

#[test]
fn lint_reports_writers_without_identity_and_unknown_identities() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut listed = ev(
        u(20),
        ACTOR_B,
        Some(u(BASE_LAST)),
        u(T1),
        Op::Tag(TagData { tag: "a".into() }),
    );
    listed.identity = Some("agent".into());
    let bare = ev(
        u(21),
        ACTOR_B,
        Some(u(20)),
        u(T1),
        Op::Tag(TagData { tag: "b".into() }),
    );
    let mut stranger = ev(
        u(22),
        ACTOR_B,
        Some(u(21)),
        u(T1),
        Op::Tag(TagData { tag: "c".into() }),
    );
    stranger.identity = Some("stranger".into());
    let mut imported = ev(
        u(23),
        ACTOR_B,
        Some(u(22)),
        u(T1),
        Op::Tag(TagData { tag: "d".into() }),
    );
    imported.identity = Some("import".into());
    append_events(&t, &[listed, bare, stranger, imported]);
    let rp = load(&t);
    // Lint reports the event; replay keeps it.
    assert!(rp.skipped.is_empty());
    assert!(rp.state.tickets[&u(T1)].tags.contains("c"));
    let (report, issues) = lint(&t.config, &rp);
    assert!(issues);
    // Only the one event without `as` lacks an identity.
    assert_eq!(
        report["unnamed_actors"],
        json!([{"actor": ACTOR_B, "events": 1}])
    );
    assert_eq!(
        report["unknown_identities"],
        json!([{"event": u(22), "actor": ACTOR_B, "as": "stranger", "op": "tag"}])
    );
    // Without an actors list only the importer's identity is known.
    let mut unlisted = t.config.clone();
    unlisted.actors = None;
    let unknown = lint(&unlisted, &rp).0["unknown_identities"].clone();
    let names: Vec<&str> = unknown
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["as"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["agent", "stranger"]);
}
