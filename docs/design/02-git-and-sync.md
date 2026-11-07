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

## Open questions

- Lock scope: the whole clone, as drafted, or per actor log. Whole clone is
  simpler and contention is low.
- Whether `sync` should also fast-forward a human convenience checkout of the
  tracker. Current leaning: no such checkout exists; humans read the rendered
  branch or org.
- Retry bound and backoff for push rejection.

### Interim choices for the local-only slice of milestone 2

Milestone 2 has no git integration, so two things that live in the git
directory above need a temporary home. Both move there in milestone 3.

- **Actor id.** Stored in `.zwanenzang/actor` inside the tracker directory.
  `init` writes `.gitignore` with `/.zwanenzang/` so it never enters history.
  It is per clone, as the design requires; nothing goes in the home
  directory. The first write by an actor also emits its `actor` event, with
  the display name from `--actor-name` or `$USER`.
- **Lock.** Mutating commands take an exclusive lock on
  `.zwanenzang/lock` for the whole tracker, which is also the answer chosen
  for the lock-scope question above.
