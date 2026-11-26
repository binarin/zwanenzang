# Data model

## Repository layout

```
zwanenzang.toml          tracker configuration (prefix, name, vocabularies, actors, repos)
.gitattributes           events/*.jsonl merge=union
events/<actor>.jsonl     one append-only log per writer (the envelope's `actor`)
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
 "as":"agent",
 "parent":"01JC3V6H2ABCDEFGHJKMNPQRST",
 "ts":"2026-11-07T12:34:56Z",
 "entity":"01JC3V5N0TICKETULIDXXXXXXX",
 "op":"status",
 "data":{"to":"agnt"}}
```

- **id**: ULID, also a hybrid logical clock. A new id must sort after the
  highest id this writer has seen; if the wall clock lags, the clock part is
  bumped. Wall-clock time is a display value, never an ordering input.
- **actor**: the writer, the per-clone id. Matches the log file name.
- **as**: optional, the identity the event was written as, such as
  `binarin` or `agent`; see Writers and identities. Events written before
  identities have none.
- **parent**: the last event this writer had seen when it wrote. Used to
  detect concurrency, not to order.
- **ts**: wall clock, informational.
- **entity**: the ticket, or the tracker root entity.
- **op** and **data**: the operation. The format grows by adding operations
  and optional fields, never by changing the meaning of existing ones.

## Writers and identities

Two things used to be one. The **writer** is the per-clone ULID in the
envelope's `actor`: it names the log, so each log has one writer and
concurrent appends never meet in one file, and everything causal is per
writer: the `actor-mismatch` check, the concurrency rule, commit identity
(unless the clone commits as git's own user, see
[git and sync](02-git-and-sync.md)) and numbering. The **identity** in `as` is who the write is for, chosen on
every write (`--actor-name`), the same from every clone: the human's name
or `agent`. The tracker's `actors` list in `zwanenzang.toml` names the
identities a write may use, validated like the other vocabularies; a write
naming another is refused (`unknown-actor`), and one naming none is refused
too (`actor-required`). Two clones writing as one identity are two writers,
so their concurrent changes are still reported.

An event's identity is its `as`; an event without `as`, written before
identities, resolves to its writer's declared display name (the `actor`
operation below), and to none when the writer never declared one. The
tool never rewrites old events. Builds that predate `as` ignore it as an
unknown envelope field, so they still replay every event; they show each
writer's display name instead of the identity.

A tracker whose `zwanenzang.toml` has no `actors` key, one created before
identities, still replays every event, but accepts no identity for new
writes: they are refused with `actors-not-configured`, whose message says
to add the list. Upgrading the build therefore stops writes to such a
tracker until its owner adds the key; the identity `import` is reserved
for the importer and accepted whatever the list says.

`scripts/assign-identities.py` is a one-off for a tracker's owner: it adds
the `actors` list when there is none, and `as` to every old event
(comments as `agent`, the rest as the human). It changes files in the
work tree only, so publishing it is an ordinary commit and push, and
other clones fetch and rebase onto it as usual. It holds the clone's lock
while it reads and rewrites, so the CLI cannot append to that clone
meanwhile, but nothing stops other clones. An event another clone appends
to a log the migration rewrote, and pushes only after the migration, still
rebases without a conflict, yet union merge then keeps both the old and
the rewritten form of that log's lines, and replay drops both as duplicate
ids. So:

1. Pause every writer, human and agent, until the migration is pushed,
   and sync every clone so that none holds unpushed events.
2. Bring the clone that runs the migration up to date with `sync`.
3. Run the script there, and review `git diff`.
4. Commit the result as an ordinary commit and push it normally.
5. Other clones sync as usual and writers resume.
6. Run `lint` afterwards; its `skipped` list names any duplicate ids a
   missed unpushed event caused.

Clients' read cursors reset once, as the logs changed.

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

Ticket views expose `activity`, the event reference (`id`, `actor`,
`identity`, `ts`)
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
- `scheduled` — a scalar field, the ticket's Org SCHEDULED date,
  `{to: string or null}` with required `to`; null clears it. Decided
  2026-11-26 (ZZ-51). The value is a normalised Org timestamp body, no
  brackets and no weekday:
  `YYYY-MM-DD[ HH:MM[-HH:MM]][ REPEATER][ DELAY]`, such as `2026-12-03`
  or `2026-12-03 10:00 +1w`. It is always an active timestamp, in
  floating local time without a time zone. Weekday names are left out
  because Org writes them in the reader's locale (its `%a`, which may be
  several words and hold digits or punctuation: `T5`, `ה'`, `Aso Tof`).
  On input the weekday is every word after the date up to the first one
  starting with an ASCII digit, `+`, `-` or `.`, which no locale's
  weekday does and every time, repeater and delay does. Words are split
  at any Unicode white space (`lv_LV` ends its weekday in a no-break
  space). A word holding `+`, `-` or a time, such as `Thu+1w`, which Org
  reads as a weekday with a repeater, is never taken for weekday, so the
  value is refused rather than losing that part. `REPEATER` is `+`, `++`
  or `.+`, a count and a unit (`h d w m y`), optionally followed by
  `/` and a second count and unit as Org habits write it; `DELAY` is `-`
  or `--`, a count and a unit. Both are kept as written text; the tool
  never interprets them. Live writes refuse a value that is not in this
  form, or names an impossible date or time (`2026-02-30`, `24:00`),
  with `invalid-timestamp`; replay accepts any string already in the
  log, so a newer build's wider grammar or an older log never loses a
  ticket's date. Nothing clears it on `done` or `cncl`. Storing the date
  is tracking: the tool never reminds, warns or reorders by it. The
  value type and input rules are shared with a later DEADLINE field.
  See the CLI contract for input and the Org client notes for sync.
- `parent` — set or clear the parent ticket. Cycles are rejected.
- `relate` / `unrelate` — undirected relation to another ticket.
- `depend` / `undepend` — add/remove a same-tracker prerequisite on the
  dependent ticket, `{to: <prerequisite id>}`. Reverse `blocks` is derived.
  Multiple prerequisites mean all-of. No tracker-side status enforcement:
  dependencies never veto a status change (the `PROJ` rule below is about
  the parent hierarchy, not dependencies).
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

- `actor` — on the tracker root entity, declares a display name for a
  writer. Written once by each writer, on its first write, naming that
  write's identity. It is what events without `as` resolve to, and the name
  builds that predate identities show.

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
tail of a writer's own log is the only thing ever rewritten, because nobody
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

- Status in vocabulary. Kind in vocabulary. Tag format. A retired status
  (below) is refused on live writes only; replay accepts it.
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
dangling repo aliases, writers with events that resolve to no identity
(`unnamed_actors`: no `as` and no declared name), and events whose `as` the
tracker does not accept (`unknown_identities`). Replay keeps such events:
`as` says who, not what.

## Prose ownership

Four kinds of text, four rules:

| Kind | Example | Storage | Written as |
|------|---------|---------|---------|
| Description | the ticket body the human writes | document `description` | the human's identity; `agent` reads only |
| Current summaries | brief, research notes (`summary`, `brief`, `notes`) | named documents | the human's identity and `agent`, compare-and-set |
| Records | short deltas: a decision and what it supersedes, an outcome, a pointer | comments | any identity, append-only |
| Bulky material | handoffs, research tied to code | files in a code repository, linked by a comment's `link` | that repository's owners |

Structure, not instructions, decides between a comment and a document:
sub-headings, tables, open questions or text that will be revised make it a
document. The agent-facing form of these rules is `tickets/prose` in the
[agent hooks](../agent-hooks/overview.md). The tracker's own `docs/`
directory holds files `import` copied; agents have no committed way to add
files there, so the rules above do not send new material to it.

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
  **Superseded (ZZ-38):** zwanenzang is the human's personal tracker, so
  the default is the human's Org keywords, lowercased:
  `todo, next, wait, agnt, revw, done, cncl`, with `todo` first and so the
  default for `create`. With the same names in Org, no keyword map is
  needed (see [03-org-client](03-org-client.md)). Meanings: `todo` not
  started; `next` the human is on it or can start now (including drafting
  the ticket's prose); `wait` waiting on something; `agnt` an agent is
  working on it; `revw` ready for the human's review; `done`; `cncl`
  cancelled. The earlier names are retired, not removed (see "Retired
  statuses" below).
  Status never says who may work on a ticket; two tags do:
  - `ready_for_agent`: standing permission, added and removed only by the
    human, for an agent to pick the ticket up autonomously; the tag stays
    through `agnt`, `wait` and `revw`. An interactive session the human is
    directing needs no tag, and a human handing work over and leaving
    grants it for that ticket.
  - `needs_human`: an agent waits on the human. `wait` with it is an
    agent's question, `wait` without it waits on something else. `revw`
    always also carries `needs_human`, so the attention queue and its
    waiting age need nothing status-specific.
  `agnt` is set by whoever starts autonomous work, is a status and not a
  lock, and does not request work. These are conventions for the human and
  the agents; zwanenzang does not enforce them. Their agent-facing form,
  the same for every tracker on the default vocabulary, is
  `tickets/statuses` in the [agent hooks](../agent-hooks/overview.md).
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
- **Retired statuses.** Because old events keep using a name, a status
  leaves use by retirement: `retired_statuses` in `zwanenzang.toml` lists
  names that stay in `statuses`. Replay accepts them, so derived state and
  lint are unchanged, but `create`, `status` and `apply` refuse them with
  `retired-status` and write nothing, even when the ticket already has
  that status. Each retired name must be in `statuses`, and the first
  status, the default for new tickets, cannot be retired. A new tracker
  retires nothing. This tracker retires its milestone 2 names `draft,
  doing, blocked, review, cancelled`; its open tickets move to the new
  names by ordinary status and tag events (`doing` to `agnt`, `draft` to
  `todo`, `blocked` to `wait`, `review` to `revw` plus `needs_human`), so
  no history is rewritten. The list is configuration, not an event, like
  the rest of the vocabulary file.
- **Projects.** Decided 2026-11-18 (ZZ-48): a ticket tagged `PROJ` groups
  its descendants, and its status follows them. This deliberately lifts
  "no tracker-side status enforcement" for this one rule, for every actor,
  the human included. `create`, `status` and `apply` refuse a write that
  changes the status of a `PROJ` ticket with `proj-hierarchy`, writing
  nothing, when after the write
  - any descendant is unfinished: no status change at all; or
  - every descendant is finished, and the new status is not `done` or
    `cncl`.

  Reopening is the exception: a change from `done` or `cncl` to an
  unfinished status is always accepted, also while descendants are
  unfinished (human decision, 2026-11-18). After that the rule applies
  again, so a reopened project stays at its status until it finishes.

  Finished means status `done` or `cncl`. Descendants are the whole
  subtree by `parent`. Tombstoned tickets are left out, though their own
  children are not; archived ones count by their status, so archiving
  does not finish a ticket. Cancelling never cascades. A project with no
  descendants counts as finished below, so it stays at its status until
  it becomes `done` or `cncl`. The tag and the two
  statuses are hard-coded and always on; there is no configuration.

  The rule judges the state after the whole write, not each event in it:
  one `apply` may finish a project before or after its children, as the
  Org client sends a parent's change before its children's. A new ticket
  starts from the first (default) status, so `create --tag PROJ --status
  next` is a change and refused, `--status done` is not. A batch that
  tags a ticket `PROJ` and changes its status is judged as a project.
  Only status writes are checked: removing the tag, re-parenting a
  ticket, adding an unfinished child under a finished project or
  reopening a child of one is not refused; reopening the project is the
  way back to a consistent state. Replay applies every status
  event as before, so concurrent writes that pass the check in their own
  clones survive sync. `lint` reports what any of these leave behind, a
  finished `PROJ` ticket with unfinished descendants, as
  `proj_open_descendants`, like concurrent dependency cycles.
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
  writers, B is concurrent with A when `B.parent < A.id` (B's writer had not
  seen A). Events of one writer are never concurrent with each other; the
  identity plays no part, so one identity on two clones is still reported.
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
  `null` clears the kind. `scheduled`: `{to}` where `null` clears the
  date. `parent`: `{to}` where `null` clears the parent.
  `relate`, `unrelate`: `{to}`. `tag`, `untag`: `{tag}`. `number`:
  `{number}`, at least 1. `archive`, `unarchive`, `tombstone`: `{}`.
  `actor`: `{name}`, the writer's own display name; a later declaration
  renames it.
  Nullable fields (`kind.to`, `priority.to`, `scheduled.to`, `parent.to`,
  `doc.base`) must be present, so a
  writer always states what it means. Unknown fields in `data` and in the
  envelope are ignored at replay, so the format can grow.
- **Create.** A `create` event's entity must be its own id
  (`create-id-mismatch` otherwise), which is what "identity is the ULID of
  its create event" means in the log.
- **Name formats.** Statuses, kinds, document names and repository aliases:
  one or more of `A-Z a-z 0-9 _ -`, at most 64 characters. The number
  prefix: an uppercase letter and up to nine uppercase letters or digits.
  Identities in `actors`, `--actor-name` and `zwanenzang.defaultActor`
  have the vocabulary format too. Writer display names in `actor` events:
  a single non-empty line of at most 128 bytes. Branch names
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
  `kind`, `priority`, `scheduled` or `parent` event, every earlier change to the same field of the
  same ticket by another writer that its writer had not seen is reported,
  if the values differ. Two writers choosing the same value is not a
  conflict.
- **Numbers.** "Unique and greater than any existing number": a number
  equal to an existing one is `number-not-unique`, a smaller one
  `number-not-greater`; a ticket that already has a number cannot get
  another (`already-numbered`).
- **What counts as seen.** Every line whose envelope parses counts for the
  hybrid clock and as the next event's parent, even when replay skips it
  (an unknown operation from a newer build, say), unless its id is out of
  range (below). Empty lines are ignored. A line found in a log other than
  its writer's is `actor-mismatch`.
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
  none is written. The writer's `actor` declaration is written only
  together with at least one real change, never alone. Every event of the
  write, the declaration and the `number` events its sync publishes
  included, carries the write's `as`. A document version whose text
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
- **Its own writer.** Each run writes as a new writer with the identity
  `import`, not as the clone's writer: the human did not write these
  events, and one log per run keeps an import recognisable. The new writer
  declares the name `import` too. The numbers the sync after the import
  publishes are written by the clone's writer, also as `import`. `import`
  is reserved and accepted without being in `actors`, so an import needs
  neither `--actor-name` nor a configured identity.
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
  an empty body writes none. Status maps `draft`, `needs-triage`,
  `needs-plan` and `ready-for-implementation` to `todo`;
  `ready-for-review` to `revw` and `needs-human-input` to `wait`, both
  with the tag `needs_human`; `done` to `done`. A missing status or one
  outside that vocabulary is imported as `todo`, with a warning. No kind,
  other tag or archive is written; a done ticket stays in the active set
  until the human archives it.
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
