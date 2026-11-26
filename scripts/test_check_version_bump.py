#!/usr/bin/env python3
"""Tests for check-version-bump.py against disposable repositories.

Usage: test_check_version_bump.py PACKAGE_SOURCE_DIR [unittest options]

PACKAGE_SOURCE_DIR is the package's `src`, the fileset the flake builds;
the script's PACKAGE_SOURCES must name exactly what it holds.

Every repository a test touches is a directory under the system temporary
directory whose name ends in `-test-repo`; `disposable` checks both
markers before anything opens or writes to it.
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-version-bump.py")
PACKAGE_SOURCE_DIR = None  # set from the command line in main

# Importing the script must not leave a __pycache__ next to it.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("check_version_bump", SCRIPT)
check_version_bump = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_version_bump)


def disposable(path):
    """`path`, refusing anything without both disposable markers."""
    real = os.path.realpath(path)
    tmp = os.path.realpath(tempfile.gettempdir())
    if not real.startswith(tmp + os.sep) or not os.path.basename(real).endswith("-test-repo"):
        raise AssertionError(f"refusing non-disposable repository: {path}")
    return real


def cargo_toml(version):
    return f'[package]\nname = "example"\nversion = "{version}"\n'


class Repository:
    """A repository whose `master` holds a package at 0.1.0."""

    def __init__(self):
        self.root = tempfile.mkdtemp(suffix="-test-repo")
        self.env = {
            k: v for k, v in os.environ.items() if not k.startswith("GIT_")
        }
        self.env.update(
            HOME=self.root,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="test",
            GIT_AUTHOR_EMAIL="test@example.invalid",
            GIT_COMMITTER_NAME="test",
            GIT_COMMITTER_EMAIL="test@example.invalid",
        )
        self.git("init", "--quiet", "--initial-branch", "master")
        self.write("Cargo.toml", cargo_toml("0.1.0"))
        self.write("src/lib.rs", "")
        self.write("README.md", "")
        self.commit("initial")
        self.git("switch", "--quiet", "--create", "feature")

    def cleanup(self):
        shutil.rmtree(disposable(self.root))

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", disposable(self.root), *args],
            env=self.env, check=True, capture_output=True, text=True,
        ).stdout

    def write(self, name, text):
        path = os.path.join(disposable(self.root), name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "--quiet", "--message", message)

    def check(self, base="master"):
        return subprocess.run(
            [sys.executable, "-I", SCRIPT, base],
            cwd=disposable(self.root), env=self.env, capture_output=True, text=True,
        )


class CheckVersionBumpTest(unittest.TestCase):
    def setUp(self):
        self.repo = Repository()
        self.addCleanup(self.repo.cleanup)

    def assertChecks(self, returncode):
        out = self.repo.check()
        self.assertEqual(out.returncode, returncode, out.stdout + out.stderr)
        return out

    def test_a_source_change_without_a_bump_fails(self):
        self.repo.write("src/lib.rs", "pub fn f() {}\n")
        self.repo.commit("change")
        out = self.assertChecks(1)
        self.assertIn("src/lib.rs", out.stderr)

    def test_a_change_outside_the_sources_needs_no_bump(self):
        self.repo.write("README.md", "more\n")
        self.repo.commit("docs")
        self.assertChecks(0)

    def test_a_source_change_with_a_bump_passes(self):
        self.repo.write("src/lib.rs", "pub fn f() {}\n")
        self.repo.write("Cargo.toml", cargo_toml("0.1.1"))
        self.repo.commit("change")
        self.assertChecks(0)

    def test_a_lower_version_fails(self):
        self.repo.write("Cargo.toml", cargo_toml("0.0.9"))
        self.repo.commit("downgrade")
        self.assertChecks(1)

    def test_the_target_tip_counts_not_the_merge_base(self):
        self.repo.write("src/lib.rs", "pub fn f() {}\n")
        self.repo.write("Cargo.toml", cargo_toml("0.2.0"))
        self.repo.commit("feature")
        self.repo.git("switch", "--quiet", "master")
        self.repo.write("src/other.rs", "")
        self.repo.write("Cargo.toml", cargo_toml("0.2.0"))
        self.repo.commit("concurrent")
        self.repo.git("switch", "--quiet", "feature")
        self.assertChecks(1)
        self.repo.write("Cargo.toml", cargo_toml("0.3.0"))
        self.repo.commit("bump again")
        self.assertChecks(0)

    def test_changes_already_on_the_target_are_not_counted(self):
        self.repo.git("switch", "--quiet", "master")
        self.repo.write("src/lib.rs", "pub fn f() {}\n")
        self.repo.write("Cargo.toml", cargo_toml("0.2.0"))
        self.repo.commit("on master")
        self.repo.git("switch", "--quiet", "feature")
        self.repo.git("merge", "--quiet", "master")
        self.repo.write("README.md", "more\n")
        self.repo.commit("docs")
        self.assertChecks(0)

    def test_precedence_follows_semver(self):
        p = check_version_bump.precedence
        for lower, higher in [
            ("0.9.0", "0.10.0"),
            ("0.1.9", "0.2.0"),
            ("1.0.0-rc.1", "1.0.0"),
            ("1.0.0-alpha", "1.0.0-alpha.1"),
            ("1.0.0-alpha.2", "1.0.0-alpha.10"),
            ("1.0.0-alpha.1", "1.0.0-alpha.beta"),
            ("1.0.0-beta", "1.0.0-rc.1"),
        ]:
            self.assertLess(p(lower), p(higher), (lower, higher))
        self.assertEqual(p("1.0.0+a"), p("1.0.0+b"))
        with self.assertRaises(SystemExit):
            p("1.0")

    def test_package_sources_match_the_flake_fileset(self):
        listed = set(check_version_bump.PACKAGE_SOURCES)
        present = set()
        for directory, dirs, files in os.walk(PACKAGE_SOURCE_DIR):
            relative = os.path.relpath(directory, PACKAGE_SOURCE_DIR)
            for name in dirs + files:
                path = os.path.normpath(os.path.join(relative, name))
                if path in listed:
                    present.add(path)
                    if name in dirs:
                        dirs.remove(name)
                elif name in files:
                    self.fail(f"{path} is in the package but not in PACKAGE_SOURCES")
        self.assertEqual(present, listed)


def main():
    global PACKAGE_SOURCE_DIR
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    PACKAGE_SOURCE_DIR = os.path.abspath(sys.argv.pop(1))
    unittest.main()


if __name__ == "__main__":
    main()
