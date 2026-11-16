#!/usr/bin/env python3
"""Give every event of a zwanenzang tracker an identity, once, by hand.

Events written before identities carry no `as` envelope field and resolve
to their writer's declared name. This adds `as` to each such event in
`events/*.jsonl`, in place: the agent identity for the listed operations
(by default `comment`), the human identity for everything else. It looks
at nothing but the operation. Events that already have `as` are left as
they are. The tracker configuration gets an `actors` list naming both
identities when it has none; without one the tool refuses new writes.

It changes files in the work tree only and commits nothing, so publishing
the result is an ordinary commit and a normal push. It holds the clone's
lock, the one the CLI takes for every write, from before it checks the
work tree is clean until the files are written, so the CLI cannot append
to this clone meanwhile. Other clones are not stopped by it: an event
another clone appends to a log rewritten here, and pushes only afterwards,
rebases without a conflict, but union merge then keeps both the old and
the rewritten lines, and replay drops both as duplicate ids. So:

  1. Pause every writer, human and agent, until the migration is pushed,
     and sync every clone so that none holds unpushed events.
  2. Bring this checkout up to date with `zz sync`.
  3. Run this script on it, then review `git diff`.
  4. Commit the result and push it normally.
  5. Other clones sync as usual; writers resume.
  6. Run `zz lint` afterwards; its `skipped` list names any duplicate ids.

Clients' read cursors reset once.

Usage: assign-identities.py [options] TRACKER_DIR
"""

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile

CONFIG_FILE = "zwanenzang.toml"
# The CLI's clone lock, `LOCK_FILE` in src/store.rs, in the git directory.
LOCK_FILE = "zwanenzang.lock"
NAME = re.compile(r"[A-Za-z0-9_-]{1,64}")
# The envelope's writer, as the tool writes it: `"actor":"<ULID>"`.
ACTOR_FIELD = re.compile(r'"actor"\s*:\s*"[0-9A-HJKMNP-TV-Z]{26}"')
ACTORS_KEY = re.compile(r"^\s*actors\s*=")
TABLE_HEADER = re.compile(r"^\s*\[")


def fail(message):
    print(f"assign-identities: {message}", file=sys.stderr)
    sys.exit(1)


def git(root, *args):
    result = subprocess.run(
        ["git", "-C", root, *args], capture_output=True, text=True
    )
    if result.returncode != 0:
        fail(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def check_top(root):
    if git(root, "rev-parse", "--show-toplevel").strip() != os.path.realpath(root):
        fail(f"{root} is not the top of a git work tree")


def lock_clone(root):
    """Takes the clone lock as `lock_repo` in src/store.rs does: an
    exclusive `flock` on the lock file in the git directory, created if
    missing and never truncated, blocking until it is free. It is held
    until the returned descriptor is closed or the process exits."""
    path = os.path.join(git(root, "rev-parse", "--absolute-git-dir").strip(), LOCK_FILE)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o666)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"assign-identities: waiting for {path}", file=sys.stderr)
        fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def check_clean(root):
    dirty = git(root, "status", "--porcelain", "--untracked-files=all")
    if dirty:
        fail(f"{root} has uncommitted changes; commit or remove them first:\n{dirty}")


def with_identity(line, identity):
    """`line` with `"as":identity` after its `actor`, or None if it has one.

    Inserts the field into the text, so every other byte stays as it was,
    and checks the result parses to the same object plus `as`. Falls back
    to re-serialising the object in its own key order when the text is not
    in the shape the tool writes."""
    event = json.loads(line)
    if not isinstance(event, dict) or "actor" not in event:
        raise ValueError("not an event envelope")
    if "as" in event:
        return None
    want = {}
    for key, value in event.items():
        want[key] = value
        if key == "actor":
            want["as"] = identity
    match = ACTOR_FIELD.search(line)
    if match:
        candidate = (
            line[: match.end()]
            + ',"as":'
            + json.dumps(identity, ensure_ascii=False)
            + line[match.end() :]
        )
        try:
            parsed = json.loads(candidate)
        except ValueError:
            parsed = None
        if parsed == want and list(parsed) == list(want):
            return candidate
    return json.dumps(want, ensure_ascii=False, separators=(",", ":"))


def rewrite_log(path, human, agent, agent_ops, dry_run):
    """Rewrites one log; returns (human, agent, already, skipped) counts."""
    with open(path, "rb") as f:
        data = f.read()
    counts = {"human": 0, "agent": 0, "already": 0, "skipped": 0}
    out = []
    for number, raw in enumerate(data.split(b"\n"), start=1):
        # A blank line, including after the final newline, stays as it is.
        if not raw.strip():
            out.append(raw)
            continue
        try:
            line = raw.decode("utf-8")
            event = json.loads(line)
            op = event.get("op") if isinstance(event, dict) else None
            if not isinstance(op, str):
                raise ValueError(f"operation {op!r} is not a string")
            identity = agent if op in agent_ops else human
            new = with_identity(line, identity)
        except ValueError as e:
            # Replay skips such a line as malformed; leave it for lint.
            print(f"{path}:{number}: left as it is: {e}", file=sys.stderr)
            counts["skipped"] += 1
            out.append(raw)
            continue
        if new is None:
            counts["already"] += 1
            out.append(raw)
            continue
        counts["agent" if identity == agent else "human"] += 1
        out.append(new.encode("utf-8"))
    if not dry_run and (counts["human"] or counts["agent"]):
        replace(path, b"\n".join(out))
    return counts


def replace(path, data):
    directory = os.path.dirname(path)
    mode = os.stat(path).st_mode
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".assign-identities-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def top_level_actors(text):
    """The `actors` list in the configuration's top-level table: a list,
    None when there is no such key, or False when it cannot be read."""
    try:
        import tomllib
    except ImportError:  # Python before 3.11: fall back to a line check.
        for line in text.splitlines():
            if TABLE_HEADER.match(line):
                break
            if ACTORS_KEY.match(line):
                return False
        return None
    try:
        actors = tomllib.loads(text).get("actors")
    except tomllib.TOMLDecodeError as e:
        fail(f"{CONFIG_FILE} does not parse: {e}")
    return actors


def config_with_actors(text, names):
    """`text` with an `actors` key before the first table, so it lands in
    the top-level table rather than in `[priority]` or a `[repos.*]`."""
    block = (
        "# Identities a write may name with --actor-name.\n"
        f"actors = {json.dumps(names, ensure_ascii=False)}\n"
        "\n"
    )
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if TABLE_HEADER.match(line):
            # Keep the comment lines just above the table with it.
            while i > 0 and lines[i - 1].lstrip().startswith("#"):
                i -= 1
            return "".join(lines[:i]) + block + "".join(lines[i:])
    if text and not text.endswith("\n"):
        text += "\n"
    return text + "\n" + block.rstrip("\n") + "\n"


def main():
    parser = argparse.ArgumentParser(
        description="Add an `as` identity to every zwanenzang event lacking one.",
        epilog="Commits nothing. Pause every writer and push every clone first; "
        "publish the result as an ordinary commit and push, then run `zz lint`. "
        "The procedure is in this script's header.",
    )
    parser.add_argument("tracker", help="the tracker checkout (holding zwanenzang.toml)")
    parser.add_argument(
        "--human", default="binarin", help="identity of every other event (default: %(default)s)"
    )
    parser.add_argument(
        "--agent", default="agent", help="identity of the agent operations (default: %(default)s)"
    )
    parser.add_argument(
        "--agent-op",
        action="append",
        metavar="OP",
        help="an operation written as the agent identity; repeatable "
        "(default: comment)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="report the counts, change nothing"
    )
    args = parser.parse_args()
    agent_ops = set(args.agent_op or ["comment"])
    for name in (args.human, args.agent):
        if not NAME.fullmatch(name):
            fail(f"identity {name!r} must be 1-64 of A-Z a-z 0-9 _ -")
    if args.human == args.agent:
        fail("--human and --agent must differ")

    root = os.path.realpath(args.tracker)
    config_path = os.path.join(root, CONFIG_FILE)
    if not os.path.isfile(config_path):
        fail(f"no {CONFIG_FILE} in {root}")
    check_top(root)
    lock = lock_clone(root)
    check_clean(root)

    with open(config_path, encoding="utf-8") as f:
        config = f.read()
    actors = top_level_actors(config)
    if actors is False:
        fail(f"{CONFIG_FILE} has an `actors` key; check it names both identities by hand")
    if actors is not None:
        missing = [n for n in (args.human, args.agent) if n not in actors]
        if missing:
            fail(f"{CONFIG_FILE} `actors` does not list {', '.join(missing)}; add them first")

    events = os.path.join(root, "events")
    logs = sorted(
        os.path.join(events, n)
        for n in (os.listdir(events) if os.path.isdir(events) else [])
        if n.endswith(".jsonl")
    )
    total = {"human": 0, "agent": 0, "already": 0, "skipped": 0}
    for path in logs:
        for key, n in rewrite_log(path, args.human, args.agent, agent_ops, args.dry_run).items():
            total[key] += n

    if actors is None:
        new_config = config_with_actors(config, [args.human, args.agent])
        try:
            import tomllib

            if tomllib.loads(new_config).get("actors") != [args.human, args.agent]:
                fail(f"could not add `actors` to {CONFIG_FILE}; add it by hand")
        except ImportError:
            pass
        if not args.dry_run:
            replace(config_path, new_config.encode("utf-8"))
    os.close(lock)

    verb = "would add" if args.dry_run else "added"
    print(
        f"{verb} `as` to {total['human'] + total['agent']} events in {len(logs)} logs: "
        f"{total['human']} {args.human}, {total['agent']} {args.agent}; "
        f"{total['already']} already had one, {total['skipped']} unreadable lines left alone"
    )
    if actors is None:
        print(f"{verb} actors = [{args.human!r}, {args.agent!r}] to {CONFIG_FILE}")
    if not args.dry_run:
        print(
            "nothing is committed; review `git diff`, commit it and push normally "
            "while writers are still paused, then run `zz lint`"
        )


if __name__ == "__main__":
    main()
