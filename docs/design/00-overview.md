# Overview

Draft, 2026-11-07. These notes capture decisions made before any code. They
are the reference while the tool is built; once the tool tracks its own work,
changes to them are tracked there.

## Why this exists

The predecessor (ai-workflow and its bug-tracker branches) kept ticket metadata
in markdown frontmatter next to prose, inside a checkout shared with dirty
human work, and tried to carry a development process in the same design.
Three things followed:

- Tickets became audit logs with a summary stapled on top. A human could not
  read them.
- Publishing one new ticket safely needed about 560 lines of git choreography,
  because git merge was the consistency mechanism for a dozen small fields.
- Process rules and tracking rules were entangled, so every tooling change was
  also a policy change.

zwanenzang separates the three. It tracks. Prose for humans has explicit
owners. Process lives elsewhere.

## Principles

1. **Trusted metadata first, flexibility second.** The derived state of a
   tracker is always consistent and always explainable from its history.
2. **The human may override anything.** A direct jump from draft to done is
   allowed; the history records it truthfully.
3. **Org is the human's authority.** The Emacs side never loses a human edit
   to a machine edit. Conflicts are shown, not resolved silently.
4. **Append only, merge never.** Git replicates the log; it does not merge
   state. Concurrent writers cannot conflict at the git level.
5. **One tracker, one compartment.** No global registry, cache, identity or
   view spans trackers. Deleting a clone deletes everything about it.
6. **Agents are ordinary clients.** They get a CLI with JSON, the same rules
   as the human, and no special authority.

## Non-goals

- Development process: stages, reviews, approvals, merge authority.
- Deadlines, capacity, estimation, boards with WIP limits.
- Multi-user collaboration with untrusted participants. Actors are one person
  and their agents; signing and abuse resistance are not design drivers.
- Being a forge. Merge requests, CI and code review stay on the forge and are
  referenced by URL.

## Glossary

- **Tracker**: one git repository holding one event log, its blobs, its
  configuration and optional supporting files. One compartment.
- **Actor**: a writer identity within one tracker. The human on one machine,
  an agent, a CI job. Each actor owns one log file.
- **Event**: one immutable line in an actor's log. Has an id, a causal parent,
  an entity and an operation.
- **Entity**: a ticket or the tracker itself. Identity is a ULID.
- **Number**: the human-facing alias of a ticket, such as `ZZ-0042`. Assigned
  at publish, never reused.
- **Document**: a named, versioned piece of prose attached to an entity.
  Text lives in content-addressed blobs.
- **Comment**: an append-only note attached to an entity.
- **Derived state**: the result of replaying all events. Never stored as a
  source.
- **Scope**: an org subtree whose root carries the tracker location property.
  Everything under it syncs with that tracker.

## Rejected alternatives

Recorded so they are not re-surveyed.

- **CRDTs with silent conflict resolution.** Concurrent edits here are rare
  and semantic, such as two actors choosing different statuses. Merging them
  automatically produces a state nobody chose, which contradicts principle 1.
  The log is CRDT-shaped for replication, but collisions are reported.
- **SQLite or DuckDB as the primary store.** A binary file in git is
  single-writer and unmergeable, so multi-machine sync gets worse. Either
  remains possible as a derived cache if replay ever becomes slow; in Rust it
  is not expected to.
- **A local daemon serializing access.** Solves only same-machine
  concurrency, which a lock in a single writer binary already solves, and
  adds a lifecycle to manage.
- **Org as a rendered projection with edit extraction.** Rejected because
  the human's org files are the authority and hold structure the tracker
  must not know about; the human also works from a single desktop Emacs
  against trackers on other machines.
- **Org files as the committed source of truth edited in place by the
  tool.** This is the predecessor's design in a different syntax and keeps
  the merge problem.
- **Operations stored in git refs** (git-bug). Invisible to `ls`, `cat`,
  grep and the forge; human readability was the first complaint.
- **A tracker as a branch of the code repository.** Trackers span several
  repositories, and for external projects the tracker cannot live in their
  repository at all.
- **Any global per-user state** such as a home-directory folder of all
  tracker worktrees or a global identity. Violates principle 5.

## Prior art read before deciding

- **epiq** (`ljtn/epiq`): per-actor JSONL logs with union merge on a
  dedicated state branch, ULIDs as a hybrid logical clock, causal parents,
  tolerant replay. Closest to this design. Rejected as a tool for its fixed
  board model, MCP-only access and global per-user state.
- **git-bug**: operations in git objects under refs, Lamport clocks,
  deterministic ordering, a generic entity layer with apply-time rules.
  The entity and rules idea is adopted; refs-only storage and go-git are not.
- **org-caldav**: per-entry sync state (hash, etag, status), classification
  of each side as new, changed or deleted, Org always wins, backup of
  overwritten org text. The sync model is adopted with finer units.
- **Fossil**: append-only ticket artifacts with a synthesized table, as
  confirmation that the pattern works at this scale.

See [data model](01-data-model.md), [git and sync](02-git-and-sync.md),
[org client](03-org-client.md), [milestones](04-milestones.md). The JSON
contract of the CLI, which clients build on, is in
[cli-json](../agent-hooks/cli-json.md); how an agent uses a tracker starts at
the [agent hooks overview](../agent-hooks/overview.md).
