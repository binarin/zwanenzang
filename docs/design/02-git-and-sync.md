# Git, sync and compartments

## The CLI owns the clone

A tracker clone is written only by `zwanenzang`. Humans and agents never edit
`events/` or `blobs/` by hand. Supporting files under `docs/` are ordinary
files and may be edited directly; they are the one place where ordinary git
merge applies, and they are text humans read anyway.

The CLI shells out to the real `git` binary. No git library.

Every mutating command does, under an exclusive `flock` on a lock file in the
clone's git directory:

1. append the event line(s) to this actor's log, write any new blobs
2. `git add` and `git commit`
3. if a remote is configured and reachable: fetch, rebase, push, retry on
   rejection a bounded number of times

Rebase cannot conflict on `events/*.jsonl` because of union merge, and cannot
conflict on `blobs/` because names are content hashes. Only `docs/` can
conflict, and that is reported, not resolved.

A read-only command (query, render, lint) takes no lock and does not fetch
unless asked.

## Offline

Appends never need the network. When the remote is unreachable, the commit
stays local and the next mutating or explicit `sync` command pushes it. Days
of offline work merge the same as seconds.

The one thing that needs the network is number assignment. Publishing is the
moment a `number` event is written, after a successful fetch. Offline tickets
have no number and display their short ULID until then.

## Actor identity

An actor id is a ULID created on first use in a clone and stored in that
clone's `.git/config` under `zwanenzang.actor`. It is per clone, so the same
human on two machines is two actors, which is what makes per-actor logs safe
without coordination. The display name is declared by an `actor` event and
may be the same on both machines.

Nothing about identity lives in the home directory.

## Remotes

A tracker's sync transport is whatever its git remote is: a forge over HTTPS
or SSH, a bare repository reached over SSH, a bare repository on the same
laptop, or no remote at all. The CLI never implements transport.

Push is always a plain non-force push of the tracker branch. Force pushes
and history rewrites are never performed by the tool.

## Compartments

One tracker is one repository and one compartment. The tool has no view that
spans trackers and no state that outlives a clone:

- derived state is computed per invocation from one clone
- actor identity is in the clone
- configuration is in the clone
- the only cross-tracker knowledge anywhere is the human's org files, which
  name tracker locations as subtree properties (see [org client](03-org-client.md))

Consequences that are deliberate:

- A client laptop with its own clone and no remote is a complete tracker.
- The desktop holds clones only for trackers the human chose to place there.
  Other trackers are reached by running the CLI on their machine over tramp.
- Moving a ticket between trackers is a human-initiated refile in org that
  creates a fresh ticket in the target. History does not travel. There is no
  import, federation or cross-reference feature between trackers.

## Several code repositories per tracker

A tracker usually spans more than one code repository. `zwanenzang.toml`
declares repository aliases with their URLs; `branch` and `mr` events name an
alias. A tracker therefore never lives inside a code repository; it is always
its own repository. zwanenzang's own tracker is `zwanenzang-tracker`, private
on the forge, while the implementation repository mirrors to GitHub.

## Rendered view for the forge

A render-only branch (working name `rendered`) in the tracker repository holds
a browsable snapshot: a `README.md` index with grouped summaries and one
markdown page per ticket assembling description, current documents and a
collapsed comment log. It is produced by `zwanenzang render`, deterministic
from the event set, regenerated from scratch, and never read back. Forge CI
runs it on every push of the tracker branch. Lint can verify that the rendered
branch matches the log.

The forge wiki repository is an alternative target for the same output if
sidebar navigation turns out to matter.

## Human checkouts

A human may keep a separate checkout of the tracker to read or edit by hand,
for instance to browse `docs/` or the logs. The CLI's clone keeps it current:

- The clone lists such checkouts in its local git configuration,
  `zwanenzang.checkout` (one value per path, `git config --add`). Nothing
  outside the clone records them.
- After every sync, each listed checkout is fast-forwarded to what has been
  published: the upstream branch as just fetched or pushed, or the clone's
  `HEAD` when it has no upstream. Unpushed commits are never handed out,
  because a later rebase rewrites them and the checkout could then no
  longer fast-forward.
- Only when it is safe: the checkout is a repository, on the same branch,
  with a clean work tree and index, and its `HEAD` is an ancestor of the
  target. The commits come from the clone's own repository by path, so no
  network is needed. Anything else leaves the checkout untouched and is
  reported in the sync result with the reason; it is never an error and
  never blocks the write.

Decided 2026-11-07, replacing the earlier open question (leaning "no such
checkout"). Not implemented yet.

## Open questions

None at present.

### Choices made while implementing milestone 3

- **A tracker is the top of its own work tree.** `init` makes the
  directory a repository when it is in none, uses it when it is already
  the top of one (a fresh clone of an empty remote, say), and refuses a
  directory inside another work tree (`inside-repository`). It commits
  `zwanenzang.toml` and `.gitattributes` and syncs, so an empty remote
  receives the tracker at once. Mutating commands refuse a tracker that is
  not the top of a work tree (`not-a-repository`); read-only commands do
  not need git at all.
- **Concurrent inits.** The repository is created in a temporary directory
  and its `.git` renamed into place, since several `git init`s in one
  directory fail on each other; exactly one rename succeeds.
- **Actor id** in the clone's local git configuration, `zwanenzang.actor`,
  created on the clone's first write. A fresh `git clone` therefore starts
  as a new actor, which is what per-clone actors mean. The first write
  also emits the `actor` event, named from `--actor-name` or `$USER`.
- **Lock.** One exclusive lock for the whole clone, `zwanenzang.lock` in
  the git directory, held across the write, the commit and the whole sync.
  This answers the lock-scope question: contention is a human and a few
  agents, and a per-log lock would not cover the shared git operations.
  A mutating command waits for the lock rather than failing.
- **What a commit holds.** Exactly the files the command wrote: `events/`,
  `blobs/`, and the supporting files an import copied. Other changes in
  the work tree, staged or not, are left alone; edits to `docs/` and to
  `zwanenzang.toml` are the human's to commit. A sync first commits any
  log lines an interrupted command appended but did not commit.
- **Commit identity and message.** Author and committer are the actor:
  its display name and `<actor id>@zwanenzang.invalid`, so a clone needs
  no git identity of its own and history shows who wrote what. Commits
  skip hooks and signing, since an agent cannot answer a passphrase prompt
  and the clone is the tool's. The message names the main operation and
  ticket, `status ZZ-0042`; a ticket committed before it has a number
  appears under its short id.
- **Upstream.** Sync uses the current branch's configured upstream
  (`branch.<name>.remote` and `.merge`). A branch without one, or a
  detached head, means the clone is the whole tracker.
- **Sync** runs after every commit and as the `sync` command: fetch the
  upstream branch; rebase onto it (`--autostash`, so the human's
  uncommitted edits survive); number; push `HEAD` to the upstream branch,
  never forced. The remote not having the branch yet is not an error; the
  push creates it.
- **Numbering at publish.** After the fetch and rebase, every live ticket
  without a number gets the next one, in id order, from the highest number
  in use plus one, written by this clone's actor and committed as
  `publish ...`. The publishing clone numbers other actors' tickets too,
  such as an import's. Without an upstream this happens at once after
  every write.
- **A push that does not land takes its numbers back.** If the push is
  rejected or fails, the publish commit is undone (`git reset --keep`, so
  nothing unrelated is touched); the numbers were never seen, and the next
  attempt assigns them again after a fresh fetch. A rejection is a plain
  non-fast-forward, or a remote reporting that another push moved the
  branch first (`incorrect old value`, `cannot lock ref`).
- **Retry bound.** Five attempts, with a random pause before each retry of
  up to 50 ms doubled per attempt. Giving up is `push-rejected`.
- **Offline is not an error for a write.** When fetch fails, the rebase
  conflicts (only `docs/` can) or the push fails, the command still
  succeeds: its events are committed locally and the next write or `sync`
  pushes them. The result reports what happened (`fetch-failed`,
  `rebase-conflict`, `push-failed`, `push-rejected`). A conflicting rebase
  is aborted, leaving the branch as it was, and is the human's to resolve.
  The `sync` command itself exits 1 in these cases.
- **Credentials.** git never prompts on a terminal
  (`GIT_TERMINAL_PROMPT=0`); a remote that needs an interactive login
  counts as unreachable. The caller's `GIT_DIR`, `GIT_WORK_TREE` and
  `GIT_INDEX_FILE` are ignored, so the tool always acts on its own clone.

### Batched mutation boundary

A client `apply` holds the same exclusive clone lock across one complete
plan validation, one mutation commit, and one sync cycle. It does not fetch
between changes. The mutation commit is named `apply client batch`; the
existing publisher may add a numbering commit or retry publication. Empty
and all-no-op batches skip both commit and sync. Rejected validation writes
no blobs or events and performs no sync; actor-id and lock bookkeeping may
still occur. This does not extend atomicity to filesystem/git failures or
remote changes learned during the subsequent sync. In particular document
compare-and-set is against local replay; a concurrent edit learned during
sync uses the existing lost-document replay semantics.
