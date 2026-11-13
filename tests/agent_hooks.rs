//! `agent-hooks`: plain-text instructions served from the executable, and the
//! bootstrap that names the selected tracker's prefix.

mod common;

use common::*;
use sha2::{Digest, Sha256};
use std::path::Path;
use std::process::Command;

struct Text {
    code: i32,
    stdout: String,
    stderr: String,
}

/// Runs the binary in `cwd` with `home` as its only data location, no
/// network-reachable origin and no git configuration beyond the repository's.
fn hooks(cwd: &Path, home: &Path, args: &[&str]) -> Text {
    assert_opens_disposable(cwd);
    assert_disposable(home);
    let out = Command::new(env!("CARGO_BIN_EXE_zwanenzang"))
        .current_dir(cwd)
        .env("HOME", home)
        .env("XDG_DATA_HOME", home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .args(args)
        .output()
        .unwrap();
    Text {
        code: out.status.code().unwrap(),
        stdout: String::from_utf8(out.stdout).unwrap(),
        stderr: String::from_utf8(out.stderr).unwrap(),
    }
}

fn entries(dir: &Path) -> Vec<String> {
    assert_disposable(dir);
    let mut v: Vec<String> = walk(dir);
    v.sort();
    v
}

fn walk(dir: &Path) -> Vec<String> {
    let mut v = Vec::new();
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        v.push(p.display().to_string());
        if p.is_dir() && !p.is_symlink() {
            v.extend(walk(&p));
        }
    }
    v
}

#[test]
fn show_document_needs_no_tracker_git_or_storage() {
    let cwd = disposable_dir();
    let home = disposable_dir();
    let before = entries(cwd.path());
    for (name, heading) in [
        ("overview", "# Using a zwanenzang tracker\n"),
        ("tickets", "# Tickets\n"),
        ("tickets/reading", "# Reading tickets\n"),
        (
            "tickets/conflicts/stale-doc-base",
            "# Refused document write: stale-doc-base\n",
        ),
        ("cli-json", "# CLI JSON contract\n"),
    ] {
        let o = hooks(
            cwd.path(),
            home.path(),
            &["agent-hooks", "show-document", name],
        );
        assert_eq!(o.code, 0, "{name}: {}", o.stderr);
        assert!(o.stdout.starts_with(heading), "{name}: {}", o.stdout);
        assert!(o.stderr.is_empty());
    }
    // Selection flags are ignored, so an unreachable URL is never cloned.
    let o = hooks(
        cwd.path(),
        home.path(),
        &[
            "--tracker-url",
            "https://example.invalid/tracker",
            "agent-hooks",
            "show-document",
            "overview",
        ],
    );
    assert_eq!(o.code, 0, "{}", o.stderr);
    assert_eq!(entries(cwd.path()), before);
    assert!(entries(home.path()).is_empty());
}

#[test]
fn unknown_documents_fail_with_nearby_topics() {
    let cwd = disposable_dir();
    let home = disposable_dir();
    let show = |name: &str| {
        hooks(
            cwd.path(),
            home.path(),
            &["agent-hooks", "show-document", name],
        )
    };
    let o = show("tickets/conflicts/missing");
    assert_eq!(o.code, 1);
    assert!(o.stdout.is_empty());
    assert!(
        o.stderr
            .contains("zz agent-hooks show-document tickets/conflicts/unpublished\n"),
        "{}",
        o.stderr
    );
    assert!(!o.stderr.contains("tickets/reading"), "{}", o.stderr);
    for name in [
        "missing",
        "../Cargo.toml",
        "/etc/passwd",
        "tickets/overview",
        "overview.md",
    ] {
        let o = show(name);
        assert_eq!(o.code, 1, "{name}");
        assert!(o.stdout.is_empty(), "{name}");
        assert!(!o.stderr.contains("root:"), "{name}");
    }
    let o = show("missing");
    assert!(o.stderr.contains("zz agent-hooks show-document tickets\n"));
    assert!(!o.stderr.contains("tickets/"), "{}", o.stderr);
}

#[test]
fn init_prints_the_prefix_bootstrap_and_writes_nothing() {
    let t = disposable_dir();
    ok(t.path(), &["init", "--prefix", "QX", "--name", "Test"]);
    ok(t.path(), &["create", "One"]);
    let home = disposable_dir();
    let logs_before = logs(t.path());
    let head = git(t.path(), &["rev-parse", "HEAD"]);
    let o = hooks(
        t.path(),
        home.path(),
        &["-C", t.path().to_str().unwrap(), "agent-hooks", "init"],
    );
    assert_eq!(o.code, 0, "{}", o.stderr);
    assert!(o.stderr.is_empty());
    assert!(o.stdout.contains("`QX-0042`"), "{}", o.stdout);
    assert!(o.stdout.contains("`qx-42`"), "{}", o.stdout);
    assert!(o.stdout.contains("`zz agent-hooks show-document overview`"));
    assert!(!o.stdout.contains('/'), "{}", o.stdout);
    assert!(!o.stdout.contains("# Using"), "not the overview itself");
    assert_eq!(logs(t.path()), logs_before);
    assert_eq!(git(t.path(), &["rev-parse", "HEAD"]), head);
    assert!(git(t.path(), &["status", "--porcelain"]).is_empty());
    assert!(entries(home.path()).is_empty());
    // The enclosing tracker is found without -C as well.
    let o2 = hooks(t.path(), home.path(), &["agent-hooks", "init"]);
    assert_eq!(o2.stdout, o.stdout);
}

#[test]
fn init_follows_url_selection() {
    let t = disposable_dir();
    ok(t.path(), &["init", "--prefix", "UR", "--name", "Test"]);
    let url = "https://example.invalid/url-tracker";
    git(t.path(), &["remote", "add", "origin", url]);
    // The URL's storage slot is a link to the marked clone, so the real
    // resolver runs without creating unmarked repositories.
    let home = disposable_dir();
    let slots = home.path().join("zwanenzang/trackers");
    std::fs::create_dir_all(&slots).unwrap();
    std::os::unix::fs::symlink(
        t.path(),
        slots.join(format!("{:x}", Sha256::digest(url.as_bytes()))),
    )
    .unwrap();
    let project = disposable_dir();
    git(project.path(), &["init"]);
    git(
        project.path(),
        &["config", "--local", "zwanenzang.trackerUrl", url],
    );
    let head = git(t.path(), &["rev-parse", "HEAD"]);
    for args in [
        &["agent-hooks", "init"][..],
        &["--tracker-url", url, "agent-hooks", "init"][..],
    ] {
        let o = hooks(project.path(), home.path(), args);
        assert_eq!(o.code, 0, "{args:?}: {}", o.stderr);
        assert!(o.stdout.contains("`UR-0042`"), "{}", o.stdout);
    }
    assert_eq!(git(t.path(), &["rev-parse", "HEAD"]), head);
    // Conflicting selectors are a usage error, as for every command.
    let o = hooks(
        project.path(),
        home.path(),
        &[
            "-C",
            t.path().to_str().unwrap(),
            "--tracker-url",
            url,
            "agent-hooks",
            "init",
        ],
    );
    assert_eq!(o.code, 2);
    assert!(o.stdout.is_empty());
}

#[test]
fn init_without_a_usable_tracker_prints_no_bootstrap() {
    let cwd = disposable_dir();
    let home = disposable_dir();
    let o = hooks(cwd.path(), home.path(), &["agent-hooks", "init"]);
    assert_eq!(o.code, 1);
    assert!(o.stdout.is_empty(), "{}", o.stdout);
    assert!(o.stderr.contains("not-a-tracker"), "{}", o.stderr);

    let broken = disposable_dir();
    write_file(broken.path(), "zwanenzang.toml", "name = \"x\"\n");
    let o = hooks(broken.path(), home.path(), &["agent-hooks", "init"]);
    assert_eq!(o.code, 1);
    assert!(o.stdout.is_empty(), "{}", o.stdout);
    assert!(o.stderr.contains("(config)"), "{}", o.stderr);

    // A clone that cannot be provisioned fails without inventing a prefix.
    let missing = cwd.path().join("absent-test-repo");
    let o = hooks(
        cwd.path(),
        home.path(),
        &[
            "--tracker-url",
            missing.to_str().unwrap(),
            "agent-hooks",
            "init",
        ],
    );
    assert_eq!(o.code, 1);
    assert!(o.stdout.is_empty(), "{}", o.stdout);
    assert!(o.stderr.contains("(git)"), "{}", o.stderr);
    assert!(!missing.exists());
}
