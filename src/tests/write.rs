use super::replay::invalid_ticket_ops;
use super::util::*;
use crate::clock::FixedClock;
use crate::error::Error;
use crate::event::{
    ActorData, CommentData, DocData, Empty, Op, ParentData, RelateData, TagData, TextTo,
};
use crate::store::{Tracker, blob_name};
use crate::ulid::Ulid;
use crate::write::{Plan, Target, Written};

fn based(dir: &tempfile::TempDir) -> Tracker {
    let t = new_tracker(dir);
    append_events(&t, &base_events(t.config.id));
    t
}

fn write_ops(
    t: &Tracker,
    clock: &mut FixedClock,
    ops: Vec<(Target, Op)>,
    blobs: Vec<String>,
) -> crate::error::Result<Written> {
    assert_disposable(&t.root);
    t.write(clock, Some("tester"), |_| Ok(Plan { ops, blobs }))
}

fn write_one(
    t: &Tracker,
    clock: &mut FixedClock,
    entity: Ulid,
    op: Op,
) -> crate::error::Result<Written> {
    write_ops(t, clock, vec![(Target::Entity(entity), op)], vec![])
}

fn rejected_code(r: crate::error::Result<Written>) -> &'static str {
    match r {
        Err(Error::Rejected(rej)) => rej.code.as_str(),
        Err(e) => panic!("expected a rejection, got {e}"),
        Ok(w) => panic!("expected a rejection, wrote {:?}", w.events),
    }
}

fn status(to: &str) -> Op {
    Op::Status(TextTo { to: to.into() })
}

fn me(t: &Tracker) -> Ulid {
    t.actor_id(false, &mut FixedClock::new(0)).unwrap()
}

#[test]
fn first_write_declares_actor_then_never_again() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = FixedClock::new(1_000_000);
    let w = write_one(&t, &mut c, u(T1), status("doing")).unwrap();
    let ops: Vec<&str> = w.events.iter().map(|e| e.op.name()).collect();
    assert_eq!(ops, vec!["actor", "status"]);
    assert_eq!(
        w.events[0].op,
        Op::Actor(ActorData {
            name: "tester".into()
        })
    );
    assert_eq!(w.events[0].entity, t.config.id);
    assert_eq!(w.primary().unwrap().op, status("doing"));
    // Each event's parent is the highest id seen before it.
    assert_eq!(w.events[0].parent, Some(u(BASE_LAST)));
    assert_eq!(w.events[1].parent, Some(w.events[0].id));
    let w = write_one(&t, &mut c, u(T1), status("done")).unwrap();
    assert_eq!(w.events.len(), 1);
    // What was written replays to the same state the write reported.
    let rp = load(&t);
    assert!(rp.skipped.is_empty());
    assert_eq!(rp.state.tickets[&u(T1)].status, "done");
    assert_eq!(rp.state.actors[&me(&t)].name.as_deref(), Some("tester"));
    assert_eq!(rp.events.len(), 9);
    let log = std::fs::read_to_string(t.log_path(me(&t))).unwrap();
    assert_eq!(log.lines().count(), 3);
    assert!(log.ends_with('\n'));
}

#[test]
fn every_rule_refused_on_write_and_nothing_written() {
    let probe = disposable_dir();
    let root = new_tracker(&probe).config.id;
    for (entity, op, code) in invalid_ticket_ops(root) {
        let dir = disposable_dir();
        let t = based(&dir);
        let before = log_snapshot(&t);
        let blobs_before = t.blob_names().unwrap();
        let mut c = FixedClock::new(1_000_000);
        let r = write_ops(
            &t,
            &mut c,
            vec![(Target::Entity(entity), op.clone())],
            vec![],
        );
        assert_eq!(rejected_code(r), code, "{op:?}");
        assert_eq!(log_snapshot(&t), before, "{op:?} wrote something");
        assert_eq!(t.blob_names().unwrap(), blobs_before);
    }
}

#[test]
fn refused_write_stores_no_blob() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = FixedClock::new(1_000_000);
    let text = "long text".to_string();
    let op = Op::Comment(CommentData {
        text: None,
        blob: Some(blob_name(&text)),
        link: None,
    });
    let r = write_ops(
        &t,
        &mut c,
        vec![(Target::Entity(u(T3)), op)],
        vec![text.clone()],
    );
    assert_eq!(rejected_code(r), "tombstoned");
    assert!(t.blob_names().unwrap().is_empty());
    let op = Op::Comment(CommentData {
        text: None,
        blob: Some(blob_name(&text)),
        link: None,
    });
    let w = write_ops(
        &t,
        &mut c,
        vec![(Target::Entity(u(T1)), op)],
        vec![text.clone()],
    )
    .unwrap();
    assert!(w.written());
    assert_eq!(t.get_blob(&blob_name(&text)).unwrap(), text);
}

#[test]
fn a_refused_event_refuses_the_whole_plan() {
    let dir = disposable_dir();
    let t = based(&dir);
    let before = log_snapshot(&t);
    let mut c = FixedClock::new(1_000_000);
    let r = write_ops(
        &t,
        &mut c,
        vec![
            (Target::Created, create("new")),
            (Target::Created, Op::Tag(TagData { tag: "ok".into() })),
            (
                Target::Created,
                Op::Tag(TagData {
                    tag: "not ok".into(),
                }),
            ),
        ],
        vec![],
    );
    assert_eq!(rejected_code(r), "invalid-tag");
    assert_eq!(log_snapshot(&t), before);
}

#[test]
fn created_target_names_the_new_ticket() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = FixedClock::new(1_000_000);
    let w = write_ops(
        &t,
        &mut c,
        vec![
            (Target::Created, create("new")),
            (Target::Created, Op::Parent(ParentData { to: Some(u(T1)) })),
            (Target::Created, Op::Tag(TagData { tag: "x".into() })),
        ],
        vec![],
    )
    .unwrap();
    let create_ev = &w.events[1];
    assert_eq!(create_ev.entity, create_ev.id);
    assert!(w.events[2..].iter().all(|e| e.entity == create_ev.id));
    let rp = load(&t);
    let n = &rp.state.tickets[&create_ev.id];
    assert_eq!(n.parent, Some(u(T1)));
    assert!(n.tags.contains("x"));
    assert_eq!(n.status, "draft");
}

#[test]
fn parent_cycle_refused_on_write() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = FixedClock::new(1_000_000);
    write_one(
        &t,
        &mut c,
        u(T1),
        Op::Parent(ParentData { to: Some(u(T2)) }),
    )
    .unwrap();
    let before = log_snapshot(&t);
    let r = write_one(
        &t,
        &mut c,
        u(T2),
        Op::Parent(ParentData { to: Some(u(T1)) }),
    );
    assert_eq!(rejected_code(r), "parent-cycle");
    assert_eq!(log_snapshot(&t), before);
    // Clearing and re-parenting the other way round is fine.
    write_one(&t, &mut c, u(T1), Op::Parent(ParentData { to: None })).unwrap();
    write_one(
        &t,
        &mut c,
        u(T2),
        Op::Parent(ParentData { to: Some(u(T1)) }),
    )
    .unwrap();
}

#[test]
fn no_op_writes_are_not_written() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = FixedClock::new(1_000_000);
    write_one(&t, &mut c, u(T1), Op::Tag(TagData { tag: "x".into() })).unwrap();
    write_one(&t, &mut c, u(T1), Op::Relate(RelateData { to: u(T2) })).unwrap();
    write_one(&t, &mut c, u(T1), Op::Archive(Empty {})).unwrap();
    let before = log_snapshot(&t);
    let no_ops = vec![
        (u(T1), status("draft")),
        (u(T1), Op::Title(TextTo { to: "one".into() })),
        (u(T1), Op::Kind(crate::event::KindData { to: None })),
        (u(T1), Op::Parent(ParentData { to: None })),
        (u(T1), Op::Tag(TagData { tag: "x".into() })),
        (u(T1), Op::Untag(TagData { tag: "y".into() })),
        (u(T2), Op::Relate(RelateData { to: u(T1) })),
        (u(T2), Op::Unrelate(RelateData { to: u(T3) })),
        (u(T1), Op::Archive(Empty {})),
        (
            t.config.id,
            Op::Actor(ActorData {
                name: "tester".into(),
            }),
        ),
    ];
    for (entity, op) in no_ops {
        let w = write_one(&t, &mut c, entity, op.clone()).unwrap();
        assert!(!w.written(), "{op:?} was written");
        assert!(w.primary().is_none());
        assert_eq!(log_snapshot(&t), before, "{op:?}");
    }
}

#[test]
fn unnamed_actor_does_not_write_a_lone_declaration() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = FixedClock::new(1_000_000);
    let w = write_one(&t, &mut c, u(T1), status("draft")).unwrap();
    assert!(!w.written());
    assert!(
        log_snapshot(&t)
            .iter()
            .all(|(n, _)| !n.starts_with(&me(&t).to_canonical()))
    );
}

#[test]
fn lagging_wall_clock_still_sorts_after_everything_seen() {
    let dir = disposable_dir();
    let t = based(&dir);
    // The wall clock is far behind the newest event in the clone.
    let mut c = FixedClock::new(1);
    let w = write_one(&t, &mut c, u(T1), status("doing")).unwrap();
    assert_eq!(w.events[0].id, Ulid::from_parts(BASE_LAST, 1));
    assert_eq!(w.events[1].id, Ulid::from_parts(BASE_LAST, 2));
    // Another actor's event from the future, which this clone has seen.
    let future = Ulid::from_parts(9_000_000_000, 77);
    append_events(
        &t,
        &[ev(
            future,
            ACTOR_B,
            Some(w.events[1].id),
            u(T2),
            status("todo"),
        )],
    );
    c.now = 2_000;
    let w = write_one(&t, &mut c, u(T1), status("done")).unwrap();
    assert_eq!(w.events[0].id, Ulid::from_parts(9_000_000_000, 78));
    assert_eq!(w.events[0].parent, Some(future));
    // Events seen but skipped count as seen too.
    let skipped_future = Ulid::from_parts(9_500_000_000, 5);
    append_raw(
        &t,
        &ACTOR_B.to_canonical(),
        &[format!(
            r#"{{"id":"{skipped_future}","actor":"{ACTOR_B}","parent":null,"ts":"x","entity":"{}","op":"newer-op","data":{{}}}}"#,
            u(T1)
        )],
    );
    let w = write_one(&t, &mut c, u(T1), status("review")).unwrap();
    assert_eq!(w.events[0].id, Ulid::from_parts(9_500_000_000, 6));
    assert!(
        load(&t)
            .skipped
            .iter()
            .all(|s| s.code.as_str() == "unknown-op")
    );
}

#[test]
fn document_compare_and_set() {
    let dir = disposable_dir();
    let t = based(&dir);
    let mut c = FixedClock::new(1_000_000);
    let set = |t: &Tracker, c: &mut FixedClock, text: &str, base: Option<Ulid>| {
        write_ops(
            t,
            c,
            vec![(
                Target::Entity(u(T1)),
                Op::Doc(DocData {
                    name: "description".into(),
                    blob: blob_name(text),
                    base,
                }),
            )],
            vec![text.to_string()],
        )
    };
    let v1 = set(&t, &mut c, "first", None)
        .unwrap()
        .primary()
        .unwrap()
        .id;
    // A second writer that read nothing may not overwrite.
    let before = log_snapshot(&t);
    let blobs_before = t.blob_names().unwrap();
    assert_eq!(
        rejected_code(set(&t, &mut c, "other", None)),
        "stale-doc-base"
    );
    assert_eq!(log_snapshot(&t), before);
    assert_eq!(
        t.blob_names().unwrap(),
        blobs_before,
        "refused text is not stored"
    );
    let v2 = set(&t, &mut c, "second", Some(v1))
        .unwrap()
        .primary()
        .unwrap()
        .id;
    // Writing against the version read before someone else wrote: refused.
    assert_eq!(
        rejected_code(set(&t, &mut c, "third", Some(v1))),
        "stale-doc-base"
    );
    // A base that is not a version of this document at all: refused.
    assert_eq!(
        rejected_code(set(&t, &mut c, "third", Some(u(T2)))),
        "stale-doc-base"
    );
    // The same text again against the current version changes nothing.
    let w = set(&t, &mut c, "second", Some(v2)).unwrap();
    assert!(!w.written());
    let rp = load(&t);
    assert!(rp.skipped.is_empty());
    assert!(rp.state.lost_docs.is_empty());
    let d = &rp.state.tickets[&u(T1)].documents["description"];
    assert_eq!(d.current, Some(v2));
    assert_eq!(d.versions.len(), 2);
    assert_eq!(
        t.get_blob(&d.current_version().unwrap().blob).unwrap(),
        "second"
    );
}
