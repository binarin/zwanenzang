# CLI JSON contract

What a client (the Emacs client, an agent, a script) can rely on when it
runs `zwanenzang`. This describes the local-only slice of milestone 2: no
git, no numbering at publish, no batched operations yet. The format grows by
adding fields; a client must ignore fields it does not know.

## Invocation

```
zwanenzang [-C DIR | --tracker DIR] [--actor-name NAME] <command> ...
```

- `-C DIR`: start the tracker search in `DIR` instead of the current
  directory. The tracker is the nearest directory, upward, that holds
  `zwanenzang.toml`. For `init`, `DIR` is where the tracker is created;
  it must not be in or below an existing tracker.
- `--actor-name NAME`: display name declared by this clone's first write.
  Defaults to `$USER`, then `unknown`. Ignored once the actor is declared.

## Output and exit status

- Success: exactly one JSON value on stdout, exit status 0. Its layout
  (indentation, key order) is not part of the contract.
- Failure: `{"error": {"code": "...", "message": "..."}}` on stdout, exit
  status 1. `code` is stable and machine-readable; `message` is for humans.
- Usage errors (unknown command, missing argument) are reported by the
  argument parser on stderr with exit status 2, not as JSON.
- `lint` prints its report and exits 1 when it found any issue.

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
| `init --prefix P [--name N]` | config, `.gitattributes`, `.gitignore`, actor id | init object |
| `create TITLE [--status S] [--kind K] [--parent T] [--tag X]...` | `create`, then `parent`, `tag` | mutation object |
| `status T STATUS` | `status` | mutation object |
| `title T TITLE` | `title` | mutation object |
| `kind T KIND` / `kind T --clear` | `kind` | mutation object |
| `parent T P` / `parent T --clear` | `parent` | mutation object |
| `relate T OTHER [--remove]` | `relate` / `unrelate` | mutation object |
| `tag T TAG [--remove]` | `tag` / `untag` | mutation object |
| `branch T REPO NAME` | `branch` | mutation object |
| `mr T REPO URL` | `mr` | mutation object |
| `archive T` | `archive` | mutation object |
| `tombstone T` | `tombstone` | mutation object |
| `comment T [TEXT] [--file PATH] [--link L]` | `comment` | mutation object |
| `doc set T NAME --base ID\|none [--file PATH]` | `doc` | mutation object |
| `doc get T NAME` | nothing | document object |
| `show T` | nothing | ticket object |
| `list [--status S]... [--tag X]... [--kind K]... [--all]` | nothing | `{"tickets": [summary, ...]}` |
| `lint` | nothing | lint report |
| `import ai-workflow SOURCE [--exclude IDS]... [--exclude-file PATH]... [--repo-alias FROM=TO]... [--dry-run]` | `actor`, then per ticket `create`, `doc`, `comment`, `branch`, `mr`, then `relate`, `parent`; copies linked files into `docs/` | import report |

`comment` reads its text from the argument, from `--file`, or from stdin.
Text up to 2048 bytes is stored inline; longer text goes to a blob. Text that
is empty or only whitespace is refused with `invalid-comment` whichever way it
would be stored. `doc set` reads the new text from `--file` or stdin.

`list` shows tickets that are neither archived nor tombstoned unless `--all`
is given. Repeated `--status` and `--kind` match any of the values; repeated
`--tag` requires all of them. Tickets are ordered by id, which is creation
order.

Read-only commands (`show`, `list`, `doc get`, `lint`) take no lock and
write nothing.

`import ai-workflow` reads the frozen ai-workflow tracker at `SOURCE` (a
checkout holding `tickets/` and `docs/`, or its `tickets/` directory) and
never writes there. `--exclude` takes comma-separated ticket ids;
`--exclude-file` a file with one id per line, `#` starting a comment. Both
repeat and add up. `--repo-alias FROM=TO` imports the source's repository
alias `FROM` as `TO`. Every alias the imported branches and merge requests
use must be declared in `zwanenzang.toml` first. The import is written as a
new actor named `ai-workflow import`; `--actor-name` does not apply. All
of it is written or none of it; `--dry-run` validates everything and
writes nothing. Running it again imports only tickets not imported yet.
How tickets map to events is listed in the
[data model](design/01-data-model.md) under the milestone 2 choices.

### Init object

```json
{"tracker": {"root": "/path", "id": "<root ULID>", "name": "...", "prefix": "ZZ",
             "statuses": ["draft", "..."], "kinds": ["task", "..."]},
 "actor": "<this clone's actor ULID>"}
```

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
 "warnings": [{"source": "AIWF-0003" | null, "code": "unknown-status", "message": "..."}]}
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
- Warning codes: `unknown-status` (missing or not in the ai-workflow
  vocabulary; imported as `draft`), `no-title` (no `# ` heading; title
  from the file name), `no-frontmatter`, `unknown-field` (kept as text),
  `missing-doc-file` (a link into `docs/` that does not resolve to a
  file there), `skipped-file` (not a `PREFIX-NNNN-slug.md` file),
  `unknown-exclude`, `excluded-but-imported`, `imported-twice`,
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
| `parent` | `{to: ticket id \| null}` |
| `relate`, `unrelate` | `{to: ticket id}` |
| `branch` | `{repo, name}` |
| `mr` | `{repo, url}` |
| `tag`, `untag` | `{tag}` |
| `archive`, `tombstone` | `{}` |
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
 "parent": "<ULID>" | null, "children": ["<ULID>", ...], "related": ["<ULID>", ...],
 "tags": ["..."], "branches": [{"repo": "app", "name": "..."}],
 "mrs": [{"repo": "app", "url": "..."}],
 "archived": false, "tombstoned": false,
 "created": {"id": "<ULID>", "actor": "<ULID>", "ts": "..."},
 "last_event": "<ULID>",
 "documents": {"description": {"current": "<version id>" | null, "blob": "<sha256>" | null,
                               "versions": [{"id", "actor", "ts", "blob", "base", "lost"}]}},
 "comments": [{"id", "actor", "ts", "text", "blob", "link"}]}
```

- `short_id` is the shortest unique prefix of the id among all entities, at
  least 10 characters. `display` is the number when there is one.
- `children` and `related` leave out tombstoned tickets. `parent` is the
  field's value even if that ticket is tombstoned.
- `last_event` is the id of the latest accepted event whose entity is this
  ticket. Changes made from the other side (a relation, a child's parent)
  do not move it.
- `documents.*.versions` is the full history in replay order. `lost: true`
  marks a version written against a stale base; it never became current.
- `comments.*.text` is always the comment's text, read from its blob when it
  has one; `blob` is `null` for inline comments.

A summary (in `list`) has the fields `id`, `short_id`, `number`, `display`,
`title`, `status`, `kind`, `parent`, `tags`, `archived`, `tombstoned` and
`last_event`.

### Document object

```json
{"ticket": "<ULID>", "display": "...", "name": "description",
 "version": "<version id>", "blob": "<sha256>", "actor": "<ULID>", "ts": "...",
 "text": "..."}
```

To change a document, pass the `version` you read as `--base` to `doc set`.
A first version uses `--base none`. If anyone wrote a version since, the
write fails with `stale-doc-base`: read again, merge, and write against the
new version.

### Lint report

```json
{"ok": false, "events": 123,
 "skipped": [{"log", "line", "id", "op", "code", "message", "raw"}],
 "concurrent": [{"entity", "field", "earlier", "earlier_value", "later", "later_value", "won"}],
 "lost_documents": [{"entity", "name", "event", "actor", "base", "current"}],
 "dangling_repos": [{"event", "entity", "op", "repo"}],
 "unnamed_actors": [{"actor", "events"}]}
```

- `skipped`: lines replay did not apply, with the reason `code` (see below)
  and the line as found (a lossy rendering when the line is not valid
  UTF-8, which is skipped as `malformed`). `log` is the log file name without `.jsonl`,
  `line` is 1-based; `id` and `op` are `null` when they could not be read.
- `concurrent`: two changes by different actors to the same field (`title`,
  `status`, `kind`, `parent`) of one ticket where the later writer had not
  seen the earlier change, with different values. The later one won.
- `lost_documents`: document versions written against a stale base;
  `current` is the version that was current when the lost one was replayed.
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
| `unknown-target`, `target-tombstoned` | a parent or relation target is missing or tombstoned |
| `parent-cycle`, `self-relation` | the parent chain would loop, or a ticket relates to itself |
| `stale-doc-base` | `doc set` with a base that is not the current version (write only) |
| `missing-blob` | a `doc` or `comment` names a blob that does not exist |
| `number-not-unique`, `number-not-greater`, `already-numbered` | number assignment rules |
