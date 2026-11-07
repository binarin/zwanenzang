# Data model

## Repository layout

```
zwanenzang.toml          tracker configuration (prefix, name, vocabularies, repos)
.gitattributes           events/*.jsonl merge=union
events/<actor>.jsonl     one append-only log per actor
blobs/<sha256>           content-addressed text of document versions
docs/                    optional bulky supporting files, linked from tickets
```

Nothing else is a source. Derived state is computed in memory on every
invocation; thousands of events replay in milliseconds in Rust, so no cache
is planned. If one becomes necessary it lives in a gitignored directory inside
the clone, never outside it.

## Events

One JSON object per line. Lines are never edited, reordered, deduplicated or
deleted once published. One id is one byte sequence; union merge depends on it.

```json
{"id":"01JC3V7K9QZ8M4R2T6W0XNPB5A",
 "actor":"01JC3TZZ0R5F6G7H8J9KMNPQRS",
 "parent":"01JC3V6H2ABCDEFGHJKMNPQRST",
 "ts":"2026-11-07T12:34:56Z",
 "entity":"01JC3V5N0TICKETULIDXXXXXXX",
 "op":"status",
 "data":{"to":"doing"}}
```

- **id**: ULID, also a hybrid logical clock. A new id must sort after the
  highest id this writer has seen; if the wall clock lags, the clock part is
  bumped. Wall-clock time is a display value, never an ordering input.
- **actor**: the writer. Matches the log file name. Carries nothing else.
- **parent**: the last event this writer had seen when it wrote. Used to
  detect concurrency, not to order.
- **ts**: wall clock, informational.
- **entity**: the ticket, or the tracker root entity.
- **op** and **data**: the operation. The format grows by adding operations
  and optional fields, never by changing the meaning of existing ones.

## Ordering and replay

Order is the ULID sort of all events across all logs. Same event set, same
order, same state. The causal parent is consulted only to classify two events
as concurrent, which drives conflict reporting and document compare-and-set.

Replay is total. An event that fails validation at replay (unknown entity,
stale document parent, unknown operation from a newer build) is skipped and
reported by lint, never fatal. The same failure on a live write is an error
returned to the caller.

## Operations

Ticket lifecycle and metadata:

- `create` — title; entity id is the event's entity id. Numberless until published.
- `number` — assigns the human-facing number. Written by the publish step only.
- `title`, `status`, `kind` — scalar fields. Status must be in the tracker's
  configured vocabulary.
- `parent` — set or clear the parent ticket. Cycles are rejected.
- `relate` / `unrelate` — undirected relation to another ticket.
- `branch`, `mr` — repository-scoped references: `{repo, name}` or `{repo, url}`.
  `repo` is an alias from `zwanenzang.toml`, so one tracker can span several
  code repositories.
- `tag` / `untag`.
- `archive` — the tracker's notion of "out of the active set". Distinct from
  status; see the org client notes.
- `tombstone` — hides an entity created by mistake. Nothing is hard-deleted.

Prose:

- `comment` — append-only note, `{text}` inline or `{blob}` for long text,
  with optional `{link}` to a file or URL. Never edited; a correction is a
  new comment.
- `doc` — sets a named document to a new version:
  `{name, blob, base}` where `base` is the version event id the writer read.
  Refused on a live write if `base` is not the current version.

Actors:

- `actor` — on the tracker root entity, declares a display name for an actor
  id. Written once by each actor on first use.

Tracker-level (entity = tracker root): `config` changes that must be
historical, such as adding a status to the vocabulary.

## Identity and numbers

Entity identity is the ULID of its `create` event. Numbers are aliases:
`<prefix>-<zero-padded>` where the prefix is tracker configuration. The
publish step assigns `max + 1` after a fetch and retries on push rejection,
dropping its own unpublished `number` events before retrying. Unpublished
tail of an actor's own log is the only thing ever rewritten, because nobody
has seen it. Gaps are never reused.

Until published, a ticket displays as its short ULID prefix. Prose should not
cite a number before publish.

## Documents

Each document version is a blob plus a `doc` event. The current version is
the latest `doc` event for that name whose `base` was current at the time,
in replay order. A `doc` whose base was stale is kept in history, reported as
a lost concurrent edit, and does not become current.

Compare-and-set means: an agent must name the version it read; if a human has
written since, the agent re-reads, merges, and writes again. The human side
always wins at the org client; see [org client](03-org-client.md).

Blob text is UTF-8, stored once per distinct content. Blobs are not garbage
collected.

## Validation rules

Applied on live writes (error) and on replay (skip and report):

- Status in vocabulary. Kind in vocabulary. Tag format.
- Parent and relation targets exist and are not tombstoned. No parent cycles.
- `doc.base` is the current version.
- `number` is unique and greater than any existing number.
- Event id greater than its parent's id.

Lint additionally reports: concurrent changes to the same scalar field of one
entity (the later ULID won; a human should know), lost document edits,
dangling repo aliases, actors without a declared name.

## Prose ownership

Four kinds of text, four rules:

| Kind | Example | Storage | Writers |
|------|---------|---------|---------|
| Description | the ticket body the human writes | document `description` | human; agents read only |
| Current summaries | overview, current status, roadmap | named documents | human and agents, compare-and-set |
| Records | decisions, evidence summaries, review verdicts | comments | anyone, append-only |
| Bulky material | plans, full reviews, research | files in `docs/`, linked | anyone, git-merged like any file |

Whether `description` stays human-only or becomes co-edited is an open
question; start human-only.

## Open questions

- Default status vocabulary. Predecessors used draft, in-progress,
  ready-for-review, needs-human-input, done. The org client maps TODO
  keywords to statuses per tracker, so the default matters less than the
  mapping.
  **Chosen for milestone 2:** `draft, todo, doing, blocked, review, done,
  cancelled`, written into `zwanenzang.toml` by `init` and editable there.
  `create` records the initial status in its own data (`{title, status,
  kind?}`, status defaulting to the first vocabulary entry), so derived state
  never depends on the configuration file's current defaults. The default
  kind vocabulary is `task, bug, feature`; kind is optional.
- Whether `archive` is an operation or a derived property of terminal
  statuses. Current leaning: an operation, because the human archives for
  reasons unrelated to status.
  **Chosen for milestone 2:** an operation, `archive` with `{}` data. No
  `unarchive` yet; it is added as a new operation if the org client needs it.
- Attachments (images). Probably blobs with a size cap, as in epiq, but not
  needed for the first milestones.

### Choices made while implementing milestone 2

Recorded here because the notes above left them open. Each may be revisited;
none changes a decision above.

- **Tracker root entity.** `init` generates a ULID for the tracker root and
  stores it as `id` in `zwanenzang.toml`. `actor` and `config` events must
  name that entity; ticket operations must not.
- **Vocabulary growth.** Replay validates status and kind against the
  configuration file's vocabulary plus every name added by earlier `config`
  events (`{add_statuses?, add_kinds?}`). Vocabularies are expected only to
  grow; removing a name from the file makes old events that use it fail
  replay validation, which lint reports. A `config` event that adds nothing
  this build knows (for instance one carrying only fields a newer build
  added) is accepted as a no-op, not skipped.
- **Tag format.** Org-compatible: one or more of `A-Z a-z 0-9 _ @ # %`, at
  most 64 characters.
- **Titles.** Non-empty after trimming, a single line, at most 512 bytes.
- **Hybrid clock.** A new id takes `max(now, highest seen id's time)` in
  milliseconds. If that equals the highest seen id's time, the random part is
  the highest seen id's random part plus one; otherwise it is fresh random.
  "Seen" means every event in every log of the clone at write time.
- **Parent.** The highest event id in the clone at write time, or `null` for
  the first event of a tracker.
- **Concurrency rule.** For two events A < B in ULID order from different
  actors, B is concurrent with A when `B.parent < A.id` (B's writer had not
  seen A). Events of one actor are never concurrent with each other.
- **Duplicate ids at replay.** Byte-identical duplicate lines (which union
  merge can produce) count once. Different lines with the same id are all
  skipped and reported.
- **Envelope checks at replay.** A malformed line, an event whose `actor`
  does not match its log file name, an unknown operation, or invalid data is
  skipped and reported, never fatal. A line that is not valid UTF-8 is
  malformed; lines are decoded one by one, so it does not affect its
  neighbours.
- **Tombstones.** Any further operation on a tombstoned entity is rejected.
  Tombstoned tickets are excluded from `list` unless asked for.
- **No-op writes.** A live write that would not change derived state (the
  same status again, an existing tag or relation) is not written; the CLI
  reports `"written": false`. Replay accepts such events if they exist.
- **Short ids.** An unpublished ticket displays as the shortest unique
  prefix of its ULID among all entities, at least 10 characters (the
  timestamp part). The CLI accepts a full ULID, any unique prefix of at least
  4 characters (case-insensitive), or a number.
- **Inline comment limit.** The CLI stores comment text inline up to 2048
  bytes and as a blob above that.
- **Documents.** The first version of a document has `base: null`. The CLI's
  `doc set` requires the caller to state the base it read, including
  `null`, so an agent cannot overwrite without naming a version.
- **Operation data.** `title`, `status`: `{to}`. `kind`: `{to}` where
  `null` clears the kind. `parent`: `{to}` where `null` clears the parent.
  `relate`, `unrelate`: `{to}`. `tag`, `untag`: `{tag}`. `number`:
  `{number}`, at least 1. `archive`, `tombstone`: `{}`. `actor`: `{name}`,
  the writing actor's own display name; a later declaration renames it.
  Nullable fields (`kind.to`, `parent.to`, `doc.base`) must be present, so a
  writer always states what it means. Unknown fields in `data` and in the
  envelope are ignored at replay, so the format can grow.
- **Create.** A `create` event's entity must be its own id
  (`create-id-mismatch` otherwise), which is what "identity is the ULID of
  its create event" means in the log.
- **Name formats.** Statuses, kinds, document names and repository aliases:
  one or more of `A-Z a-z 0-9 _ -`, at most 64 characters. The number
  prefix: an uppercase letter and up to nine uppercase letters or digits.
  Actor names: a single non-empty line of at most 128 bytes. Branch names
  and merge request URLs: a single non-empty line. Numbers display
  zero-padded to four digits, `ZZ-0042`.
- **Repository aliases** are declared in `zwanenzang.toml` as
  `[repos.<alias>]` tables with a `url` key, so further keys can be added.
- **Relations** are undirected: `relate` adds the pair to both tickets.
  `relate` needs a live target; `unrelate` only needs the target to exist,
  so a relation to a ticket tombstoned later can still be removed. Views
  leave tombstoned tickets out of `related` and `children`; state keeps
  them.
- **Blobs must exist.** A `doc` or `comment` naming a blob that is not in
  `blobs/` is rejected (`missing-blob`). A live write stores its blob only
  after the event is accepted, and before the event line is appended, so no
  accepted event ever names a missing blob.
- **Stale document base at replay.** The Documents section is followed: the
  version is kept in history marked lost and does not become current; lint
  reports it. The mention of a stale document parent among skipped events
  under "Ordering and replay" and "Validation rules" is read as "does not
  become current", not as removal from history. A base that is not a
  version of that document at all counts as stale. On a live write a stale
  base is the error `stale-doc-base`.
- **Concurrent field reports.** For each accepted `title`, `status`,
  `kind` or `parent` event, every earlier change to the same field of the
  same ticket by another actor that its writer had not seen is reported, if
  the values differ. Two actors choosing the same value is not a conflict.
- **Numbers.** "Unique and greater than any existing number": a number
  equal to an existing one is `number-not-unique`, a smaller one
  `number-not-greater`; a ticket that already has a number cannot get
  another (`already-numbered`).
- **What counts as seen.** Every line whose envelope parses counts for the
  hybrid clock and as the next event's parent, even when replay skips it
  (an unknown operation from a newer build, say). Empty lines are ignored.
  A line found in a log other than its actor's is `actor-mismatch`.
- **Live writes are all or nothing per command.** A command such as
  `create --parent P --tag X` writes several events; if any is refused,
  none is written. The actor's `actor` declaration is written only together
  with at least one real change, never alone. A document version whose text
  equals the current version is a no-op.
- **Interrupted appends.** If a log does not end in a newline (an
  interrupted write), the next append starts with one, so lines never run
  together; the partial line is reported as malformed.
