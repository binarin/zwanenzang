//! Provisioning tests use marked paths, never real URL-keyed storage.

use std::path::Path;

use super::util::{assert_disposable, disposable_dir, new_tracker};
use crate::git::Repo;
use crate::locator::{parse_locator, provision};

fn provision_test(
    root: &Path,
    dir: &Path,
    origin: &Path,
) -> crate::error::Result<crate::store::Tracker> {
    assert_disposable(root);
    assert_disposable(origin);
    assert_eq!(dir.parent(), Some(root));
    assert!(
        dir.file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .ends_with("-test-repo")
    );
    if dir.exists() {
        assert_disposable(dir);
    }
    provision(root, dir, &parse_locator(origin.to_str().unwrap())?)
}

fn remote_tracker() -> (tempfile::TempDir, crate::ulid::Ulid) {
    let seed = disposable_dir();
    let tracker = new_tracker(&seed);
    let remote = disposable_dir();
    assert_disposable(seed.path());
    assert_disposable(remote.path());
    let out = crate::git::command(seed.path())
        .args(["clone", "--bare", "--"])
        .arg(seed.path())
        .arg(remote.path())
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    (remote, tracker.config.id)
}

#[test]
fn concurrent_provisioning_reuses_one_complete_clone_and_actor() {
    let (remote, tracker_id) = remote_tracker();
    let root = disposable_dir();
    let dir = root.path().join("clone-test-repo");
    std::thread::scope(|scope| {
        let workers: Vec<_> = (0..4)
            .map(|_| {
                scope.spawn(|| {
                    let clone = provision_test(root.path(), &dir, remote.path()).unwrap();
                    assert_eq!(clone.config.id, tracker_id);
                })
            })
            .collect();
        for w in workers {
            w.join().unwrap();
        }
    });
    assert_disposable(&dir);
    let repo = Repo::open(&dir).unwrap();
    repo.config_set("zwanenzang.actor", "preserved").unwrap();
    std::fs::write(dir.join("unpublished"), "local work").unwrap();
    provision_test(root.path(), &dir, remote.path()).unwrap();
    assert_eq!(
        repo.config_get("zwanenzang.actor").unwrap().as_deref(),
        Some("preserved")
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("unpublished")).unwrap(),
        "local work"
    );
}

#[test]
fn wrong_origin_and_incomplete_storage_are_never_replaced() {
    let (remote, _) = remote_tracker();
    let root = disposable_dir();
    let dir = root.path().join("clone-test-repo");
    provision_test(root.path(), &dir, remote.path()).unwrap();
    assert_disposable(&dir);
    let repo = Repo::open(&dir).unwrap();
    repo.config_set("remote.origin.url", "https://example.invalid/other")
        .unwrap();
    assert!(provision_test(root.path(), &dir, remote.path()).is_err());
    assert_eq!(
        repo.config_get("remote.origin.url").unwrap().as_deref(),
        Some("https://example.invalid/other")
    );

    let incomplete = root.path().join("incomplete-test-repo");
    std::fs::create_dir(&incomplete).unwrap();
    assert_disposable(&incomplete);
    std::fs::write(incomplete.join("precious"), "keep").unwrap();
    assert!(provision_test(root.path(), &incomplete, remote.path()).is_err());
    assert_eq!(
        std::fs::read_to_string(incomplete.join("precious")).unwrap(),
        "keep"
    );
    assert!(!incomplete.join(".git").exists());
}

#[test]
fn linked_worktrees_and_broken_symlinks_are_refused() {
    let (remote, _) = remote_tracker();
    let root = disposable_dir();
    let clone = root.path().join("clone-test-repo");
    provision_test(root.path(), &clone, remote.path()).unwrap();
    let linked = root.path().join("linked-test-repo");
    assert_disposable(&clone);
    assert_disposable(root.path());
    Repo::open(&clone)
        .unwrap()
        .read(&["worktree", "add", "--detach", linked.to_str().unwrap()])
        .unwrap();
    assert_disposable(&linked);
    assert!(linked.join(".git").is_file());
    assert!(provision_test(root.path(), &linked, remote.path()).is_err());
    let broken = root.path().join("broken-test-repo");
    std::os::unix::fs::symlink(root.path().join("missing-test-repo"), &broken).unwrap();
    assert!(provision_test(root.path(), &broken, remote.path()).is_err());
    assert!(std::fs::symlink_metadata(&broken).unwrap().is_symlink());
}

#[test]
fn failed_clone_does_not_replace_existing_storage() {
    let not_remote = disposable_dir();
    let root = disposable_dir();
    let dir = root.path().join("clone-test-repo");
    assert_eq!(
        provision_test(root.path(), &dir, not_remote.path())
            .unwrap_err()
            .code(),
        "git"
    );
    // A later retry must refuse any leftover directory rather than repair it.
    if !dir.exists() {
        std::fs::create_dir(&dir).unwrap();
    }
    assert_disposable(&dir);
    std::fs::write(dir.join("precious"), "keep").unwrap();
    assert_eq!(
        provision_test(root.path(), &dir, not_remote.path())
            .unwrap_err()
            .code(),
        "invalid-argument"
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("precious")).unwrap(),
        "keep"
    );
}

#[test]
fn nested_repository_is_not_a_standalone_clone() {
    let (remote, _) = remote_tracker();
    let root = disposable_dir();
    new_tracker(&root);
    let dir = root.path().join("nested-test-repo");
    std::fs::create_dir(&dir).unwrap();
    assert_disposable(&dir);
    std::fs::write(dir.join("zwanenzang.toml"), "").unwrap();
    std::fs::create_dir(dir.join(".git")).unwrap();
    assert!(provision_test(root.path(), &dir, remote.path()).is_err());
}
