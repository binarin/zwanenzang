#!/usr/bin/env python3
"""Tests for assign-identities.py against disposable trackers.

Usage: test_assign_identities.py ZWANENZANG_BINARY [unittest options]

Every repository a test touches lives in its own directory under the
system temporary directory whose name ends in `-test-repo`; `disposable`
checks both markers before anything opens, writes to or pushes from it.
"""

import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assign-identities.py")
CLI = None  # set from the command line in main


def disposable(path):
    """`path`, refusing anything without both disposable markers."""
    real = os.path.realpath(path)
    tmp = os.path.realpath(tempfile.gettempdir())
    if not real.startswith(tmp + os.sep) or not os.path.basename(real).endswith("-test-repo"):
        raise AssertionError(f"refusing non-disposable repository: {path}")
    return real


def environment(home):
    env = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith("GIT_") and k != "XDG_DATA_HOME"
    }
    env.update(
        HOME=home,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_AUTHOR_NAME="test",
        GIT_AUTHOR_EMAIL="test@example.invalid",
        GIT_COMMITTER_NAME="test",
        GIT_COMMITTER_EMAIL="test@example.invalid",
    )
    return env


class Tracker:
    """A tracker clone with a bare remote, in one disposable directory."""

    def __init__(self):
        self.base = tempfile.mkdtemp(suffix="-test-repo")
        self.env = environment(self.base)
        self.remote = os.path.join(disposable(self.base), "remote-test-repo")
        self.root = os.path.join(self.base, "tracker-test-repo")
        self.git_in(self.base, "init", "--quiet", "--bare", disposable(self.remote))
        out = self.cli(
            "--actor-name", "tester", "init", self.root,
            "--remote", f"{self.remote}?ref=main", "--prefix", "ZZ", "--name", "Test",
            directory=self.base,
        )
        assert out.returncode == 0, out.stdout + out.stderr

    def cleanup(self):
        shutil.rmtree(disposable(self.base))

    def git_in(self, directory, *args):
        disposable(directory)
        return subprocess.run(
            ["git", "-C", directory, *args],
            env=self.env, check=True, capture_output=True, text=True,
        ).stdout

    def git(self, *args):
        return self.git_in(self.root, *args)

    def cli(self, *args, directory=None):
        directory = directory or self.root
        disposable(directory)
        return subprocess.run(
            [CLI, "-C", directory, *args], env=self.env, capture_output=True, text=True
        )

    def ok(self, *args):
        out = self.cli(*args)
        assert out.returncode == 0, out.stdout + out.stderr
        return json.loads(out.stdout)

    def script(self, *args):
        disposable(self.root)
        return subprocess.run(
            [sys.executable, "-I", SCRIPT, *args, self.root],
            env=self.env, capture_output=True, text=True,
        )

    def path(self, name):
        return os.path.join(disposable(self.root), name)

    def read(self, name):
        with open(self.path(name), encoding="utf-8") as f:
            return f.read()

    def write(self, name, text):
        with open(self.path(name), "w", encoding="utf-8") as f:
            f.write(text)

    def logs(self):
        events = self.path("events")
        return {n: self.read(os.path.join("events", n)) for n in sorted(os.listdir(events))}

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message)

    def lock_path(self):
        return os.path.join(self.git("rev-parse", "--absolute-git-dir").strip(), "zwanenzang.lock")

    def make_old(self):
        """Turns the tracker into one written before identities: no `as` on
        any event and no `actors` list, committed."""
        for name, text in self.logs().items():
            self.write(os.path.join("events", name), text.replace(',"as":"tester"', ""))
        config = self.read("zwanenzang.toml")
        self.write(
            "zwanenzang.toml",
            "".join(l for l in config.splitlines(keepends=True) if not l.startswith("actors =")),
        )
        self.commit("events from before identities")


class AssignIdentitiesTest(unittest.TestCase):
    def setUp(self):
        self.t = Tracker()
        self.addCleanup(self.t.cleanup)
        ticket = self.t.ok("--actor-name", "tester", "create", "First")["ticket"]["id"]
        self.t.ok("--actor-name", "tester", "comment", ticket, "a comment")
        self.t.ok("--actor-name", "tester", "tag", ticket, "seen")
        self.ticket = ticket

    def test_migrates_old_events_and_the_cli_accepts_the_result(self):
        t = self.t
        t.make_old()
        self.assertNotIn('"as":', "".join(t.logs().values()))
        refused = t.cli("--actor-name", "agent", "comment", self.ticket, "too early")
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(json.loads(refused.stdout)["error"]["code"], "actors-not-configured")
        before = t.logs()

        dry = t.script("--human", "tester", "--dry-run")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("would add", dry.stdout)
        self.assertEqual(t.logs(), before)
        self.assertEqual(t.git("status", "--porcelain"), "")

        out = t.script("--human", "tester")
        self.assertEqual(out.returncode, 0, out.stderr)
        after = t.logs()
        for name, text in before.items():
            lines, new = text.splitlines(), after[name].splitlines()
            self.assertEqual(len(lines), len(new))
            for old, line in zip(lines, new):
                event = json.loads(old)
                want = "agent" if event["op"] == "comment" else "tester"
                # Only the field is inserted; every other byte stays.
                self.assertEqual(line.replace(f',"as":"{want}"', "", 1), old)
                self.assertEqual(json.loads(line)["as"], want)
        self.assertIn('\nactors = ["tester", "agent"]\n', t.read("zwanenzang.toml"))

        t.commit("assign identities")
        lint = t.ok("lint")
        self.assertTrue(lint["ok"], lint)
        written = t.ok("--actor-name", "agent", "comment", self.ticket, "after")
        self.assertEqual(written["event"]["as"], "agent")

        # A second run finds nothing to do.
        again = t.script("--human", "tester")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("added `as` to 0 events", again.stdout)
        self.assertEqual(t.git("status", "--porcelain"), "")

    def test_refuses_a_dirty_tree(self):
        t = self.t
        t.make_old()
        t.write("stray", "x\n")
        before = t.logs()
        out = t.script("--human", "tester")
        self.assertEqual(out.returncode, 1)
        self.assertIn("uncommitted changes", out.stderr)
        self.assertEqual(t.logs(), before)

    def test_names_must_match_the_vocabulary_format_exactly(self):
        t = self.t
        t.make_old()
        for name in ("agent\n", "two words", "", "a" * 65):
            out = t.script("--agent", name)
            self.assertEqual(out.returncode, 1, name)
            self.assertIn("must be 1-64 of", out.stderr)
        self.assertEqual(t.git("status", "--porcelain"), "")

    def test_non_string_operations_are_left_alone(self):
        t = self.t
        t.make_old()
        name, text = next(iter(t.logs().items()))
        writer = json.loads(text.splitlines()[0])["actor"]
        odd = [
            json.dumps({"id": "01M6Y59XPNBPDNXM61N9YN9G5A", "actor": writer, "op": []}),
            json.dumps({"id": "01M6Y59XPNBPDNXM61N9YN9G5B", "actor": writer, "op": {}}),
            json.dumps({"id": "01M6Y59XPNBPDNXM61N9YN9G5C", "actor": writer}),
        ]
        t.write(os.path.join("events", name), text + "\n".join(odd) + "\n")
        t.commit("malformed lines")
        out = t.script("--human", "tester")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("3 unreadable lines left alone", out.stdout)
        lines = t.logs()[name].splitlines()
        self.assertEqual(lines[-3:], odd)
        self.assertTrue(all('"as":' in l for l in lines[:-3]))

    def hold_lock(self):
        fd = os.open(self.t.lock_path(), os.O_WRONLY | os.O_CREAT, 0o666)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd

    def wait_blocked(self, process):
        time.sleep(1)
        self.assertIsNone(process.poll(), "did not wait for the clone lock")

    def test_the_clone_lock_is_the_one_the_cli_takes(self):
        t = self.t
        fd = self.hold_lock()
        try:
            disposable(t.root)
            write = subprocess.Popen(
                [CLI, "-C", t.root, "--actor-name", "tester", "tag", self.ticket, "late"],
                env=t.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            self.wait_blocked(write)
        finally:
            os.close(fd)
        _, stderr = write.communicate(timeout=30)
        self.assertEqual(write.returncode, 0, stderr)

    def test_waits_for_the_clone_lock_before_reading(self):
        t = self.t
        t.make_old()
        fd = self.hold_lock()
        try:
            disposable(t.root)
            run = subprocess.Popen(
                [sys.executable, "-I", SCRIPT, "--human", "tester", t.root],
                env=t.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            self.wait_blocked(run)
            # A change made while it waits counts: it checks after locking.
            t.write("stray", "x\n")
        finally:
            os.close(fd)
        _, stderr = run.communicate(timeout=30)
        self.assertEqual(run.returncode, 1)
        self.assertIn("waiting for", stderr)
        self.assertIn("uncommitted changes", stderr)
        self.assertNotIn('"as":', "".join(t.logs().values()))


def main():
    global CLI
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    CLI = os.path.abspath(sys.argv.pop(1))
    unittest.main()


if __name__ == "__main__":
    main()
