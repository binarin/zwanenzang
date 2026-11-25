//! `zwanenzang.useGitIdentity`: with the switch on, every commit the tool
//! makes is authored and committed as git's own user instead of the
//! writer. Driven through the CLI against a disposable bare remote; the
//! git user comes from local or command-scope configuration, never the
//! developer's.

mod common;

use std::path::{Path, PathBuf};

use common::*;

const ADA: &str = "Ada Example <ada@example.org>";

/// Command-scope configuration giving git a user.
const GIT_USER: &[(&str, &str)] = &[
    ("GIT_CONFIG_COUNT", "2"),
    ("GIT_CONFIG_KEY_0", "user.name"),
    ("GIT_CONFIG_VALUE_0", "Ada Example"),
    ("GIT_CONFIG_KEY_1", "user.email"),
    ("GIT_CONFIG_VALUE_1", "ada@example.org"),
];

/// Command-scope configuration turning the switch on and giving git a user.
const SWITCH_AND_GIT_USER: &[(&str, &str)] = &[
    ("GIT_CONFIG_COUNT", "3"),
    ("GIT_CONFIG_KEY_0", "user.name"),
    ("GIT_CONFIG_VALUE_0", "Ada Example"),
    ("GIT_CONFIG_KEY_1", "user.email"),
    ("GIT_CONFIG_VALUE_1", "ada@example.org"),
    ("GIT_CONFIG_KEY_2", "zwanenzang.useGitIdentity"),
    ("GIT_CONFIG_VALUE_2", "true"),
];

/// Command-scope configuration leaving git without an identity: no user,
/// and no guessing one from the host.
const NO_GIT_USER: &[(&str, &str)] = &[
    ("GIT_CONFIG_COUNT", "1"),
    ("GIT_CONFIG_KEY_0", "user.useConfigOnly"),
    ("GIT_CONFIG_VALUE_0", "true"),
];

struct Net {
    dir: tempfile::TempDir,
}

impl Net {
    /// A bare remote with its default branch `main`, and nothing else.
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

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(format!("{name}-test-repo"))
    }

    /// Runs `init` for `<name>-test-repo` with `extra` arguments.
    fn init(&self, name: &str, extra: &[&str], env: &[(&str, &str)]) -> Out {
        let dest = self.path(name);
        let locator = format!("{}?ref=main", self.remote().to_str().unwrap());
        let mut args = vec![
            "init",
            dest.to_str().unwrap(),
            "--remote",
            &locator,
            "--prefix",
            "ZZ",
            "--name",
            "Test",
        ];
        args.extend(extra);
        run_in_env(self.dir.path(), &args, "", env)
    }

    /// A tracker clone at `<name>-test-repo`, published by `init`.
    fn tracker(&self, name: &str) -> PathBuf {
        let out = self.init(name, &[], &[]);
        assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);
        self.path(name)
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

    /// Points `clone`'s origin somewhere that does not exist, or back.
    fn offline(&self, clone: &Path, off: bool) {
        let url = if off {
            self.dir.path().join("gone-test-repo")
        } else {
            self.remote()
        };
        git(
            clone,
            &[
                "config",
                "--local",
                "remote.origin.url",
                url.to_str().unwrap(),
            ],
        );
    }

    /// The branches the remote has.
    fn remote_refs(&self) -> String {
        git(&self.remote(), &["for-each-ref", "--format=%(refname)"])
    }
}

/// `operation | author | committer` of every commit, oldest first; the
/// operation is the first word of the subject.
fn idents(dir: &Path) -> Vec<String> {
    git(
        dir,
        &["log", "--reverse", "--format=%s | %an <%ae> | %cn <%ce>"],
    )
    .lines()
    .map(|l| {
        let (subject, idents) = l.split_once(" | ").unwrap();
        format!("{} | {idents}", subject.split(' ').next().unwrap())
    })
    .collect()
}

/// The commit identity of a writer under its identity `tester`.
fn writer(dir: &Path) -> String {
    format!("{TESTER} <{}@zwanenzang.invalid>", actor_of(dir))
}

fn run_ok(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> serde_json::Value {
    let out = run_in_env(dir, args, "", env);
    assert_eq!(out.code, 0, "{args:?}: {}\n{}", out.json, out.stderr);
    out.json
}

fn run_err(dir: &Path, args: &[&str], env: &[(&str, &str)], code: &str) -> String {
    let out = run_in_env(dir, args, "", env);
    assert_eq!(out.code, 1, "{args:?} should fail: {}", out.json);
    assert_eq!(out.json["error"]["code"], code, "{args:?}: {}", out.json);
    out.json["error"]["message"].as_str().unwrap().to_string()
}

/// Everything a refused command must not have changed.
fn snapshot(dir: &Path) -> (String, String, Vec<(String, Vec<u8>)>) {
    (
        git(dir, &["rev-parse", "HEAD"]),
        git(dir, &["status", "--porcelain", "--untracked-files=all"]),
        // A fresh clone of a tracker without events has no events/ yet.
        if dir.join("events").exists() {
            logs(dir)
        } else {
            Vec::new()
        },
    )
}

#[test]
fn switch_off_commits_as_the_writer_despite_a_git_user() {
    let net = Net::new();
    let a = net.tracker("a");
    git(&a, &["config", "--local", "user.name", "Ada Example"]);
    git(&a, &["config", "--local", "user.email", "ada@example.org"]);
    run_ok(&a, &["create", "one"], GIT_USER);
    let me = writer(&a);
    assert_eq!(
        idents(&a),
        [
            format!("init | {me} | {me}"),
            format!("create | {me} | {me}"),
            format!("publish | {me} | {me}"),
        ]
    );
}

#[test]
fn switch_on_locally_covers_writes_numbers_and_rebased_commits() {
    let net = Net::new();
    let a = net.tracker("a");
    let me = writer(&a);
    // A write committed before the switch, still unpublished.
    net.offline(&a, true);
    let out = run_in(&a, &["create", "local"], "");
    assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);
    assert_eq!(out.json["sync"]["error"]["code"], "fetch-failed");
    net.offline(&a, false);
    // Another clone publishes meanwhile, so a's write must be rebased.
    let b = net.clone_as("b");
    run_ok(&b, &["create", "remote"], &[]);
    let other = writer(&b);

    git(
        &a,
        &["config", "--local", "zwanenzang.useGitIdentity", "true"],
    );
    git(&a, &["config", "--local", "user.name", "Ada Example"]);
    git(&a, &["config", "--local", "user.email", "ada@example.org"]);
    let out = run_ok(&a, &["sync"], &[]);
    assert_eq!(out["sync"]["pushed"], true, "{out}");
    run_ok(&a, &["create", "after"], &[]);

    assert_eq!(
        idents(&a),
        [
            format!("init | {me} | {me}"),
            format!("create | {other} | {other}"),
            format!("publish | {other} | {other}"),
            // Replayed by the rebase: its author kept, its committer git's.
            format!("create | {me} | {ADA}"),
            format!("publish | {ADA} | {ADA}"),
            format!("create | {ADA} | {ADA}"),
            format!("publish | {ADA} | {ADA}"),
        ]
    );
}

#[test]
fn switch_on_at_a_non_local_level_applies_too() {
    let net = Net::new();
    let a = net.tracker("a");
    run_ok(&a, &["create", "one"], SWITCH_AND_GIT_USER);
    let me = writer(&a);
    assert_eq!(
        idents(&a),
        [
            format!("init | {me} | {me}"),
            format!("create | {ADA} | {ADA}"),
            format!("publish | {ADA} | {ADA}"),
        ]
    );
    let local = git(&a, &["config", "--local", "--list"]);
    assert!(!local.contains("usegitidentity"), "{local}");
}

#[test]
fn init_use_git_identity_sets_the_local_switch_before_the_first_commit() {
    let net = Net::new();
    let out = net.init("a", &["--use-git-identity"], GIT_USER);
    assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);
    assert_eq!(out.json["sync"]["pushed"], true, "{}", out.json);
    let a = net.path("a");
    assert_eq!(
        git(
            &a,
            &["config", "--local", "--get", "zwanenzang.useGitIdentity"]
        )
        .trim(),
        "true"
    );
    assert_eq!(idents(&a), [format!("init | {ADA} | {ADA}")]);
    assert_eq!(
        git(
            &net.remote(),
            &["log", "--format=%an <%ae> | %cn <%ce>", "main"]
        )
        .trim(),
        format!("{ADA} | {ADA}")
    );
}

#[test]
fn a_missing_git_identity_refuses_before_writing() {
    let net = Net::new();
    let a = net.tracker("a");
    git(
        &a,
        &["config", "--local", "zwanenzang.useGitIdentity", "true"],
    );
    let before = snapshot(&a);
    for args in [&["create", "one"][..], &["sync"]] {
        let message = run_err(&a, args, NO_GIT_USER, "git-identity-missing");
        for named in ["user.name", "user.email", "zwanenzang.useGitIdentity"] {
            assert!(message.contains(named), "{args:?}: {message}");
        }
        assert_eq!(snapshot(&a), before, "{args:?}");
    }
}

#[test]
fn init_without_a_git_identity_refuses_before_creating_the_directory() {
    let net = Net::new();
    let flag = net.init("flag", &["--use-git-identity"], NO_GIT_USER);
    assert_eq!(flag.code, 1, "{}", flag.json);
    assert_eq!(flag.json["error"]["code"], "git-identity-missing");
    assert!(!net.path("flag").exists());

    let switch = [
        ("GIT_CONFIG_COUNT", "2"),
        ("GIT_CONFIG_KEY_0", "user.useConfigOnly"),
        ("GIT_CONFIG_VALUE_0", "true"),
        ("GIT_CONFIG_KEY_1", "zwanenzang.useGitIdentity"),
        ("GIT_CONFIG_VALUE_1", "true"),
    ];
    let config = net.init("config", &[], &switch);
    assert_eq!(config.code, 1, "{}", config.json);
    assert_eq!(config.json["error"]["code"], "git-identity-missing");
    assert!(!net.path("config").exists());
    assert_eq!(net.remote_refs(), "");
}

#[test]
fn a_bad_boolean_switch_is_an_error() {
    let net = Net::new();
    let a = net.tracker("a");
    git(
        &a,
        &["config", "--local", "zwanenzang.useGitIdentity", "maybe"],
    );
    let before = snapshot(&a);
    let message = run_err(&a, &["create", "one"], GIT_USER, "config");
    assert!(message.contains("zwanenzang.useGitIdentity"), "{message}");
    assert_eq!(snapshot(&a), before);

    let bad = [
        ("GIT_CONFIG_COUNT", "1"),
        ("GIT_CONFIG_KEY_0", "zwanenzang.useGitIdentity"),
        ("GIT_CONFIG_VALUE_0", "maybe"),
    ];
    let out = net.init("b", &[], &bad);
    assert_eq!(out.code, 1, "{}", out.json);
    assert_eq!(out.json["error"]["code"], "config", "{}", out.json);
    assert!(!net.path("b").exists());
}

#[test]
fn a_refusal_on_a_fresh_clone_creates_no_lock_file() {
    let net = Net::new();
    net.tracker("a");
    for (name, args) in [("create", &["create", "one"][..]), ("sync", &["sync"])] {
        let b = net.clone_as(name);
        git(
            &b,
            &["config", "--local", "zwanenzang.useGitIdentity", "true"],
        );
        let lock = b.join(".git/zwanenzang.lock");
        assert!(!lock.exists());
        let before = snapshot(&b);
        run_err(&b, args, NO_GIT_USER, "git-identity-missing");
        assert!(!lock.exists(), "{args:?} created {lock:?}");
        assert_eq!(snapshot(&b), before, "{args:?}");
    }
}

/// Command-scope configuration whose `includeIf` turns the switch on only
/// in the repository at `dest`, with `extra` settings on top.
fn switch_only_in(net: &Net, dest: &Path, extra: &[(&str, &str)]) -> Vec<(String, String)> {
    write_file(
        net.dir.path(),
        "switch.gitconfig",
        "[zwanenzang]\n\tuseGitIdentity = true\n",
    );
    let include = net.dir.path().join("switch.gitconfig");
    let mut settings = vec![
        (
            format!("includeIf.gitdir:{}/.path", dest.display()),
            include.to_str().unwrap().to_string(),
        ),
        ("user.useConfigOnly".into(), "true".into()),
    ];
    settings.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    let mut env = vec![("GIT_CONFIG_COUNT".to_string(), settings.len().to_string())];
    for (i, (k, v)) in settings.into_iter().enumerate() {
        env.push((format!("GIT_CONFIG_KEY_{i}"), k));
        env.push((format!("GIT_CONFIG_VALUE_{i}"), v));
    }
    env
}

fn pairs(env: &[(String, String)]) -> Vec<(&str, &str)> {
    env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect()
}

#[test]
fn init_refused_inside_the_new_clone_leaves_nothing_and_can_be_retried() {
    let net = Net::new();
    let root = std::fs::canonicalize(net.dir.path()).unwrap();

    // A destination that does not exist, under a parent that does not
    // either: both are removed again.
    let parent = root.join("parent-test-repo");
    let dest = parent.join("c-test-repo");
    let env = switch_only_in(&net, &dest, &[]);
    let init = |dest: &Path, env: &[(String, String)]| {
        // Each destination publishes a branch of its own.
        let branch = dest.file_name().unwrap().to_str().unwrap();
        let locator = format!("{}?ref={branch}", net.remote().to_str().unwrap());
        run_in_env(
            &root,
            &[
                "init",
                dest.to_str().unwrap(),
                "--remote",
                &locator,
                "--prefix",
                "ZZ",
                "--name",
                "Test",
            ],
            "",
            &pairs(env),
        )
    };
    let out = init(&dest, &env);
    assert_eq!(out.code, 1, "{}", out.json);
    assert_eq!(
        out.json["error"]["code"], "git-identity-missing",
        "{}",
        out.json
    );
    assert!(!parent.exists(), "{parent:?} is left behind");
    assert_eq!(net.remote_refs(), "");

    let env = switch_only_in(
        &net,
        &dest,
        &[
            ("user.name", "Ada Example"),
            ("user.email", "ada@example.org"),
        ],
    );
    let out = init(&dest, &env);
    assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);
    assert_eq!(out.json["sync"]["pushed"], true, "{}", out.json);
    assert_eq!(idents(&dest), [format!("init | {ADA} | {ADA}")]);

    // A destination that already exists, empty, stays as it was.
    let empty = net.path("empty");
    std::fs::create_dir(&empty).unwrap();
    let out = init(&empty, &switch_only_in(&net, &empty, &[]));
    assert_eq!(out.code, 1, "{}", out.json);
    assert_eq!(
        out.json["error"]["code"], "git-identity-missing",
        "{}",
        out.json
    );
    assert_eq!(std::fs::read_dir(&empty).unwrap().count(), 0);
}

#[test]
fn init_refused_with_dot_dot_in_the_destination_removes_what_it_created() {
    let net = Net::new();
    let root = std::fs::canonicalize(net.dir.path()).unwrap();
    let dest = root.join("new-parent-test-repo/../dotdot-test-repo");
    let env = switch_only_in(&net, &root.join("dotdot-test-repo"), &[]);
    let locator = format!("{}?ref=dotdot", net.remote().to_str().unwrap());
    let out = run_in_env(
        &root,
        &[
            "init",
            dest.to_str().unwrap(),
            "--remote",
            &locator,
            "--prefix",
            "ZZ",
        ],
        "",
        &pairs(&env),
    );
    assert_eq!(out.code, 1, "{}", out.json);
    assert_eq!(
        out.json["error"]["code"], "git-identity-missing",
        "{}",
        out.json
    );
    assert!(!root.join("dotdot-test-repo").exists());
    assert!(!root.join("new-parent-test-repo").exists());
}

/// Holds started commands paused in the `git` wrapper of
/// [`pausing_git`] until released; releases them all when dropped, so a
/// failing test does not leave them waiting.
struct Pauses(Vec<PathBuf>);

impl Pauses {
    fn release(&self, marker: &Path) {
        std::fs::write(marker.with_extension("go"), "").unwrap();
    }
}

impl Drop for Pauses {
    fn drop(&mut self) {
        for m in &self.0 {
            let _ = std::fs::write(m.with_extension("go"), "");
        }
    }
}

/// A directory holding a `git` that runs the real one, except that in a
/// process whose environment sets `ZZ_TEST_GIT_PAUSE`, a git command whose
/// arguments contain it first creates the file `ZZ_TEST_GIT_MARKER` and
/// then waits for that file with the extension `go`. Read by the wrapper
/// only; the binary under test knows nothing of it.
fn pausing_git(net: &Net) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::var_os("PATH").unwrap();
    let real = std::env::split_paths(&path)
        .map(|d| d.join("git"))
        .find(|g| g.is_file())
        .expect("git on PATH");
    let script = format!(
        "#!/bin/sh\n\
         if [ -n \"$ZZ_TEST_GIT_PAUSE\" ]; then\n\
         \x20 case \" $* \" in\n\
         \x20   *\" $ZZ_TEST_GIT_PAUSE \"*)\n\
         \x20     : > \"$ZZ_TEST_GIT_MARKER\"\n\
         \x20     while [ ! -e \"${{ZZ_TEST_GIT_MARKER%.*}}.go\" ]; do sleep 0.01; done ;;\n\
         \x20 esac\n\
         fi\n\
         exec '{}' \"$@\"\n",
        real.display()
    );
    write_file(net.dir.path(), "bin/git", &script);
    let git = net.dir.path().join("bin/git");
    std::fs::set_permissions(&git, std::fs::Permissions::from_mode(0o755)).unwrap();
    git.parent().unwrap().to_path_buf()
}

fn wait_for(what: &str, cond: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while !cond() {
        assert!(
            std::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

/// Whether process `pid` has `file` open.
fn has_open(pid: u32, file: &Path) -> bool {
    std::fs::read_dir(format!("/proc/{pid}/fd"))
        .map(|fds| {
            fds.filter_map(|fd| std::fs::read_link(fd.ok()?.path()).ok())
                .any(|target| target == file)
        })
        .unwrap_or(false)
}

/// Init B waits on the lock of the repository init A created; A is then
/// refused and removes that repository, lock file included. B must not
/// carry on under the lock of a file that is gone: it starts over, makes
/// the repository again and initializes it.
#[cfg(target_os = "linux")]
#[test]
fn an_init_waiting_on_a_removed_repository_starts_over() {
    let net = Net::new();
    let root = std::fs::canonicalize(net.dir.path()).unwrap();
    let dest = root.join("c-test-repo");
    let bin = pausing_git(&net);
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
    let a_marker = root.join("a.paused");
    let b_marker = root.join("b.paused");
    let pauses = Pauses(vec![a_marker.clone(), b_marker.clone()]);
    let locator = format!("{}?ref=main", net.remote().to_str().unwrap());
    let args = [
        "init",
        dest.to_str().unwrap(),
        "--remote",
        &locator,
        "--prefix",
        "ZZ",
    ];
    let start = |identity: &[(&str, &str)], pause: &str, marker: &Path| {
        let mut env = switch_only_in(&net, &dest, identity);
        env.push(("PATH".into(), path.clone()));
        env.push(("ZZ_TEST_GIT_PAUSE".into(), pause.into()));
        env.push(("ZZ_TEST_GIT_MARKER".into(), marker.to_str().unwrap().into()));
        spawn_as(&root, Some(TESTER), &args, &pairs(&env))
    };

    // B passes its destination check, then pauses reading the remote.
    let b = start(
        &[
            ("user.name", "Ada Example"),
            ("user.email", "ada@example.org"),
        ],
        "ls-remote",
        &b_marker,
    );
    wait_for("B to pause", || b_marker.exists());
    // A creates the repository, takes its lock, and pauses checking the
    // identity it does not have.
    let a = start(&[], "var GIT_COMMITTER_IDENT", &a_marker);
    wait_for("A to pause", || a_marker.exists());
    // B finds A's repository and waits on its lock.
    let lock = dest.join(".git/zwanenzang.lock");
    pauses.release(&b_marker);
    wait_for("B to open A's lock file", || has_open(b.id(), &lock));
    // A is refused and removes what it created, lock file included.
    pauses.release(&a_marker);
    let a = finish(a);
    assert_eq!(a.code, 1, "{}\n{}", a.json, a.stderr);
    assert_eq!(
        a.json["error"]["code"], "git-identity-missing",
        "{}",
        a.json
    );

    let b = finish(b);
    assert_eq!(b.code, 0, "{}\n{}", b.json, b.stderr);
    assert_eq!(b.json["sync"]["pushed"], true, "{}", b.json);
    assert_eq!(idents(&dest), [format!("init | {ADA} | {ADA}")]);
}
