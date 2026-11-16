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

## Stable clone placement

Clients reuse one durable clone per chosen tracker locator, per user and
execution host, rather than cloning per workspace or session. A locator is
an origin URL with an optional `?ref=BRANCH` selector naming the tracker's
branch; the selector is a plain branch name, never a tag or a commit
revision, and an unqualified locator means the remote's advertised default
branch. The standard path is
`${XDG_DATA_HOME:-$HOME/.local/share}/zwanenzang/trackers/<key>`, with `<key>` the
full lowercase SHA-256 of the locator's exact UTF-8 bytes, without a trailing
newline; the selector is part of the key, so different selected branches
have separate clones that are never switched to each other's branches, and
an unqualified locator keeps hashing its plain URL bytes, as storage written
before selectors did. It is data, not cache: unpublished events may live only
there. Workspace cleanup must not remove it. The CLI implements this resolver
with `--tracker-url LOCATOR`, or a code repository's local
`zwanenzang.trackerUrl` git setting, which takes the same spelling. No project
file, global git setting or global registry is consulted. Explicit `-C` wins
and never falls back to discovery; otherwise an enclosing tracker wins over
project configuration. `--tracker-url` overrides discovery and conflicts with
`-C`. `init` ignores `-C` (it searches nothing) and refuses `--tracker-url`:
it creates a tracker in its directory argument and names its remote with
`--remote LOCATOR`, publishing a new branch. Org locations remain
explicit paths, including existing custom locations.

The project chooses a canonical URL spelling. No automatic URL normalization,
transport equivalence, redirect following or git URL-rewrite resolution determines
identity. Different spellings are different keys unless the caller explicitly
chooses the existing canonical URL. Do not store credentials in URLs. On an origin
change, stop clients, verify tracker identity, update the remote and move the whole
clone to the new key, refusing an occupied destination. Adopt an existing clone by
moving it with its `.git`, not by replacing it: retain its actor, unpublished work
and clone-local configuration, and review relative checkout paths. Update explicit
path users after a move.

The CLI serializes the existence check and clone on an exclusive lock of the
parent directory itself. This leaves no registry or lock file outside a clone.
It checks the work-tree root, tracker configuration and exact clone-local origin
before reuse. Failed checks stop for inspection; an existing directory is never
automatically removed, reset or replaced. Moves require quiescent clients and the
same provisioning lock. Existing symlinks to standalone clones are supported;
linked worktrees are not. Provisioning never fetches an existing clone, even
for reads; run `sync` for current remote state. The first clone needs a reachable
remote. Local origins must be absolute paths (or `file://` URLs), so identity
cannot depend on which code repository invokes the command. Relative data-home
paths are refused; an empty XDG value falls back to HOME, and missing both fails.
Once provisioned, mutations and sync use only the existing clone lock; no
per-workspace worktrees, branch switching or manual git writes alongside clients.
Read-only calls remain unlocked, not isolated from writes or rebase, and a
read/write pair is not a transaction. Clients retry overlapping reads and stale
document bases; this convention does not add stronger read semantics.

## Actor identity

Writers and identities are separate (see the
[data model](01-data-model.md)). The **writer** id is a ULID created on the
first write in a clone and stored in that clone's `.git/config` under
`zwanenzang.actor`. It is per clone, so the same human on two machines is
two writers, which is what makes per-writer logs safe without coordination
and keeps concurrent edits from two machines reported.

The **identity** is named on every write: `--actor-name NAME`, else the
clone's `zwanenzang.defaultActor`, set by hand with `git config`. A write
with neither is refused (`actor-required`), as is a name not in the
tracker's `actors` list (`unknown-actor`); there is no `$USER` fallback,
because agents on the human's host would otherwise write as the human.
Dry runs and read-only commands need no identity, and neither does a
`sync` with nothing to number. The identity is recorded as `as` on each
event the write produces, so any clone can write as any identity: an agent
session passes `--actor-name agent` in the human's clone, and the human's
edits from that clone are the human's.

Both live only inside the tracker and its clone, even when that clone is
placed beneath the home directory. There is no separate user identity file:
the list of identities is the tracker's configuration, and the default is
the clone's.

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
- the writer id and default identity are in the clone; the identities a
  tracker accepts are in its configuration
- configuration is in the clone
- the parent directory of stable clones holds no registry, identity, derived
  state or URL-to-path mapping file; its child names are computed from URLs
- the human's org files name tracker locations as subtree properties (see
  [org client](03-org-client.md)); URL selection does not search for other
  trackers or aggregate them

Consequences that are deliberate:

- A client laptop with its own clone and no remote is a complete tracker.
- Each execution host holds clones only for trackers explicitly used there.
  Other trackers are reached by running the CLI on their machine over tramp;
  the URL-keyed path is then on that host, not implicitly on the desktop.
- Moving a ticket between trackers is a human-initiated refile in org that
  creates a fresh ticket in the target. History does not travel. There is no
  import, federation or cross-reference feature between trackers.

## Several code repositories per tracker

A tracker usually spans more than one code repository. `zwanenzang.toml`
declares repository aliases with their URLs; `branch` and `mr` events name an
alias. A tracker's checkout is therefore always its own repository work tree
and never a subdirectory of a project checkout, but the tracker's history may
share a repository with other branches: `init` publishes independent orphan
history on a locator-selected branch of any existing remote, project history
untouched and unmixing. zwanenzang's own tracker is `zwanenzang-tracker`,
private on the forge, while the implementation repository mirrors to GitHub.

## Rendered view for the forge

Superseded by the [static site](05-static-site.md): `render` writes HTML
into a directory outside the tracker, and no `rendered` branch or lint check
of it exists. The earlier plan, kept for reference:

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
checkout"). Implemented in milestone 3 with these concrete boundaries:

- **Configuration.** Read only clone-local `zwanenzang.checkout` values,
  in order, including duplicates. Relative paths resolve against the owned
  clone root, regardless of the CLI's starting directory. Paths are not
  shell-expanded; absolute paths are recommended. Canonicalize before
  opening: symlink aliases of a checkout work, but a subdirectory of a
  repository, a bare repository, an empty path or a missing path is skipped.
  The source clone, its aliases, and all linked worktrees sharing its common
  git directory are skipped, since moving a shared ref could leave the
  source's work tree behind.
- **Published target.** Carry an immutable commit id through the sync.
  A successful push selects the pushed commit. Otherwise use the last
  successful fetch's commit from this sync, even after an aborted rebase,
  failed push, exhausted retries, or a later failed fetch. A successful
  fetch that finds no upstream branch clears the target; a later successful
  push can establish it. If no target was observed (including an initial
  fetch failure), skip all checkouts. Cached remote refs and `FETCH_HEAD`
  from earlier invocations are never used as substitutes. Without an
  upstream, select owned `HEAD` after numbering. A detached source has no
  branch to match and skips its checkouts, even in this local case.
- **Safety.** Compare full branch refs, not ambiguous short names. Refuse
  an unborn or detached checkout, a different branch, or a git operation
  in progress (merge, rebase, cherry-pick, revert, sequencer or bisect).
  Clean means no staged, tracked, untracked, ignored or submodule changes;
  these checks apply even when `HEAD` already equals the target. Ignored
  files are included conservatively so a future tracked path cannot
  overwrite them. Fetch only the selected commit from the owned clone's
  absolute local path, without updating remote refs, tags or `FETCH_HEAD`,
  and without submodule recursion or automatic maintenance. Checkout commands
  disable lazy object fetching and allow only the file transport, so a URL
  rewrite cannot turn the local transfer into a network fetch. Check ancestry,
  then run `merge --ff-only --no-autostash`, with hooks and submodule
  recursion disabled. Disable fsmonitor hooks during inspection too. Do not
  stash, reset, commit, rebase or push human work.
  Git supplies normal index/ref locking and its overwrite checks. These are
  optimistic checks, not an exclusive lock against a human switching
  branches or editing concurrently; serialize such operations with sync.
- **Reporting.** Every returned sync report includes `checkouts` with the
  selected target, an inspection error if configuration/source inspection
  failed, and one ordered result per configured value otherwise. Results
  are `updated`, `up-to-date`, or `skipped` with a stable reason and a human
  message. A failed local transfer or merge is also a skip; continue with
  the other checkouts. A transfer may leave fetched objects behind, but
  routine prerequisite/ancestry skips leave work trees, indices and refs
  alone. There is no human lock to wait for. Checkout skips and inspection
  failures never set the publication error or change exit status. A fatal
  owned-clone/disk error that prevents a sync report still fails as before;
  no checkout phase runs in that case. No-op writes still skip sync entirely.

The exact result and reason vocabulary is in [cli-json](../agent-hooks/cli-json.md).

## Open questions

None at present.

### Choices made while implementing milestone 3

- **A tracker is the top of its own work tree.** Revisited with remote-backed
  `init`: the destination must be nonexistent or empty, and becomes a fresh
  repository on the branch the locator selects — a directory inside another
  work tree is refused (`inside-repository`), and so is one holding anything,
  even only a `.git`. The initial commit holds `zwanenzang.toml`,
  `.gitattributes` and the bootstrap `AGENTS.md`, is pushed as a create-only
  non-force push of the new branch, and leaves the origin and upstream
  configured for ordinary sync. Success is reported only after that push;
  a failure keeps the checkout and its commit and names the retry command,
  with no claim of rollback. Mutating commands refuse a tracker that is
  not the top of a work tree (`not-a-repository`); read-only commands do
  not need git at all.
- **Concurrent inits.** The repository is created in a temporary directory
  and its `.git` renamed into place, since several `git init`s in one
  directory fail on each other; exactly one rename succeeds.
- **Writer id** in the clone's local git configuration, `zwanenzang.actor`,
  created on the clone's first write. A fresh `git clone` therefore starts
  as a new writer, which is what per-clone writers mean. The first write
  also emits the writer's `actor` event, naming that write's identity.
- **Identities in `init`.** `init` writes `actors = [NAME, "agent"]` when
  given `--actor-name NAME`, and `actors = ["agent"]` otherwise; the human
  adds names by editing `zwanenzang.toml`. It does not set the clone's
  `zwanenzang.defaultActor`.
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
- **Commit identity and message.** Author and committer are the identity
  of the write, else the writer's display name, else the writer id, with
  `<writer id>@zwanenzang.invalid`, so a clone needs
  no git identity of its own and history shows who wrote what. Commits
  skip hooks and signing, since an agent cannot answer a passphrase prompt
  and the clone is the tool's. The message names the main operation and
  ticket, `status ZZ-42`; a ticket committed before it has a number
  appears under its short id.
- **Upstream.** Sync uses the current branch's configured upstream
  (`branch.<name>.remote` and `.merge`). A branch without one, or a
  detached head, means the clone is the whole tracker.
- **Sync** runs after every commit and as the `sync` command: fetch the
  upstream branch; rebase onto it (`--autostash`, so the human's
  uncommitted edits survive); number; push `HEAD` to the upstream branch,
  never forced. Skip rebase entirely when the fetched commit is already an
  ancestor of local `HEAD` (including equal heads): even a no-op rebase
  autostashes dirty files, rewriting them on restore and triggering editor
  auto-revert messages. When local `HEAD` is an ancestor of the fetched
  commit, first try `merge --ff-only --no-autostash` with hooks disabled:
  unrelated dirty files retain their contents, timestamps and index state.
  If that refuses (for example, a dirty file would be overwritten), fall
  back to rebase with autostash. Divergent histories also still rebase with
  autostash. These remaining paths restore every dirty file and may trigger
  editor auto-revert even for files upstream did not change; staged edits
  may return unstaged, as Git restores the stash without `--index`. Avoiding
  such rewrites for divergent histories is outside this change's scope.
  No Emacs notifications are suppressed globally. Sync does not serialize
  or rewrite the tracker configuration itself. The remote not having the
  branch yet is not an error; the push creates it.
- **Numbering at publish.** After the fetch and rebase, every live ticket
  without a number gets the next one, in id order, from the highest number
  in use plus one, written by this clone's writer as the identity of the
  write the sync follows (or of the `sync` command) and committed as
  `publish ...`. The publishing clone numbers other writers' tickets too,
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
