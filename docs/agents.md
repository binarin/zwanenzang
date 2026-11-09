# Using a tracker from a project

For an agent whose project names a zwanenzang tracker. This covers how to use
the tool. It sets no process: what to record and when is up to the project.

The full contract, with every command, field and error code, is in
[cli-json](cli-json.md).

## The CLI

The examples write `zwanenzang`, which works if it is on `PATH`. Otherwise run
it from its flake, keeping the `--`:

```sh
nix run git+https://forgejo.lynx-lizard.ts.net/binarin/zwanenzang#zwanenzang -- <arguments>
```

## One stable clone per origin URL

Reuse one persistent clone per tracker URL, per user and execution host, across
workspaces and sessions. Keep it outside code repositories and workspace cleanup.
The standard location is
`${XDG_DATA_HOME:-$HOME/.local/share}/zwanenzang/trackers/<key>`, where `<key>` is
the full lowercase SHA-256 of the chosen origin URL's UTF-8 bytes, with no trailing
newline. This is durable data, not a disposable cache: it can hold unpublished work.
The CLI still takes a path; it does not locate or clone URLs itself.

Choose one canonical URL spelling from the project's instructions. Hash it
exactly: do not strip `.git`, fold case, remove credentials, follow redirects or
apply git's `insteadOf` rewrites. HTTPS, SSH, scp-style URLs and host aliases are
not automatically equivalent. When another spelling names the same tracker,
explicitly use the already chosen URL and clone, rather than making another.
Do not put credentials in the URL; use git's credential or SSH configuration.

For first-time setup or reuse, this Bash recipe requires `git`, `sha256sum` and
`flock`. The directory lock serializes provisioning only, without a registry or
a persistent lock file outside the clones:

```bash
set -euo pipefail
url='https://forge.example/owner/tracker.git' # canonical project URL
root="${XDG_DATA_HOME:-$HOME/.local/share}/zwanenzang/trackers"
key=$(printf '%s' "$url" | sha256sum)
dir="$root/${key%% *}"
mkdir -p -- "$root"
(
    flock -x 9
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        GIT_TERMINAL_PROMPT=0 git clone -- "$url" "$dir"
    fi
    # Refuse incomplete clones, nested paths, linked worktrees and changed origins.
    [[ -d "$dir/.git" && -f "$dir/zwanenzang.toml" ]]
    [[ $(git -C "$dir" rev-parse --show-toplevel) == $(cd "$dir" && pwd -P) ]]
    [[ $(git -C "$dir" config --local --get remote.origin.url) == "$url" ]]
) 9<"$root"
zwanenzang -C "$dir" sync
```

On any setup check failure, stop and inspect; never reset, delete or reclone an
existing directory automatically. An interrupted clone can leave an incomplete
directory. An origin mismatch can mean a changed URL or the wrong tracker, not
permission to overwrite it. For a remote rename or transport change, stop clients,
verify the tracker identity, update the origin and move the entire clone to the
new URL's key. Refuse an occupied destination. Do the same to adopt a pre-existing
clone into this layout: move it, including `.git`, rather than recloning. Preserve
unpushed commits, actor identity, local configuration and checkout registrations;
review relative checkout paths after a move. Coordinate moves with provisioning
using the directory lock above. Existing explicit clone paths (including Org
scope locations) remain supported; update their callers when moving one.

Pass `-C "$dir"` on every command; without it the tracker is searched for upward
from the current directory. Pass a stable `--actor-name` on writes, for example
`zwanenzang -C "$dir" --actor-name workstation <write command>`. It names the
clone's first write, is ignored afterwards, and defaults to `$USER` or `unknown`.
The CLI has no command to rename an actor.

The actor is the clone, not the session: all clients reusing it share one actor
and log. Separate users or execution hosts still have separate clones and actors.
Concurrent mutations and syncs wait on the existing exclusive clone lock, held
through validation, append, commit and publication; do not wrap CLI writes in an
external acquisition of that same lock. Do not switch branches, run manual git
writes or change clone configuration while clients are using it. Read-only calls
remain unlocked and do not provide isolation from an ongoing write or rebase;
retry a read that overlaps one. A read followed by a write is not a transaction:
refresh and retry stale document bases as described below.

The CLI never prompts for credentials (`GIT_TERMINAL_PROMPT=0`), so the clone's
remote must work non-interactively. Otherwise every sync reports `fetch-failed`
while writes keep succeeding locally and tickets never get numbers.

Do not clone a tracker inside a code work tree: it shows up as untracked there
and `git add -A` can pick it up. Do not use linked worktrees as independent
tracker clones; they share git state but not the clone lock.

## Reading

```sh
zwanenzang -C <dir> sync
zwanenzang -C <dir> show ZZ-0042
zwanenzang -C <dir> list --status todo
zwanenzang -C <dir> query --tag example --title parser
zwanenzang -C <dir> doc get ZZ-0042 plan
```

Read-only commands answer from the clone and do not fetch, so run `sync` first
when current state matters. `list` returns summaries; `query` takes more filters
and returns full tickets, as `show` does. A ticket reference is a number, an id
or a unique id prefix.

## Writing

```sh
zwanenzang -C <dir> create "A title" --status todo --tag example
zwanenzang -C <dir> status ZZ-0042 doing
zwanenzang -C <dir> mr ZZ-0042 app https://forge.example/app/pulls/7
```

Status and kind names, and the repository aliases `branch` and `mr` take, are in
the clone's `zwanenzang.toml`. An unknown status or kind is refused; an unknown
alias is written anyway and only `lint` reports it.

Every write commits and then syncs. Output is one JSON value on stdout, unless
the arguments themselves are wrong, which is a message on stderr and exit
status 2.

- A refused command prints `{"error": {"code": ..., "message": ...}}` and exits
  1. Nothing was written.
- A write that could not reach the remote still succeeds and exits 0. It is
  committed locally, `sync.error` says what went wrong, and the next write that
  changes something, or `sync`, pushes it. Until then it exists only in this
  clone.
- `sync` itself exits 1 in that case, also reporting it in `sync.error`, with no
  top-level `error`.
- `"written": false` means the write would change nothing. No event was written
  and no sync ran.

## Prose

These are rules of the data. The CLI stores whatever text it is given and does
not check them.

- All prose is Org, not Markdown.
- The `description` document belongs to the human. Agents read it and do not
  write it.
- Agents write comments and named documents of their own choosing.
- Comments are append-only. A correction is a new comment.

Org lists start with `-`, which the argument parser rejects as a comment
argument, so pass prose with `--file` or on stdin:

```sh
zwanenzang -C <dir> comment ZZ-0042 --file note.org
```

Writing a document names the version it is based on: `version` from `doc get`,
or `none` for a new document. The text comes from `--file` or stdin.

```sh
zwanenzang -C <dir> doc set ZZ-0042 plan --base <version> --file plan.org
```

On `stale-doc-base` someone wrote a newer version: read again, merge, and write
against the new version.

That check only sees what the clone has, so `sync` before the `doc get`. A write
that raced a version from another clone exits 0 all the same, and when the two
meet, the one with the lower id stays current and the other is marked
`lost: true`. Compare `event.id` with `ticket.documents.<name>.current` in the
output, and if they differ treat it as a stale base. This can still happen after
a successful write, when another clone's earlier offline version arrives; `lint`
lists these under `lost_documents`.

## Numbers

A ticket has no number until it is published, and the number cannot be predicted.
Do not cite one from a write whose sync failed; refer to the ticket by its short
id. `display` holds the number once there is one and the short id until then. The
short id keeps working afterwards.
