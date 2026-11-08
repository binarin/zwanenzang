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

## A clone per workspace

Each workspace gets its own clone, outside any code repository:

```sh
git clone <tracker url> <dir>
zwanenzang -C <dir> --actor-name <name> <write command>
```

Pass `-C <dir>` on every command; without it the tracker is searched for upward
from the current directory. `--actor-name` names the actor on the clone's first
write and is ignored after that, so it is safe to pass on every write. Without
it the name is `$USER`.

The actor is the clone: a new clone is a new actor with its own log under
`events/`. A tracker therefore collects one log per clone over time, by design.

Do not clone a tracker inside a code work tree. The CLI does not refuse it, but
the clone shows up as untracked there and `git add -A` picks it up.

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
  committed locally, `sync.error` says what went wrong, and the next write or
  `sync` pushes it. Until then it exists only in this clone.
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
