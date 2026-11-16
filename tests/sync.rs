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
    /// A bare remote and a first clone holding a fresh, pushed tracker.
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
        let net = Net { dir };
        let a = net.path("a");
        let out = run_in(
            net.dir.path(),
            &[
                "init",
                a.to_str().unwrap(),
                "--remote",
                &net.locator(),
                "--prefix",
                "ZZ",
                "--name",
                "Test",
            ],
            "",
        );
        assert_eq!(out.code, 0, "{}\n{}", out.json, out.stderr);
        assert_eq!(out.json["sync"]["pushed"], true, "{}", out.json);
        net
    }

    fn remote(&self) -> PathBuf {
        self.dir.path().join("remote-test-repo")
    }

    /// The remote as a locator selecting its default branch, `main`.
    fn locator(&self) -> String {
        format!("{}?ref=main", self.remote().to_str().unwrap())
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
fn concurrent_dependencies_preserve_and_diagnose_cycles() {
    let net = Net::new();
    let a = net.path("a");
    let x = id(&ok(&a, &["create", "X"]));
    let y = id(&ok(&a, &["create", "Y"]));
    let b = net.clone_as("b");
    net.offline(&a, true);
    net.offline(&b, true);
    ok(&a, &["depend", &x, &y]);
    ok(&b, &["depend", &y, &x]);
    net.offline(&a, false);
    net.offline(&b, false);
    ok(&a, &["sync"]);
    ok(&b, &["sync"]);
    ok(&a, &["sync"]);
    assert_eq!(tickets(&a), tickets(&b));
    assert_eq!(ok(&a, &["show", &x])["depends_on"], json!([y]));
    assert_eq!(ok(&a, &["show", &y])["depends_on"], json!([x]));
    let lint = run_in(&a, &["lint"], "");
    assert_eq!(lint.code, 1);
    assert_eq!(lint.json["skipped"], json!([]));
    assert_eq!(lint.json["dependency_cycles"].as_array().unwrap().len(), 2);
    ok(&a, &["depend", &x, &y, "--remove"]);
    assert_eq!(run_in(&a, &["lint"], "").code, 0);
}

#[test]
fn clones_share_one_numbering() {
    let net = Net::new();
    let a = net.path("a");
    let first = ok(&a, &["create", "From A"]);
    assert_eq!(first["sync"]["upstream"], "origin/main");
    assert_eq!(first["sync"]["pushed"], true);
    assert_eq!(first["ticket"]["display"], "ZZ-1");
    let b = net.clone_as("b");
    let second = ok(&b, &["create", "From B"]);
    assert_eq!(second["ticket"]["display"], "ZZ-2");
    assert_ne!(actor_of(&a), actor_of(&b), "a writer per clone");
    // A sees B's ticket after a sync; reads alone do not fetch.
    assert_eq!(tickets(&a).as_array().unwrap().len(), 1);
    let s = ok(&a, &["sync"]);
    assert_eq!(s["sync"]["pushed"], true);
    assert_eq!(s["sync"]["numbered"], json!([]));
    assert_eq!(tickets(&a), tickets(&b));
    assert_eq!(git(&a, &["status", "--porcelain"]), "");
}

#[test]
fn clones_writing_as_one_identity_are_still_reported_concurrent() {
    let net = Net::new();
    let a = net.path("a");
    let b = net.clone_as("b");
    // One identity on two machines: by flag on A, by clone default on B.
    git(
        &b,
        &["config", "--local", "zwanenzang.defaultActor", "agent"],
    );
    let t = id(&run_ok(&a, Some("agent"), &["create", "Shared"]));
    // B's first write declares its writer and fetches the shared ticket.
    run_ok(&b, None, &["create", "B's own"]);
    let on_a = run_ok(&a, Some("agent"), &["status", &t, "next"]);
    // B has not fetched A's change when it builds its own.
    let on_b = run_ok(&b, None, &["status", &t, "wait"]);
    assert_eq!(on_b["event"]["as"], "agent");
    assert_eq!(on_b["sync"]["pushed"], true);
    assert_ne!(on_a["event"]["actor"], on_b["event"]["actor"]);
    ok(&a, &["sync"]);
    for clone in [&a, &b] {
        let lint = run_in(clone, &["lint"], "");
        assert_eq!(lint.code, 1, "{}", lint.json);
        let concurrent = lint.json["concurrent"].as_array().unwrap();
        assert_eq!(concurrent.len(), 1, "{}", lint.json);
        assert_eq!(concurrent[0]["field"], "status");
        assert_eq!(concurrent[0]["earlier"], on_a["event"]["id"]);
        assert_eq!(concurrent[0]["later"], on_b["event"]["id"]);
        let shown = ok(clone, &["show", &t]);
        assert_eq!(shown["activity"]["identity"], "agent");
        assert_eq!(shown["activity"]["actor"], on_b["event"]["actor"]);
    }
}

/// Runs as `actor` (no flag for `None`) and expects success.
fn run_ok(dir: &Path, actor: Option<&str>, args: &[&str]) -> Value {
    let o = run_as(dir, actor, args, "", &[]);
    assert_eq!(o.code, 0, "{args:?} failed: {} {}", o.json, o.stderr);
    o.json
}

#[test]
fn sync_without_upstream_changes_leaves_edited_config_untouched() {
    for staged in [false, true] {
        let net = Net::new();
        let a = net.path("a");
        let config = format!("{}\n# Local edit\n", read(&a, "zwanenzang.toml"));
        write_file(&a, "zwanenzang.toml", &config);
        if staged {
            git(&a, &["add", "zwanenzang.toml"]);
        }
        // A fixed old timestamp detects even a same-content rewrite without
        // relying on filesystem timestamp resolution or sleeps.
        let path = a.join("zwanenzang.toml");
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(
                std::fs::FileTimes::new().set_modified(
                    std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000),
                ),
            )
            .unwrap();
        let before = std::fs::metadata(&path).unwrap().modified().unwrap();
        let index = git(&a, &["diff", "--cached"]);
        // Explicit sync has equal heads; create also tests local commits ahead
        // of the fetched head, before numbering and pushing.
        for args in [vec!["sync"], vec!["create", "Local ticket"], vec!["sync"]] {
            let out = ok(&a, &args);
            assert_eq!(out["sync"]["error"], Value::Null, "{out}");
            assert_eq!(out["sync"]["pushed"], true, "{out}");
            assert_eq!(read(&a, "zwanenzang.toml"), config);
            assert_eq!(git(&a, &["diff", "--cached"]), index);
            assert_eq!(
                std::fs::metadata(&path).unwrap().modified().unwrap(),
                before
            );
        }
    }
}

#[test]
fn fast_forward_keeps_unrelated_edited_config_untouched() {
    for staged in [false, true] {
        let net = Net::new();
        let a = net.path("a");
        let b = net.clone_as("b");
        let config = format!("{}\n# Local edit\n", read(&a, "zwanenzang.toml"));
        write_file(&a, "zwanenzang.toml", &config);
        if staged {
            git(&a, &["add", "zwanenzang.toml"]);
        }
        let path = a.join("zwanenzang.toml");
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(
                std::fs::FileTimes::new().set_modified(
                    std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000),
                ),
            )
            .unwrap();
        let before = std::fs::metadata(&path).unwrap().modified().unwrap();
        let index = git(&a, &["diff", "--cached"]);
        // Neither user-configured autostash nor hooks may rewrite local edits.
        git(&a, &["config", "merge.autostash", "true"]);
        write_file(&a, ".git/hooks/post-merge", "#!/bin/sh\ntouch hook-ran\n");
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(
            a.join(".git/hooks/post-merge"),
            std::fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        ok(&b, &["create", "Remote ticket"]);
        let out = ok(&a, &["sync"]);
        assert_eq!(out["sync"]["error"], Value::Null, "{out}");
        assert_eq!(out["sync"]["pushed"], true);
        assert_eq!(
            git(&a, &["rev-parse", "HEAD"]),
            git(&b, &["rev-parse", "HEAD"])
        );
        assert_eq!(read(&a, "zwanenzang.toml"), config);
        assert_eq!(git(&a, &["diff", "--cached"]), index);
        assert_eq!(
            std::fs::metadata(&path).unwrap().modified().unwrap(),
            before
        );
        assert!(!a.join("hook-ran").exists());
    }
}

#[test]
fn fast_forward_overlapping_dirty_file_falls_back_to_autostash() {
    let net = Net::new();
    let a = net.path("a");
    let b = net.clone_as("b");
    let original = read(&a, "zwanenzang.toml");
    let local = original.replace("name = \"Test\"", "name = \"Edited\"");
    assert_ne!(local, original);
    write_file(&a, "zwanenzang.toml", &local);
    let remote = format!("{original}\n# Remote configuration note\n");
    write_file(&b, "zwanenzang.toml", &remote);
    git(&b, &["add", "zwanenzang.toml"]);
    git(&b, &["commit", "--quiet", "-m", "Update configuration"]);
    git(&b, &["push", "--quiet"]);
    let out = ok(&a, &["sync"]);
    assert_eq!(out["sync"]["error"], Value::Null, "{out}");
    assert_eq!(out["sync"]["pushed"], true);
    assert_eq!(
        git(&a, &["rev-parse", "HEAD"]),
        git(&b, &["rev-parse", "HEAD"])
    );
    assert_eq!(
        read(&a, "zwanenzang.toml"),
        format!("{local}\n# Remote configuration note\n")
    );
}

#[test]
fn upstream_changes_still_rebase_and_preserve_edited_config() {
    let net = Net::new();
    let a = net.path("a");
    let b = net.clone_as("b");
    let config = format!("{}\n# Local edit\n", read(&a, "zwanenzang.toml"));
    write_file(&a, "zwanenzang.toml", &config);
    net.offline(&a, true);
    ok(&a, &["create", "Local offline ticket"]);
    ok(&b, &["create", "Remote ticket"]);
    net.offline(&a, false);
    let out = ok(&a, &["sync"]);
    assert_eq!(out["sync"]["error"], Value::Null, "{out}");
    assert_eq!(out["sync"]["pushed"], true);
    assert_eq!(read(&a, "zwanenzang.toml"), config);
    assert_eq!(numbers(&a).len(), 2);
    ok(&b, &["sync"]);
    assert_eq!(tickets(&a), tickets(&b));
    assert_eq!(git(&a, &["rev-list", "--merges", "HEAD"]), "");
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
    assert_eq!(on["ticket"]["display"], "ZZ-1");
    net.offline(&a, false);
    let s = ok(&a, &["sync"]);
    assert_eq!(s["sync"]["numbered"][0]["id"], off_id.as_str());
    assert_eq!(s["sync"]["numbered"][0]["display"], "ZZ-2");
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
    assert_eq!(s["sync"]["numbered"][0]["display"], "ZZ-1");
    assert_eq!(numbers(&a), [1]);
}

#[test]
fn racing_clones_never_share_a_number() {
    let net = Net::new();
    let clones = [net.path("a"), net.clone_as("b"), net.clone_as("c")];
    let traces = GitTraces::new(&net, &clones);
    let per_clone = 4;
    let race = || {
        std::thread::scope(|s| {
            for k in 0..clones.len() {
                let traces = &traces;
                s.spawn(move || {
                    for i in 0..per_clone {
                        let out = traces.ok(k, &["create", &format!("clone {k} ticket {i}")]);
                        // Bounded retry may yield under sustained contention;
                        // the final uncontended syncs below publish that tail.
                        assert!(
                            out["sync"]["error"].is_null()
                                || out["sync"]["error"]["code"] == "push-rejected",
                            "{out}"
                        );
                    }
                });
            }
        });
        // One pass publishes every clone's tail, but a clone synced early in
        // it does not see tails published after it; the second pass does.
        for _ in 0..2 {
            for k in 0..clones.len() {
                traces.ok(k, &["sync"]);
            }
        }
        let total = (clones.len() * per_clone) as u64;
        // Unique and without gaps; tickets are numbered in publish order,
        // which across clones is not id order.
        let mut got = numbers(&clones[0]);
        got.sort();
        assert_eq!(got, (1..=total).collect::<Vec<_>>());
        for c in &clones[1..] {
            assert_eq!(tickets(c), tickets(&clones[0]));
        }
        let lint = run_in(&clones[0], &["lint"], "");
        assert_eq!(lint.code, 0, "{}", lint.json);
    };
    // CI has seen `git commit` in a clone fail with "could not parse HEAD"
    // (ZZ-44), which has not been reproduced elsewhere. CI runs this inside
    // the nix build sandbox, whose temporary directory is lost, so a failure
    // prints what git did in each clone.
    if let Err(panic) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(race)) {
        eprintln!("{}", traces.report(&net));
        std::panic::resume_unwind(panic);
    }
}

/// Git tracing of the CLI's runs in each clone, written next to the clones
/// in the disposable directory and reported only when the test fails.
struct GitTraces {
    clones: Vec<(PathBuf, PathBuf, PathBuf)>,
}

impl GitTraces {
    const EVENTS: usize = 200;
    const REF_UPDATES: usize = 60;

    fn new(net: &Net, clones: &[PathBuf]) -> GitTraces {
        let clones = clones
            .iter()
            .map(|c| {
                let name = c.file_name().unwrap().to_string_lossy().into_owned();
                let events = net.dir.path().join(format!("{name}.trace2-event"));
                let refs = net.dir.path().join(format!("{name}.trace-refs"));
                (c.clone(), events, refs)
            })
            .collect();
        GitTraces { clones }
    }

    /// Runs the CLI in clone `k` with tracing and expects success.
    fn ok(&self, k: usize, args: &[&str]) -> Value {
        let (clone, events, refs) = &self.clones[k];
        let env = [
            ("GIT_TRACE2_EVENT", events.to_str().unwrap()),
            ("GIT_TRACE_REFS", refs.to_str().unwrap()),
        ];
        let o = run_in_env(clone, args, "", &env);
        assert_eq!(o.code, 0, "{args:?} failed: {} {}", o.json, o.stderr);
        o.json
    }

    /// The state of every clone and the remote, and the tail of what git
    /// did in each clone, including the remote's side of its pushes.
    fn report(&self, net: &Net) -> String {
        let mut r = String::new();
        let remote = net.remote();
        r += "=== git diagnostics: remote ===\n";
        r += &section(
            &remote,
            "log --oneline -5 main",
            &["log", "--oneline", "-5", "main"],
        );
        r += &section(&remote, "fsck --no-dangling", &["fsck", "--no-dangling"]);
        for (clone, events, refs) in &self.clones {
            r += &format!("=== git diagnostics: {} ===\n", clone.display());
            let head = std::fs::read_to_string(clone.join(".git/HEAD"));
            r += &format!("-- .git/HEAD: {head:?}\n");
            for (title, args) in [
                ("rev-parse HEAD", &["rev-parse", "HEAD"][..]),
                ("cat-file -t HEAD", &["cat-file", "-t", "HEAD"]),
                ("log --oneline -5", &["log", "--oneline", "-5"]),
                ("fsck --no-dangling", &["fsck", "--no-dangling"]),
                ("count-objects -v", &["count-objects", "-v"]),
                ("status --short", &["status", "--short"]),
            ] {
                r += &section(clone, title, args);
            }
            let entries = std::fs::read_dir(clone.join(".git")).map(|d| {
                let mut v: Vec<_> = d
                    .filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect();
                v.sort();
                v.join(" ")
            });
            r += &format!("-- .git entries: {entries:?}\n");
            // Read directly: `git reflog` gives up on a HEAD it cannot parse.
            r += "-- last 15 entries of .git/logs/HEAD\n";
            r += &tail(&clone.join(".git/logs/HEAD"), 15, |l| Some(l.to_string()));
            r += &format!("-- last {} git process events (UTC)\n", Self::EVENTS);
            r += &tail(events, Self::EVENTS, compact_event);
            r += &format!(
                "-- last {} ref updates, the remote's during pushes included (local time)\n",
                Self::REF_UPDATES
            );
            r += &tail(refs, Self::REF_UPDATES, |l| {
                let update = l.contains(" -> ")
                    && !l.contains("reflog_ent")
                    && !l.contains(": AUTO_MERGE 0000000000000000000000000000000000000000 ->");
                let failed = (l.contains("transaction_prepare:") || l.contains("finish:"))
                    && !l.contains(": 0");
                (update || failed).then(|| l.to_string())
            });
        }
        r.replace(net.dir.path().to_str().unwrap(), "$NET")
    }
}

fn section(dir: &Path, title: &str, args: &[&str]) -> String {
    let out = git_report(dir, args);
    let lines: Vec<&str> = out.lines().take(30).collect();
    format!("-- {title}\n{}\n", lines.join("\n"))
}

/// The last `n` lines of `file` that `keep` turns into report lines.
fn tail(file: &Path, n: usize, keep: impl Fn(&str) -> Option<String>) -> String {
    let Ok(text) = std::fs::read_to_string(file) else {
        return "(no trace)\n".to_string();
    };
    let kept: Vec<String> = text.lines().filter_map(keep).collect();
    let mut out = kept[kept.len().saturating_sub(n)..].join("\n");
    out.push('\n');
    out
}

/// One trace2 event as `time pid depth event detail`, for the events that
/// say which git process ran, what it started and how it ended.
fn compact_event(line: &str) -> Option<String> {
    let v: Value = serde_json::from_str(line).ok()?;
    let event = v["event"].as_str()?;
    let detail = match event {
        "start" | "child_start" => v["argv"]
            .as_array()?
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" "),
        "exit" => format!("code {}", v["code"]),
        "child_exit" => format!("pid {} code {}", v["pid"], v["code"]),
        "error" | "signal" => v["msg"].as_str().unwrap_or("").to_string(),
        "region_enter" if v["category"] == "maintenance" || v["category"] == "gc" => {
            format!("{}/{}", v["category"].as_str()?, v["label"].as_str()?)
        }
        _ => return None,
    };
    let sid = v["sid"].as_str()?;
    let depth = sid.matches('/').count();
    let pid = sid
        .rsplit_once("-P")
        .and_then(|(_, p)| u32::from_str_radix(p, 16).ok())
        .map_or("?".to_string(), |p| p.to_string());
    let time = v["time"].as_str()?;
    let time = time.split_once('T').map_or(time, |(_, t)| t);
    Some(format!("{time} P{pid} d{depth} {event} {detail}"))
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
fn batch_commits_once_syncs_once_and_returns_published_state() {
    let net = Net::new();
    let a = net.path("a");
    let b = net.clone_as("b");
    let before = git(&a, &["rev-parse", "HEAD"]);
    // Count actual fetches via a repository-local git trace; numbering is
    // allowed its own commit, but each change must not run its own sync.
    let trace = a.join("batch-trace");
    let out = run_in_env(&a, &["apply"], &json!({"changes":[
        {"op":"create","data":{"title":"Synthetic batch parent"}},
        {"op":"create","data":{"title":"Synthetic batch child"}},
        {"op":"parent","ticket":{"created":1},"data":{"to":{"created":0}}},
        {"op":"doc","ticket":{"created":1},"data":{"name":"description","text":"Synthetic body","base":null}}
    ]}).to_string(), &[("GIT_TRACE2_EVENT", trace.to_str().unwrap())]);
    assert_eq!(out.code, 0, "{} {}", out.json, out.stderr);
    let out = out.json;
    assert_eq!(out["sync"]["pushed"], true, "{out}");
    assert_eq!(out["sync"]["numbered"].as_array().unwrap().len(), 2);
    assert_eq!(
        git(
            &a,
            &["rev-list", "--count", &format!("{}..HEAD", before.trim())]
        )
        .trim(),
        "2"
    );
    let trace = read(&a, "batch-trace");
    let fetches = trace
        .lines()
        .filter(|line| {
            let v: Value = serde_json::from_str(line).unwrap();
            v["event"] == "start"
                && v["argv"]
                    .as_array()
                    .is_some_and(|args| args.iter().any(|a| a == "fetch"))
        })
        .count();
    assert_eq!(fetches, 1, "one fetch for the whole batch");
    ok(&b, &["sync"]);
    assert_eq!(tickets(&a), tickets(&b));
    for t in out["tickets"].as_array().unwrap() {
        assert_eq!(*t, ok(&b, &["show", t["id"].as_str().unwrap()]));
    }
    assert_eq!(run_in(&b, &["lint"], "").code, 0);
}

#[test]
fn offline_batch_succeeds_locally_and_publishes_on_later_sync() {
    let net = Net::new();
    let a = net.path("a");
    net.offline(&a, true);
    let before = git(&a, &["rev-parse", "HEAD"]);
    let out = ok_stdin(
        &a,
        &["apply"],
        &json!({"changes":[
            {"op":"create","data":{"title":"Synthetic offline ticket"}},
            {"op":"tag","ticket":{"created":0},"data":{"tag":"sample"}}
        ]})
        .to_string(),
    );
    assert_eq!(out["written"], true);
    assert_eq!(out["sync"]["error"]["code"], "fetch-failed");
    assert_eq!(out["tickets"][0]["number"], Value::Null);
    assert_eq!(
        git(
            &a,
            &["rev-list", "--count", &format!("{}..HEAD", before.trim())]
        )
        .trim(),
        "1"
    );
    net.offline(&a, false);
    ok(&a, &["sync"]);
    let b = net.clone_as("b");
    assert_eq!(tickets(&a), tickets(&b));
    assert_eq!(numbers(&b), [1]);
}

/// Every configured checkout belongs to this test's disposable network.
fn configure_checkout(source: &Path, checkout: &Path) {
    assert_disposable(checkout);
    git(
        source,
        &[
            "config",
            "--local",
            "--add",
            "zwanenzang.checkout",
            checkout.to_str().unwrap(),
        ],
    );
}

fn head(p: &Path) -> String {
    git(p, &["rev-parse", "HEAD"]).trim().into()
}

fn checkout_results(out: &Value) -> &Value {
    assert_eq!(out["sync"]["checkouts"]["error"], Value::Null, "{out}");
    &out["sync"]["checkouts"]["results"]
}

#[test]
fn human_checkouts_follow_mutations_explicit_sync_and_batches() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human with spaces");
    let b = net.clone_as("b");
    configure_checkout(&a, &human);
    let initial = head(&human);
    let out = ok(&a, &["create", "Synthetic published ticket"]);
    assert_eq!(
        checkout_results(&out),
        &json!([{
            "path":human, "status":"updated"
        }])
    );
    assert_ne!(head(&human), initial);
    assert_eq!(head(&human), head(&a));
    assert_eq!(out["sync"]["checkouts"]["target"], head(&a));
    assert_eq!(tickets(&human), tickets(&a));
    let fetch_head = std::fs::read(human.join(".git/FETCH_HEAD")).ok();
    let remote_ref = git(&human, &["rev-parse", "origin/main"]);
    // New publications by another writer are received by explicit sync.
    ok(&b, &["create", "Synthetic other writer"]);
    let out = ok(&a, &["sync"]);
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), head(&a));
    assert_eq!(git(&human, &["rev-parse", "origin/main"]), remote_ref);
    assert_eq!(
        std::fs::read(human.join(".git/FETCH_HEAD")).ok(),
        fetch_head
    );
    let out = ok(&a, &["sync"]);
    assert_eq!(checkout_results(&out)[0]["status"], "up-to-date");
    let out = ok_stdin(
        &a,
        &["apply"],
        &json!({"changes":[
            {"op":"create","data":{"title":"Synthetic checkout batch"}}
        ]})
        .to_string(),
    );
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), head(&a));
}

#[test]
fn local_checkouts_use_numbered_head_and_relative_paths() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    git(&a, &["branch", "--unset-upstream"]);
    // Relative to source root, even when CLI starts in a subdirectory.
    git(
        &a,
        &[
            "config",
            "--local",
            "--add",
            "zwanenzang.checkout",
            "../human-test-repo",
        ],
    );
    // Duplicates are reported in configuration order.
    configure_checkout(&a, &human);
    let sub = a.join("sub-test-repo");
    std::fs::create_dir(&sub).unwrap();
    let out = ok(&sub, &["create", "Synthetic local publication"]);
    assert_eq!(out["sync"]["upstream"], Value::Null);
    assert_eq!(out["sync"]["pushed"], false);
    assert_eq!(out["ticket"]["number"], 1);
    assert_eq!(checkout_results(&out)[0]["path"], "../human-test-repo");
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(checkout_results(&out)[1]["status"], "up-to-date");
    assert_eq!(head(&human), head(&a));
    assert_eq!(tickets(&human), tickets(&a));
    assert_eq!(
        git(&net.remote(), &["rev-parse", "main"]).trim(),
        git(&a, &["rev-parse", "HEAD~2"]).trim()
    );
}

#[test]
fn human_work_and_unsafe_repositories_are_skipped_individually() {
    let net = Net::new();
    let a = net.path("a");
    // A tracked supporting file, so tracked edits are separate from untracked work.
    write_file(&a, "docs/notes.md", "Synthetic original\n");
    git(&a, &["add", "docs/notes.md"]);
    git(&a, &["commit", "--quiet", "-m", "add synthetic notes"]);
    git(&a, &["push", "--quiet"]);
    let mut cases = Vec::new();
    for (name, reason) in [
        ("modified", "dirty"),
        ("staged", "dirty"),
        ("untracked", "dirty"),
        ("ignored", "dirty"),
        ("ahead", "not-fast-forward"),
        ("divergent", "not-fast-forward"),
        ("wrong", "wrong-branch"),
        ("ambiguous-branch", "wrong-branch"),
        ("detached", "detached-head"),
        ("operation", "operation-in-progress"),
    ] {
        let p = net.clone_as(name);
        match name {
            "modified" => write_file(&p, "docs/notes.md", "Synthetic unstaged work\n"),
            "staged" => {
                write_file(&p, "docs/notes.md", "Synthetic staged work\n");
                git(&p, &["add", "docs/notes.md"]);
            }
            "untracked" => write_file(&p, "docs/untracked.md", "Synthetic untracked work\n"),
            "ignored" => {
                write_file(&p, ".git/info/exclude", "ignored\n");
                write_file(&p, "ignored", "Synthetic ignored work\n");
            }
            "ahead" | "divergent" => {
                write_file(&p, "docs/local.md", "Synthetic committed work\n");
                git(&p, &["add", "docs/local.md"]);
                git(&p, &["commit", "--quiet", "-m", "human work"]);
            }
            "wrong" => {
                git(&p, &["switch", "--quiet", "-c", "human"]);
            }
            "ambiguous-branch" => {
                // --short HEAD can say heads/main here; compare full refs instead.
                git(&p, &["branch", "heads/main"]);
                git(&p, &["switch", "--quiet", "heads/main"]);
            }
            "detached" => {
                git(&p, &["switch", "--quiet", "--detach"]);
            }
            "operation" => write_file(&p, ".git/MERGE_HEAD", &format!("{}\n", head(&p))),
            _ => unreachable!(),
        }
        configure_checkout(&a, &p);
        let before = head(&p);
        let status = git(
            &p,
            &[
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored",
            ],
        );
        cases.push((p, reason, before, status));
    }
    // No local advance: the two extra human commits are ahead of the target.
    let out = ok(&a, &["sync"]);
    for (i, (_, reason, _, _)) in cases.iter().enumerate() {
        assert_eq!(checkout_results(&out)[i]["reason"], *reason, "{out}");
    }
    let good = net.clone_as("good");
    configure_checkout(&a, &good);
    let out = ok(&a, &["create", "Synthetic safe publication"]);
    for (i, (p, reason, before, status)) in cases.iter().enumerate() {
        let r = &checkout_results(&out)[i];
        assert_eq!(r["status"], "skipped", "{r}");
        assert_eq!(r["reason"], *reason, "{r}");
        assert_eq!(head(p), *before);
        assert_eq!(
            git(
                p,
                &[
                    "status",
                    "--porcelain=v1",
                    "--untracked-files=all",
                    "--ignored"
                ]
            ),
            *status
        );
        assert_eq!(
            read(p, "docs/notes.md"),
            match *reason {
                "dirty" if p == &net.path("modified") => "Synthetic unstaged work\n",
                "dirty" if p == &net.path("staged") => "Synthetic staged work\n",
                _ => "Synthetic original\n",
            }
        );
    }
    assert_eq!(checkout_results(&out)[cases.len()]["status"], "updated");
    assert_eq!(head(&good), head(&a));
    assert_eq!(out["sync"]["error"], Value::Null);
}

#[test]
fn invalid_paths_source_aliases_and_shared_worktrees_are_skipped() {
    let net = Net::new();
    let a = net.path("a");
    let plain = net.path("plain");
    std::fs::create_dir(&plain).unwrap();
    let nested = a.join("nested-test-repo");
    std::fs::create_dir(&nested).unwrap();
    let linked = net.path("linked");
    git(
        &a,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "linked",
            linked.to_str().unwrap(),
        ],
    );
    let alias = net.path("alias");
    std::os::unix::fs::symlink(&a, &alias).unwrap();
    for p in [&plain, &nested, &net.remote(), &a, &alias, &linked] {
        configure_checkout(&a, p);
    }
    let missing = net.path("missing");
    assert_disposable(missing.parent().unwrap());
    git(
        &a,
        &[
            "config",
            "--local",
            "--add",
            "zwanenzang.checkout",
            missing.to_str().unwrap(),
        ],
    );
    git(
        &a,
        &["config", "--local", "--add", "zwanenzang.checkout", ""],
    );
    let out = ok(&a, &["sync"]);
    let reasons: Vec<_> = checkout_results(&out)
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["reason"].as_str().unwrap())
        .collect();
    assert_eq!(
        reasons,
        [
            "not-a-repository",
            "not-a-repository",
            "not-a-repository",
            "source-repository",
            "source-repository",
            "source-repository",
            "not-a-repository",
            "not-a-repository"
        ]
    );
    assert_eq!(out["sync"]["error"], Value::Null);
    assert_eq!(git(&a, &["status", "--porcelain"]), "");
}

#[test]
fn detached_source_does_not_choose_a_human_branch() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    configure_checkout(&a, &human);
    git(&a, &["switch", "--quiet", "--detach"]);
    let initial = head(&human);
    let out = ok(&a, &["create", "Synthetic detached publication"]);
    assert_eq!(checkout_results(&out)[0]["reason"], "source-detached");
    assert_eq!(out["sync"]["checkouts"]["target"], head(&a));
    assert_eq!(head(&human), initial);
}

#[test]
fn failed_fetch_never_uses_cached_refs_or_unpushed_head() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    configure_checkout(&a, &human);
    let initial = head(&human);
    net.offline(&a, true);
    let out = ok(&a, &["create", "Synthetic offline boundary"]);
    assert_eq!(out["sync"]["error"]["code"], "fetch-failed");
    assert_eq!(out["sync"]["checkouts"]["target"], Value::Null);
    assert_eq!(checkout_results(&out)[0]["reason"], "no-published-target");
    assert_eq!(head(&human), initial);
    assert_ne!(head(&a), initial);
    let out = run_in(&a, &["sync"], "");
    assert_eq!(out.code, 1);
    assert_eq!(
        checkout_results(&out.json)[0]["reason"],
        "no-published-target"
    );
    net.offline(&a, false);
    let out = ok(&a, &["sync"]);
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), head(&a));
}

#[test]
fn failed_push_updates_to_fetched_history_without_unpublished_numbers() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    let b = net.clone_as("b");
    configure_checkout(&a, &human);
    ok(&b, &["create", "Synthetic published before refusal"]);
    let published = head(&b);
    write_file(&net.remote(), "hooks/pre-receive", "#!/bin/sh\nexit 1\n");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        net.remote().join("hooks/pre-receive"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let out = ok(&a, &["create", "Synthetic unpublished after refusal"]);
    assert_eq!(out["sync"]["error"]["code"], "push-failed");
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(out["sync"]["checkouts"]["target"], published);
    assert_eq!(head(&human), published);
    assert_ne!(head(&a), published);
    assert_eq!(tickets(&human).as_array().unwrap().len(), 1);
    assert_eq!(out["ticket"]["number"], Value::Null);
    assert_eq!(out["sync"]["numbered"], json!([]));
    std::fs::remove_file(net.remote().join("hooks/pre-receive")).unwrap();
    let out = ok(&a, &["sync"]);
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(tickets(&human), tickets(&a));
}

#[test]
fn rebase_conflict_still_hands_out_only_the_fetched_commit() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    let b = net.clone_as("b");
    configure_checkout(&a, &human);
    for (p, text) in [(&a, "Synthetic A\n"), (&b, "Synthetic B\n")] {
        write_file(p, "docs/notes.md", text);
        git(p, &["add", "docs/notes.md"]);
        git(p, &["commit", "--quiet", "-m", "synthetic notes"]);
    }
    git(&b, &["push", "--quiet"]);
    let published = head(&b);
    let out = ok(&a, &["create", "Synthetic unpushed conflict"]);
    assert_eq!(out["sync"]["error"]["code"], "rebase-conflict");
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), published);
    assert_eq!(read(&human, "docs/notes.md"), "Synthetic B\n");
    assert_eq!(read(&a, "docs/notes.md"), "Synthetic A\n");
    assert_eq!(tickets(&human), json!([]));
}

/// Move the remote branch inside its update hook, after receive-pack has
/// checked the old value. The real ref transaction then loses a push race.
/// This exercises bounded retries without timing or process-global state.
fn install_racing_remote(net: &Net, source_offline_after_race: Option<&Path>) {
    assert_disposable(&net.remote());
    let offline = source_offline_after_race.map_or(String::new(), |source| {
        assert_disposable(source);
        // Test paths are generated by tempfile. Quote shell metacharacters.
        let quoted = format!(
            "'{}'",
            source.join(".git").to_str().unwrap().replace('\'', "'\\''")
        );
        // receive-pack exports GIT_DIR=.; explicitly select the source config.
        format!("git --git-dir={quoted} config remote.origin.url ../gone-test-repo || exit 1\n")
    });
    write_file(
        &net.remote(),
        "hooks/update",
        &format!(
            r#"#!/bin/sh
ref=$1
old=$2
tree=$(git rev-parse "$old^{{tree}}") || exit 1
next=$(printf 'Synthetic racing publication\n' | git -c user.name=Test -c user.email=test@example.invalid commit-tree "$tree" -p "$old") || exit 1
git update-ref "$ref" "$next" "$old" || exit 1
{offline}exit 0
"#
        ),
    );
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        net.remote().join("hooks/update"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
}

#[test]
fn exhausted_retries_use_last_fetched_commit_not_unpushed_head() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    configure_checkout(&a, &human);
    install_racing_remote(&net, None);
    let out = ok(&a, &["create", "Synthetic bounded retry boundary"]);
    assert_eq!(out["sync"]["error"]["code"], "push-rejected", "{out}");
    assert_eq!(out["sync"]["numbered"], json!([]));
    assert_eq!(out["ticket"]["number"], Value::Null);
    let target = out["sync"]["checkouts"]["target"].as_str().unwrap();
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), target);
    // The final rejected push advanced the remote once more after our fetch.
    assert_eq!(git(&net.remote(), &["rev-parse", "main~1"]).trim(), target);
    assert_eq!(
        git(
            &net.remote(),
            &["rev-list", "--count", &format!("{target}~4..main")]
        )
        .trim(),
        "5"
    );
    assert_eq!(tickets(&human), json!([]));
    assert_ne!(head(&a), target);
    std::fs::remove_file(net.remote().join("hooks/update")).unwrap();
    let out = ok(&a, &["sync"]);
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(tickets(&human), tickets(&a));
}

#[test]
fn failed_retry_fetch_keeps_the_earlier_successful_observation() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    let b = net.clone_as("b");
    configure_checkout(&a, &human);
    ok(&b, &["create", "Synthetic publication before retry"]);
    let published = head(&b);
    install_racing_remote(&net, Some(&a));
    let out = ok(&a, &["create", "Synthetic retry fetch boundary"]);
    assert_eq!(out["sync"]["error"]["code"], "fetch-failed", "{out}");
    assert_eq!(out["sync"]["checkouts"]["target"], published);
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), published);
    assert_eq!(tickets(&human).as_array().unwrap().len(), 1);
    assert_eq!(out["ticket"]["number"], Value::Null);
}

#[test]
fn missing_remote_branch_and_failed_push_provide_no_target() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    configure_checkout(&a, &human);
    git(
        &a,
        &["config", "--local", "branch.main.merge", "refs/heads/new"],
    );
    write_file(&net.remote(), "hooks/pre-receive", "#!/bin/sh\nexit 1\n");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        net.remote().join("hooks/pre-receive"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let initial = head(&human);
    let out = ok(&a, &["create", "Synthetic new upstream failure"]);
    assert_eq!(out["sync"]["error"]["code"], "push-failed");
    assert_eq!(out["sync"]["checkouts"]["target"], Value::Null);
    assert_eq!(checkout_results(&out)[0]["reason"], "no-published-target");
    assert_eq!(head(&human), initial);
    std::fs::remove_file(net.remote().join("hooks/pre-receive")).unwrap();
    let out = ok(&a, &["sync"]);
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), head(&a));
    assert_eq!(
        git(&net.remote(), &["rev-parse", "new"]).trim(),
        head(&human)
    );
}

#[test]
fn ambiguous_short_branch_name_still_uses_its_configured_upstream() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    configure_checkout(&a, &human);
    // A tag named main makes `symbolic-ref --short HEAD` return heads/main.
    git(&a, &["tag", "main"]);
    net.offline(&a, true);
    let before = head(&human);
    let out = ok(&a, &["create", "Synthetic ambiguous ref boundary"]);
    assert_eq!(out["sync"]["upstream"], "origin/main");
    assert_eq!(out["sync"]["error"]["code"], "fetch-failed");
    assert_eq!(checkout_results(&out)[0]["reason"], "no-published-target");
    assert_eq!(head(&human), before);
}

#[test]
fn checkout_git_failure_does_not_block_other_checkouts_or_sync() {
    let net = Net::new();
    let a = net.path("a");
    let locked = net.clone_as("locked");
    let good = net.clone_as("good");
    configure_checkout(&a, &locked);
    configure_checkout(&a, &good);
    let before = head(&locked);
    write_file(&locked, ".git/index.lock", "Synthetic lock\n");
    let out = ok(&a, &["create", "Synthetic locked index boundary"]);
    assert_eq!(out["sync"]["error"], Value::Null);
    assert_eq!(checkout_results(&out)[0]["reason"], "update-failed");
    assert_eq!(checkout_results(&out)[1]["status"], "updated");
    assert_eq!(head(&locked), before);
    assert_eq!(read(&locked, ".git/index.lock"), "Synthetic lock\n");
    assert_eq!(head(&good), head(&a));
}

#[test]
fn human_hooks_and_autostash_cannot_modify_checkout_updates() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    configure_checkout(&a, &human);
    write_file(
        &human,
        ".git/hooks/post-merge",
        "#!/bin/sh\nprintf 'hook ran' > hook-ran\nexit 1\n",
    );
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(
        human.join(".git/hooks/post-merge"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    git(&human, &["config", "--local", "merge.autostash", "true"]);
    let out = ok(&a, &["create", "Synthetic hook-free update"]);
    assert_eq!(checkout_results(&out)[0]["status"], "updated");
    assert_eq!(head(&human), head(&a));
    assert!(!human.join("hook-ran").exists());
    assert_eq!(git(&human, &["stash", "list"]), "");
    let before = head(&human);
    write_file(&human, "zwanenzang.toml", "Synthetic human edit\n");
    let out = ok(&a, &["create", "Synthetic dirty autostash boundary"]);
    assert_eq!(checkout_results(&out)[0]["reason"], "dirty");
    assert_eq!(head(&human), before);
    assert_eq!(read(&human, "zwanenzang.toml"), "Synthetic human edit\n");
    assert_eq!(git(&human, &["stash", "list"]), "");
}

#[test]
fn command_scope_checkout_configuration_is_not_a_registry() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    let before = head(&human);
    let out = run_in_env(
        &a,
        &["create", "Synthetic local configuration only"],
        "",
        &[
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", "zwanenzang.checkout"),
            ("GIT_CONFIG_VALUE_0", human.to_str().unwrap()),
        ],
    );
    assert_eq!(out.code, 0, "{}", out.json);
    assert_eq!(checkout_results(&out.json), &json!([]));
    assert_eq!(head(&human), before);
}

#[test]
fn unborn_human_repository_is_not_given_an_initial_branch() {
    let net = Net::new();
    let a = net.path("a");
    git(net.dir.path(), &["init", "--quiet", "unborn-test-repo"]);
    let unborn = net.path("unborn");
    configure_checkout(&a, &unborn);
    let out = ok(&a, &["sync"]);
    assert_eq!(checkout_results(&out)[0]["reason"], "unborn-head");
    assert_eq!(
        git(&unborn, &["symbolic-ref", "HEAD"]).trim(),
        "refs/heads/main"
    );
    assert_eq!(git(&unborn, &["for-each-ref", "--format=%(refname)"]), "");
}

#[test]
fn local_transfer_cannot_be_rewritten_to_a_network_transport() {
    let net = Net::new();
    let a = net.path("a");
    let human = net.clone_as("human");
    configure_checkout(&a, &human);
    let before = head(&human);
    git(
        &human,
        &[
            "config",
            "--local",
            "url.ssh://invalid.example/.insteadOf",
            a.to_str().unwrap(),
        ],
    );
    git(
        &human,
        &["config", "--local", "protocol.ssh.allow", "always"],
    );
    let out = ok(&a, &["create", "Synthetic transport boundary"]);
    assert_eq!(out["sync"]["pushed"], true);
    assert_eq!(checkout_results(&out)[0]["reason"], "update-failed");
    assert!(
        checkout_results(&out)[0]["message"]
            .as_str()
            .unwrap()
            .contains("transport 'ssh' not allowed"),
        "{out}"
    );
    assert_eq!(head(&human), before);
}
