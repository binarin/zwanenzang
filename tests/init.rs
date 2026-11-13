//! `zz init`: remote-backed creation and publication of a tracker, driven
//! through the CLI against disposable bare remotes.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use common::*;
use serde_json::Value;
use sha2::{Digest, Sha256};

struct Net {
    dir: tempfile::TempDir,
}

impl Net {
    /// A bare remote, with its advertised default branch `main`.
    fn new() -> Net {
        let dir = disposable_dir();
        git(
            dir.path(),
            &[
                "init",
                "--quiet",
                "--bare",
                "-b",
                "main",
                "remote-test-repo",
            ],
        );
        Net { dir }
    }

    fn remote(&self) -> PathBuf {
        self.dir.path().join("remote-test-repo")
    }

    fn url(&self) -> String {
        self.remote().to_str().unwrap().to_string()
    }

    /// The locator for the remote, with an optional `?ref=` selector.
    fn locator(&self, selector: Option<&str>) -> String {
        match selector {
            None => self.url(),
            Some(branch) => format!("{}?ref={branch}", self.url()),
        }
    }

    /// Initializes a tracker at `<name>-test-repo` against the remote.
    fn init(&self, name: &str, selector: Option<&str>) -> Out {
        let dest = self.dir.path().join(format!("{name}-test-repo"));
        self.init_at(&dest, selector)
    }

    fn init_at(&self, dest: &Path, selector: Option<&str>) -> Out {
        run_in(
            self.dir.path(),
            &[
                "init",
                dest.to_str().unwrap(),
                "--remote",
                &self.locator(selector),
                "--prefix",
                "ZZ",
                "--name",
                "Test",
            ],
            "",
        )
    }

    /// Pushes an unrelated commit to the remote's default branch, so the
    /// remote is populated with project history init must not inherit.
    fn populate(&self) {
        git(
            self.dir.path(),
            &["init", "--quiet", "-b", "main", "seed-test-repo"],
        );
        let seed = self.dir.path().join("seed-test-repo");
        write_file(&seed, "README.md", "project\n");
        git(&seed, &["add", "."]);
        git(&seed, &["commit", "--quiet", "-m", "project history"]);
        git(
            &seed,
            &["push", "--quiet", self.remote().to_str().unwrap(), "main"],
        );
    }

    /// The refs of the bare remote, one `name commit` per line.
    fn refs(&self) -> String {
        git(
            &self.remote(),
            &["for-each-ref", "--format=%(refname) %(objectname)"],
        )
    }
}

fn out_json(o: &Out) -> &Value {
    assert_eq!(o.code, 0, "{}\n{}", o.json, o.stderr);
    &o.json
}

#[test]
fn init_publishes_an_empty_remote_on_the_configured_initial_branch() {
    let net = Net::new();
    // The remote advertises nothing; no selector means git's configured
    // initial branch, and the caller's git configuration decides it.
    let made = net.init("empty", None);
    let out = out_json(&made);
    assert_eq!(out["remote"]["url"], net.url());
    assert_eq!(out["remote"]["branch"], "master");
    assert_eq!(out["sync"]["upstream"], "origin/master");
    assert_eq!(out["sync"]["pushed"], true);
    assert_eq!(out["tracker"]["prefix"], "ZZ");
    let empty = net.dir.path().join("empty-test-repo");
    assert_eq!(
        git(&empty, &["symbolic-ref", "HEAD"]).trim(),
        "refs/heads/master"
    );
    assert_eq!(
        git(&net.remote(), &["for-each-ref", "--format=%(refname)"]).trim(),
        "refs/heads/master"
    );

    // With init.defaultBranch configured, that branch is created instead,
    // and the tracker name defaults to the directory name. A fresh
    // remote: the one above is no longer empty.
    let net = Net::new();
    let dest = net.dir.path().join("trunk-test-repo");
    let out = run_in_env(
        net.dir.path(),
        &[
            "init",
            dest.to_str().unwrap(),
            "--remote",
            &net.locator(None),
            "--prefix",
            "ZZ",
        ],
        "",
        &[
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", "init.defaultBranch"),
            ("GIT_CONFIG_VALUE_0", "trunk"),
        ],
    );
    assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);
    assert_eq!(out.json["remote"]["branch"], "trunk");
    assert_eq!(out.json["tracker"]["name"], "trunk-test-repo");
    assert_eq!(
        git(&net.remote(), &["for-each-ref", "--format=%(refname)"]),
        "refs/heads/trunk\n"
    );
}

#[test]
fn init_with_a_selector_creates_independent_history_on_a_populated_remote() {
    let net = Net::new();
    net.populate();
    let main_before = net.refs();
    let made = net.init("tickets", Some("tickets"));
    let out = out_json(&made);
    assert_eq!(out["remote"]["branch"], "tickets");
    assert_eq!(out["sync"]["upstream"], "origin/tickets");
    let dest = net.dir.path().join("tickets-test-repo");
    // Independent history: one commit, unrelated to the project's.
    assert_eq!(git(&dest, &["rev-list", "--count", "HEAD"]).trim(), "1");
    assert_eq!(git(&dest, &["log", "--format=%s"]), "init\n");
    // The remote's existing history and advertised default are untouched.
    let mut refs = net.refs();
    refs.truncate(main_before.len());
    assert_eq!(refs, main_before);
    assert_eq!(
        git(&net.remote(), &["symbolic-ref", "HEAD"]).trim(),
        "refs/heads/main"
    );
    assert!(net.refs().contains("refs/heads/tickets"));
    // The tracker works: a ticket is created and published on the branch.
    let made = ok(&dest, &["create", "After init"]);
    assert_eq!(made["sync"]["pushed"], true, "{made}");
    assert_eq!(made["ticket"]["display"], "ZZ-0001");
}

#[test]
fn init_refuses_an_existing_branch_without_touching_the_destination() {
    let net = Net::new();
    net.populate();
    let dest = net.dir.path().join("main-test-repo");
    let e = err(
        net.dir.path(),
        &[
            "init",
            dest.to_str().unwrap(),
            "--remote",
            &net.locator(Some("main")),
            "--prefix",
            "ZZ",
        ],
        "branch-exists",
    );
    assert!(e["error"]["message"].as_str().unwrap().contains("main"));
    assert!(!dest.exists(), "a refused init creates nothing");

    // Without a selector, the populated remote's default branch exists.
    let e = net.init("any", None);
    assert_eq!(e.code, 1, "{}", e.json);
    assert_eq!(e.json["error"]["code"], "branch-exists");
    assert!(!net.dir.path().join("any-test-repo").exists());
}

#[test]
fn init_loses_a_concurrent_publication_race_without_forcing() {
    for _ in 0..5 {
        let net = Net::new();
        let a = net.dir.path().join("a-test-repo");
        let b = net.dir.path().join("b-test-repo");
        let (oa, ob) = std::thread::scope(|s| {
            let ha = s.spawn(|| net.init_at(&a, Some("tickets")));
            let hb = s.spawn(|| net.init_at(&b, Some("tickets")));
            (ha.join().unwrap(), hb.join().unwrap())
        });
        let outs = [&oa, &ob];
        let winners: Vec<&&Out> = outs.iter().filter(|o| o.code == 0).collect();
        assert_eq!(winners.len(), 1, "exactly one init succeeds");
        let losers: Vec<&&Out> = outs.iter().filter(|o| o.code != 0).collect();
        assert_eq!(losers.len(), 1);
        assert_eq!(losers[0].json["error"]["code"], "branch-exists");
        // Exactly one branch on the remote, never force-updated.
        assert_eq!(
            git(&net.remote(), &["for-each-ref", "--format=%(refname)"]),
            "refs/heads/tickets\n"
        );
        assert_eq!(
            git(
                &net.remote(),
                &["rev-list", "--count", "refs/heads/tickets"]
            )
            .trim(),
            "1"
        );
    }
}

#[test]
fn init_push_failure_keeps_the_tracker_and_names_the_retry() {
    let net = Net::new();
    // A receiving hook that declines everything: the remote is readable,
    // but no push lands.
    write_file(
        &net.remote(),
        "hooks/pre-receive",
        "#!/bin/sh\necho declined >&2\nexit 1\n",
    );
    std::fs::set_permissions(
        net.remote().join("hooks/pre-receive"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let dest = net.dir.path().join("kept-test-repo");
    let e = err(
        net.dir.path(),
        &[
            "init",
            dest.to_str().unwrap(),
            "--remote",
            &net.locator(Some("main")),
            "--prefix",
            "ZZ",
        ],
        "push-failed",
    );
    let message = e["error"]["message"].as_str().unwrap();
    assert!(
        message.contains(&format!(
            "git -C {} push origin HEAD:refs/heads/main",
            dest.display()
        )),
        "names the retry push command: {message}"
    );
    // The local checkout and its commit survive; nothing was rolled back.
    assert!(dest.join("zwanenzang.toml").is_file());
    assert_eq!(git(&dest, &["log", "--format=%s"]), "init\n");
    assert_eq!(
        git(&dest, &["config", "--local", "remote.origin.url"]).trim(),
        net.url()
    );
    assert_eq!(
        git(&dest, &["config", "--local", "branch.main.merge"]).trim(),
        "refs/heads/main"
    );
    assert_eq!(
        git(&net.remote(), &["for-each-ref", "--format=%(refname)"]),
        ""
    );
    // The named retry publishes the kept tracker.
    std::fs::remove_file(net.remote().join("hooks/pre-receive")).unwrap();
    let sync = ok(&dest, &["sync"]);
    assert_eq!(sync["sync"]["pushed"], true, "{sync}");
    assert_eq!(
        git(&net.remote(), &["for-each-ref", "--format=%(refname)"]),
        "refs/heads/main\n"
    );
}

#[test]
fn init_refuses_unusable_destinations_and_locators() {
    let net = Net::new();
    let root = net.dir.path();
    // A destination holding anything, even only a dotfile, is refused.
    for setup in ["file", "dir"] {
        let dest = root.join(format!("{setup}-test-repo"));
        match setup {
            "file" => std::fs::write(&dest, "x").unwrap(),
            _ => {
                std::fs::create_dir(&dest).unwrap();
                std::fs::write(dest.join(".hidden"), "x").unwrap();
            }
        }
        err(
            root,
            &[
                "init",
                dest.to_str().unwrap(),
                "--remote",
                &net.locator(None),
                "--prefix",
                "ZZ",
            ],
            "invalid-argument",
        );
        if setup == "dir" {
            assert!(dest.join(".hidden").exists(), "untouched");
        }
    }
    // An empty directory is accepted, as is a nested missing path.
    let empty = root.join("empty-test-repo");
    std::fs::create_dir(&empty).unwrap();
    assert_eq!(net.init_at(&empty, Some("main")).code, 0);
    let nested = root.join("nested-test-repo/deeper");
    let out = net.init_at(&nested, Some("tickets"));
    assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);

    // Locator and selector validation.
    for locator in [
        "relative/path",
        "https://example.invalid/x?rev=tickets",
        "https://example.invalid/x?ref=",
        "https://example.invalid/x?ref=refs/heads/main",
        "https://example.invalid/x?ref=refs/tags/v1",
        "https://example.invalid/x?ref=1234567890123456789012345678901234567890",
        "https://example.invalid/x?ref=-dash",
        "https://example.invalid/x?ref=has space",
        "https://example.invalid/x?other=y",
    ] {
        let dest = root.join("refused-test-repo");
        err(
            root,
            &[
                "init",
                dest.to_str().unwrap(),
                "--remote",
                locator,
                "--prefix",
                "ZZ",
            ],
            "invalid-argument",
        );
        assert!(!dest.exists(), "{locator}: nothing created");
    }
    // A remote that does not exist is a fetch failure, before anything
    // is created locally.
    let missing = root.join("missing-remote.git");
    let dest = root.join("unreachable-test-repo");
    err(
        root,
        &[
            "init",
            dest.to_str().unwrap(),
            "--remote",
            missing.to_str().unwrap(),
            "--prefix",
            "ZZ",
        ],
        "fetch-failed",
    );
    assert!(!dest.exists());
    // init does not provision URL-selected storage. Without -C, since the
    // harness always passes one and the two selectors conflict there.
    let usage = Command::new(env!("CARGO_BIN_EXE_zwanenzang"))
        .current_dir(root)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args([
            "--tracker-url",
            &net.locator(Some("main")),
            "init",
            dest.to_str().unwrap(),
            "--remote",
            &net.locator(Some("main")),
            "--prefix",
            "ZZ",
        ])
        .output()
        .unwrap();
    assert_eq!(usage.status.code(), Some(1));
    let json: Value = serde_json::from_slice(&usage.stdout).unwrap();
    assert_eq!(json["error"]["code"], "invalid-argument");
    assert!(!dest.exists());
    // Required arguments are usage errors.
    let usage = Command::new(env!("CARGO_BIN_EXE_zwanenzang"))
        .current_dir(root)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(["init", root.join("nope-test-repo").to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(usage.status.code(), Some(2));
    assert!(!root.join("nope-test-repo").exists());
}

#[test]
fn init_refuses_destinations_inside_trackers_and_work_trees() {
    let net = Net::new();
    assert_eq!(net.init("a", Some("main")).code, 0);
    let a = net.dir.path().join("a-test-repo");
    let inner = a.join("nested-test-repo");
    std::fs::create_dir(&inner).unwrap();
    err(
        &inner,
        &[
            "init",
            inner.to_str().unwrap(),
            "--remote",
            &net.locator(Some("tickets")),
            "--prefix",
            "QQ",
        ],
        "already-initialized",
    );
    git(net.dir.path(), &["init", "--quiet", "code-test-repo"]);
    let code = net.dir.path().join("code-test-repo");
    git(&code, &["commit", "--quiet", "--allow-empty", "-m", "code"]);
    let sub = code.join("sub-test-repo");
    std::fs::create_dir(&sub).unwrap();
    err(
        &sub,
        &[
            "init",
            sub.to_str().unwrap(),
            "--remote",
            &net.locator(Some("tickets")),
            "--prefix",
            "QQ",
        ],
        "inside-repository",
    );
    assert!(!sub.join("zwanenzang.toml").exists());
}

#[test]
fn init_commits_the_bootstrap_as_agents_md() {
    let net = Net::new();
    let made = net.init("agents", Some("main"));
    let out = out_json(&made);
    assert_eq!(out["tracker"]["prefix"], "ZZ");
    let dest = net.dir.path().join("agents-test-repo");
    let agents = read(&dest, "AGENTS.md");
    assert!(
        agents.contains("zz agent-hooks show-document overview"),
        "{agents}"
    );
    assert!(agents.contains("`ZZ-0042`"), "{agents}");
    assert!(agents.contains("`zz-42`"), "{agents}");
    assert!(agents.starts_with("# Agent instructions"), "{agents}");
    let files = git(&dest, &["ls-files"]);
    for name in [".gitattributes", "AGENTS.md", "zwanenzang.toml"] {
        assert!(files.lines().any(|f| f == name), "{files}");
    }
    assert_eq!(git(&dest, &["status", "--porcelain"]), "");
}

#[test]
fn two_branches_of_one_remote_are_separate_trackers_with_separate_storage() {
    let net = Net::new();
    let tickets = net.dir.path().join("tickets-test-repo");
    assert_eq!(net.init_at(&tickets, Some("tickets")).code, 0);
    ok(&tickets, &["create", "On tickets"]);
    let dev = net.dir.path().join("dev-test-repo");
    assert_eq!(net.init_at(&dev, Some("dev")).code, 0);
    ok(&dev, &["create", "On dev"]);

    // A project selecting each branch provisions one clone per locator and
    // sees only that branch's tracker.
    let project = disposable_dir();
    git(project.path(), &["init", "--quiet"]);
    let data = disposable_dir();
    let run = |locator: &str, args: &[&str]| invoke(project.path(), data.path(), locator, args);
    let tickets_list = run(&net.locator(Some("tickets")), &["list"]);
    assert_eq!(tickets_list.0, 0, "{}", tickets_list.1);
    assert_eq!(tickets_list.1["tickets"][0]["title"], "On tickets");
    let dev_list = run(&net.locator(Some("dev")), &["list"]);
    assert_eq!(dev_list.1["tickets"][0]["title"], "On dev");
    // Separate storage slots: one per locator spelling.
    let slots = std::fs::read_dir(data.path().join("zwanenzang/trackers")).unwrap();
    assert_eq!(slots.count(), 2);
}

#[test]
fn unqualified_locator_clones_the_remote_default_branch_as_before() {
    let net = Net::new();
    // A tracker on the remote's advertised default branch `main`.
    assert_eq!(net.init("tracker", Some("main")).code, 0);
    let t = net.dir.path().join("tracker-test-repo");
    ok(&t, &["create", "Default branch ticket"]);

    let project = disposable_dir();
    git(project.path(), &["init", "--quiet"]);
    let data = disposable_dir();
    let (code, list) = invoke(project.path(), data.path(), &net.locator(None), &["list"]);
    assert_eq!(code, 0, "{list}");
    assert_eq!(list["tickets"][0]["title"], "Default branch ticket");
    // The same storage a locator without a selector always used: keyed by
    // the plain URL bytes.
    let key = format!("{:x}", Sha256::digest(net.url().as_bytes()));
    assert!(data.path().join("zwanenzang/trackers").join(key).is_dir());
}

/// Runs the binary from `project` with `data` as its data home, selecting
/// the tracker by `locator`.
fn invoke(project: &Path, data: &Path, locator: &str, args: &[&str]) -> (i32, Value) {
    assert_opens_disposable(project);
    assert_disposable(data);
    let out = Command::new(env!("CARGO_BIN_EXE_zwanenzang"))
        .current_dir(project)
        .env("XDG_DATA_HOME", data)
        .env("HOME", data)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .arg("--tracker-url")
        .arg(locator)
        .args(args)
        .output()
        .unwrap();
    (
        out.status.code().unwrap(),
        serde_json::from_slice(&out.stdout).unwrap_or(Value::Null),
    )
}
