use std::fs;

use super::util::*;
use crate::clock::FixedClock;
use crate::config::{CONFIG_FILE, Config};
use crate::error::Error;
use crate::store::{Tracker, blob_name, find_root};

#[test]
fn init_writes_layout() {
    let dir = disposable_dir();
    let t = new_tracker(&dir);
    let root = dir.path();
    assert_eq!(
        fs::read_to_string(root.join(".gitattributes")).unwrap(),
        "events/*.jsonl merge=union\n"
    );
    assert_eq!(
        fs::read_to_string(root.join(".gitignore")).unwrap(),
        "/.zwanenzang/\n"
    );
    assert!(root.join("events").is_dir());
    assert!(root.join("blobs").is_dir());
    let cfg = Config::parse(&fs::read_to_string(root.join(CONFIG_FILE)).unwrap()).unwrap();
    assert_eq!(cfg, t.config);
    assert_eq!(cfg.prefix, "ZZ");
    assert_eq!(cfg.statuses[0], "draft");
    let actor = fs::read_to_string(root.join(".zwanenzang/actor")).unwrap();
    assert_eq!(
        actor.trim(),
        t.actor_id(false, &mut FixedClock::new(0))
            .unwrap()
            .to_canonical()
    );
    // No events are written by init.
    assert!(log_snapshot(&t).is_empty());
}

#[test]
fn init_twice_refused() {
    let dir = disposable_dir();
    new_tracker(&dir);
    let err = Tracker::init(dir.path(), "x", "ZZ", &mut init_clock()).unwrap_err();
    assert!(matches!(err, Error::AlreadyInitialized(_)), "{err}");
}

#[test]
fn init_keeps_existing_gitattributes() {
    let dir = disposable_dir();
    assert_disposable(dir.path());
    fs::write(dir.path().join(".gitattributes"), "*.png binary").unwrap();
    new_tracker(&dir);
    assert_eq!(
        fs::read_to_string(dir.path().join(".gitattributes")).unwrap(),
        "*.png binary\nevents/*.jsonl merge=union\n"
    );
}

#[test]
fn find_root_searches_upward() {
    let dir = disposable_dir();
    let t = new_tracker(&dir);
    let sub = dir.path().join("docs/deep");
    fs::create_dir_all(&sub).unwrap();
    assert_eq!(find_root(&sub).unwrap(), t.root);
    let other = disposable_dir();
    assert!(matches!(
        find_root(other.path()),
        Err(Error::NotATracker(_))
    ));
}

#[test]
fn append_and_reread() {
    let dir = disposable_dir();
    let t = new_tracker(&dir);
    t.append_lines(ACTOR_A, &["{\"a\":1}".into(), "{\"a\":2}".into()])
        .unwrap();
    t.append_lines(ACTOR_A, &["{\"a\":3}".into()]).unwrap();
    t.append_lines(ACTOR_B, &["{\"b\":1}".into()]).unwrap();
    assert_eq!(
        fs::read_to_string(t.log_path(ACTOR_A)).unwrap(),
        "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n"
    );
    let lines = t.read_logs().unwrap();
    let got: Vec<(String, usize, String)> = lines
        .into_iter()
        .map(|l| (l.log, l.line_no, l.text))
        .collect();
    let a = ACTOR_A.to_canonical();
    let b = ACTOR_B.to_canonical();
    assert_eq!(
        got,
        vec![
            (a.clone(), 1, "{\"a\":1}".into()),
            (a.clone(), 2, "{\"a\":2}".into()),
            (a, 3, "{\"a\":3}".into()),
            (b, 1, "{\"b\":1}".into()),
        ]
    );
}

#[test]
fn append_repairs_missing_final_newline() {
    let dir = disposable_dir();
    let t = new_tracker(&dir);
    assert_disposable(&t.root);
    fs::write(t.log_path(ACTOR_A), "{\"partial\":true}").unwrap();
    t.append_lines(ACTOR_A, &["{\"next\":1}".into()]).unwrap();
    assert_eq!(
        fs::read_to_string(t.log_path(ACTOR_A)).unwrap(),
        "{\"partial\":true}\n{\"next\":1}\n"
    );
}

#[test]
fn blob_store_hashes_and_dedupes() {
    let dir = disposable_dir();
    let t = new_tracker(&dir);
    let mut c = FixedClock::new(5);
    let name = t.put_blob("hello", &mut c).unwrap();
    assert_eq!(
        name,
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    );
    assert_eq!(name, blob_name("hello"));
    assert_eq!(t.put_blob("hello", &mut c).unwrap(), name);
    let other = t.put_blob("hello\n", &mut c).unwrap();
    assert_ne!(other, name);
    let files: Vec<String> = fs::read_dir(t.blobs_dir())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(files.len(), 2, "no temporary files remain: {files:?}");
    assert_eq!(t.get_blob(&name).unwrap(), "hello");
    assert!(t.blob_names().unwrap().contains(&name));
    assert!(matches!(
        t.get_blob(&"0".repeat(64)),
        Err(Error::MissingBlob(_))
    ));
    assert!(matches!(t.get_blob("../x"), Err(Error::MissingBlob(_))));
}

#[test]
fn lock_is_exclusive() {
    let dir = disposable_dir();
    let t = new_tracker(&dir);
    let guard = t.lock().unwrap();
    let f = fs::OpenOptions::new()
        .write(true)
        .open(dir.path().join(".zwanenzang/lock"))
        .unwrap();
    assert!(f.try_lock().is_err());
    drop(guard);
    assert!(f.try_lock().is_ok());
}
