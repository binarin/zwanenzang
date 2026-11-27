//! Helpers for driving the built binary. Every tracker these tests touch is
//! a directory under the system temporary directory whose name ends in
//! `-test-repo`; each helper that opens or writes one checks both markers
//! first and panics otherwise. The binary searches upward from `-C DIR` for
//! the tracker it opens, so the helper checks the tracker found that way,
//! not only `DIR`.

#![allow(dead_code)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

use serde_json::Value;

pub const MARKER: &str = "-test-repo";

/// `GIT_CONFIG_GLOBAL` for every git the tests run, the binary's included:
/// no user configuration, and no automatic maintenance or gc racing the
/// next command (see the file).
pub const GIT_CONFIG_GLOBAL: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/gitconfig");

/// Bare remotes backing `tracker()`; held so they outlive the trackers.
static REMOTES: Mutex<Vec<tempfile::TempDir>> = Mutex::new(Vec::new());

/// A bare remote for one tracker, as `URL` for `init --remote`.
pub fn bare_remote() -> (tempfile::TempDir, String) {
    let remote = disposable_dir();
    git(remote.path(), &["init", "--quiet", "--bare", "remote.git"]);
    let url = remote
        .path()
        .join("remote.git")
        .to_str()
        .unwrap()
        .to_string();
    (remote, url)
}

/// Why `path` is not disposable, or `None` when it carries both markers.
pub fn not_disposable(path: &Path) -> Option<String> {
    let tmp = std::fs::canonicalize(std::env::temp_dir()).expect("temp dir");
    let p = std::fs::canonicalize(path).expect("test path exists");
    if !p.starts_with(&tmp) {
        return Some(format!(
            "{p:?} is not under the temporary directory {tmp:?}"
        ));
    }
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if !name.ends_with(MARKER) {
        return Some(format!("{p:?}: directory name does not end in {MARKER}"));
    }
    None
}

pub fn assert_disposable(path: &Path) {
    if let Some(why) = not_disposable(path) {
        panic!("refusing to touch {why}");
    }
}

/// The tracker the binary opens when pointed at `dir`: the nearest
/// directory, upward, holding `zwanenzang.toml`. Walked here rather than by
/// the library under test.
pub fn tracker_above(dir: &Path) -> Option<PathBuf> {
    let start = std::fs::canonicalize(dir).expect("test path exists");
    start
        .ancestors()
        .find(|d| d.join("zwanenzang.toml").is_file())
        .map(Path::to_path_buf)
}

/// Checks `dir` and whatever tracker the binary would open from it.
pub fn assert_opens_disposable(dir: &Path) {
    assert_disposable(dir);
    let root = tracker_above(dir).unwrap_or_else(|| dir.to_path_buf());
    if let Some(why) = not_disposable(&root) {
        panic!("refusing to run in {dir:?}: the binary would open the tracker at {why}");
    }
    if root.join(".git").exists() {
        // Sync can also write configured human checkouts. Check those before
        // launching the binary, including aliases and paths not created yet.
        let out = git_command(&root)
            .args([
                "config",
                "--local",
                "--null",
                "--get-all",
                "zwanenzang.checkout",
            ])
            .output()
            .expect("read checkout configuration");
        assert!(
            matches!(out.status.code(), Some(0 | 1)),
            "cannot inspect checkout configuration"
        );
        for value in out.stdout.split(|&b| b == 0).filter(|b| !b.is_empty()) {
            let path = root.join(std::str::from_utf8(value).expect("UTF-8 checkout path"));
            if path.exists() {
                assert_disposable(&path);
            } else {
                assert!(
                    path.file_name()
                        .unwrap()
                        .to_string_lossy()
                        .ends_with(MARKER),
                    "unmarked checkout path: {path:?}"
                );
                let ancestor = path
                    .ancestors()
                    .find(|p| p.exists())
                    .expect("existing ancestor");
                assert_disposable(ancestor);
            }
        }
    }
}

pub fn disposable_dir() -> tempfile::TempDir {
    let d = tempfile::Builder::new()
        .prefix("zwanenzang-cli-")
        .suffix(MARKER)
        .tempdir_in(std::env::temp_dir())
        .expect("create temp dir");
    assert_disposable(d.path());
    d
}

pub struct Out {
    pub code: i32,
    pub json: Value,
    pub stderr: String,
}

/// Runs the binary against `dir` with `args`, feeding `stdin`.
pub fn run_in(dir: &Path, args: &[&str], stdin: &str) -> Out {
    run_in_env(dir, args, stdin, &[])
}

/// The identity the helpers write as unless a test picks another; `init`
/// puts it in the tracker's `actors` list.
pub const TESTER: &str = "tester";

/// Runs with per-child environment overrides, avoiding process-global state
/// in parallel tests. The same disposable-repository checks still apply.
pub fn run_in_env(dir: &Path, args: &[&str], stdin: &str, env: &[(&str, &str)]) -> Out {
    run_as(dir, Some(TESTER), args, stdin, env)
}

/// Runs with `--actor-name actor`, or without the flag for `None`.
pub fn run_as(
    dir: &Path,
    actor: Option<&str>,
    args: &[&str],
    stdin: &str,
    env: &[(&str, &str)],
) -> Out {
    let mut child = spawn_as(dir, actor, args, env);
    // A command that fails before reading stdin (a usage error) may exit
    // first; the write then fails with a broken pipe, which is not an error
    // of the test.
    if let Err(e) = child.stdin.take().unwrap().write_all(stdin.as_bytes())
        && e.kind() != std::io::ErrorKind::BrokenPipe
    {
        panic!("writing stdin: {e}");
    }
    finish(child)
}

/// Starts the binary like [`run_as`] without waiting for it; its stdin is
/// a pipe the caller writes or drops. Collect it with [`finish`].
pub fn spawn_as(
    dir: &Path,
    actor: Option<&str>,
    args: &[&str],
    env: &[(&str, &str)],
) -> std::process::Child {
    assert_opens_disposable(dir);
    let mut command = Command::new(env!("CARGO_BIN_EXE_zwanenzang"));
    command.arg("-C").arg(dir);
    if let Some(a) = actor {
        command.args(["--actor-name", a]);
    }
    clear_inherited_git_config(&mut command);
    command
        .args(args)
        .current_dir(dir)
        // Nor the developer's identity overrides, so a commit made as git's
        // own user takes its identity from the configuration a test sets.
        .env_remove("GIT_AUTHOR_NAME")
        .env_remove("GIT_AUTHOR_EMAIL")
        .env_remove("GIT_COMMITTER_NAME")
        .env_remove("GIT_COMMITTER_EMAIL")
        .env_remove("EMAIL")
        .envs(env.iter().copied())
        // The binary's git commands see no user or system configuration,
        // so a developer's hooks, signing or url rewrites play no part.
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", GIT_CONFIG_GLOBAL)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn zwanenzang")
}

/// Waits for a binary started with [`spawn_as`] and parses its output.
pub fn finish(child: std::process::Child) -> Out {
    let out = child.wait_with_output().unwrap();
    let stdout = String::from_utf8(out.stdout).unwrap();
    let json = if stdout.trim().is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&stdout)
            .unwrap_or_else(|e| panic!("stdout is not JSON ({e}): {stdout}"))
    };
    Out {
        code: out.status.code().unwrap_or(-1),
        json,
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

/// Runs and expects success.
pub fn ok(dir: &Path, args: &[&str]) -> Value {
    ok_stdin(dir, args, "")
}

pub fn ok_stdin(dir: &Path, args: &[&str], stdin: &str) -> Value {
    let o = run_in(dir, args, stdin);
    assert_eq!(o.code, 0, "{args:?} failed: {} {}", o.json, o.stderr);
    o.json
}

/// Runs and expects a JSON error with `code`.
pub fn err(dir: &Path, args: &[&str], code: &str) -> Value {
    let o = run_in(dir, args, "");
    assert_eq!(o.code, 1, "{args:?} should fail: {}", o.json);
    assert_eq!(o.json["error"]["code"], code, "{args:?}: {}", o.json);
    assert!(o.json["error"]["message"].is_string());
    o.json
}

/// A fresh tracker with prefix ZZ, initialized against its own bare
/// remote on branch `main`.
pub fn tracker() -> tempfile::TempDir {
    let d = disposable_dir();
    init_tracker(d.path(), "ZZ");
    d
}

/// Runs `init` creating a tracker with `prefix` in the disposable `dir`
/// against a fresh bare remote on branch `main`.
pub fn init_tracker(dir: &Path, prefix: &str) -> Value {
    let (remote, url) = bare_remote();
    let out = ok(
        dir,
        &[
            "init",
            dir.to_str().unwrap(),
            "--remote",
            &format!("{url}?ref=main"),
            "--prefix",
            prefix,
            "--name",
            "Test",
        ],
    );
    REMOTES.lock().unwrap().push(remote);
    out
}

/// Drops the tracker clone's upstream configuration, making the clone the
/// whole tracker for tests of upstream-less behavior.
pub fn without_upstream(dir: &Path) {
    git(
        dir,
        &["config", "--local", "--remove-section", "branch.main"],
    );
}

/// Appends raw lines to `events/<log>.jsonl`.
pub fn append_raw(dir: &Path, log: &str, lines: &[String]) {
    assert_disposable(dir);
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("events").join(format!("{log}.jsonl")))
        .unwrap();
    for l in lines {
        writeln!(f, "{l}").unwrap();
    }
}

/// Every log file and its bytes.
pub fn logs(dir: &Path) -> Vec<(String, Vec<u8>)> {
    assert_disposable(dir);
    let mut v: Vec<_> = std::fs::read_dir(dir.join("events"))
        .unwrap()
        .map(|e| {
            let e = e.unwrap();
            (
                e.file_name().to_string_lossy().into_owned(),
                std::fs::read(e.path()).unwrap(),
            )
        })
        .collect();
    v.sort();
    v
}

pub fn read(dir: &Path, rel: &str) -> String {
    assert_disposable(dir);
    std::fs::read_to_string(dir.join(rel)).unwrap()
}

/// The actor id of the clone at `dir`, from its git configuration.
pub fn actor_of(dir: &Path) -> String {
    git(dir, &["config", "--local", "zwanenzang.actor"])
        .trim()
        .to_string()
}

pub fn id(v: &Value) -> String {
    v["ticket"]["id"].as_str().unwrap().to_string()
}

/// Writes `text` to `rel` under the disposable `dir`, creating directories.
pub fn write_file(dir: &Path, rel: &str, text: &str) {
    assert_disposable(dir);
    let p = dir.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

/// Appends `text` to the tracker configuration of the disposable `dir`.
pub fn append_config(dir: &Path, text: &str) {
    assert_disposable(dir);
    let p = dir.join("zwanenzang.toml");
    let mut cur = std::fs::read_to_string(&p).unwrap();
    cur.push_str(text);
    std::fs::write(p, cur).unwrap();
}

/// Copies the directory tree `src` into the disposable `dst`.
pub fn copy_tree(src: &Path, dst: &Path) {
    assert_disposable(dst);
    fn walk(src: &Path, dst: &Path) {
        std::fs::create_dir_all(dst).unwrap();
        for e in std::fs::read_dir(src).unwrap() {
            let e = e.unwrap();
            let to = dst.join(e.file_name());
            if e.file_type().unwrap().is_dir() {
                walk(&e.path(), &to);
            } else {
                std::fs::copy(e.path(), to).unwrap();
            }
        }
    }
    walk(src, dst);
}

/// Runs git in the disposable repository `dir`, with an identity and no
/// user or system configuration, and returns its stdout.
pub fn git(dir: &Path, args: &[&str]) -> String {
    assert_disposable(dir);
    let out = git_command(dir).args(args).output().expect("run git");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

/// Runs git like `git` but never panics on its failure, returning the exit
/// status and both streams: for describing a repository that may be broken.
pub fn git_report(dir: &Path, args: &[&str]) -> String {
    match git_command(dir).args(args).output() {
        Ok(out) => format!(
            "{}{}{}",
            if out.status.success() {
                String::new()
            } else {
                format!("[{}] ", out.status)
            },
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
        Err(e) => format!("cannot run git: {e}\n"),
    }
}

/// Removes command-scope git configuration the test process inherited
/// (`GIT_CONFIG_COUNT` and its keys and values, `GIT_CONFIG_PARAMETERS`), so
/// only what a test passes explicitly applies.
fn clear_inherited_git_config(command: &mut Command) {
    for (key, _) in std::env::vars_os() {
        let inherited = key.to_str().is_some_and(|k| {
            k == "GIT_CONFIG_COUNT"
                || k == "GIT_CONFIG_PARAMETERS"
                || k.starts_with("GIT_CONFIG_KEY_")
                || k.starts_with("GIT_CONFIG_VALUE_")
        });
        if inherited {
            command.env_remove(key);
        }
    }
}

fn git_command(dir: &Path) -> Command {
    assert_disposable(dir);
    let mut command = Command::new("git");
    clear_inherited_git_config(&mut command);
    command
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "init.defaultBranch=main",
            "-c",
            "commit.gpgsign=false",
        ])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", GIT_CONFIG_GLOBAL)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE");
    command
}
