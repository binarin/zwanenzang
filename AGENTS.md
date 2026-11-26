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
- Every pull request that changes the package's source fileset (the paths
  in `nix/_packages/zwanenzang.nix`: `Cargo.toml`, `Cargo.lock`,
  `build.rs`, `docs/agent-hooks`, `site`, `src`, `tests`) bumps the
  `[package] version` in `Cargo.toml` by hand, with `Cargo.lock`, in the
  same pull request. Before 1.0, a breaking change or a new feature bumps
  the minor version and a fix bumps the patch version. The new version must
  be above the target branch's current one. CI checks this with
  `scripts/check-version-bump.py`, but the check is only as current as the
  target tip it ran against: two pull requests bumping to the same version
  make identical edits that merge cleanly, and the forge does not re-run
  the check when the target moves. So a pull request whose target branch
  moved after its check ran is rebased (and bumps again if needed), or has
  its check re-run, before it is merged. Branch protection that blocks
  merging an outdated pull request, with the version-bump job as a
  required check, makes this automatic. `--version` shows this version
  with the flake commit and its date.

## This project's tracker

This project's tracker is `zwanenzang-tracker` on the forge
(`https://forgejo.lynx-lizard.ts.net/binarin/zwanenzang-tracker`). How to use
it, including statuses, workflow tags, the `brief` handoff and how to advance
a ticket, is in [docs/agent-hooks](docs/agent-hooks/overview.md), the same
text `zz agent-hooks show-document overview` prints; this project adds
nothing to it. An agent orchestrating a batch run of implementer and
reviewer agents over its tickets follows `docs/batch-ticket-run.md` in that
tracker repository.

Private ticket details and handoffs stay in the private tracker, never in
this repository.

## Nix flake

- Use flake-parts and the same pinned inputs as `swan-lake-common`: the
  `binarin` forks on GitHub with `swan-lake-current` branches
  (`flake-parts`, `nixpkgs` at `swan-lake-current/nixos-26.05`,
  `nixpkgs-unstable` at `swan-lake-current/nixpkgs-unstable`, `import-tree`).
  These branch names exist to share the nix cache across all repositories;
  do not pin anything else and do not add inputs that are not already in
  that set.
- Never depend on `swan-lake-common`. It consumes this flake's overlay for
  the CLI and the Emacs client, so a dependency the other way is circular.
- The flake exports the `zwanenzang` package, the `zwanenzang-el` Emacs
  package, `overlays.default` (adds `pkgs.zwanenzang` and
  `epkgs.zwanenzang` to every `emacsPackagesFor` set), a dev shell, and
  `nix flake check` running both test suites. Build the CLI with
  `rustPlatform` from the pinned nixpkgs; no rust overlay inputs.
  `zwanenzang-el` is built with `nixpkgs-unstable`'s `emacs`, because the
  client needs Emacs 31 and stable nixpkgs has 30.

## Scope guard

Tracking only. If a change would add process rules, stages, approvals,
scheduling or reminders to the tool, it does not belong here; the design
overview lists non-goals. The bundled agent documents may state rules of use
(actor names, where prose belongs, ticket links, the default statuses and
workflow tags), which the tool does not enforce. The Emacs client is developed here, as the `zwanenzang` package
in `emacs/` (Emacs 31+, built-in libraries plus the specifically accepted
`org-ql` dependency and its required closure). Other direct external packages
require individual human acceptance; this is not blanket permission.
`swan-lake-common` only
installs it through the overlay and points it at org files. The CLI's JSON
contract stays documented, since agents and scripts use it too.

## Fixtures and references

- Import fixture: the frozen ai-workflow tracker, the `bug-tracker` branch of
  `forgejo.lynx-lizard.ts.net/binarin/ai-workflow`. Tickets are markdown with
  YAML frontmatter (`status`, `branches`, `merge-requests`, `related`,
  `original-ticket`, `handoff`) and a body whose first heading is the
  title. Twenty-seven tickets, `AIWF-NNNN`. Its `tracker-dashboard` and
  `tracker-lint` tools on `master` are the starting point for `render` and
  `lint` behaviour, not code to port.
- That tracker is private. None of its text (tickets, titles, ids, how
  they were classified for import) goes into this repository: not in
  fixtures, docs, comments or commit messages. The importer's tests use
  the synthetic tickets in `tests/fixtures/ai-workflow/`, which follow the
  same format.
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

The Emacs client has two ERT layers in `emacs/test/`, both run by `nix
flake check` under `emacs --batch`: pure parse and render tests that need no
CLI, and integration tests that drive this flake's CLI. The elisp
integration helper enforces the same two markers before it opens, writes to
or pushes from a repository; the client itself has no bypass either.

To run the ERT suite against a checkout's sources, use `nix run .#emacs-test`
from the repository root, optionally with a test-name regexp
(`nix run .#emacs-test -- '^zwanenzang-queue-'`). Do not run `emacs --batch`
from `PATH` for this: the personal Emacs there may point its config directory
at a real one, and a test can write state into it. The app uses this flake's
Emacs and CLI with a throwaway `HOME`.

Fixture-based tests import the synthetic fixture in the frozen tracker's
format into such a repository and assert on what replay produces. The real
tracker is imported only by hand, into a disposable directory, and nothing
from that run is committed.
