# zwanenzang

A small, local-first issue tracker for one person and their agents.

- Metadata is an append-only event log in a git repository that only the
  `zwanenzang` CLI writes. Git carries it between machines without ever
  merging it.
- Org mode in Emacs is the human's authority. An org subtree syncs two-way
  with one tracker, org-caldav style.
- Agents use the same CLI with JSON in and out.
- Current state, dashboards and a browsable rendering for the forge are
  derived views, never sources.
- One tracker is one repository and one compartment. Nothing aggregates
  trackers across projects or clients.

Tracking only. Development process, review stages and authority rules belong
to the projects that use it, not here.

Design notes live in [docs/design](docs/design/00-overview.md). This project's
own tracker is a separate private repository, `zwanenzang-tracker`.

Implementation language: Rust. Distribution: nix flake.
