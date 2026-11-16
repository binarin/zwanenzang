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
  including client laptops. The CLI package installs both `zwanenzang` and
  the short command `zz`, linked to the same git-PATH-wrapped executable.
  The default flake command remains `zwanenzang`; Cargo builds/installs only
  that name. The dev shell supplies build tools, not the installed CLI.
- The Emacs client is developed in this repository, as the `zwanenzang`
  Emacs package in `emacs/`. `swan-lake-common` consumes it through this
  flake's overlay. Tracker locations are org properties in the human's own
  files, so nothing sensitive enters either repository.
- `zwanenzang` on the forge mirrors to GitHub; `zwanenzang-tracker` is
  private and holds this project's own events.
- Agent-facing documentation is done, moved out of milestone 5: the
  [agent hooks](../agent-hooks/overview.md) say how an agent uses a tracker
  from a project, including its rules of use (actor names, where prose
  belongs, ticket links, the default statuses and workflow tags) but no
  further process. They ship inside the
  executable rather than being copied into each project:
  `zz agent-hooks init` prints a bootstrap paragraph naming the selected
  tracker's prefix, for the project to paste into its own agent
  instructions, and `zz agent-hooks show-document NAME` prints one document
  of the tree as plain text, needing no tracker. Agents read them
  progressively: each landing document lists only its immediate subtopics,
  by command, never by file path, so no store path or version reaches agent
  context and a session reads whatever the executable it runs bundles.
  `docs/agent-hooks/` is the only source: a file's name is its path without
  `.md`, and a directory's `overview.md` is named after the directory
  (`tickets/overview.md` is `tickets`). `build.rs` embeds the tree, so Cargo
  and Nix builds carry the same text. The JSON contract lives there too, as
  `cli-json`, not copied. Project policy beyond those rules of use, and
  agent-framework formats such as skill files, stay out of the bundle.

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

## 4. Static HTML site via `zz render`

- Local first, implemented: `zz render DIR` writes a self-contained site
  (two panes, fuzzy filter, full-text search, status, tag and archived
  filters) that opens from `file://`. It reads replayed state directly and
  converts Org prose with its own small renderer; the page is hand-written
  under `site/`. See [static site](05-static-site.md).
- Later: hosting the output (on the tailnet, for phone viewing) and building
  it in CI. Forgejo serves no HTML pages from a branch, so this replaces the
  earlier plan of Org pages on a `rendered` branch and the lint check that
  compared that branch with the log.

## 5. Multiple trackers and remote execution

- CLI over tramp with `process-file`; scope location as execution host.
- Doctor command across all configured org files.
- Refile flow between a personal inbox scope and a client scope.
- Archive hook emitting `archive` events.

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
