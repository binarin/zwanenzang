//! Git integration: a bare repository as the remote and clones as machines,
//! all inside one disposable directory, driven through the CLI.

mod common;

use std::path::{Path, PathBuf};

use common::*;
use serde_json::{Value, json};

struct Net {
    dir: tempfile::TempDir,
}

impl Net {
    /// A bare remote and a first clone holding a fresh tracker, pushed.
    fn new() -> Net {
        let dir = disposable_dir();
        git(
            dir.path(),
            &["init", "--quiet", "--bare", "remote-test-repo"],
        );
        let net = Net { dir };
        let a = net.clone_as("a");
        let out = ok(&a, &["init", "--prefix", "ZZ", "--name", "Test"]);
        assert_eq!(out["sync"]["pushed"], true, "{out}");
        net
    }

    fn remote(&self) -> PathBuf {
        self.dir.path().join("remote-test-repo")
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(format!("{name}-test-repo"))
    }

    /// Clones the remote into `<name>-test-repo`.
    fn clone_as(&self, name: &str) -> PathBuf {
        let to = format!("{name}-test-repo");
        git(
            self.dir.path(),
            &["clone", "--quiet", "remote-test-repo", &to],
        );
        self.path(name)
    }

    /// Points `clone`'s remote somewhere that does not exist, or back.
    fn offline(&self, clone: &Path, off: bool) {
        let url = if off {
            self.dir.path().join("gone-test-repo")
        } else {
            self.remote()
        };
        git(
            clone,
            &["remote", "set-url", "origin", url.to_str().unwrap()],
        );
    }
}

fn tickets(p: &Path) -> Value {
    ok(p, &["list", "--all"])["tickets"].clone()
}

fn numbers(p: &Path) -> Vec<u64> {
    tickets(p)
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["number"].as_u64().expect("numbered"))
        .collect()
}

#[test]
fn clones_share_one_numbering() {
    let net = Net::new();
    let a = net.path("a");
    let first = ok(&a, &["create", "From A"]);
    assert_eq!(first["sync"]["upstream"], "origin/main");
    assert_eq!(first["sync"]["pushed"], true);
    assert_eq!(first["ticket"]["display"], "ZZ-0001");
    let b = net.clone_as("b");
    let second = ok(&b, &["create", "From B"]);
    assert_eq!(second["ticket"]["display"], "ZZ-0002");
    assert_ne!(actor_of(&a), actor_of(&b), "an actor per clone");
    // A sees B's ticket after a sync; reads alone do not fetch.
    assert_eq!(tickets(&a).as_array().unwrap().len(), 1);
    let s = ok(&a, &["sync"]);
    assert_eq!(s["sync"]["pushed"], true);
    assert_eq!(s["sync"]["numbered"], json!([]));
    assert_eq!(tickets(&a), tickets(&b));
    assert_eq!(git(&a, &["status", "--porcelain"]), "");
}

#[test]
fn offline_writes_wait_for_their_numbers() {
    let net = Net::new();
    let a = net.path("a");
    let b = net.clone_as("b");
    net.offline(&a, true);
    let off = ok(&a, &["create", "Written offline"]);
    let off_id = id(&off);
    assert_eq!(off["written"], true, "the write itself succeeds");
    assert_eq!(off["sync"]["error"]["code"], "fetch-failed");
    assert_eq!(off["sync"]["pushed"], false);
    assert_eq!(off["ticket"]["number"], Value::Null);
    let off_sync = run_in(&a, &["sync"], "");
    assert_eq!(off_sync.code, 1);
    assert_eq!(off_sync.json["sync"]["error"]["code"], "fetch-failed");

    // Meanwhile B publishes, so A's ticket is numbered after B's.
    let on = ok(&b, &["create", "Written online"]);
    assert_eq!(on["ticket"]["display"], "ZZ-0001");
    net.offline(&a, false);
    let s = ok(&a, &["sync"]);
    assert_eq!(s["sync"]["numbered"][0]["id"], off_id.as_str());
    assert_eq!(s["sync"]["numbered"][0]["display"], "ZZ-0002");
    ok(&b, &["sync"]);
    assert_eq!(tickets(&a), tickets(&b));
    // History is linear: A's commits were rebased onto B's.
    assert_eq!(git(&a, &["rev-list", "--merges", "HEAD"]), "");
    assert_eq!(run_in(&a, &["lint"], "").code, 0);
}

#[test]
fn a_failed_push_takes_its_numbers_back() {
    let net = Net::new();
    let a = net.path("a");
    let hook = net.remote().join("hooks/pre-receive");
    write_file(&net.remote(), "hooks/pre-receive", "#!/bin/sh\nexit 1\n");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = ok(&a, &["create", "Refused by the remote"]);
    assert_eq!(out["sync"]["error"]["code"], "push-failed");
    assert_eq!(out["sync"]["numbered"], json!([]));
    assert_eq!(out["ticket"]["number"], Value::Null);
    let log = git(&a, &["log", "--format=%s"]);
    assert!(!log.contains("publish"), "{log}");
    assert_eq!(git(&a, &["status", "--porcelain"]), "");

    std::fs::remove_file(&hook).unwrap();
    let s = ok(&a, &["sync"]);
    assert_eq!(s["sync"]["pushed"], true);
    assert_eq!(s["sync"]["numbered"][0]["display"], "ZZ-0001");
    assert_eq!(numbers(&a), [1]);
}

#[test]
fn racing_clones_never_share_a_number() {
    let net = Net::new();
    let clones = [net.path("a"), net.clone_as("b"), net.clone_as("c")];
    let per_clone = 4;
    std::thread::scope(|s| {
        for (k, c) in clones.iter().enumerate() {
            s.spawn(move || {
                for i in 0..per_clone {
                    let out = ok(c, &["create", &format!("clone {k} ticket {i}")]);
                    assert_eq!(out["sync"]["error"], Value::Null, "{out}");
                }
            });
        }
    });
    for c in &clones {
        ok(c, &["sync"]);
    }
    let total = (clones.len() * per_clone) as u64;
    // Unique and without gaps; tickets are numbered in publish order, which
    // across clones is not id order.
    let mut got = numbers(&clones[0]);
    got.sort();
    assert_eq!(got, (1..=total).collect::<Vec<_>>());
    for c in &clones[1..] {
        assert_eq!(tickets(c), tickets(&clones[0]));
    }
    let lint = run_in(&clones[0], &["lint"], "");
    assert_eq!(lint.code, 0, "{}", lint.json);
}

#[test]
fn a_conflict_in_docs_is_reported_not_resolved() {
    let net = Net::new();
    let a = net.path("a");
    let b = net.clone_as("b");
    for (clone, text) in [(&a, "from a\n"), (&b, "from b\n")] {
        write_file(clone, "docs/notes.md", text);
        git(clone, &["add", "docs/notes.md"]);
        git(clone, &["commit", "--quiet", "-m", "notes"]);
    }
    git(&b, &["push", "--quiet"]);
    let before = git(&a, &["rev-parse", "HEAD"]);
    let out = ok(&a, &["create", "Despite the conflict"]);
    assert_eq!(out["written"], true);
    assert_eq!(out["sync"]["error"]["code"], "rebase-conflict");
    assert_eq!(out["sync"]["pushed"], false);
    // The rebase was aborted: A's branch holds its own commits only.
    assert_eq!(git(&a, &["rev-parse", "HEAD~1"]), before);
    assert!(!a.join(".git/rebase-merge").exists());
    assert_eq!(read(&a, "docs/notes.md"), "from a\n");
}

#[test]
fn init_refuses_a_directory_inside_another_repository() {
    let net = Net::new();
    let inner = net.path("a").join("nested-test-repo");
    std::fs::create_dir(&inner).unwrap();
    // Refused as inside the tracker before git is consulted.
    err(&inner, &["init", "--prefix", "QQ"], "already-initialized");
    git(net.dir.path(), &["init", "--quiet", "code-test-repo"]);
    let code = net.path("code");
    git(&code, &["commit", "--quiet", "--allow-empty", "-m", "code"]);
    let sub = code.join("sub-test-repo");
    std::fs::create_dir(&sub).unwrap();
    err(&sub, &["init", "--prefix", "QQ"], "inside-repository");
    assert!(!sub.join("zwanenzang.toml").exists());
}
