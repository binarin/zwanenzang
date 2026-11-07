# Org client

Emacs is a peer client of a tracker, not a renderer of it. The human's org
files are the authority for the human's edits; the event log is the authority
for everything else. The client's job is to move changes between the two
without losing either.

## Scope: the subtree property is the registry

Any org heading may carry a property naming a tracker location, for example
`:ZWANENZANG: /ssh:devbox:~/trackers/zwanenzang-tracker` or a local path.
That heading is the scope root. Everything beneath it syncs with that tracker.

- The mapping is one-to-one across all of the human's org files: one tracker
  appears in exactly one scope. The doctor command reports violations.
- There is no other registry. Which trackers exist, where they are and which
  file they sync with is answered by scanning the configured org files for
  scope roots.
- The location doubles as the execution host. A tramp path means the CLI runs
  on that machine with `process-file`; a local path means it runs locally.
  The desktop never needs a clone of a tracker it reaches over tramp.
- Headings above the scope root and non-ticket headings inside it are the
  human's own structure. The tracker never sees them.

## Ticket headings

A ticket is a heading inside a scope that carries the client's own identity
property, `:ZWANENZANG_ID:`, holding the ticket ULID. The org `:ID:`
property is not used for tracker identity and org-id is never consulted;
headings are located by scanning the scope. This is deliberate: org-id tooling
and subtree copies touch `:ID:` freely, and the predecessor saw duplicated and
arbitrarily reassigned ids.

Mapping between heading and ticket:

| Org | Tracker |
|-----|---------|
| TODO keyword | status, via the scope's keyword map |
| heading title | title |
| nesting under another ticket heading | parent |
| nesting under a non-ticket heading | nothing |
| tags | tags, optionally filtered by a per-tracker allowlist |
| body text before the first subheading | document `description` |
| subheadings marked with a document property | named documents |
| a read-only drawer or subtree | comments, newest last |
| properties | number, relations, branches, MRs, repo links |

## Keyword map

The map between TODO keywords and statuses lives in org, on the scope root,
because the keywords are the human's: `#+TODO` lines and `org-todo-keywords`
differ between people and files, and the tracker's vocabulary does not.

```
:ZWANENZANG_KEYWORDS: TODO=todo,draft NEXT=doing,review WAIT=blocked DONE=done CNCL=cancelled
```

- Each entry is `KEYWORD=status[,status...]`. The first status is what a
  push writes when the human sets that keyword; every listed status is
  shown with that keyword on pull. So several statuses can share a
  keyword, and every status in the tracker's vocabulary must appear exactly
  once; doctor reports a status with no keyword or with two.
- A status is pushed only when the keyword changed since the heading's sync
  state. A ticket pulled as `draft` shows TODO and stays `draft` until the
  human actually changes its keyword.
- Without the property, a keyword maps to the status of the same name,
  ignoring case, and nothing else is mapped.
- An unmapped keyword blocks that heading's push: the heading gets the
  conflict tag and a note naming the keyword, and nothing is written for it
  until the map or the keyword changes. A fallback status would record
  something the human did not choose. Removing the keyword from a ticket
  heading counts as unmapped too.
- A pulled status the map does not cover (the vocabulary grew, say) is
  treated the same way, on that heading only.

Terminal statuses are the ones mapped from org's done-state keywords (those
after `|`), so the tracker needs no list of its own.

## Hidden documents

Agents may keep documents the human does not want in org, such as a
running status summary. The scope root lists them:

```
:ZWANENZANG_HIDE_DOCS: status plan
```

A hidden document is never pulled or pushed and has no sync state, so it
cannot conflict. The heading shows a single link line in place of each
hidden document, which opens it through the CLI, so nothing disappears
without trace. The description cannot be hidden.

## Sync state per heading

Following org-caldav, but at finer granularity. Each ticket heading stores in
properties:

- the opaque event cursor returned by the batched read for this ticket
- a hash of the description text as last synced
- per named document: its synced version id and a hash of its text

State travels with the org file, so files on different machines never share
or leak state, and a refiled heading carries its state with it.

## Pull

For every ticket in scope, fetch events after the cursor. For every field and
document:

- unchanged locally since the cursor: apply the remote change
- changed locally: keep the local value, apply nothing, add a conflict tag to
  the heading, and record the skipped remote value in a drawer so it can be
  seen. The remote change remains in history regardless.

Tickets in the tracker but absent from the scope are inserted only if they
are not archived, not tombstoned, and have events newer than the scope's last
pull: under their parent's heading when it is in scope, otherwise under the
scope's inbox heading. An archived ticket never reappears on its own; an
open ticket that was archived in org reappears exactly when something
happens to it.

## Push

For every ticket in scope, compare the heading with its sync state and emit
events for what differs: keyword to `status`, title, parent from nesting,
tags, description and documents as new versions with the synced version as
`base`. Then publish and pull once more so numbers and cursors land.

Push always succeeds for the human. If an agent changed the same field in
between, the human's event is later in ULID order and wins; lint reports the
collision; the agent's change stays in history.

## Create

A heading inside a scope with a TODO keyword and no identity property is a
new ticket on push. Headings without a keyword are the human's structure and
never become tickets, so grouping headings inside a scope are safe. The
client writes the identity property immediately and the number property
after publish. Capturing a TODO with org-capture into any scope is
therefore ticket creation.

A heading inside a scope with an identity property the tracker does not know
is **not** created. It is reported as foreign or stale, and the client offers
one action: create here as a new ticket, which strips the old identity and
sync properties and records the old id as free text in the description. This
single rule covers both an accidentally reassigned id and a refile from
another tracker's scope.

## Duplicate ids

Two headings in one scope with the same identity property block that ticket's
sync and are reported with both locations. The copy whose description and
document hashes still match the sync state is proposed as the original; the
other becomes plain text when the human confirms. If both copies were edited,
the client asks and never guesses.

## Archive, not delete

The human archives headings rather than deleting them. Archiving moves the
subtree to an archive file where it is outside any scope, so to the client an
archived ticket is simply absent. Rules:

- Absence from scope is never a deletion. No prompt, no event.
- When a heading is archived with org-archive, an archive hook may emit an
  `archive` event so the tracker knows. If the hook did not run, the tracker
  still learns nothing and the ticket stays as it was, which is safe.
- Archiving an open ticket also closes it. If the heading's keyword is a
  done state (DONE, CNCL) its status is pushed first; otherwise the hook
  sets the status mapped from the first done-state keyword (DONE), so
  archiving never prompts for a note. Then it emits `archive`. Status and
  the archived flag stay separate: the flag is what takes a ticket out of
  default views (`list`, `query` without `--all`), whatever its status.
- The re-insertion rule in Pull is what brings an archived-but-active ticket
  back when it changes.

Refile from a personal inbox scope into a client tracker's scope is handled by
the foreign-id rule above. History does not travel, which is accepted.

## Prose in org

- The description is the human's. Pull overwrites it only when the local text
  is unchanged since the cursor. Agents cannot write it.
- Named documents render as subheadings carrying a document property. The
  human edits them freely; push sends a new version. Pull applies an agent's
  new version only when the local text is unchanged; otherwise conflict tag,
  the agent's text in a drawer, and the agent will have to rebase on its next
  write anyway.
- Comments render read-only, newest last, each with a link to any file or URL
  it names. Removing them from the buffer changes nothing.
- Bulky files are links, opened over tramp.

## Commands

Pull one heading, pull scope, pull all scopes; push one heading, push scope,
push all scopes; sync (pull then push then pull); create from heading; open a
linked file or the forge page; doctor (duplicate ids, foreign ids, orphaned
sync properties, scope roots pointing at the same tracker, keyword maps that
leave a status without a keyword or give it two).

The elisp stays thin. The CLI exposes batched JSON operations so one tramp
round trip serves a whole scope.

### Batched read contract (milestone 3)

`read` takes one JSON object on stdin: `cursors` maps the tickets already
present in the scope to their last read cursors (or null for a first read),
and `since` is the last scope cursor (or null). It reads locally, without a
lock, fetch or write. A client runs `sync` first when it wants remote changes.
All returned state and cursors come from one replay.

Known tickets are returned even when archived or tombstoned, so the client
can handle their removal. Absent tickets are discovered only when live and
affected by events since `since`; null discovers all live tickets. Each
result holds the full ticket, current document text, accepted events after
its cursor, and the next cursor. A scope read also returns tracker identity,
the replayed vocabularies, so a client can validate its keyword map, and
the declared actor names, so it can name comment authors.
The exact JSON is in [cli-json](../cli-json.md).

Per-ticket history includes events that affect its visible state from the
other side: relations on either end, a child's parent change on both the
old and new parent, and a child's or related ticket's tombstone that shrinks
the visible child/relation list. `last_event` keeps its original meaning
(events whose entity is the ticket); it is not a sync cursor.

Cursors are opaque strings, not bare ULIDs. An event can arrive through git
later while sorting before an event already read. Each cursor therefore
fingerprints the accepted history through its position. If that prefix no
longer matches (or the cursor belongs to another ticket/tracker), `read`
returns the whole relevant history and `reset: true`. The client compares
the full state against its saved sync state, preserving local edits as on
any pull; replayed events must not be appended as duplicate comments.
A scope reset conservatively rediscovers every live absent ticket. This can
reinsert an absent ticket after merged older history. Malformed tokens are
errors. Clients must retain the token
verbatim rather than parse it or use `last_event` in its place.

This settles the cursor choice left by milestone 2's `query`.

### Batched apply contract (milestone 3)

`apply` accepts one JSON request with an ordered `changes` list. Each change
is one ticket operation, using ordinary ticket references or
`{"created": N}` to name the ticket created by earlier change N (zero-based
input index). A scope push creates new headings first, then sends their
parent/relations, tags and prose using those references. This compiles to the
existing write core's `Plan`, `Target::Nth` and deferred `refs`; no second
identity mechanism or event format is introduced.

All changes validate against preceding changes under one clone lock before
any blob or event is written. A rejection refuses the entire scope push.
Documents carry text and an explicit compare-and-set base, including null
for a first version; there is no force/Org-wins bypass. On a stale base the
client reads again, preserves the human edit, and resubmits against the
current version according to the conflict rules above. Submit only one new
version per document per batch.

The result maps every input position to its ticket id, written flag and
event id (null for a no-op), and separately maps create positions to new
ticket ids. Distinct targeted tickets have full post-sync state, so the
client can save assigned numbers. A batch makes one mutation commit and
one sync cycle; numbering may commit separately. An empty or all-no-op
batch does neither. Offline results retain local success and report sync
failure. Validation is atomic locally; disk failures and concurrently merged
remote events have the same semantics as ordinary writes. A subsequent
`read` supplies cursors and any indirect or concurrent changes; clients must
not infer cursors from apply event ids. Exact shapes and error semantics are
in [cli-json](../cli-json.md).

Human checkout fast-forwarding is implemented in the CLI's sync phase (see
[git and sync](02-git-and-sync.md)). The Emacs implementation lives in `emacs/`
and follows the decisions below; these contracts supply the CLI halves it
needs.

## Emacs client decisions (milestone 3)

Decided 2026-11-07 for the first Emacs implementation.

### Package and distribution

- The client is developed in this repository as the Emacs package
  `zwanenzang` in `emacs/`: one `zwanenzang.el` to start, symbol prefix
  `zwanenzang-`, tests in `emacs/test/`. It requires Emacs 31.1 and uses
  built-in libraries only (org, native JSON, `secure-hash`).
- The flake's `overlays.default` adds `pkgs.zwanenzang` (the CLI) and
  extends `emacsPackagesFor` so every Emacs package set has
  `epkgs.zwanenzang`. `packages.zwanenzang-el` is built against
  `nixpkgs-unstable`'s `emacs`, since stable nixpkgs has Emacs 30;
  the CLI stays on stable nixpkgs. `swan-lake-common` consumes the
  overlay; this repository never depends on it.
- `zwanenzang-program` names the CLI. The Nix build substitutes the store
  path of this flake's CLI as its default; outside Nix the default is
  `zwanenzang` on `PATH`.

### Activation and calls

- Explicit interactive commands only: no minor mode, hooks or timers.
- CLI calls are synchronous: `call-process` for local scopes now,
  `process-file` over tramp in milestone 5.
- First commands: `zwanenzang-pull`, `zwanenzang-push` and
  `zwanenzang-sync` act on the scope at point (sync is CLI `sync`, pull,
  push, pull); `zwanenzang-sync-all` syncs every scope in
  `zwanenzang-org-files`, which defaults to `org-agenda-files`;
  `zwanenzang-adopt-foreign`, `zwanenzang-resolve-duplicate` and
  `zwanenzang-open`.
- Deferred to milestone 5: per-heading operations, doctor across files,
  the archive hook, tramp.

### Properties

Every property the client owns starts with `ZWANENZANG`.

- Scope root: `ZWANENZANG` (the location), `ZWANENZANG_KEYWORDS`,
  `ZWANENZANG_HIDE_DOCS`, `ZWANENZANG_CURSOR` (scope cursor) and
  `ZWANENZANG_TRACKER`, the tracker id recorded on first pull. A later
  read that returns another id blocks the scope.
- Inbox: the child heading of the root with `ZWANENZANG_INBOX: t`, created
  as "Inbox" under the root the first time a pull needs it.
- Ticket heading: `ZWANENZANG_ID` (ULID), `ZWANENZANG_NUMBER` (display
  form), `ZWANENZANG_CURSOR`, `ZWANENZANG_SYNC`, `ZWANENZANG_DESC_VERSION`
  and `ZWANENZANG_DESC_HASH`. `ZWANENZANG_SYNC` is a compact snapshot of
  the last synced fields, for example `status=draft title=<hash>
  tags=<hash> parent=<id> nest=<id>` (exact form under Pull below). It
  stores the tracker status, so a draft shown as TODO stays draft.
- Named document: a subheading with `ZWANENZANG_DOC: <name>`,
  `ZWANENZANG_VERSION` and `ZWANENZANG_HASH`.

### Prose, comments and conflicts

- The description is the body before the first subheading, excluding
  drawers and planning lines.
- Comments go in a `:ZWANENZANG_COMMENTS:` drawer, newest last, each
  `[timestamp] actor:` followed by the text. The drawer is rewritten from
  tracker state and never read back.
- Skipped remote values go in a `:ZWANENZANG_CONFLICT:` drawer. The
  conflict tag is `zz_conflict`; it is never pushed as a tracker tag.
- Each hidden document is one link line using a `zwanenzang:` Org link
  type, which opens the document read-only through the CLI. The lines go
  in a `:ZWANENZANG_HIDDEN:` drawer next to the comments drawer,
  `[[zwanenzang:<id>/<doc>][<doc> (hidden)]]` for each hidden document the
  ticket has, rewritten from tracker state. Being a drawer, it is not part
  of the description. `description` in `ZWANENZANG_HIDE_DOCS` is
  reported and ignored.
- A comment's actor is its display name from `read`'s `tracker.actors`,
  or the first ten characters of its id when it declared none.

### Pull

Decided 2026-11-07 with the first `zwanenzang-pull`. Pull acts on the
scope containing point; it neither runs CLI `sync` nor writes to the
tracker.

- Identity: pull runs `list --all` first and sends `read` only the ids
  the tracker knows. A heading whose id the tracker does not know is
  foreign; two headings in the scope with one id are duplicates. Both
  block only those headings: they get `zz_conflict`, a note in
  `:ZWANENZANG_CONFLICT:` and a report line, and are never sent to
  `read`. Everything else pulls. Adopting a foreign heading and
  resolving a duplicate are separate commands, not part of pull.
- Tracker identity: the first pull records `ZWANENZANG_TRACKER`; a read
  that returns another id blocks the whole scope and changes nothing.
- Keyword map: parsed against `read`'s `statuses`. A status with no
  keyword or with two is reported (the first keyword is used). An entry
  naming a keyword the buffer does not define, or a status outside the
  vocabulary, is reported and ignored. Without the property, each TODO
  keyword maps the status of the same name, ignoring case.
- Field by field, for status, title, tags, parent, description and each
  named document: the remote value applies when Org still shows the
  value as last synced; Org's value stays when only Org changed; when
  both changed, Org's value stays, the heading gets `zz_conflict` and
  the skipped remote value goes in the conflict drawer. A field with no
  recorded sync state counts as changed on both sides unless the values
  agree. Status is compared as keywords, through the map, so a draft
  shown as TODO stays draft; a synced status the map no longer covers
  counts as unknown. Tags exclude `zz_conflict` and Org's
  `ARCHIVE`, which are never tracker tags.
- The conflict drawer and tag are recomputed by every pull: they hold
  what this pull could not apply, and disappear once Org agrees with the
  tracker (by hand, or after a push).
- `ZWANENZANG_SYNC` is `status=<status> title=<hash> tags=<hash>
  parent=<id> nest=<id>`, `-` for none. `nest` is the ticket heading the
  heading was nested under at that sync; it differs from `parent` when
  the parent has no heading in scope. Hashes, here and in
  `ZWANENZANG_DESC_HASH` and `ZWANENZANG_HASH`, are the first 16 hex
  digits of the SHA-256 of the UTF-8 text; tags are hashed sorted and
  joined by spaces.
- Parent: when the tracker parent changed and the nesting did not, the
  subtree moves under the new parent's heading, or under the inbox when
  the parent has no heading in scope or was cleared. When the nesting
  changed too, it is a conflict, as is a move under the heading's own
  descendant.
- Discovery: a new ticket goes under its parent's heading when that is
  in scope (parents are inserted before children), otherwise under the
  inbox.
- A pulled status the map does not cover blocks that heading: only the
  tag and a note are written. A discovered ticket with such a status is
  not inserted, and the scope cursor is not advanced, so it arrives once
  the map covers it.
- Archived and tombstoned: the heading stays in place and its other
  fields still apply. An archived ticket is reported. A tombstoned one
  also gets `zz_conflict` and a note, since writes to it would be
  refused.
- Known limitation: in-place archival with Org's `ARCHIVE` tag is not
  mapped. Pull never adds the tag, keeps it where the human set it, and
  `archived` is not part of `ZWANENZANG_SYNC`.
- Prose: the description and named documents are compared normalized,
  without leading blank lines or trailing whitespace. A line Org would
  read as a heading, a drawer boundary or a `#+` keyword is written with
  a leading comma, which reading strips again, so tracker text cannot
  change the outline. Comment text and skipped values are written as
  fixed-width `: ` lines.
- Named documents are the ticket heading's direct children with
  `ZWANENZANG_DOC`, titled with the document name. A tracker document
  without such a subheading gets one, including one the human deleted:
  removing it from the buffer is not a deletion.
- `reset: true` needs nothing special: pull always compares full state
  with the sync state, and comments are re-rendered from state, so
  nothing is duplicated. It is reported.
- The buffer is edited (visiting the file if needed) but never saved.
  One scope's pull is a single undo step and works whatever the folding.
  A CLI failure before or during the edit leaves the buffer as it was.

### Errors and reports

- A command failure (a JSON error object, or a usage error with exit
  status 2) is a `user-error` with the code and message; the buffer is
  left untouched.
- Publication errors (`fetch-failed`, `push-rejected`, ...) and checkout
  skips are not failures: the client echoes a one-line summary and appends
  a readable report to the `*zwanenzang*` buffer.

### Bootstrap and tests

- The human's org file is bootstrapped by ordinary create-on-push, by
  hand; nothing private is committed.
- Two ERT layers run under `nix flake check` with `emacs --batch`: pure
  parse and render tests without the CLI, and integration tests that drive
  this flake's CLI against disposable trackers. The elisp integration
  helper checks the same markers as the Rust helpers (a path under the
  system temporary directory, a directory name ending in `-test-repo`)
  before it opens, writes to or pushes from a repository. The client has
  no bypass.

## Open questions

None at present. The keyword map, unmapped keywords, ticket headings needing
a keyword, hidden documents and closing on archive were decided 2026-11-07
(sections above).
