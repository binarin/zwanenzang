# CLI JSON contract

What a client (the Emacs client, an agent, a script) can rely on when it
runs `zwanenzang`. Every write is committed to the tracker's git repository
and synced with its upstream. Clients can read or apply a whole scope in one
JSON request. The format grows by adding fields; a client must ignore fields it does not know.

## Invocation

```
zwanenzang [-C DIR | --tracker DIR | --tracker-url URL] [--actor-name NAME] <command> ...
```

- `-C DIR`: start the tracker search in `DIR` instead of the current
  directory. The tracker is the nearest directory, upward, that holds
  `zwanenzang.toml`. For `init`, `DIR` is where the tracker is created;
  it must not be in or below an existing tracker, nor inside another git
  work tree unless it is that work tree's top.
- `--tracker-url URL`: provision/reuse a durable clone keyed by the exact
  origin URL. Mutually exclusive with `-C` / `--tracker`. Not valid for `init`.
- With neither selector, use the enclosing tracker, if any; otherwise use
  exactly one `zwanenzang.trackerUrl` value from the enclosing code repository's
  **local** git configuration. No global config or project file is consulted.
  Missing configuration is `not-a-tracker`; multiple values are
  `invalid-argument`. Explicit `-C` never falls back to URL selection.
- `--actor-name NAME`: display name declared by this clone's first write.
  Defaults to `$USER`, then `unknown`. Ignored once the actor is declared.

The `git` binary must be on `PATH` (the nix package falls back to its own).
The clone's actor id is `zwanenzang.actor` in its local git configuration.

### URL-selected storage

The clone lives at
`${XDG_DATA_HOME:-$HOME/.local/share}/zwanenzang/trackers/<key>`, where `<key>`
is the full lowercase SHA-256 of the URL's exact UTF-8 bytes, without a trailing
newline. Different URL spellings are distinct; no normalization or git rewrite
is used to compute identity. Use a canonical URL without credentials. Local
origins must be absolute paths or `file://` URLs. Storage must be absolute;
missing HOME and XDG_DATA_HOME, or relative data-home values, are
`invalid-argument`.

An exclusive parent-directory lock covers provisioning and validation. Existing
storage must be a standalone tracker work-tree root with a `.git` directory and
exactly the requested clone-local origin; invalid storage is refused, never
reset or replaced. Incomplete storage and origin mismatches are
`invalid-argument`; git failures are `git`, filesystem failures `io`. A failed
clone may leave a directory requiring manual inspection. Symlinks to valid
standalone clones work; linked worktrees do not. The clone's existing actor,
unpublished work and configuration survive reuse.

The initial clone needs the network; existing clones are not fetched implicitly.
Read-only commands retain their unlocked, local-only semantics, and mutations
retain the exclusive clone lock and usual commit/sync behavior. Storage is
persistent data, not a cache: do not remove it during workspace cleanup.

## Output and exit status

- Success: exactly one JSON value on stdout, exit status 0. Its layout
  (indentation, key order) is not part of the contract.
- Failure: `{"error": {"code": "...", "message": "..."}}` on stdout, exit
  status 1. `code` is stable and machine-readable; `message` is for humans.
- Usage errors (unknown command, missing argument) are reported by the
  argument parser on stderr with exit status 2, not as JSON.
- `lint` prints its report and exits 1 when it found any issue.
- `sync` prints its sync object and exits 1 when `sync.error` is set; there
  is no top-level `error` then.

Nothing is printed on stderr on success.

## Ticket references

Wherever a command takes a ticket it accepts:

- a full ULID,
- any unique prefix of at least 4 characters, case-insensitive,
- a number such as `ZZ-0042` or `zz-42`, once the ticket has one.

An unknown reference fails with `unknown-ticket`, an ambiguous prefix with
`ambiguous-ticket`. Tombstoned tickets still resolve, so `show` works on
them; any change to them fails with `tombstoned`.

## Commands

| Command | Writes | Output |
|---|---|---|
| `init --prefix P [--name N]` | config, `.gitattributes`, actor id; a git repository if there is none; first commit | init object |
| `create TITLE [--status S] [--kind K] [--parent T] [--tag X]...` | `create`, then `parent`, `tag` | mutation object |
| `status T STATUS` | `status` | mutation object |
| `title T TITLE` | `title` | mutation object |
| `kind T KIND` / `kind T --clear` | `kind` | mutation object |
| `priority T VALUE` / `priority T --clear` | `priority` | mutation object |
| `parent T P` / `parent T --clear` | `parent` | mutation object |
| `relate T OTHER [--remove]` | `relate` / `unrelate` | mutation object |
| `depend T PREREQUISITE [--remove]` | `depend` / `undepend` | mutation object |
| `tag T TAG [--remove]` | `tag` / `untag` | mutation object |
| `branch T REPO NAME` | `branch` | mutation object |
| `mr T REPO URL` | `mr` | mutation object |
| `archive T` | `archive` | mutation object |
| `unarchive T` | `unarchive` | mutation object |
| `tombstone T` | `tombstone` | mutation object |
| `comment T [TEXT] [--file PATH] [--link L]` | `comment` | mutation object |
| `doc set T NAME --base ID\|none [--file PATH]` | `doc` | mutation object |
| `doc get T NAME` | nothing | document object |
| `show T` | nothing | ticket object |
| `list [--status S]... [--tag X]... [--kind K]... [--all]` | nothing | `{"tickets": [summary, ...]}` |
| `query [T]... [--status S]... [--tag X]... [--kind K]... [--parent T\|none] [--under T] [--repo R]... [--title TEXT] [--all] [--summary]` | nothing | `{"tickets": [ticket, ...]}` |
| `sync` | `number`, commits | `{"sync": sync object}` |
| `read` | nothing; request from stdin | scope read object (below) |
| `apply` | list of changes from stdin, one mutation commit and one sync | batch apply object (below) |
| `lint` | nothing | lint report |
| `import ai-workflow SOURCE [--exclude ENTRIES]... [--exclude-file PATH]... [--repo-alias FROM=TO]... [--dry-run]` | `actor`, then per ticket `create`, `doc`, `comment`, `branch`, `mr`, then `relate`, `parent`; copies linked files into `docs/` | import report |

`comment` reads its text from the argument, from `--file`, or from stdin.
Text up to 2048 bytes is stored inline; longer text goes to a blob. Text that
is empty or only whitespace is refused with `invalid-comment` whichever way it
would be stored. `doc set` reads the new text from `--file` or stdin.

`archive` and `unarchive` change only the `archived` flag, never `status`.
Archiving an archived ticket or unarchiving one that is not archived writes
nothing and reports `"written": false`. Both are refused on a tombstoned
ticket with `tombstoned`.

`depend T P` records that T depends on P (all prerequisites, not any-of).
It never changes or restricts status. Self-edges and added edges closing a
cycle are refused with `dependency-cycle`; targets must exist and new edges
require a live target. Existing edges survive archive/tombstone and can still
be removed with `--remove`. An existing addition or absent removal is a
no-op. Concurrent valid edges may form a cycle after sync; replay keeps them
and lint reports the cycle rather than silently dropping an edge.

`list` shows tickets that are neither archived nor tombstoned unless `--all`
is given. Repeated `--status` and `--kind` match any of the values; repeated
`--tag` requires all of them. Tickets are ordered by id, which is creation
order.

`query` returns full ticket objects, as `show` does, for every ticket that
matches all of the filters given; `--summary` returns summaries instead.
Ticket arguments limit the result to those tickets and, unlike the other
filters, include them even when archived or tombstoned; otherwise those are
left out unless `--all` is given. `--status`, `--kind` and `--repo` match any
of their values and `--tag` requires all, as in `list`. `--parent T` keeps
direct children of `T`, `--parent none` tickets without a parent, `--under
T` descendants of `T` at any depth (not `T` itself). `--repo` matches a
branch or merge request in that repository alias, and `--title` a substring
of the title, ignoring case. Tickets are ordered by id. An unknown or
ambiguous ticket reference anywhere fails the whole query.

`query` reads derived state only. `read` supplies events after per-ticket
cursors and document text for a whole scope in one call.

Read-only commands (`show`, `list`, `query`, `read`, `doc get`, `lint`) take no lock,
write nothing, do not fetch and do not need git.

Every command that writes events commits them, as one commit holding only
the files it wrote, and then syncs: fetch the branch's upstream, rebase,
give every unnumbered live ticket the next number, push. A clone whose
branch has no upstream is the whole tracker and numbers new tickets at
once. When the remote cannot be reached, the rebase conflicts or the push
fails, the command still succeeds with its events committed locally, and
its `sync` object says what went wrong; the next write or `sync` pushes
them. `sync` runs the same steps without a write and exits 1 when they
fail. Edits to `docs/` and `zwanenzang.toml` are never committed by the
tool.

`import ai-workflow` reads the frozen ai-workflow tracker at `SOURCE` (a
checkout holding `tickets/` and `docs/`, or its `tickets/` directory) and
never writes there. `--exclude` takes comma-separated entries;
`--exclude-file` a file with one entry per line, `#` starting a comment.
Both repeat and add up. An entry is a ticket id (`AIWF-0005`), which leaves
that ticket out, or a path pattern starting with `docs/`
(`docs/*-review.md`), which leaves matching supporting files uncopied;
`*` matches any characters and `?` one character, neither crossing a
`/`, and the pattern must match the whole path. `--repo-alias FROM=TO` imports the source's repository
alias `FROM` as `TO`. Every alias the imported branches and merge requests
use must be declared in `zwanenzang.toml` first. The import is written as a
new actor named `ai-workflow import`; `--actor-name` names only this clone's actor, which numbers the imported tickets in the sync afterwards. All
of it is written or none of it; `--dry-run` validates everything and
writes nothing. Running it again imports only tickets not imported yet.
How tickets map to events is listed in the
[data model](design/01-data-model.md) under the milestone 2 choices.

### Batch apply

`apply` takes exactly one JSON object on stdin. `changes` is required and
may be empty. Each change has `op`, `data` (an object), and, except for
`create`, a non-null `ticket`:

```json
{"changes": [
  {"op": "create", "data": {"title": "Example parent", "status": "todo"}},
  {"op": "create", "data": {"title": "Example child"}},
  {"op": "parent", "ticket": {"created": 1}, "data": {"to": {"created": 0}}},
  {"op": "doc", "ticket": {"created": 1},
   "data": {"name": "description", "text": "Example body", "base": null}},
  {"op": "tag", "ticket": "ZZ-0042", "data": {"tag": "example"}}
]}
```

A reference is either an ordinary ticket reference string, or
`{"created": N}` where N is the zero-based **change index** of an earlier
`create` in this request. The same syntax works for `ticket` and for
`parent.to`, `relate.to`, `unrelate.to`, `depend.to` and `undepend.to`. Forward references, references
to non-create changes and negative/non-integer indices are invalid. Order
all creates before changes that connect them when pushing a scope. Ordinary
references resolve against the state at the start of the batch under the
write lock, before any fetch; use created references for new tickets.

Supported operations and their complete input data fields:

| op | data |
|---|---|
| `create` | `{title, status?, kind?}`; default status is the first replayed vocabulary entry; kind defaults to null; ticket absent or null |
| `title`, `status` | `{to: string}` |
| `kind` | `{to: string or null}`; required, null clears |
| `priority` | `{to: integer or null}`; required, null clears explicit priority |
| `parent` | `{to: reference or null}`; required, null clears |
| `relate`, `unrelate`, `depend`, `undepend` | `{to: reference}` |
| `tag`, `untag` | `{tag: string}` |
| `branch` | `{repo: string, name: string}` |
| `mr` | `{repo: string, url: string}` |
| `archive`, `unarchive`, `tombstone` | `{}` |
| `comment` | `{text: string, link?: string or null}` |
| `doc` | `{name: string, text: string, base: full version ULID or null}` |

Document text is UTF-8 JSON text, including empty text. `base` is mandatory:
null asserts that the document does not exist; otherwise it must be the
current version id returned by a read. A stale base rejects the entire
batch with `stale-doc-base`, even if the submitted text is identical.
With a current base, identical text is a no-op and retains the old version.
Do not submit two changed versions of the same document in one batch: the
second would need the not-yet-known version id produced by the first.
Comments follow the ordinary CLI's whitespace and inline/blob rules. Clients
send text, never blob hashes. `number`, `actor`, and `config` are unavailable
in batches.

The whole batch is validated in input order through the ordinary live-write
core, against the effects of earlier changes. Reference resolution and
request shape checks precede that validation. A failure writes no events,
blobs or commit and performs no sync. Existing actor-id/lock bookkeeping may
still occur. There are no partial results. Invalid JSON, missing/unknown
request, change or data fields, bad field types, unsupported operations and
invalid created references use `invalid-argument`. Existing ticket resolution
and validation errors retain their usual codes. Error messages are for
humans; callers must not parse them to locate a change.

A successful nonempty mutation writes one commit (`apply client batch`),
then runs one sync cycle under the same lock; publication may add its own
numbering commit and retry as usual. Remote failure still returns success
with local events committed and the failure in `sync`. This is validation
atomicity, not a rollback guarantee for disk/git failures or remote races.
A concurrent remote document edit can still become a lost edit at replay;
clients inspect the next `read` and handle conflicts as on ordinary sync.

```json
{"written": true,
 "results": [{"ticket": "<ULID>", "written": true, "event": "<event ULID>"},
             {"ticket": "<ULID>", "written": false, "event": null}],
 "created": {"0": "<created ticket ULID>"},
 "tickets": [{"id": "<ULID>", "...": "full ticket fields"}],
 "events": [{"...": "written event envelope"}],
 "sync": {"...": "ordinary sync object"}}
```

- `results` has exactly one entry per input change, in input order. Each
  entry names the resolved ticket and the event id it wrote, or null for a
  no-op. Creates always write; their event id equals the ticket id.
- `created` maps create change indices (JSON object keys are strings) to
  ticket ULIDs. Use these ids to persist identity back to client headings.
- `tickets` contains each distinct ticket targeted by a change once, in id
  order, with full state **after sync**, including assigned numbers. Tickets
  mentioned only as `to` targets are not included. Use `read` for all affected
  tickets, current document text and new cursors; `apply` returns no cursors
  and does not change the read contract.
- `events` contains the mutation's written envelopes in order, including a
  possible actor declaration, excluding no-ops and publication events.
- An empty or entirely no-op batch returns `written: false`, `events: []`,
  `created: {}`, `sync: null`; it does not commit or sync. No-op results and
  their tickets are still returned; an empty batch has empty lists.

### Scope read

`read` takes exactly one JSON object on stdin. Both fields may be omitted:

```json
{"cursors": {"ZZ-0042": "<opaque ticket cursor>", "ZZ-0043": null},
 "since": "<opaque scope cursor>"}
```

`cursors` names headings already in scope using any supported ticket
reference. Null requests all history for that ticket. `since` is the scope
cursor from the last read; null requests discovery of all live tickets.
Unknown or ambiguous references fail the whole call with the usual ticket
reference errors. Duplicate references to the same ticket, malformed cursors
and unknown request fields fail with `invalid-argument`.
No actor is allocated; no git repository is needed.

```json
{"tracker": {"id": "<tracker ULID>", "name": "...", "prefix": "ZZ",
             "statuses": ["draft", "..."], "kinds": ["task", "..."],
             "priority": {"highest": 65, "lowest": 67, "default": 66},
             "actors": {"<actor ULID>": "<display name>"}},
 "cursor": "<opaque scope cursor>" | null,
 "reset": false,
 "tickets": [{"ticket": {<full ticket object>},
              "documents": {"description": "<current text>", "plan": "..."},
              "events": [{<accepted event>}, ...],
              "cursor": "<opaque ticket cursor>", "reset": false}]}
```

- Tickets are in id order. All named tickets are returned, including
  archived and tombstoned tickets, even with no newer events. Other tickets
  appear only when neither archived nor tombstoned and affected by an
  event newer than the scope cursor. Supplying only `since` discovers
  changes to absent tickets; supplying `{}` reads every live ticket.
- Full state and current document text are returned even when no events
  are newer. `documents` maps names to UTF-8 text, with version ids and
  blob names in `ticket.documents`. Missing document blobs fail the call.
  Vocabularies include accepted `config` events. `tracker.actors` maps
  every actor with an accepted declaration to its display name, so a
  client can name comment authors; undeclared actors are left out.
- Events are in id order, exclusive of the input cursor. They include
  relations from the other end, child moves on both old and new parents,
  and tombstones that remove visible children or relations. The event's
  `entity` remains the ticket it was written on. Tracker-level events are
  excluded from per-ticket history.
- Cursors are opaque and specific to a tracker or ticket. Save them
  verbatim, separately from `last_event`. They fingerprint history so a
  lower-id event merged later cannot be silently missed. A changed or
  unavailable history prefix returns `reset: true` and all accepted
  history for that ticket. A scope reset rediscovers all live absent
  tickets. Treat these as a full comparison against the client's saved
  sync state, preserving local edits and avoiding duplicate comments.
  A well-formed cursor for another entity also resets. Null input is an
  initial read, with `reset: false`. An empty tracker has a null scope cursor.
- The response uses one replay of local logs. It does not fetch; call
  `sync` first to incorporate remote events.

### Init object

```json
{"tracker": {"root": "/path", "id": "<root ULID>", "name": "...", "prefix": "ZZ",
             "statuses": ["draft", "..."], "kinds": ["task", "..."]},
 "actor": "<this clone's actor ULID>",
 "sync": {<sync object>}}
```

### Sync object

```json
{"upstream": "origin/main" | null, "pushed": true,
 "numbered": [{"id": "<ticket ULID>", "number": 42, "display": "ZZ-0042",
               "event": "<number event ULID>"}],
 "error": null | {"code": "fetch-failed", "message": "..."},
 "checkouts": {
   "target": "<commit object id>" | null,
   "error": null | {"code": "checkout-inspection-failed", "message": "..."},
   "results": [
     {"path": "/configured/checkout", "status": "updated"},
     {"path": "../other-checkout", "status": "up-to-date"},
     {"path": "/dirty/checkout", "status": "skipped",
      "reason": "dirty", "message": "..."}
   ]}}
```

- `upstream` is `null` when the branch has none; nothing is fetched or
  pushed then, and `pushed` is `false`.
- `numbered`: numbers this sync assigned, and pushed when there is an
  upstream. A push that does not land takes its numbers back, so they are
  never listed then.
- `error.code`: `fetch-failed` (the remote could not be reached),
  `rebase-conflict` (rebasing onto the remote conflicted, which only
  `docs/` can; the rebase was aborted), `push-failed`, `push-rejected`
  (the remote kept moving; gave up after five attempts).

`checkouts` is present on every returned sync object, including sync after
mutations, batches and init. Configure paths in the **owned clone** with:

```sh
git -C /owned/clone config --local --add zwanenzang.checkout /human/checkout
```

Only local values are read; there is no global registry. Values must be
UTF-8; an undecodable list is an inspection failure. Relative paths
resolve against the owned clone root, without shell or `~` expansion.
`results` follows configuration order, including duplicates, with `path`
exactly as configured. With no configured paths it is `[]`. Each result has
`status`: `updated` (fast-forwarded), `up-to-date` (already at target and
passed safety checks), or `skipped`. Only `skipped` has `reason` and
`message`; messages are for humans, not parsing. All these fields are
returned even when publication failed, and never change the mutation's
success or `sync` exit status; only the outer `error` does that.

`target` is the commit successfully pushed, or, if push did not succeed,
the commit from the last successful fetch **during this sync**. A failed
retry fetch retains an earlier successful observation; a fetch finding no
upstream branch clears it. An initial fetch failure or an absent branch
with no successful push leaves `target: null`, and checkouts are skipped.
Cached remote refs and earlier `FETCH_HEAD` values are never fallbacks.
Without an upstream, `target` is owned `HEAD` after numbering. It is
reported even with no configured checkouts. Unpushed commits are never used
when an upstream exists. The target is an observation, not a claim that
the remote has stopped moving since it was fetched/pushed.

`checkouts.error` is normally null. Failure to read the list or inspect the
source sets `checkout-inspection-failed` and leaves `results: []`, without
changing the outer publication error. A fatal owned-clone error that prevents
a sync report also prevents checkout updates. Empty/all-no-op writes do
not sync, so still return `sync: null`.

Skip reasons (stable strings):

| reason | Meaning |
|---|---|
| `no-published-target` | No commit safely observed during this sync; no checkout inspection attempted. |
| `source-detached` | Owned clone has no current branch to match. |
| `not-a-repository` | Empty/missing/inaccessible path, bare repository, or path not at a work tree root. |
| `source-repository` | Source itself, an alias, or a linked worktree sharing its common git directory. |
| `detached-head` | Human checkout has no current branch. |
| `wrong-branch` | Full branch ref differs from the owned clone's current branch, regardless of upstream branch names. |
| `operation-in-progress` | Human checkout has an unfinished merge, rebase, cherry-pick, revert, sequencer or bisect. |
| `dirty` | Work tree/index has staged, tracked, untracked, ignored or submodule changes. |
| `unborn-head` | Checkout has a branch but no HEAD commit. |
| `not-fast-forward` | Human HEAD is ahead of, divergent from, or unrelated to the target. |
| `update-failed` | Other checkout inspection, local transfer, ancestry check or fast-forward failure (e.g. an index lock); remaining paths are still attempted. |

When several checks fail, the first applicable reason in the table is
reported. Checkouts are canonicalized before opening, so aliases cannot
evade the source check. Commits are fetched only from the owned clone by
local path; human remote refs, tags and `FETCH_HEAD` are left alone. A
transfer can add objects even if ancestry or fast-forward later fails.
Checkout commands allow only the file transport (including after URL
rewrites) and disable lazy object fetching, so a missing object or rewritten
network URL yields `update-failed` rather than contacting a human remote.
The update uses Git's normal ref/index locks and overwrite checks, disables
autostash, hooks, fsmonitor and submodule recursion, and never resets or stashes human
work. Safety checks are optimistic; human branch changes and edits should
be serialized with sync.

### Mutation object

```json
{"written": true,
 "event": {<the event the command asked for>},
 "events": [{<every line written, in order>}],
 "ticket": {<ticket object after the write>}}
```

- A write that would not change derived state (the same status again, an
  existing tag, `--remove` of a tag the ticket does not have, a document
  version with the text it already has) is not written: `written` is
  `false`, `event` is `null` and `events` is empty.
- The first write by a clone's actor also writes an `actor` event before
  the requested one, so `events` may be longer than one.
- For `create`, `event` is the `create` event and `events` also holds the
  `parent` and `tag` events from `--parent` and `--tag`.
- A command writes all of its events or none: if one is refused, nothing is
  written and the error is returned.
- `sync` is the sync object for the sync after the write, or `null` when
  nothing was written. `ticket` is the state after it, so a ticket can
  already carry its number. The `number` events are in `sync.numbered`,
  not in `events`.

### Import report

```json
{"dry_run": false,
 "source": {"root": "/path", "tickets": "/path/tickets", "revision": "<commit>" | null},
 "actor": "<the import actor's ULID>" | null,
 "events": 183,
 "imported": [{"source": "AIWF-0003", "file": "tickets/AIWF-0003-x.md", "id": "<ULID>" | null,
               "title": "...", "status": "todo", "source_status": "needs-plan" | null,
               "kept_fields": ["handoff"]}],
 "already_imported": [{"source": "AIWF-0001", "id": "<ULID>"}],
 "excluded": [{"source": "AIWF-0005", "file": "tickets/AIWF-0005-y.md"}],
 "dropped_references": [{"source": "AIWF-0003", "field": "related" | "original-ticket" | "parent",
                         "target": "AIWF-0005", "reason": "excluded" | "missing" | "self"}],
 "docs": [{"path": "docs/notes.md", "linked_from": ["AIWF-0003"], "existing": false}],
 "dropped_docs": [{"path": "docs/review.md", "linked_from": ["AIWF-0003"], "pattern": "docs/*review*"}],
 "warnings": [{"source": "AIWF-0003" | null, "code": "unknown-status", "message": "..."}],
 "sync": {<sync object>} | null}
```

- `revision` is the source's commit when `SOURCE`'s root is a git
  checkout, read with read-only git commands; otherwise `null`.
- `actor` and each `imported[].id` are `null` on a dry run and when
  nothing was written. `events` counts the lines written, or that would
  be written on a dry run.
- `already_imported`: tickets an earlier run imported, found by their
  provenance comment; they are left as they are.
- `dropped_references`: references of the imported tickets to tickets
  that are excluded, not in the source, or the ticket itself. Nothing is
  written for them.
- `docs`: supporting files linked from imported descriptions, copied to
  the same path in the tracker. `existing` means the tracker already held
  identical content.
- `dropped_docs`: linked supporting files an exclude pattern left out,
  with the first pattern that matched. The link text in the description
  stays as written; no file and no link comment is written for them.
- Warning codes: `unknown-status` (missing or not in the ai-workflow
  vocabulary; imported as `draft`), `no-title` (no `# ` heading; title
  from the file name), `no-frontmatter`, `unknown-field` (kept as text),
  `missing-doc-file` (a link into `docs/` that does not resolve to a
  file there), `skipped-file` (not a `PREFIX-NNNN-slug.md` file),
  `unknown-exclude` (an excluded id not in the source, or a pattern
  matching no file linked from an imported ticket), `excluded-but-imported`, `imported-twice`,
  `dirty-source`, `no-revision`.

### Event

Each event is the envelope from the [data model](design/01-data-model.md):

```json
{"id": "...", "actor": "...", "parent": "..." | null, "ts": "2026-11-07T12:34:56Z",
 "entity": "...", "op": "status", "data": {"to": "doing"}}
```

Operation data:

| op | data |
|---|---|
| `create` | `{title, status, kind?}` |
| `number` | `{number}` |
| `title`, `status` | `{to}` |
| `kind` | `{to: name \| null}` |
| `priority` | `{to: integer \| null}`; native Org value |
| `parent` | `{to: ticket id \| null}` |
| `relate`, `unrelate` | `{to: ticket id}` |
| `branch` | `{repo, name}` |
| `mr` | `{repo, url}` |
| `tag`, `untag` | `{tag}` |
| `archive`, `unarchive`, `tombstone` | `{}` |
| `comment` | `{text}` or `{blob}`, plus optional `{link}` |
| `doc` | `{name, blob, base: version id \| null}` |
| `actor` | `{name}` (the writing actor's display name) |
| `config` | `{add_statuses?, add_kinds?}` |

### Ticket object

`show` returns, and every mutation object embeds:

```json
{"id": "<ULID>", "short_id": "01JC3V5N0T", "number": 42 | null,
 "display": "ZZ-0042" | "<short_id>",
 "title": "...", "status": "doing", "kind": "bug" | null,
 "priority": 65 | null,
 "parent": "<ULID>" | null, "children": ["<ULID>", ...], "related": ["<ULID>", ...],
 "tags": ["..."], "branches": [{"repo": "app", "name": "..."}],
 "mrs": [{"repo": "app", "url": "..."}],
 "archived": false, "tombstoned": false,
 "created": {"id": "<ULID>", "actor": "<ULID>", "ts": "..."},
 "last_event": "<ULID>",
 "activity": {"id": "<ULID>", "actor": "<ULID>", "ts": "..."},
 "tag_since": {"example": {"id": "<ULID>", "actor": "<ULID>", "ts": "..."}},
 "documents": {"description": {"current": "<version id>" | null, "blob": "<sha256>" | null,
                               "versions": [{"id", "actor", "ts", "blob", "base", "lost"}]}},
 "comments": [{"id", "actor", "ts", "text", "blob", "link"}]}
```

- `short_id` is the shortest unique prefix of the id among all entities, at
  least 10 characters. `display` is the number when there is one.
- `priority` is an explicit native Org value: 0–64 means numeric cookies,
  65–90 means A–Z. Null means no cookie, not an explicit default. Effective
  priority uses `[priority].default` in `zwanenzang.toml`; `highest`, `lowest`
  and `default` are configurable integers with `0 <= highest <= default <=
  lowest <= 90`, defaulting to 65/67/66. Live priority writes outside that
  range return `invalid-priority`. Replay accepts any native value 0–90,
  so changing settings does not invalidate old events. `read.tracker.priority`
  exposes the three settings. Clearing priority never materializes a default.
- `children` and `related` leave out tombstoned tickets. `parent` is the
  field's value even if that ticket is tombstoned.
- `last_event` is the id of the latest accepted event whose entity is this
  ticket. Changes made from the other side (a relation, a child's parent)
  do not move it.
- `activity` references the same event as `last_event`, including its original
  wall-clock `ts`. It includes accepted replay no-ops and lost document versions,
  not rejected events. Live no-ops write nothing. It is not a sync/freshness time;
  timestamps may be skewed and must not be inferred from ULID bits or Git dates.
- `tag_since` maps each currently present tag to the accepted event that began
  its current uninterrupted membership interval. Duplicate additions do not
  reset it; removal clears it; readdition starts a new interval. Ordinary
  activity does not reset it. Both fields are derived by full replay, including
  late-arriving older events; they are not writable metadata.
- `documents.*.versions` is the full history in replay order. `lost: true`
  marks a version written against a stale base; it never became current.
- `comments.*.text` is always the comment's text, read from its blob when it
  has one; `blob` is `null` for inline comments.

A summary (in `list`, and in `query --summary`) has the fields `id`, `short_id`, `number`, `display`,
`title`, `status`, `kind`, `priority`, `parent`, `tags`, `depends_on`, `blocks`, `archived`,
`tombstoned`, `last_event`, `activity` and `tag_since`. Full ticket objects include these fields too.
`depends_on` contains prerequisite ULIDs; `blocks` contains dependent ULIDs,
computed from forward edges. Both arrays are sorted, include archived and
tombstoned endpoints, and contain no cross-tracker identities.

### Document object

```json
{"ticket": "<ULID>", "display": "...", "name": "description",
 "version": "<version id>", "blob": "<sha256>", "actor": "<ULID>", "ts": "...",
 "text": "..."}
```

To change a document, pass the `version` you read as `--base` to `doc set`.
A first version uses `--base none`. If this clone knows of a version written
since, the write fails with `stale-doc-base`: read again, merge, and write
against the new version. A concurrent version the clone has not fetched yet
is not refused; once both are known, the one with the lower id stays current
and the other is marked `lost` in `versions`.

### Lint report

```json
{"ok": false, "events": 123,
 "skipped": [{"log", "line", "id", "op", "code", "message", "raw"}],
 "concurrent": [{"entity", "field", "earlier", "earlier_value", "later", "later_value", "won"}],
 "lost_documents": [{"entity", "name", "event", "actor", "base", "current"}],
 "dependency_cycles": [{"ticket", "to"}],
 "dangling_repos": [{"event", "entity", "op", "repo"}],
 "unnamed_actors": [{"actor", "events"}]}
```

- `skipped`: lines replay did not apply, with the reason `code` (see below)
  and the line as found (a lossy rendering when the line is not valid
  UTF-8, which is skipped as `malformed`). `log` is the log file name without `.jsonl`,
  `line` is 1-based; `id` and `op` are `null` when they could not be read.
- `concurrent`: two changes by different actors to the same field (`title`,
  `status`, `kind`, `priority`, `parent`) of one ticket where the later writer had not
  seen the earlier change, with different values. The later one won.
  Directed dependency add/remove disagreements on the same edge use field
  `depends_on` and values `{to: <prerequisite ULID>, present: boolean}`.
  Edits on distinct edges do not conflict; no-op writes express no intent
  against unseen changes.
- `lost_documents`: document versions written against a stale base;
  `current` is the version that was current when the lost one was replayed.
- `dependency_cycles`: every current edge participating in a dependency cycle,
  sorted by dependent (`ticket`) then prerequisite (`to`). Tombstoned endpoints
  are included. This is a current-graph diagnostic, not skipped history;
  removing edges can clear it. A nonempty array makes lint exit 1.
- `dangling_repos`: `branch` and `mr` events naming a repository alias that
  `zwanenzang.toml` does not declare.
- `unnamed_actors`: actors with accepted events but no `actor` declaration.

## Error codes

Command errors:

| code | meaning |
|---|---|
| `not-a-tracker` | no `zwanenzang.toml` here or above |
| `already-initialized` | `init` in an existing tracker or anywhere inside one |
| `config` | `zwanenzang.toml` or the actor id file is invalid, or `init` got a bad prefix or name |
| `unknown-ticket`, `ambiguous-ticket` | a ticket reference did not resolve to one ticket |
| `unknown-document` | `doc get` of a document the ticket does not have |
| `missing-blob` | a blob to read is missing |
| `invalid-argument` | an argument is malformed, such as `--base` |
| `invalid-source` | an import source file cannot be read as a ticket: frontmatter outside the supported subset, a field of the wrong shape, a duplicate id |
| `undeclared-repo` | an import would use repository aliases that `zwanenzang.toml` does not declare |
| `doc-conflict` | an import would overwrite a file in `docs/` that has different content |
| `not-a-repository` | a write in a tracker that is not the top of a git work tree |
| `inside-repository` | `init` in a directory inside another git work tree |
| `git` | a git command failed unexpectedly |
| `io` | a file could not be read or written |

Rejections: returned as the error code when a write is refused, and as
`skipped[].code` in lint when replay skips an event.

| code | meaning |
|---|---|
| `malformed` | the line is not a valid event envelope (replay only) |
| `invalid-data` | the operation's data does not parse or is out of range |
| `unknown-op` | an operation this build does not know (replay only) |
| `actor-mismatch` | the event's actor is not the log it was found in (replay only) |
| `duplicate-id` | different lines share one id (replay only) |
| `id-not-after-parent` | the id does not sort after the event's parent |
| `id-out-of-range` | the id's time is more than 1000 years after the newest id before it; such a line also does not count as seen |
| `unknown-entity` | the ticket does not exist |
| `entity-exists`, `create-id-mismatch` | a `create` that does not create a new entity named by its own id |
| `wrong-entity` | a ticket operation on the tracker root, or `actor`/`config` on a ticket |
| `tombstoned` | the ticket is tombstoned |
| `invalid-title`, `invalid-tag`, `invalid-name`, `invalid-comment` | a value has the wrong format |
| `status-not-in-vocabulary`, `kind-not-in-vocabulary` | not in the tracker's vocabulary |
| `invalid-priority` | outside the configured live range or not a native Org priority value |
| `unknown-target`, `target-tombstoned` | a parent, relation or dependency target is missing or tombstoned |
| `parent-cycle`, `self-relation` | the parent chain would loop, or a ticket relates to itself |
| `dependency-cycle` | a dependency self-edge (write/replay), or an added edge would close a cycle (write only) |
| `stale-doc-base` | `doc set` with a base that is not the current version (write only) |
| `missing-blob` | a `doc` or `comment` names a blob that does not exist |
| `number-not-unique`, `number-not-greater`, `already-numbered` | number assignment rules |
