#!/usr/bin/env python3
"""Fail when HEAD changes the package's sources without a version bump.

Usage: check-version-bump.py BASE

BASE is the branch a pull request targets, e.g. `origin/master`. If any
path in PACKAGE_SOURCES differs between HEAD and its merge base with
BASE, the `[package] version` in HEAD's Cargo.toml must be strictly
greater, by semver precedence, than the one in BASE's Cargo.toml as it
is now, not at the merge base.

The result is only as current as the BASE tip it ran against. Two
branches that bump to the same version make identical edits, which git
merges cleanly, and the forge does not re-run a pull request's check when
its target moves; so a green result goes stale once BASE moves. A pull
request whose target moved must be rebased, or have this check re-run,
before it is merged. Branch protection that blocks merging an outdated
pull request, with this check required, does that automatically.

Runs git in the current directory and changes nothing.
"""

import re
import subprocess
import sys
import tomllib

# The package's source fileset in nix/_packages/zwanenzang.nix; keep the
# two lists the same.
PACKAGE_SOURCES = [
    "Cargo.toml",
    "Cargo.lock",
    "build.rs",
    "docs/agent-hooks",
    "site",
    "src",
    "tests",
]

SEMVER = re.compile(
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def git(*args):
    return subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    ).stdout


def package_version(rev):
    return tomllib.loads(git("show", f"{rev}:Cargo.toml"))["package"]["version"]


def precedence(version):
    """A sort key for `version` that orders it by semver precedence."""
    m = SEMVER.fullmatch(version)
    if not m:
        raise SystemExit(f"not a semver version: {version!r}")
    core = tuple(int(part) for part in m.group(1, 2, 3))
    if m.group(4) is None:
        # A release ranks above every pre-release of the same core.
        return core, (1,)
    identifiers = [
        (0, int(i), "") if i.isdigit() else (1, 0, i) for i in m.group(4).split(".")
    ]
    return core, (0, identifiers)


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__.split("\n\n")[1])
    base = argv[1]
    merge_base = git("merge-base", base, "HEAD").strip()
    changed = git("diff", "--name-only", merge_base, "HEAD", "--", *PACKAGE_SOURCES).splitlines()
    if not changed:
        print(f"no package sources changed since {base}; no bump needed")
        return 0
    head, target = package_version("HEAD"), package_version(base)
    if precedence(head) > precedence(target):
        print(f"package sources changed; version {head} is above {base}'s {target}")
        return 0
    print(
        f"package sources changed but version {head} is not above {base}'s {target};"
        " bump [package] version in Cargo.toml (and Cargo.lock). Changed:",
        *changed,
        sep="\n  ",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
