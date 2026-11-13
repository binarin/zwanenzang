//! Test helpers. Every tracker a test touches lives in a directory under the
//! system temporary directory whose name ends in `-test-repo`; each helper
//! that opens or writes one checks both markers first and panics otherwise.

use std::path::Path;

use serde_json::Value;

use crate::clock::FixedClock;
use crate::event::{ActorData, CreateData, Empty, Event, NumberData, Op};
use crate::replay::Replay;
use crate::store::Tracker;
use crate::ulid::Ulid;

pub const MARKER: &str = "-test-repo";

pub fn assert_disposable(path: &Path) {
    let tmp = std::fs::canonicalize(std::env::temp_dir()).expect("temp dir");
    let p = std::fs::canonicalize(path).expect("test path exists");
    assert!(
        p.starts_with(&tmp),
        "refusing to touch {p:?}: not under the temporary directory {tmp:?}"
    );
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
    assert!(
        name.ends_with(MARKER),
        "refusing to touch {p:?}: directory name does not end in {MARKER}"
    );
}

/// A fresh disposable directory, removed when dropped.
pub fn disposable_dir() -> tempfile::TempDir {
    let d = tempfile::Builder::new()
        .prefix("zwanenzang-")
        .suffix(MARKER)
        .tempdir_in(std::env::temp_dir())
        .expect("create temp dir");
    assert_disposable(d.path());
    d
}

/// The clock every tracker in these tests is initialised with, so the root
/// id is the same across trackers.
pub fn init_clock() -> FixedClock {
    FixedClock::new(1_000)
}

pub fn new_tracker(dir: &tempfile::TempDir) -> Tracker {
    assert_disposable(dir.path());
    Tracker::create_local(
        dir.path(),
        "test",
        "ZZ",
        "main",
        &[],
        None,
        &mut init_clock(),
    )
    .expect("init")
}

/// Appends raw lines to the log named `log`, which is normally an actor id.
pub fn append_raw(t: &Tracker, log: &str, lines: &[String]) {
    assert_disposable(&t.root);
    use std::io::Write;
    let dir = t.events_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(format!("{log}.jsonl")))
        .unwrap();
    for l in lines {
        writeln!(f, "{l}").unwrap();
    }
}

/// Appends raw bytes to the log named `log`, for lines that are not text.
pub fn append_bytes(t: &Tracker, log: &str, bytes: &[u8]) {
    assert_disposable(&t.root);
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(t.events_dir().join(format!("{log}.jsonl")))
        .unwrap();
    f.write_all(bytes).unwrap();
}

pub fn append_events(t: &Tracker, events: &[Event]) {
    for e in events {
        append_raw(t, &e.actor.to_canonical(), &[e.to_line()]);
    }
}

pub fn load(t: &Tracker) -> Replay {
    assert_disposable(&t.root);
    t.load().expect("load")
}

/// All log bytes, for asserting that nothing was written.
pub fn log_snapshot(t: &Tracker) -> Vec<(String, Vec<u8>)> {
    assert_disposable(&t.root);
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(t.events_dir()) {
        for e in rd {
            let e = e.unwrap();
            out.push((
                e.file_name().to_string_lossy().into_owned(),
                std::fs::read(e.path()).unwrap(),
            ));
        }
    }
    out.sort();
    out
}

pub fn u(t: u64) -> Ulid {
    Ulid::from_parts(t, 0)
}

pub const ACTOR_A: Ulid = Ulid((1u128 << 80) | 0xA);
pub const ACTOR_B: Ulid = Ulid((1u128 << 80) | 0xB);

pub fn ev(id: Ulid, actor: Ulid, parent: Option<Ulid>, entity: Ulid, op: Op) -> Event {
    Event {
        id,
        actor,
        parent,
        ts: "2026-11-07T00:00:00Z".into(),
        entity,
        op,
    }
}

pub fn create(title: &str) -> Op {
    Op::Create(CreateData {
        title: title.into(),
        status: "todo".into(),
        kind: None,
    })
}

/// Tickets of the base fixture.
pub const T1: u64 = 11;
pub const T2: u64 = 12;
pub const T3: u64 = 13;
/// The last event of the base fixture.
pub const BASE_LAST: u64 = 15;

/// A tracker with: actor A named, tickets T1, T2, T3 created by A, T3
/// tombstoned, T1 numbered 5.
pub fn base_events(root: Ulid) -> Vec<Event> {
    let a = ACTOR_A;
    vec![
        ev(
            u(10),
            a,
            None,
            root,
            Op::Actor(ActorData {
                name: "alice".into(),
            }),
        ),
        ev(u(T1), a, Some(u(10)), u(T1), create("one")),
        ev(u(T2), a, Some(u(T1)), u(T2), create("two")),
        ev(u(T3), a, Some(u(T2)), u(T3), create("three")),
        ev(u(14), a, Some(u(T3)), u(T3), Op::Tombstone(Empty {})),
        ev(
            u(BASE_LAST),
            a,
            Some(u(14)),
            u(T1),
            Op::Number(NumberData { number: 5 }),
        ),
    ]
}

pub fn skipped_codes(rp: &Replay) -> Vec<&'static str> {
    rp.skipped.iter().map(|s| s.code.as_str()).collect()
}

pub fn json(v: impl serde::Serialize) -> Value {
    serde_json::to_value(v).unwrap()
}

/// Runs a read-only git command in the disposable repository `dir` and
/// returns its trimmed stdout.
pub fn git_out(dir: &Path, args: &[&str]) -> String {
    assert_disposable(dir);
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .output()
        .expect("run git");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}
