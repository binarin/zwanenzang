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

use serde_json::Value;

pub const MARKER: &str = "-test-repo";

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
    if let Some(why) = tracker_above(dir).and_then(|root| not_disposable(&root)) {
        panic!("refusing to run in {dir:?}: the binary would open the tracker at {why}");
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
    assert_opens_disposable(dir);
    let mut child = Command::new(env!("CARGO_BIN_EXE_zwanenzang"))
        .arg("-C")
        .arg(dir)
        .args(["--actor-name", "tester"])
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn zwanenzang");
    // A command that fails before reading stdin (a usage error) may exit
    // first; the write then fails with a broken pipe, which is not an error
    // of the test.
    if let Err(e) = child.stdin.take().unwrap().write_all(stdin.as_bytes())
        && e.kind() != std::io::ErrorKind::BrokenPipe
    {
        panic!("writing stdin: {e}");
    }
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

/// A fresh tracker with prefix ZZ.
pub fn tracker() -> tempfile::TempDir {
    let d = disposable_dir();
    ok(d.path(), &["init", "--prefix", "ZZ", "--name", "Test"]);
    d
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

pub fn id(v: &Value) -> String {
    v["ticket"]["id"].as_str().unwrap().to_string()
}
