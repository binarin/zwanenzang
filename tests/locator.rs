mod common;

use common::*;
use sha2::{Digest, Sha256};
use std::path::Path;
use std::process::Command;

// Exercise the real URL resolver without creating unmarked test repositories:
// the computed slot points to an independently marked disposable clone.
fn slot(data: &Path, url: &str, clone: &Path) {
    assert_disposable(data);
    assert_disposable(clone);
    let root = data.join("zwanenzang/trackers");
    std::fs::create_dir_all(&root).unwrap();
    std::os::unix::fs::symlink(
        clone,
        root.join(format!("{:x}", Sha256::digest(url.as_bytes()))),
    )
    .unwrap();
}

fn invoke(
    project: &Path,
    data: &Path,
    clones: &[&Path],
    args: &[&str],
) -> (i32, serde_json::Value) {
    assert_opens_disposable(project);
    assert_disposable(data);
    for clone in clones {
        assert_opens_disposable(clone);
    }
    let out = Command::new(env!("CARGO_BIN_EXE_zwanenzang"))
        .current_dir(project)
        .env("XDG_DATA_HOME", data)
        .env("HOME", data)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .args(args)
        .output()
        .unwrap();
    (
        out.status.code().unwrap(),
        serde_json::from_slice(&out.stdout).unwrap_or(serde_json::Value::Null),
    )
}

#[test]
fn project_local_config_explicit_overrides_and_tracker_precedence() {
    let project = disposable_dir();
    git(project.path(), &["init"]);
    let one = tracker();
    let two = tracker();
    ok(one.path(), &["create", "One"]);
    ok(two.path(), &["create", "Two"]);
    let url_one = "https://example.invalid/one";
    let url_two = "https://example.invalid/two";
    git(one.path(), &["remote", "add", "origin", url_one]);
    git(two.path(), &["remote", "add", "origin", url_two]);
    let data = disposable_dir();
    slot(data.path(), url_one, one.path());
    slot(data.path(), url_two, two.path());
    git(
        project.path(),
        &["config", "--local", "zwanenzang.trackerUrl", url_one],
    );
    let clones = [one.path(), two.path()];
    let run = |cwd, args: &[&str]| invoke(cwd, data.path(), &clones, args);
    let (code, list) = run(project.path(), &["list"]);
    assert_eq!(code, 0, "{list}");
    assert_eq!(list["tickets"][0]["title"], "One");
    let (code, list) = run(project.path(), &["--tracker-url", url_two, "list"]);
    assert_eq!(code, 0, "{list}");
    assert_eq!(list["tickets"][0]["title"], "Two");
    let (code, list) = run(
        project.path(),
        &["-C", two.path().to_str().unwrap(), "list"],
    );
    assert_eq!(code, 0, "{list}");
    assert_eq!(list["tickets"][0]["title"], "Two");
    // A tracker is used directly, even if its git config points elsewhere.
    git(
        one.path(),
        &["config", "--local", "zwanenzang.trackerUrl", url_two],
    );
    assert_eq!(run(one.path(), &["list"]).1["tickets"][0]["title"], "One");
    // Read-only calls do not sync (these origins cannot be reached).
    assert_eq!(logs(one.path()).len(), 1);
    // Discovery also works below the code repository root.
    let nested = project.path().join("nested-test-repo");
    std::fs::create_dir(&nested).unwrap();
    assert_eq!(run(&nested, &["list"]).1["tickets"][0]["title"], "One");
    // Multiple local values are ambiguous, not a silent last-value choice.
    git(
        project.path(),
        &[
            "config",
            "--local",
            "--add",
            "zwanenzang.trackerUrl",
            url_two,
        ],
    );
    assert_eq!(
        run(project.path(), &["list"]).1["error"]["code"],
        "invalid-argument"
    );
    // Explicit paths never fall back to project URL discovery.
    assert_eq!(
        run(
            project.path(),
            &["-C", project.path().to_str().unwrap(), "list"]
        )
        .1["error"]["code"],
        "not-a-tracker"
    );
}

#[test]
fn invalid_selection_is_refused_without_touching_storage() {
    let project = disposable_dir();
    let data = disposable_dir();
    let run = |args: &[&str]| invoke(project.path(), data.path(), &[], args);
    assert_eq!(run(&["list"]).1["error"]["code"], "not-a-tracker");
    for url in ["", "relative/path", "-option"] {
        assert_eq!(
            run(&[&format!("--tracker-url={url}"), "list"]).1["error"]["code"],
            "invalid-argument"
        );
    }
    assert_eq!(
        run(&[
            "--tracker-url",
            "https://example.invalid/new",
            "init",
            "--prefix",
            "ZZ"
        ])
        .1["error"]["code"],
        "invalid-argument"
    );
    assert!(!data.path().join("zwanenzang").exists());
    assert_eq!(
        run(&[
            "-C",
            project.path().to_str().unwrap(),
            "--tracker-url",
            "https://example.invalid/new",
            "list"
        ])
        .0,
        2
    );
}
