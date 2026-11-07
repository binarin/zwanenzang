# Milestones

Thin vertical slices. Each is usable on its own; nothing in a later slice is
needed to start using an earlier one. Tracking of this work lives in a plain
org file on the desktop until milestone 3 makes it a synced scope.

## Context

- The ai-workflow effort is abandoned. Its tracker branch is frozen and
  becomes the import fixture (27 AIWF tickets).
- The swan-lake (ZL) tracker keeps running on the frozen ai-workflow tooling
  until zwanenzang can take it over. It is not a fixture yet.
- Rust, distributed as a nix flake. Nix is available on every machine,
  including client laptops.
- The Emacs client is developed in `swan-lake-common` under the existing
  emacs module. Tracker locations are org properties, so nothing sensitive
  enters that repository.
- `zwanenzang` on the forge mirrors to GitHub; `zwanenzang-tracker` is
  private and holds this project's own events.

## 1. Design notes and schema

These documents. Settle the event envelope, operations, document model,
identity and numbering, validation rules, and the org mapping. Done when the
open questions that block milestone 2 are answered; the rest stay listed.

## 2. Event log core, local only

- Crate layout, `zwanenzang.toml`, event types with serde, ULID with hybrid
  clock, per-actor log append, blob store.
- Replay to derived state; ordering; concurrency classification; validation
  on write and tolerant validation on replay.
- Operations: create, title, status, parent, relate, tag, branch, mr, archive,
  tombstone, comment, doc, actor.
- `lint`, `show`, `list`, `query` with JSON output.
- Importer from the frozen ai-workflow tracker producing synthetic events,
  used as the realistic fixture and the eventual retirement path.
- No git yet. Tests run against temporary directories.

## 3. Git integration and the first org sync

- Owned clone, flock, commit per mutation, fetch, rebase, push, bounded retry.
- Number assignment at publish; offline behaviour; actor id in clone config.
- Fast-forward the human checkouts a clone lists after each sync.
  Implemented with clone-local `zwanenzang.checkout` paths, a known
  published commit target, safety checks and per-checkout sync results.
- Batched JSON operations for clients: read a scope's worth of tickets and
  events after cursors in one call; apply a list of changes in one call.
  Milestone 2's `query` covers the ticket half; the per-ticket event
  cursors are new here.
  The read half is implemented as `read` (JSON on stdin, opaque scope and
  per-ticket cursors, document text). `apply` implements the write half:
  one validated list, earlier-create references, explicit document bases,
  positional results, one mutation commit and one sync.
- Emacs client against a local desktop clone: scope roots, pull, push,
  create, sync state in properties, Org wins, conflict tag, foreign and
  duplicate id handling, archive as absence.
- Bootstrap complete: the org file tracking this work becomes a synced scope
  of `zwanenzang-tracker`.

## 4. Rendering

- `render` producing the index and per-ticket pages, deterministic.
- Forge CI on `zwanenzang-tracker` pushing the `rendered` branch.
- Lint check that the rendered branch matches the log.

## 5. Multiple trackers and remote execution

- CLI over tramp with `process-file`; scope location as execution host.
- Doctor command across all configured org files.
- Refile flow between a personal inbox scope and a client scope.
- Archive hook emitting `archive` events.
- Agent-facing documentation: how an agent is pointed at a tracker from a
  project, with no process rules attached.

## 6. Take over the ZL tracker

- Import swan-lake's tracker branch; freeze it; point its projects at the new
  tracker. The ai-workflow import fixture becomes the real zwanenzang
  history at the same time, imported with the reviewed exclude list kept
  in the private `zwanenzang-tracker` (it names private tickets, so it
  never enters this repository).

## Deliberately absent

Stage machinery, review loops, authority rules, scheduling, reminders,
dashboards beyond `render` and org-agenda. Projects that want a process put
it in their own instructions and use the tracker through the CLI.
