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
unknown operation from a newer build) is skipped and reported by lint, never
fatal. The same failure on a live write is an error returned to the caller.
A `doc` event with a stale base is the one exception: replay keeps it in the
document's history as a lost edit instead of skipping it (see Documents).

## Derived activity and tag intervals

Ticket views expose `activity`, the event reference (`id`, `actor`, `ts`)
corresponding to `last_event`: any accepted own-ticket event, including replay
no-ops and lost document versions. Other-side relationship changes do not
advance it. `tag_since` records the effective absent-to-present event for each
currently present tag. Duplicate additions preserve the interval; removal
clears it, and readdition starts a new interval. These are derived during
replay, not new operations or writable clocks. Late-arriving history therefore
recomputes them deterministically. Event order remains ULID order; selected
wall time need not increase. Neither field claims remote freshness.

## Operations

Ticket lifecycle and metadata:

- `create` — title; entity id is the event's entity id. Numberless until published.
- `number` — assigns the human-facing number. Written by the publish step only.
- `title`, `status`, `kind`, `priority` — scalar fields. Status must be in
  the tracker's configured vocabulary. Priority is nullable native Org value
  0–90 (numeric 0–64, A–Z as 65–90), `{to: integer or null}` with required
  `to`. Live range/default settings live in `[priority]` in TOML; replay
  accepts all native values to preserve history when settings change.
  Unset is distinct from the effective default. See the Org client notes.
- `parent` — set or clear the parent ticket. Cycles are rejected.
- `relate` / `unrelate` — undirected relation to another ticket.
- `depend` / `undepend` — add/remove a same-tracker prerequisite on the
  dependent ticket, `{to: <prerequisite id>}`. Reverse `blocks` is derived.
  Multiple prerequisites mean all-of. No tracker-side status enforcement.
- `branch`, `mr` — repository-scoped references: `{repo, name}` or `{repo, url}`.
  `repo` is an alias from `zwanenzang.toml`, so one tracker can span several
  code repositories.
- `tag` / `untag`.
- `archive` — the tracker's notion of "out of the active set". Distinct from
  status; see the org client notes.
- `unarchive` — puts a ticket back in the active set. Leaves status as it is,
  as `archive` does.
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
`<prefix>-<n>`, such as `ZZ-42`, where the prefix is tracker
configuration and the number is decimal without padding. Input ignores
the prefix's letter case and leading zeros, so `zz-0042` resolves to the
same ticket; a bare number is not number syntax. Earlier versions
displayed four zero-padded digits (`ZZ-0042`); the log stores only the
integer, so references written in that form keep resolving. The
publish step assigns `max + 1` after a fetch and retries on push rejection,
dropping its own unpublished `number` events before retrying. Unpublished
tail of an actor's own log is the only thing ever rewritten, because nobody
has seen it. Gaps are never reused.

Until published, a ticket displays as its short ULID prefix. Prose should not
cite a number before publish. How publish runs is in
[git and sync](02-git-and-sync.md), milestone 3 choices.

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
- `doc.base` is the current version. On replay a stale base is not skipped:
  the version is kept in history as lost and does not become current.
- `number` is unique and greater than any existing number.
- Event id greater than its parent's id.

Dependency self-edges are rejected on write and replay. New dependency edges
must target live tickets; existing edges survive archive/tombstone and can
still be removed. Both forward `depends_on` and reverse `blocks` views retain
tombstoned endpoints, so a missing prerequisite never silently disappears.
The live writer rejects an added edge when its target can already reach the
dependent, including within a batch. Replay deliberately does not reject
longer dependency cycles: individually valid concurrent writes can create one,
and rejecting the later edge would lose a chosen relationship. Lint reports
every current cycle-participating edge as `{ticket, to}` under
`dependency_cycles`, including tombstoned endpoints. Removing an edge repairs
the graph; unrelated writes and status changes remain unrestricted.

Concurrent add/remove changes to the same directed edge use ULID order and
are reported as field `depends_on`, with `{to, present}` values. Distinct
prerequisite edits commute. As with tags, an absent removal or existing addition
is a live no-op: it cannot express intent against an unseen remote write.
Org reconciles its edited set against the state it reads before applying.

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

Prose is Org, not Markdown: descriptions, named documents and comments are
written and read as Org text. The event core and the CLI stay format-blind;
they store UTF-8 text and never parse or convert it.

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
  **Chosen for milestone 2:** an operation, `archive` with `{}` data.
  **Added in milestone 3:** `unarchive`, also with `{}` data, because the
  Emacs client needs it to revive tickets moved back from an `.org_archive`
  file. It mirrors `archive`: ticket entities only, refused on tombstoned
  tickets, and it does not touch status. The flag is the state of the latest
  of the two in ULID order; a concurrent pair is not a concurrent field
  report. A live no-op writes no event, so unarchiving on a clone that has
  not yet fetched a concurrent `archive` writes nothing and the archive
  stands, with no lint report; clients should sync before reviving. A build
  older than the operation skips it as `unknown-op`, so such a build keeps
  the ticket archived until the build is updated.
- Attachments (images). Probably blobs with a size cap, as in epiq, but not
  needed for the first milestones.
- Numbers for imported tickets.
  **Decided:** fresh numbers. The importer writes no `number` events,
  because only publish writes numbers; the sync after the import numbers
  the imported tickets like any others, in import order from `max + 1`,
  without gaps. The original `AIWF-NNNN` stays in each provenance comment.
  Keeping the original numbers, under either prefix, was rejected: it
  would be the one exception to "only publish writes numbers", for the
  sake of ids of an abandoned project.

### Choices made while implementing milestone 2

Recorded here because the notes above left them open. Each may be revisited;
none changes a decision above.

- **No nested trackers.** `init` refuses a directory that is a tracker or
  lies anywhere inside one (`already-initialized`, naming the existing
  root), since a nested tracker would capture the upward search of every
  command run below it. `init` takes the tracker lock like any mutating
  command and repeats the check under it, so of several concurrent `init`s
  in one directory exactly one succeeds.
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
  same status again, an existing tag or relation, archiving an archived
  ticket, unarchiving one that is not archived) is not written; the CLI
  reports `"written": false`. Replay accepts such events if they exist.
- **Short ids.** An unpublished ticket displays as the shortest unique
  prefix of its ULID among all entities, at least 10 characters (the
  timestamp part). The CLI accepts a full ULID, any unique prefix of at least
  4 characters (case-insensitive), or a number.
- **Inline comment limit.** The CLI stores comment text inline up to 2048
  bytes and as a blob above that. The storage form does not change what is
  accepted: a live write refuses empty or whitespace-only text with
  `invalid-comment` in both forms. Replay checks inline text only, since it
  does not read blobs.
- **Documents.** The first version of a document has `base: null`. The CLI's
  `doc set` requires the caller to state the base it read, including
  `null`, so an agent cannot overwrite without naming a version.
- **Operation data.** `title`, `status`: `{to}`. `kind`: `{to}` where
  `null` clears the kind. `parent`: `{to}` where `null` clears the parent.
  `relate`, `unrelate`: `{to}`. `tag`, `untag`: `{tag}`. `number`:
  `{number}`, at least 1. `archive`, `unarchive`, `tombstone`: `{}`.
  `actor`: `{name}`, the writing actor's own display name; a later
  declaration renames it.
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
  unpadded, `ZZ-42`; padded input such as `ZZ-0042` is accepted.
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
- **Stale document base.** A base that is not a version of that document
  at all counts as stale. On a live write a stale base is the error
  `stale-doc-base`.
- **Concurrent field reports.** For each accepted `title`, `status`,
  `kind`, `priority` or `parent` event, every earlier change to the same field of the
  same ticket by another actor that its writer had not seen is reported, if
  the values differ. Two actors choosing the same value is not a conflict.
- **Numbers.** "Unique and greater than any existing number": a number
  equal to an existing one is `number-not-unique`, a smaller one
  `number-not-greater`; a ticket that already has a number cannot get
  another (`already-numbered`).
- **What counts as seen.** Every line whose envelope parses counts for the
  hybrid clock and as the next event's parent, even when replay skips it
  (an unknown operation from a newer build, say), unless its id is out of
  range (below). Empty lines are ignored. A line found in a log other than
  its actor's is `actor-mismatch`.
- **Ids out of range.** Going through ids in ULID order, an id whose time is
  more than 1000 years after the newest id seen before it (the tracker
  root's id for the first) is `id-out-of-range`: skipped, and not seen.
  Without a bound, one line at the end of the ULID range, even one replay
  skips, would leave the hybrid clock no later id and make every later
  write fail. The bound is relative so that reaching the end takes a chain
  of such leaps rather than one line; a fixed ceiling would only move the
  blocking id below it. A live write whose clock is more than 1000 years
  past everything seen is refused with the same code.
- **Live writes are all or nothing per command.** A command such as
  `create --parent P --tag X` writes several events; if any is refused,
  none is written. The actor's `actor` declaration is written only together
  with at least one real change, never alone. A document version whose text
  equals the current version is a no-op.
- **Batched client writes (milestone 3).** `apply` compiles a JSON list to
  one ordinary live-write plan; each change is one existing operation.
  References to earlier create change indices use the plan's existing
  deferred targets, not new on-disk ids. Validation sees preceding changes,
  and rejects the entire batch before writing any blob or log line.
  Documents take text plus a required base; stale bases fail even for
  identical text, while identical text with a current base is a no-op.
  Per-operation outcomes retain input positions including no-ops. The
  [CLI contract](../agent-hooks/cli-json.md) specifies the accepted operations, reference
  syntax, mapping back to created tickets, and failure boundaries.
- **Interrupted appends.** If a log does not end in a newline (an
  interrupted write), the next append starts with one, so lines never run
  together; the partial line is reported as malformed.

- **Query reads derived state only.** `query` filters tickets by fields
  of derived state (status, kind, tags, parent, ancestry, repository, title
  text, named tickets) and returns full ticket objects. Filters are flags
  combined with "and", not an expression language; the clients known so
  far ask for a scope's tickets or a few named ones, and an "or" across
  fields can be two calls. Events after a cursor are left to milestone 3's
  batched read, because the org client keeps one cursor per ticket and
  that read takes the whole set of cursors in one call; a single
  `--after` on `query` would not serve it.

#### Import from the frozen ai-workflow tracker

- **What is imported is the caller's choice.** The importer takes the ids
  to leave out as input (`--exclude`, `--exclude-file`) and never
  classifies tickets itself. A relation, `original-ticket` or `parent`
  naming a left-out ticket, a ticket not in the source, or the ticket
  itself is dropped and reported, so no event names a ticket that is not
  there and replay rejects nothing.
- **One write.** The import is a single live write through the same
  `apply` as every command, so one refused event refuses the whole import.
  Supporting files are copied after every event has been accepted and
  before any line is appended. `--dry-run` runs the same validation and
  writes nothing.
- **Its own actor.** Each run writes as a new actor that declares the name
  `ai-workflow import`, not as the clone's actor: the human did not write
  these events, and one log per run keeps an import recognisable.
- **Ids and times.** Ids come from the hybrid clock at import time and
  `ts` is the import time; history is not reconstructed from the source's
  git log, because ids order writes and wall-clock time is display only,
  and historical ids would sort before events already in the tracker. The
  importer's clock moves at least one millisecond per event, so each
  imported ticket's id has its own time part and short ids keep their
  10-character minimum; ids run ahead of the wall clock by at most a few
  milliseconds per event. When the source root is a git checkout, its
  `HEAD` is read with read-only git commands and recorded as provenance,
  with a warning if `tickets/` or `docs/` differ from it.
- **No numbers.** See the decided question above. Because the import
  writes no numbers itself, the target tracker can have any prefix and
  need not be empty; publish numbers what it imported.
- **Ticket fields.** The title is the first `# ` heading outside fenced
  code; without one it is the file name's slug, with a warning. The body
  without that line, trimmed of blank lines at both ends and with `\n`
  line endings, becomes the first version of the `description` document;
  an empty body writes none. Status maps `draft` to `draft`;
  `needs-triage`, `needs-plan` and `ready-for-implementation` to `todo`;
  `ready-for-review` to `review`; `needs-human-input` to `blocked`; `done`
  to `done`. A missing status or one outside that vocabulary is imported as
  `draft`, with a warning. No kind, tag or archive is written; a done
  ticket stays in the active set until the human archives it.
- **Provenance comment.** Each imported ticket gets one comment whose first
  line is `Imported from the ai-workflow tracker: <id>`, followed by the
  source file, the source revision, the original status, the
  `original-ticket` and any frontmatter with no counterpart here
  (`handoff`, unknown keys) verbatim. Such fields are kept only as text,
  never as structured state, so no process metadata enters derived state.
- **References.** `related` and `original-ticket` become `relate` (the
  provenance comment keeps the direction of `original-ticket`); `parent`
  becomes `parent`. `branches` (`repo: name`) become `branch` events with
  the source key as alias; `merge-requests` become `mr` events with the
  repository name in the URL (`https://HOST/OWNER/REPO/pulls/N`) as alias.
  `--repo-alias FROM=TO` renames an alias. Every alias must be declared in
  `zwanenzang.toml` before anything is written (`undeclared-repo`), so
  lint reports no dangling repositories.
- **Supporting files.** A link in an imported description that resolves
  into the source's `docs/` copies that file to the same path in the
  tracker and adds a comment whose `link` is that path. Only files linked
  from imported tickets are copied, links inside the copied files are not
  followed, and the description text is left as written. A destination
  with different content refuses the import (`doc-conflict`).
- **Leaving supporting files out.** The same exclude input takes `docs/`
  path patterns beside ticket ids (`*` and `?` within one path segment,
  matched against the whole path), so process records such as reviews and
  stage histories need not enter the tracker while plans and contracts
  do. A linked file a pattern matches is not copied and gets no link
  comment; the description keeps the link text as written, and the report
  lists it under `dropped_docs`. One input for both keeps a single
  reviewed list of what stays behind.
- **Re-running.** A ticket counts as imported when a live ticket carries
  its provenance comment; re-runs skip it and import only the rest, so an
  exclusion can be lifted later. References from newly imported tickets
  are restored, so an earlier import only gains relations, and a parent if
  it has none, to newly imported tickets. Excluding a ticket that is
  already imported leaves it as it is, with a warning. Tombstoning an
  imported ticket lets it be imported again.
- **Source format.** The frontmatter reader accepts the subset the frozen
  tracker writes: scalars, flow or block lists of scalars and one-level
  maps. Anything else, a field of the wrong shape, a malformed merge
  request URL or a duplicate id refuses the import (`invalid-source`)
  rather than importing a misread value.
