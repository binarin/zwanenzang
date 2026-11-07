# Working on zwanenzang

Read [docs/design/00-overview.md](docs/design/00-overview.md) first; it links
the other design notes. [docs/design/04-milestones.md](docs/design/04-milestones.md)
says what is being built now. This file holds the constraints that are not
design decisions.

## Repository and conventions

- `master` is integrated through pull requests on the forge
  (`forgejo.lynx-lizard.ts.net/binarin/zwanenzang`). It mirrors to GitHub, so
  nothing private goes in this repository. This project's own tracker data is
  in the separate private repository `zwanenzang-tracker`.
- Rust, stable toolchain from nixpkgs. Shell out to the `git` binary; no git
  library crate.
- Commits are small and explain why. Design changes update the notes under
  `docs/design/` in the same change; open questions are answered there, not
  in chat.

## Nix flake

- Use flake-parts and the same pinned inputs as `swan-lake-common`: the
  `binarin` forks on GitHub with `swan-lake-current` branches
  (`flake-parts`, `nixpkgs` at `swan-lake-current/nixos-26.05`,
  `nixpkgs-unstable` at `swan-lake-current/nixpkgs-unstable`, `import-tree`).
  These branch names exist to share the nix cache across all repositories;
  do not pin anything else and do not add inputs that are not already in
  that set.
- Never depend on `swan-lake-common`. It will consume this flake for the
  Emacs client, so a dependency the other way is circular.
- The flake exports the `zwanenzang` package, a dev shell, and `nix flake
  check` running the test suite. Build with `rustPlatform` from the pinned
  nixpkgs; no rust overlay inputs.

## Scope guard

Tracking only. If a change would add process rules, stages, approvals,
scheduling or reminders, it does not belong here; the design overview lists
non-goals. The Emacs client is developed in `swan-lake-common`, not here;
this repository only provides the CLI it calls and documents the JSON
contract.

## Fixtures and references

- Import fixture: the frozen ai-workflow tracker, the `bug-tracker` branch of
  `forgejo.lynx-lizard.ts.net/binarin/ai-workflow`. Tickets are markdown with
  YAML frontmatter (`status`, `branches`, `merge-requests`, `related`,
  `handoff`) and a body whose first heading is the title. Twenty-eight
  tickets, `AIWF-NNNN`. Its `tracker-dashboard` and `tracker-lint` tools on
  `master` are the starting point for `render` and `lint` behaviour, not
  code to port.
- Prior art consulted, for reading rather than reuse: epiq (per-actor JSONL
  with union merge, `source/git/` and its `AGENTS.md`), git-bug
  (`doc/design/data-model.md`), org-caldav (`org-caldav.el`, sync state and
  the Org-wins rule).

## Testing

Unit tests on the event core run against temporary directories.

Git integration tests create everything they touch: a bare repository acting
as the remote and one or more clones acting as machines or agents, all inside
one temporary directory that is deleted afterwards. They drive the CLI against
those clones and assert on derived state, union merge, numbering and retry.
They never touch a real tracker.

That rule is enforced, not assumed. A repository is only eligible for tests if
it carries clear markers of being disposable: its path is under the system
temporary directory and the directory name ends in `-test-repo`. Any test
helper that opens, writes to or pushes from a repository checks both markers
first and refuses otherwise. The CLI itself keeps no test mode and no
environment variable that bypasses the check; a test that needs a repository
creates one that satisfies the markers.

Fixture-based tests import the frozen tracker into such a repository and
assert on what replay produces.
