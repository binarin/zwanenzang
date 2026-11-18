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
  Remote calls use the literal program name `zwanenzang`; the operator must
  make it available in TRAMP's effective remote PATH (`tramp-remote-path`),
  which need not match an interactive SSH shell's PATH. Local calls retain
  `zwanenzang-program`, including the Nix package's substituted store path.
  TRAMP handles execution, argument quoting and connections. JSON stdin is
  staged in a local temporary file for `process-file`; client-owned stdin
  and stderr files are removed on success, failure or quit.
- A scope may point at the same persistent clone agents use on that execution
  host; see [stable clone placement](02-git-and-sync.md#stable-clone-placement).
  The property stays a path, not an origin URL, and existing locations remain
  valid. Adopting or moving a clone requires updating this property; it never
  silently creates a replacement clone. Multiple clients sharing the clone
  share its writer and mutation lock, not the Org heading's sync state;
  each write names its own identity.
- Headings above the scope root and non-ticket headings inside it are the
  human's own structure. The tracker never sees them.

## Ticket headings

A ticket is a heading inside a scope that carries the client's own identity
property, `:ZWANENZANG_ID:`, holding the ticket ULID. The org `:ID:`
property is not used for tracker identity and the org-id location registry is
never consulted; headings are located by scanning the scope. This is deliberate:
org-id tooling and subtree copies touch `:ID:` freely, and the predecessor saw
duplicated and arbitrarily reassigned ids.

For ordinary Org links and tooling, successful ticket pulls also fill in a
missing `:ID:` using `org-id-new` (a fresh Org identity, independent of the
ticket ULID). Existing IDs are left untouched, including copied IDs: tracker
sync neither relies on them nor repairs them. Newly pushed tickets get this
ID alongside `ZWANENZANG_ID`, before the creation save. Existing ticket
headings acquire it on their next pull/push/sync, without saving the file;
a repeated no-op does not regenerate it. Blocked foreign/duplicate headings,
scope roots, inboxes, grouping headings and named documents are not assigned
IDs. Generation does not read or write the global org-id location registry;
Org's own tooling remains responsible for indexing links.

Mapping between heading and ticket:

| Org | Tracker |
|-----|---------|
| TODO keyword | status, via the scope's keyword map |
| heading title, after the number prefix | title |
| nesting under another ticket heading | parent |
| nesting under a non-ticket heading | nothing |
| tags | tags (all of them; a per-tracker allowlist is not pursued, since local-only tags are not expected in tracker trees) |
| body text before the first subheading | document `description` |
| links in a read-only generated drawer, opening document buffers | named documents |
| a read-only drawer or subtree | comments, newest first |
| properties | number, dependencies (`ZWANENZANG_DEPENDS_ON`, editable) |
| read-only generated drawers | prerequisites, dependents, relations, branches, MRs |

### Number prefix

Decided 2026-11-10 (ZZ-3): a numbered ticket's heading shows its number
as real heading text, after the keyword, priority cookie and `COMMENT`
marker: `* TODO [#A] [ZZ-42] Title`. It is visible wherever the heading
is (buffer, agenda, search, org-ql, exports); a display-only overlay or
font-lock would not be. The number uses the unpadded display form
(ZZ-20).

- The client owns it. Reading a heading strips it before the title is
  compared, hashed or pushed, so the tracker title never contains it and
  `title=` in `ZWANENZANG_SYNC` hashes the title without it. Every
  heading write (pull, conflict notes) puts it back.
- An unnumbered ticket, and any heading without `ZWANENZANG_NUMBER`, gets
  none; its whole headline is title. The prefix appears with the pull
  that brings the number.
- What counts as a prefix: at the start of the title, a bracketed token
  starting with the tracker prefix of the heading's own number and a
  dash, containing no blank or bracket, followed by blanks or the end;
  letter case ignored. So a stale `[ZZ-9]`, the old padded `[ZZ-0042]`
  or a mistyped `[ZZ-]` is the client's and is replaced, while
  `[AB-3] Title`, `[ZZ-3]Title`, a statistics cookie or a token later in
  the title stay title text. Only one token is stripped.
- An edited or removed prefix is not a conflict and not a title change:
  the next pull silently rewrites it. A tracker title that itself begins
  with a prefix-shaped token keeps it behind the real prefix
  (`[ZZ-1] [ZZ-5] Literal`), and reads back unchanged.
- `zwanenzang-heading-number-prefix` (default on) turns it off; pull then
  removes the prefixes, except before a title that would read as one,
  where the prefix stays so the title survives.
- Detaching a duplicate copy and adopting a foreign ticket strip the old
  prefix along with the client's properties, so it does not become title
  text of a new ticket.
- Upgrading: headings written before this get the prefix on their next
  pull, without a conflict, since their synced title hash has none.
  A pull that only adds or repairs prefixes edits the buffer but reports
  nothing changed.

## Keyword map

The map between TODO keywords and statuses lives in org, on the scope root,
because the keywords are the human's: `#+TODO` lines and `org-todo-keywords`
differ between people and files, and the tracker's vocabulary does not.

The default vocabulary (see [01-data-model](01-data-model.md)) is the
human's global Org keywords lowercased, `todo next wait agnt revw done
cncl` for `TODO NEXT WAIT AGNT REVW DONE CNCL`, so the human's scopes need
no map: the same-name rule below covers every status. AGNT and REVW are
global keywords in the human's Org configuration, a separate sequence of
active states (`AGNT REVW |`), not a per-file `#+TODO` line, because
ticket headings move between scope files. A map is for other keyword
sets, for example:

```
:ZWANENZANG_KEYWORDS: TODO=todo NEXT=next,agnt WAIT=wait,revw DONE=done CNCL=cncl
```

- Each entry is `KEYWORD=status[,status...]`. The first status is what a
  push writes when the human sets that keyword; every listed status is
  shown with that keyword on pull. So several statuses can share a
  keyword, and every status in the tracker's vocabulary must appear exactly
  once; doctor reports a status with no keyword or with two.
- A status is pushed only when the keyword changed since the heading's sync
  state. With the map above, a ticket pulled as `agnt` shows NEXT and stays
  `agnt` until the human actually changes its keyword.
- Without the property, a keyword maps to the status of the same name,
  ignoring case, and nothing else is mapped.
- An unmapped keyword blocks that heading's push: the heading gets the
  conflict tag and a note naming the keyword, and nothing is written for it
  until the map or the keyword changes. A fallback status would record
  something the human did not choose. Removing the keyword from a ticket
  heading counts as unmapped too.
- A pulled status the map does not cover (the vocabulary grew, say) is
  treated the same way, on that heading only.
- Retired statuses (`read`'s `tracker.retired_statuses`) need no keyword,
  so a map or same-name rule that leaves them out is no scope problem; a
  ticket still in one is blocked on its heading like any unmapped status
  until it moves to a current status. A retired status may still share a
  keyword: it is listed after the current statuses, so that keyword
  pushes the current status. A keyword mapped only to a retired status
  pushes it, and the CLI refuses the push with `retired-status`.
- Status changes the client writes (pull, and the comment commands) edit
  the keyword textually, without Org's state-change logging: no LOGBOOK
  entry or CLOSED line, because tracker history is the record. A keyword
  change the human makes with `C-c C-t` logs as Org normally does, note
  prompts included.

Terminal statuses are the ones mapped from org's done-state keywords (those
after `|`), so the tracker needs no list of its own.

## Named documents

Named documents are not written into Org. A ticket heading lists them in
a generated `:ZWANENZANG_DOCUMENTS:` drawer, one link each with the date
and author of the current version; following a link opens the document in
a buffer of its own, filled from the CLI, and saving that buffer writes a
new version. Org files never hold a copy, so there is nothing to keep in
sync and nothing to hide: the description is the only prose a ticket
heading carries. Documents are blobs without a file extension, so the
client opens them as Org buffers rather than as files. Details are under
"Document buffers" below.

Earlier versions wrote named documents as subheadings and could leave some
out with the scope root's `ZWANENZANG_HIDE_DOCS`. That property is now
ignored and reported once per scope in each Emacs session; the inline
subheadings are migrated away by pull, as described under Pull.

## Sync state per heading

Following org-caldav, but at finer granularity. Each ticket heading stores in
properties:

- the opaque event cursor returned by the batched read for this ticket
- a hash of the description text as last synced

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
tags, dependencies, description and documents as new versions with the synced version as
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

`zwanenzang-adopt-foreign` performs this explicitly on the ticket at or
above point. It first runs CLI sync, refusing adoption on any fetch or
publication error rather than deciding an identity is foreign from a stale
clone. It then checks the current tracker's identity and known ids,
and creates only that heading, using its current keyword, title, priority,
tags, description, named document text and same-scope parent. It neither
adopts child tickets nor pushes unrelated edits. Known ids (including
archived/tombstoned tickets) are refused; duplicates of a foreign id can be
adopted one at a time. No history is transferred.

Adoption clears the ticket's `ZWANENZANG*` properties, `ARCHIVE_*`
properties, conflict tag and generated drawers.
Direct inline named-document children of the old form keep `ZWANENZANG_DOC`, but lose their old
tracker state and generated drawers too. Human properties, standard Org
IDs, text and other children remain. In particular, old dependency numbers
are not reinterpreted in the destination tracker. The description gains a
plain `Former tracker id: ...` line. Those inline documents are created as
documents of the new ticket, like any inline document a push finds, and
the final pull removes them. New identity and saving follow create-on-push;
a final scope pull installs fresh sync state. A refused create restores the
original buffer; failures after successful apply retain the new identity
and report recovery information, as for ordinary push.

## Duplicate ids

Two headings in one scope with the same identity property block that ticket's
sync and are reported with both locations. The copy whose description and
document hashes still match the sync state is proposed as the original; the
other becomes plain text when the human confirms. If both copies were edited,
the client asks and never guesses.

`zwanenzang-resolve-duplicate` acts on the ticket at or above point, within
its scope only (nested scopes are excluded), and supports more than two
copies. It always asks which heading keeps the identity, labeling choices
by line and title, then asks for confirmation before changing anything.
Exactly one copy whose description and every present direct named document
match their saved hashes is offered as the default; missing hashes count as
unknown. These hashes are only a suggestion, not proof of origin (deleted
named documents cannot be detected from their former headings' properties).
With zero or multiple matches there is no default, even when all text agrees.

Detached copies and their direct named-document headings lose all
`ZWANENZANG*` properties, the conflict tag and their TODO keywords. Removing
the keywords prevents the next push from creating replacement tickets.
Text, drawers other than the generated `ZWANENZANG_CONFLICT` drawer
(including previously rendered comments), ordinary Org IDs, priority and
other tags/properties remain. The generated conflict drawer is removed
from detached entries and their direct named documents.

If any copy selected for detachment contains ticket headings (known tickets
or new TODO headings, including descendants under grouping headings), the
command refuses before changing anything and asks the human to move them
first. Otherwise the next push could silently change those children's
tracker parents. There is no warning-and-proceed or automatic refiling;
children under the retained copy do not prevent resolution. Nested scopes
remain separate. The retained heading's sync state remains intact; the next
pull recomputes its old duplicate diagnostic. No tracker calls or events occur, no file is
saved, and the edit is one undo step. Cancellation changes nothing.

## Archive, not delete

The human archives headings rather than deleting them. Archiving moves the
subtree to an archive file where it is outside any scope, so to the client an
archived ticket is simply absent. Rules:

- Absence from scope is never a deletion. No prompt, no event.
- Loading the client installs `org-archive-hook`, gated on the original
  heading's tracker scope. Org calls it after copying the subtree but before
  removing the original. The hook sends one atomic batch for all identified
  ticket headings moved within that scope (including children of grouping
  headings): each ticket's closing status, then `archive`. It never creates
  tickets, pushes other edits, pulls, rewrites keywords or saves Org files.
  Locally edited title, priority, tags, dependencies, parent, description and
  named documents are listed per ticket in the report as not pushed: those
  edits remain only in the Org archive. Push before archiving to publish them.
- Foreign/duplicate identities, tombstones, invalid keyword maps, no mapped
  first done keyword, tracker/priority mismatch or CLI refusal leave the
  whole batch unwritten. Archiving a scope root or a subtree containing a
  nested scope is unsupported and reported, not guessed across trackers.
  Failures and keyboard quits warn but do not interrupt Org's move: throwing
  from this hook would leave both copied and original subtrees. Correct the
  problem, check tracker state, set a closing status and run
  `zwanenzang archive` manually if needed. Offline local success is retained and
  publication failure is reported normally. If the hook did not run, the
  tracker learns nothing and the ticket stays as it was, which is safe.
  In-place ARCHIVE tagging is not this hook and still emits no events.
- Archiving an open ticket also closes it. A tracker status already mapped
  to a done keyword is preserved, including when Org still shows a stale
  open keyword. The exception is an explicit human edit to a done keyword
  different from both the synced and remote keywords: that keyword's first
  mapped status is pushed, as on ordinary push. For a remotely open ticket,
  use the heading's done keyword if present, otherwise the first done-state
  keyword (DONE), and send its first status before `archive`. Two statuses
  sharing a done keyword agree; archival does not collapse them to its first
  status. Archiving never prompts for a note. Status and
  the archived flag stay separate: the flag is what takes a ticket out of
  default views (`list`, `query` without `--all`), whatever its status.
- The re-insertion rule in Pull is what brings an archived-but-active ticket
  back when it changes.
- Emitting `unarchive`: a heading in scope that carries `ARCHIVE_TIME` and
  whose ticket is archived in the tracker has been restored by the human, so
  push sends `unarchive` and removes the `ARCHIVE_*` properties once `apply`
  succeeds. Its status follows the keyword as for any edit. A heading with
  `ARCHIVE_TIME` whose ticket is not archived sends nothing, and keeps the
  properties. `zwanenzang-unarchive` does the same for the ticket heading at
  point on demand; with a prefix argument, also every archived ticket
  heading in its subtree. It leaves status alone, as the operation does.

Refile from a personal inbox scope into a client tracker's scope is handled by
the foreign-id rule above. History does not travel, which is accepted.

## Prose in org

Tracker prose (descriptions, named documents, comments) is Org, not Markdown.
The CLI stays format-blind and nothing converts it.

- The description is the human's. Pull overwrites it only when the local text
  is unchanged since the cursor. Agents cannot write it.
- Named documents are links on the ticket heading, edited in document
  buffers of their own (see "Document buffers"). Saving one writes a new
  version based on the version it was opened with, so an agent's version
  written since is never overwritten unseen.
- Comments render read-only, newest first, each with a link to any file or URL
  it names. Removing them from the buffer changes nothing.
- Bulky files are links, opened over tramp.

## Commands

Pull one heading, pull scope, pull all scopes; push one heading, push scope,
push all scopes; sync (pull then push then pull); create from heading; open a
named document for editing, or start a new one; open a
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
the writers' declared names; comments and document versions carry their
resolved `identity` themselves, so the client can name their authors.
The exact JSON is in [cli-json](../agent-hooks/cli-json.md).

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
in [cli-json](../agent-hooks/cli-json.md).

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
  built-in libraries (org, native JSON, `secure-hash`) plus the specifically
  accepted `org-ql` dependency for the attention queue. Other direct external
  dependencies require individual human acceptance. The pinned package's
  required direct closure is compat, dash, f, map, org, org-super-agenda, ov,
  peg, s, transient and ts; its further transitive closure is ht, cond-let,
  llama and seq, supplied by Nix. This does not
  authorize unrelated use of those libraries or additional flake inputs.
- The flake's `overlays.default` adds `pkgs.zwanenzang` (the CLI) and
  extends `emacsPackagesFor` so every Emacs package set has
  `epkgs.zwanenzang`. `packages.zwanenzang-el` is built against
  `nixpkgs-unstable`'s `emacs`, since stable nixpkgs has Emacs 30;
  the CLI stays on stable nixpkgs. `swan-lake-common` consumes the
  overlay; this repository never depends on it.
- `zwanenzang-program` names the CLI. The Nix build substitutes the store
  path of this flake's CLI as its default; outside Nix the default is
  `zwanenzang` on `PATH`.
- `zwanenzang-actor-name` is the identity the client writes as. When set,
  every CLI call passes `--actor-name` with it, the same in every scope;
  the default nil passes nothing, so each clone's
  `zwanenzang.defaultActor` decides, and a clone without one refuses the
  client's writes with `actor-required`. Reads pass it too; they ignore it.
  A call whose own arguments already name `--actor-name` keeps that one
  and is not given the setting, since the CLI refuses the flag twice.

### Activation and calls

- Sync runs through explicit interactive commands: no minor mode or timers.
  Loading the client installs the Org archive hook described above.
  It also installs a global Org completion-blocker hook for the dependency
  UI below; only this blocker is gated by inherited `ZWANENZANG` and never
  calls the CLI. The `org-add-note` and show-branches advice below are
  installed the same way.
- CLI calls are synchronous: `call-process-region` for local scopes,
  `process-file` over tramp.
- First commands: `zwanenzang-pull`, `zwanenzang-push` and
  `zwanenzang-sync` act on the scope at point (sync is CLI `sync`, pull,
  push, pull); `zwanenzang-sync-all` syncs every scope in
  `zwanenzang-org-files`, which defaults to `org-agenda-files`;
  `zwanenzang-unarchive`, `zwanenzang-adopt-foreign`,
  `zwanenzang-resolve-duplicate`, `zwanenzang-open`, and
  `zwanenzang-add-dependency` / `zwanenzang-remove-dependency` (see
  Dependencies).
- Deferred to milestone 5: per-heading operations and doctor across files.
  TRAMP execution and the archive hook are implemented.

### Properties

Every tracker property the client owns starts with `ZWANENZANG`. The
standard Org `ID` is only filled in when missing, as described above.

- Scope root: `ZWANENZANG` (the location), `ZWANENZANG_KEYWORDS`,
  `ZWANENZANG_CURSOR` (scope cursor) and
  `ZWANENZANG_TRACKER`, the tracker id recorded on first pull. A later
  read that returns another id blocks the scope.
- Inbox: the child heading of the root with `ZWANENZANG_INBOX: t`, created
  as "Inbox" under the root the first time a pull needs it.
- Ticket heading: `ZWANENZANG_ID` (ULID), `ZWANENZANG_NUMBER` (display
  form, such as `ZZ-42`), `ZWANENZANG_CURSOR`, `ZWANENZANG_SYNC`, `ZWANENZANG_DESC_VERSION`
  and `ZWANENZANG_DESC_HASH`. `ZWANENZANG_SYNC` is a compact snapshot of
  the last synced fields, for example `status=agnt title=<hash>
  tags=<hash> depends=<hash> parent=<id> nest=<id>` (exact form under Pull below). It
  stores the tracker status, so an `agnt` shown as NEXT stays `agnt`.
- Inline named document, the old form pull migrates away: a subheading
  with `ZWANENZANG_DOC: <name>`, `ZWANENZANG_VERSION` and
  `ZWANENZANG_HASH`. `ZWANENZANG_DOC_FORMAT` set to `org-src-v1`
  identifies its literal source-block body (not tracker metadata). The
  client no longer writes any of these.

### Adding comments

On ticket headings inside a scope and their direct named-document children
(`ZWANENZANG_DOC`), `org-add-note` (`C-c C-z`, or agenda `z`) opens an Org
comment compose buffer for the owning ticket. This includes point in the
document's body; the document text is not a note destination. `C-c C-c`
appends one tracker comment through `apply`, then pulls the scope to render
it; `C-c C-k` aborts without writing. It never pushes other Org edits.
Unpublished owners are refused: push them explicitly first. Ownership does
not cross a child ticket, structural heading or nested scope. Structural
headings and headings outside scopes keep ordinary Org note behavior.
The explicit `zwanenzang-comment` command uses the same ownership rules.

The advice is installed on load, gated by the inherited `ZWANENZANG`
property. A prefix argument bypasses it; setting
`zwanenzang-redirect-org-notes` to nil disables it. State-change logging
continues through `org-add-log-setup`, untouched. `zwanenzang-comment` is
also available directly. The optional CLI link field is not exposed;
ordinary Org links can be included in the comment text.

The compose buffer can also change the ticket's status and tags with the
comment. These keys only record pending changes; nothing is written or
edited until `C-c C-c`, and the header line lists what is pending (for
example `Comment -> NEXT, +ready_for_agent, -needs_human: C-c C-c send`):

- `C-c C-t` picks a TODO keyword as `org-todo` offers it in the source
  buffer: its fast selection keys when it has them, otherwise completion.
  The keyword stands for the status the scope's keyword map gives it,
  as on push; a keyword only a retired status has cannot be picked. The
  heading's current keyword clears a pending status.
- `C-c C-q` toggles tags against the ticket's tags with the pending
  changes applied. Candidates are the source buffer's Org tags and the
  tags tickets carry in the tracker; `zz_conflict` and `ARCHIVE` are not
  tracker tags and are refused.
- `C-c C-a` hands the ticket to an agent: status `todo`,
  `+ready_for_agent`, `-needs_human`. It answers an agent's question,
  gives review feedback or hands a ticket over: on the heading, `C-c C-z`,
  `C-c C-a`, then `C-c C-c`.

`C-c C-c` sends the comment and the pending changes as one `apply` batch
(one commit, one sync), the comment first, then the status, tags added and
tags removed, and pulls as for a plain comment. The pull rewrites the
keyword and tags without Org logging; the tracker history is the record.
With nothing pending it sends the comment alone, as before; a plain
comment changes no status or tag. When changes are pending and the
heading's keyword or tags differ from the last sync, the send is refused
and the draft kept: push the heading first. That holds even when the
tracker already has the same value: until a push or pull records it, the
pull after the send would compare the sent change with the old baseline
and keep the local edit as a conflict, and a later push could undo the
change. `zwanenzang-comment-send` returns the comment's event id, the first
result of the batch.

The compose buffer retains a refused draft and its compose window. Aborting
or accepting a write restores the window configuration and source point from
before composition, including the selected window (also when invoked from an
agenda). Temporary splits are removed; existing windows and their buffers are
restored. After a locally accepted write it closes and restores those windows
even if publication or the subsequent pull fails: retry sync or pull, not send.
Publication failures use the normal report. A killed,
retargeted, duplicate or foreign source heading is refused before writing.
The generated comments drawer remains a one-way projection, not an input;
manual edits there are overwritten on pull (no new edit warning is added).

### New comments

Decided 2026-11-13. Comments arrive only through explicit pulls and syncs,
and land in folded drawers, so the client remembers which ones a pull
brought and lets the human step through them. Nothing about this is
written to Org or the tracker, and nothing is persisted: it lives in the
buffer for the Emacs session, and restarting Emacs or killing the buffer
forgets it. Reading a comment does not clear it.

- Each scope has its own set of new comments. Every pull compares the
  comments it renders with those it rendered before in this session, by
  comment id, so a reset replaying old history marks only comments this
  session has not shown, a late lower-id one included.
- The first pull of a scope in a session, and a ticket rendered in a scope
  for the first time (discovered, or a heading the human added), are the
  baseline: none of their comments are new.
- Comments sent from this Emacs session are never new, remembered by their
  accepted event id as soon as `apply` accepts them, so also when the pull
  after the send fails. Comments from agents and from `zz` in a terminal,
  even as the same identity, are new.
- A command that brings new comments to a scope replaces that scope's set;
  one bringing none keeps it. Every pull of one command counts together:
  a sync whose push pulls again keeps what its first pull brought. Other
  scopes, and the other scopes of a `zwanenzang-sync-all`, keep theirs.
- The command's report adds the count and the tickets, sorted by number,
  for example `3 new comments: ZZ-12 (2), ZZ-40`; nothing when none are new.
- In a graphical frame each ticket heading with new comments gets a fringe
  mark, like the one Org's capture leaves through bookmarks
  (`zwanenzang-new-comment-fringe-mark`, face
  `zwanenzang-new-comment-fringe`; nil turns it off). Text terminals have
  no substitute.
- `zwanenzang-next-new-comment` and `zwanenzang-previous-new-comment` move
  like `org-next-link`: within the current buffer (its accessible part),
  from point, skipping a comment point is on. Point lands at the start of
  the comment's first line in `:ZWANENZANG_COMMENTS:`; when that is hidden
  the ticket heading, its entry and that drawer are revealed, and siblings
  and other drawers keep their folds. With no further comment the message
  is `No further new comment` and point stays; the same command again
  wraps to the buffer's start or end. They do not touch `next-error`.
- `zwanenzang-clear-new-comments` forgets the sets of every scope in the
  current buffer, and their marks; with `C-u`, of every buffer.
- None of these commands is bound to a key.

Positions are never stored. Navigation and the fringe marks find each
comment again from the buffer: the ticket heading by `ZWANENZANG_ID` in the
scope, then, in its comments drawer, the comments as the last pull rendered
them, each matched whole (header line, text and link) and in order after
the one before. A comment quoting another's `[timestamp] actor:` line, or
sharing it, is therefore not taken for that comment. Body rewrites, parent
moves and text the human adds do not lose them; a comment the drawer no
longer holds, and a ticket whose heading left the scope or has a
duplicate, are skipped. Marks are rebuilt after
every pull and navigation.

### Showing branches

Org's `C-c C-k` outside a note (`org-kill-note-or-show-branches`) shows
every subheading of the heading at point, or of the whole buffer before the
first heading. In a scope that unfolds every named document and the human's
notes under each ticket. The client advises `org-fold-show-branches`, which
both cases call, to stop at ticket headings instead:

- The human's structure (inbox, grouping headings, scope roots) shows as
  before, and so does every ticket heading reached through it.
- Below a ticket heading only its child tickets show; named documents and
  the human's own subheadings stay folded, with everything under them. On a
  ticket heading itself, `C-c C-k` therefore lists its child tickets.
- A ticket is what the scan treats as one: a heading with `ZWANENZANG_ID`,
  or a new heading with a TODO keyword that is not the inbox or a document.
  Identities outside any scope are not tickets.
- On a non-ticket heading below a ticket, such as a named document, its
  subheadings show by the same rule. Subtrees with no scope in or above
  them keep Org's behaviour. Bodies are never shown, as in Org.

With a prefix argument, `C-u C-c C-k` in a scope renormalizes the whole
scope: it does what plain `C-c C-k` does on the nearest scope root at or
above point, scopes nested in it included, so the human can get back to
the ticket-level view from anywhere. Org itself ignores that prefix.

- Point stays where it is. If its text is now hidden, it moves to the
  nearest visible heading at or above it.
- A narrowed buffer is never widened. If the scope root is outside the
  restriction, each outermost heading in it is treated as by plain
  `C-c C-k`, and the restriction stays.
- Outside any scope or before the first heading the prefix changes
  nothing, and in a note buffer `C-c C-k` still aborts the note.
- The same is available as `M-x zwanenzang-show-scope-branches`.

Both pieces of advice are installed on load, like the note redirect, and
never call the CLI or modify the buffer. Setting
`zwanenzang-show-branches-to-tickets` to nil disables them.

### Prose, comments and conflicts

- The description is the body before the first subheading, excluding
  drawers and planning lines.
- Comments go in a `:ZWANENZANG_COMMENTS:` drawer at the end of the body,
  below the description, newest first, each `[timestamp] actor:` followed by
  the text as plain Org, so its links work. The drawer is rewritten from
  tracker state and never read back.
  Newest means reverse event replay order, not wall-clock timestamp order.
  This applies immediately after an accepted comment send and on every pull,
  including cursor resets; the CLI keeps its ascending replay order.
- Skipped remote values go in a `:ZWANENZANG_CONFLICT:` drawer. The
  conflict tag is `zz_conflict`; it is never pushed as a tracker tag.
- Named documents go in a `:ZWANENZANG_DOCUMENTS:` drawer after the
  comments drawer, rewritten from tracker state by every pull and never
  read back: one item per document with a current version,
  `- [[zwanenzang:<id>/<name>][<name>]] DATE ACTOR`, the date and author
  of that version. The description is the body and is not listed; a
  ticket without other documents gets no drawer. A new version changes
  the drawer, so unlike the link drawers below it counts as pulling the
  ticket. Pull removes the `:ZWANENZANG_HIDDEN:` drawer earlier versions
  wrote in its place.
- References go in two more generated drawers after the documents one, both
  rewritten from tracker state by every pull and never read back:
  `:ZWANENZANG_RELATIONS:` (Prerequisites, Blocks, Related) and
  `:ZWANENZANG_CODE:` (Branches, MRs). Each holds one top-level list item
  per kind with the references as sub-items; an empty kind is left out,
  and a drawer with nothing in it is not written. No properties carry
  these: a property drawer holds one value per key, and a drawer can be
  rendered freely. `ZWANENZANG_DEPENDS_ON` stays the only editable
  dependency input; the relations drawer repeats it as links.
- A ticket reference is `[[zwanenzang:<id>][NUMBER KEYWORD Title]]`, the
  keyword the scope's keyword map shows for the ticket's status (the
  status itself when the map has none), sorted by number. An archived or
  tombstoned ticket is marked so; one the tracker does not know is named
  by its id with `(unknown)`. Labels come from `list --all` with `read`'s
  newer state over it, so a prerequisite's new title or status reaches its
  dependents on the next pull even though they have no events of their own.
- A branch is plain text `ALIAS: name`. A merge request is
  `[[url][ALIAS #N]]` when the URL's last path segment (query and fragment
  dropped) is a number N, otherwise `ALIAS SEGMENT`, or just the alias.
  Repository URLs in `zwanenzang.toml` are not used.
- `zwanenzang:<id>` without a document name is a ticket link. Following it
  jumps to that ticket's heading in the scope the link is in, widening if
  needed. A ticket with no heading there opens a read-only `org-mode`
  buffer `*zwanenzang NUMBER*` built from one `read` and `list --all`:
  title, status, kind, tags, description, comments and references
  (parent, children, the relations and code lists). Buffers the client
  opens this way remember the scope and tracker they came from, so their
  links work too, leading back into that scope when it has the heading.
- A comment's or document version's author is its `identity`, else its
  writer's display name from `read`'s `tracker.actors`, else the first ten
  characters of the writer id.

### Pull

Decided 2026-11-07 with the first `zwanenzang-pull`. Pull acts on the
scope containing point; it neither runs CLI `sync` nor writes to the
tracker.

- Identity: pull runs `list --all` first and sends `read` only the ids
  the tracker knows. A heading whose id the tracker does not know is
  foreign; two headings in the scope with one id are duplicates. Both
  block only those headings: they get `zz_conflict`, a note in
  `:ZWANENZANG_CONFLICT:` and a report line with the heading's line
  number (not in the note, which would move it), and are never sent to
  `read`. Everything else pulls. Adopting a foreign heading and
  resolving a duplicate are separate commands, not part of pull.
- Tracker identity: the first pull records `ZWANENZANG_TRACKER`; a read
  that returns another id blocks the whole scope and changes nothing.
- Keyword map: parsed against `read`'s `statuses`. A status with no
  keyword (unless retired) or with two is reported (the first keyword is
  used). An entry
  naming a keyword the buffer does not define, or a status outside the
  vocabulary, is reported and ignored. Without the property, each TODO
  keyword maps the status of the same name, ignoring case.
- Field by field, for status, title, tags, dependencies, parent and
  description: the remote value applies when Org still shows the
  value as last synced; Org's value stays when only Org changed; when
  both changed, Org's value stays, the heading gets `zz_conflict` and
  the skipped remote value goes in the conflict drawer. A field with no
  recorded sync state counts as changed on both sides unless the values
  agree. Status is compared as keywords, through the map, so an `agnt`
  shown as NEXT stays `agnt`; a synced status the map no longer covers
  counts as unknown. Tags exclude `zz_conflict` and Org's
  `ARCHIVE`, which are never tracker tags.
- The conflict drawer and tag are recomputed by every pull: they hold
  what this pull could not apply, and disappear once Org agrees with the
  tracker (by hand, or after a push).
- `ZWANENZANG_SYNC` is `status=<status> title=<hash> tags=<hash>
  depends=<hash> parent=<id> nest=<id>`, `-` for none. `nest` is the ticket heading the
  heading was nested under at that sync; it differs from `parent` when
  the parent has no heading in scope. Hashes, here and in
  `ZWANENZANG_DESC_HASH` and `ZWANENZANG_HASH`, are the first 16 hex
  digits of the SHA-256 of the UTF-8 text; tags are hashed sorted and
  joined by spaces.
- Parent: when the tracker parent changed and the nesting did not, the
  subtree moves under the new parent's heading, or under the inbox when
  the parent has no heading in scope or was cleared. When the nesting
  changed too, it is a conflict, as is a move under the heading's own
  descendant, including one an earlier move in the same pull would
  cause. A move that does not happen leaves the nesting's sync state as
  it was.
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
  without leading blank lines or trailing whitespace. Descriptions are written
  verbatim (`#+begin_src`, links and other Org included) except for what
  would break the body. A heading line and every drawer-like line (`:word:`
  alone on a line, `:END:` too) get a leading comma, whatever follows them,
  which reading strips again. Escaping those only when an `:END:` followed
  in the text was not enough: a human can add a drawer below later, the line
  then read as its opening, and the push truncated the description. The
  cost is a comma on `:wip:`-shaped lines of prose. In comments, heading
  lines and `:END:` lines get the comma. Skipped values are fixed-width
  `: ` lines. Drawers end at `:END:` in any case, as in Org. This comma is
  the client's own: descriptions and comments are entry text, not source
  blocks, and Org has no quoting convention there. Inline named documents
  of the old form used Org's source-block quoting instead, below.
- Inline named documents (the old form, read for migration and push only)
  use a dedicated codec, not the description/drawer
  parser. `org-src-v1` bodies end in one `#+begin_src org -i :eval never
  :exports code :noweb no` block. Its content uses Org's own source-block
  quoting (`org-escape-code-in-string`): one more comma before a `*` or
  `#+` that starts a line after any indentation and commas.
  `C-c '` strips that quoting in the editor and puts it back on return, and
  the parsed source value is already decoded, so the client adds no quoting
  of its own. Only decoded, normalized prose is hashed, compared and sent to
  the CLI. Drawers within that prose are literal content, never host metadata.
  Host properties and human drawers remain outside the block. Prose does not
  execute or become host tickets/scopes, and source blocks export as code.
  Parent moves and refiles do not shift contained prose headings. Links keep
  their existing Org-file base; no checkout projection is introduced.
- An absent format property means the legacy comma-escaped representation,
  even if its prose contains source blocks. Adoption retains the codec while clearing old
  state; duplicate detachment preserves literal prose before dropping client
  properties. Unknown formats or malformed wrappers refuse sync before any
  apply, rather than publishing fences or truncated text. Repair the wrapper
  (including its final closing fence) before retrying.
- Finish or abort an active source editor before client operations on its
  host buffer. The client refuses those operations, preserving both buffers
  and in-flight edits, rather than reading stale host text or invalidating
  editor markers. Standalone source editors are prose, not tracker scopes;
  note capture there is not extended to the host ticket.
- Reading is lenient about files earlier versions wrote. Drawers do not
  nest, so a drawer-like line with another one before its `:END:` is text;
  only the property drawer, the logbook and the client's own drawers run
  through such lines. Org itself would still fold that text as a drawer. Two
  cases stay ambiguous: a bare `:B:` with a lone `:END:` typed below it is a
  drawer (it is one, to Org too), and a human's own `:NOTES:` drawer holding
  a `:word:` line leaks its opening line into the description. Reading also
  strips the comma an earlier version put on `#+` lines, so files written
  then do not read as edited.
- Writing a body keeps planning lines first and the other drawers in
  their order, then `:ZWANENZANG_CONFLICT:`, then the text, then the
  comments, documents, relations and code drawers. A comments drawer in the old position above
  the text moves down the next time the body is written. Human text around
  drawers moves, verbatim, in front of the tail drawers; the description it
  forms is unchanged.
- Drawer visibility is local UI state, never tracker data. Property drawers
  are closed after client updates, including no-op updates. Body rewrites
  and parent moves preserve unchanged drawers' open/closed state; comments
  open when their rendered content changes (including first insertion),
  not merely because another field or the description changed. Trailing
  blank lines after a drawer are not part of that comparison. Body rewrites
  retain the complete enclosing outline fold, including its newline
  boundaries, under a folded ticket or ancestor. Unchanged bodies do not
  recreate outline folds. Rewrites preserve the original enclosing extent
  rather than splitting an ancestor overlay around the body: later documents
  and siblings must stay in that fold, and ordinary Org search or visibility
  save/restore must not concatenate visible heading lines. Parent moves retain
  the moved entries' outline hiding and respect a folded destination.
  Opening a changed drawer does not reveal it through an outline fold.
  These visibility updates do not save the file or repair pre-existing damage.
- Inline named documents, the ticket heading's direct children with
  `ZWANENZANG_DOC` that earlier versions wrote, are migrated away: pull
  deletes such a subheading with its subtree when its text is the one
  last synced (`ZWANENZANG_HASH`), the tracker's current text, or empty
  with no such document in the tracker. One with edits the tracker
  lacks stays, with a conflict note on its ticket to push it or delete
  the heading; so does one carrying anything of the human's that the
  tracker does not have and deleting would lose: subheadings, properties
  other than the client's (`ID`, `CUSTOM_ID` and the like), planning
  lines, a TODO keyword, priority, tags or drawers of its own. A second
  heading for one name, and one named `description`, stay too. Pull never writes such a subheading, and the
  tracker's text is never compared into Org: the documents drawer links
  it. Migration writes no tracker version.
- `reset: true` needs nothing special: pull always compares full state
  with the sync state, and comments are re-rendered from state, so
  nothing is duplicated. It is reported.
- The buffer is edited (visiting the file if needed) but never saved.
  One scope's pull is a single undo step and works whatever the folding.
  A CLI failure before or during the edit leaves the buffer as it was.

### Push

Decided 2026-11-08 with the first `zwanenzang-push`, which acts on the scope
containing point: its own `read`, one `apply`, then a pull so numbers,
cursors and sync state land. It never fetches first; `zwanenzang-sync`
does.

- What is sent: for each field where Org differs from the sync state, Org's
  value, whatever the tracker has now. The agent's value stays in history.
  A field the tracker already agrees with is not sent, and neither is one
  only the tracker changed: the pull applies that.
- Status goes by keyword, only when it changed, as the first status of
  that keyword. If the tracker already has a status of that keyword, the
  two agree. Tags are sent as the difference between Org's set and the
  tracker's; `zz_conflict` and `ARCHIVE` are never among them.
- Documents use the current version from push's own read as `base`, so
  the human's text goes on top of whatever an agent wrote. When an edit
  sits unfetched on the remote, the human's version can still end up lost
  at replay: the final pull then shows a conflict with the text kept in Org,
  and the next push settles it. If the clone moves between the read and the
  apply, so the base is stale, push reads again, rebuilds and applies once
  more; a second stale base is a `user-error`, with the buffer untouched.
- No sync state means no wiping: a field with nothing recorded is sent
  when Org has a value, but an empty one is left alone. An empty new
  document is not created either.
- Creates come first in the batch, then each heading's changes in buffer
  order, ancestors first, so a reshuffled nesting has no moment with a
  parent cycle. A refused batch changes nothing, in the tracker or the
  buffer, and the error names no heading, as the CLI's does not.
- Identity must survive: without `ZWANENZANG_ID` the next push would create
  the ticket again. So it is written right after `apply` returns, and a push
  that created at least one ticket saves the file right then, and says so in
  the report. Everything else leaves buffers unsaved: pull, pushes that
  created nothing, and the pull ending a push. A read-only buffer is refused
  before `apply`. If writing back still fails after `apply` succeeded, the
  error lists the created numbers and ids so the human can recover.
- Parent comes from nesting: the nearest ticket heading above, new ones
  included. Grouping headings are transparent; the inbox or scope root
  means no ancestor. `parent` is sent only when the nesting changed since
  `nest=`, so a ticket parked in the inbox keeps its tracker parent.
- Inline documents of the old form are still pushed during the
  transition, so text typed into one is not lost: an edited one sends a
  new version, one with no recorded hash a first version, and the pull
  ending the push then removes it as synced. The name `description` and
  a second heading for a name already seen are refused with a report
  line. `ZWANENZANG_HIDE_DOCS` no longer holds any back.
- Blocked and skipped: foreign and duplicate ids, a tombstoned ticket, an
  Org keyword with no status or no keyword at all, a tracker status with no
  keyword, an empty title. The final pull writes the tag and note, because
  pull recomputes that drawer: an unmapped or missing Org keyword now gets
  its note there too. A tracker id mismatch skips the whole scope. Headings
  tagged `zz_conflict` for field conflicts are pushed like any other, and
  the final pull clears their tag and drawer once the fields agree.
- A status change the CLI's `PROJ` rule would refuse (data model,
  Projects) is left out of the batch and reported, `ZZ-1 Title: status not
  pushed: tagged PROJ, it has unfinished descendants ZZ-3`, so it does not
  refuse the rest of the scope. Push judges it as the CLI does, on the
  tracker after the whole batch: its read, `list --all` and the batch's own
  statuses, parents and tags, repeating while one left out makes another
  refused. Org keeps the keyword; the pull ending the push writes no note,
  and the next push tries again. This is the one exception to "the
  human's push goes through". A new heading the rule refuses, and a comment
  send or archive whose status change it refuses, are refused by the CLI
  with `proj-hierarchy` as a whole, nothing lost.
- A new heading that cannot be created (unmapped keyword, no title, a
  blocked ticket heading above it) is only reported; it is not a ticket, so
  no note is written on it. A ticket moved under a blocked heading keeps
  its parent, reported, and the nesting's sync state, so it retries.
- An invalid tag, or a document name the CLI refuses, refuses the batch
  with the CLI's error, which names it. Nothing is lost.
- `zwanenzang-sync` is CLI `sync`, pull, push, the push ending in a pull. An
  unreachable remote is reported and the rest works on the local clone.
  `zwanenzang-sync-all` does that for every scope in `zwanenzang-org-files`;
  a scope that fails is reported and the others still run.

### Document buffers

Decided 2026-11-13 (ZZ-0028/ZZ-0042): named documents leave the outline.

- Following a `zwanenzang:<id>/<name>` link, from a ticket's documents
  drawer, a show buffer or anywhere `zwanenzang-open` works, opens an
  editable `org-mode` buffer `*zwanenzang NUMBER NAME*`
  (`zwanenzang-document-mode`) filled by `doc get`. It remembers the
  version it shows and the scope and tracker it was opened from. Nothing
  is written to a file. A buffer already open for that document is shown
  as it is when it holds unsaved edits and refreshed from the tracker
  otherwise.
- `C-c C-c` writes the whole text, however the buffer is narrowed,
  normalized as all prose is, as a new version
  in one `apply` `doc` change with the shown version as `base`, the same
  compare-and-set as `doc set --base`. It then closes the buffer and
  pulls the scope once, as sending a comment does; a document opened
  outside any live scope is only reported. Unchanged text writes nothing
  and closes the buffer. An empty new document is refused.
- When another version was written since (`stale-doc-base`), nothing is
  written and the buffer stays as it is. The refusal and the header line
  name that version's author. A second `C-c C-c` asks "Replace version by
  AUTHOR?"; yes writes against that version as the new base, no keeps
  the text. `M-x zwanenzang-document-ediff` compares the buffer with the
  tracker's current text.
- `C-c C-k` closes the buffer without writing, asking first when it was
  edited.
- `zwanenzang-new-document` asks for a name on a pushed ticket heading
  and opens an empty buffer; its first save creates the document (`base`
  null). The name must be what the CLI accepts (letters, digits, `-`,
  `_`, at most 64) and not `description`; a name the ticket has opens
  that document.
- A document buffer is prose, not a scope: client commands that act on a
  scope refuse there, and Org notes behave as in any Org buffer, as in a
  source editor.

### Errors and reports

- A command failure (a JSON error object, or a usage error with exit
  status 2) is a `user-error` with the code and message; the buffer is
  left untouched.
- Publication errors (`fetch-failed`, `push-rejected`, ...) and checkout
  skips are not failures: the client echoes a one-line summary and appends
  a readable report to the `*zwanenzang*` buffer.
- The report lists per ticket, by number and title, what was pulled, moved,
  pushed (changes the tracker wrote, not its no-ops) and created, then conflicts and checkout results from the sync
  object. Conflict lines show both Org's title and the tracker's. A command
  of several steps makes one report; the conflicts in it are the last
  pull's, so ones a push settled are gone. The echo points at the buffer
  only when something needs a look; a clean run is one line.
- A ticket counts as pulled when what Org shows of it changed. The
  relations and code drawers are left out of that comparison: a change
  confined to them is written but not reported, so a renamed prerequisite
  does not report every dependent as pulled.

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

## Dependencies

Decided 2026-11-09, starting with an Org-only manual UX experiment. The
human accepted that interaction and authorized tracker-backed relationships.
Dependencies add no tracker-side completion policy and require neither
org-contrib's `org-depend` nor Org Edna. Those packages share a `BLOCKER` property name
but not a grammar; generating it could silently enable their enforcement.

Enter dependencies manually on the dependent heading:

```org
** TODO A prerequisite
:PROPERTIES:
:ZWANENZANG_ID: 01M00000000000000000000001
:ZWANENZANG_NUMBER: ZZ-42
:END:
** TODO The dependent ticket
:PROPERTIES:
:ZWANENZANG_ID: 01M00000000000000000000002
:ZWANENZANG_DEPENDS_ON: ZZ-42
:END:
```

Both headings must be inside a scope carrying `ZWANENZANG`. The property
is a whitespace-separated list of human-facing ticket IDs in that same
tracker, such as `ZZ-42`, not internal ULIDs, Org links or Org `ID`
values. A reference is compared by its prefix, ignoring letter case, and
its number as an integer, so `zz-0042` is the same reference; this applies
to local `ZWANENZANG_NUMBER` values too. Resolve them through the snapshot's display references or local
`ZWANENZANG_NUMBER` properties; use stable identity internally to find
local edits. Unpublished tickets must acquire a number before they can be
referenced. Every prerequisite must be done. The dependency property itself
is not inherited. Edit it directly or with the two commands below; there
are no overlays or agenda additions.
Pull/push synchronize it with the ticket's `depends_on` set. The event log
stores stable identities; the property always shows published ticket numbers.

`zwanenzang-add-dependency` and `zwanenzang-remove-dependency` act on the
nearest ticket heading (one with `ZWANENZANG_ID`) at or above point. They
only edit that heading's `ZWANENZANG_DEPENDS_ON`, keeping the spelling of
the numbers already there and sorting by number; removing the last one
removes the property. Nothing is sent: the next push does that, under the
usual Org-wins and conflict rules. Both read a fresh `list --all` of the
scope's tracker and refuse a heading that tracker does not know.

- Add offers every numbered ticket that is not archived or tombstoned,
  except the ticket itself, its current prerequisites (compared by number)
  and the tickets that already depend on it directly or transitively in
  the tracker's `depends_on`, which would make a cycle. Done tickets are
  offered.
- Remove offers the numbers in the property, with titles where the
  tracker knows them; every spelling of the chosen number is removed.
- Candidates read `NUMBER Title`, so ordinary completion styles match
  either. The completion table has the category `zwanenzang-ticket`, keeps
  numeric order (`display-sort-function`), and has an
  `annotation-function` showing status, kind and tags. Completion UIs such
  as marginalia show that annotation without the client depending on them.
  Description text is not fetched. The package binds no keys for them.

- Loading the package installs a global `org-blocker-hook` function, gated
  on inherited `ZWANENZANG` and a nonempty `ZWANENZANG_DEPENDS_ON` on the
  heading itself. Unrelated Org headings are unaffected.
- Only a transition from an unfinished/no keyword to a done keyword is
  checked. Starting, reopening, changing unfinished states or switching
  between done keywords is unrestricted. Completion/reopening never
  changes another ticket's keyword or sets a `blocked` status/tag.
- Same-scope Org headings supply their current, possibly unsynced keywords.
  Otherwise the last tracker snapshot supplies status, interpreted through
  the dependent scope's current keyword map and buffer's done keywords.
  Different scope configurations may interpret completion differently.
- Successful `zwanenzang-sync`/`zwanenzang-sync-all` automatically retain an
  in-memory snapshot for each scope from the final pull's `list --all` and
  `read` results, preferring `read` where both contain the ticket. These
  are separate local loads, not an atomic all-ticket snapshot. Plain pull
  or push does not refresh the dependency snapshot.
- The snapshot is buffer-local and not persisted, shared across trackers,
  timed out or refreshed by timers. A failed sync/publication keeps the
  previous snapshot. Checks never fetch or run the CLI. Reopening a buffer
  starts without a snapshot; absent prerequisites remain unknown until a
  successful sync. Changing the scope location or recorded tracker identity
  invalidates its snapshot.
- Missing tickets, unknown/unmapped states and duplicate local IDs block
  completion with a reason. A known tombstone blocks even if a surviving
  local heading says DONE. Archiving alone neither satisfies nor invalidates
  a prerequisite; its status determines completion. Without a snapshot,
  unique local headings can still satisfy prerequisites.
- Rejection lists prerequisite references, titles when known and reasons,
  plus the snapshot age (or its absence). There is no claim of live remote
  knowledge. Use Org's normal triple-prefix `C-u C-u C-u C-c C-t` to
  change state without blockers, or its `NOBLOCKING` property; overrides
  leave dependencies intact. The triple prefix retains Org's normal state
  selection/cycling behavior, so the next keyword may still be unfinished.
- Pulls continue to rewrite headings directly, bypassing TODO hooks. A
  remote completion is accepted even if its prerequisites are unfinished;
  the CLI remains tracking-only and human overrides are always possible.

### Tracker-backed synchronization

- Directed same-tracker edges are stored once on the dependent; reverse
  `blocks` is derived. CLI `depend T PREREQUISITE [--remove]` and batch
  `depend`/`undepend` edit edges without imposing any status policy.
- Pull reconciles the dependency set as one field, using the normalized,
  sorted ticket-number set's hash in `ZWANENZANG_SYNC` as `depends=`.
  Order, repeated references, letter case and leading zeros are not
  edits; the set sorts by prefix, then numerically (`ZZ-9 ZZ-10`). Pull
  writes the property in the tracker's unpadded form whenever Org holds
  the same set in another spelling. Remote-only
  changes apply; simultaneous disagreement keeps Org, with the skipped
  remote numbers in the conflict drawer. Push sends edge differences between
  the edited Org set and its own current read; the human's set wins over
  known concurrent edits. Unseen remote changes have the same next-pull
  conflict/next-push settlement boundary as other synced fields.
- On upgrade, a missing `depends=` baseline means the empty set. Existing
  manually entered dependencies are therefore preserved and pushed; an
  empty property can receive remotely stored relationships. Removing a
  property with recorded sync state explicitly clears the dependency set.
- Clients before unpadded numbers wrote `ZWANENZANG_NUMBER` and the
  property as `ZZ-0042` and hashed that padded set as `depends=`. A
  `depends=` equal to the padded form of the Org or tracker set counts as
  that set, so padding alone is never an edit or a conflict. The first pull
  rewrites both properties; there is no migration command.
- Resolution uses pull/push's existing `list --all` number map, including
  archived/tombstoned prerequisites absent from Org. No org-id lookup, global
  registry or extra TODO-transition CLI calls are introduced. Unknown or
  ambiguous numbers refuse the whole push before apply. New headings may
  depend on published tickets; referencing new prerequisites still requires
  publishing them first. A remote prerequisite without a number leaves the
  field unchanged and raises a pull conflict until it has a number.
- Dependency removals precede additions in the batch, after creates, avoiding
  temporary cycles when reversing relationships. The CLI rejects local
  self-edges/cycles atomically. Replay preserves cycles introduced by
  concurrent writes and lint diagnoses them; Org completion checks remain
  overridable even for such cycles. Archive/tombstone never deletes edges.
- The blocker and snapshot rules above are unchanged: no CLI completion
  vetoes, implicit terminal-status vocabulary, automatic status changes,
  any-of dependencies, triggers, cascading reopening or cross-tracker lookup.

## Priority and attention queue

Native Org priority cookies synchronize as a separate nullable `priority`
scalar, not title text or tags. Unset stays unset; effective ranking uses
`org-priority-default`. Numeric priorities (0–64) and alphabetical priorities
(A–Z, integer codes 65–90) use Org's own representation. `zwanenzang.toml`
may configure `[priority]` with `highest`, `lowest`, `default` integer values;
absent settings use Org's standard 65/67/66 defaults. Live writes validate
against that range. Replay validates against all native Org values, so a
later range change does not erase historical choices. Concurrent priority
changes are reported like other scalar fields.

Org retains authority over edited cookies. `priority=` in the sync snapshot
stores the explicit value, or `-1` for unset. Upgrading a missing baseline
means unset, preserving existing local cookies. Pull merges priority field by
field; push sends edited cookies, including explicit clearing. A new heading's
priority is sent after its create. Heading rewrites preserve numeric as well
as alphabetical cookies. Scope pull/push refuses mismatched Org buffer and
tracker range/default settings with guidance; it never silently overwrites
Org settings or TOML. Align `#+PRIORITIES` or buffer-local Org settings and
TOML manually. A priority refusal includes a complete `[priority]` replacement
section using the running buffer's Org values (including `#+PRIORITIES`).
Reporting the refusal copies that section to the kill-ring; interactive Emacs
asks whether to visit the tracker's `zwanenzang.toml`, with the mismatch and
copy notice in the prompt. After declining or visiting, the copy notice is
shown again with a pointer to `*zwanenzang*`. Declining still leaves the snippet
available. Visiting never inserts or saves anything. Either align Org to the
tracker values shown in the report, or replace the existing TOML section with
the snippet, save, commit and push in the tracker clone, then retry. Changing
TOML changes the range/default for every user of the tracker; the tool does not
commit this human configuration edit. Both the report and the copied snippet
explain that letters are stored as integer character codes, not quoted letters. Tracker-identity refusals do not offer this priority remedy.

Pull projects read-only `ZWANENZANG_ACTIVITY` (selected event timestamp),
`ZWANENZANG_TAG_SINCE` (JSON current tag interval event references),
`ZWANENZANG_INACTIVE` (archive/tombstone eligibility), and
`ZWANENZANG_READ_AT` (time this event snapshot was first read, NOT last
fetch; unchanged cursors keep it so no-op pulls do not dirty the buffer). Incremental reads and
cursor resets both use the full replay-derived values; ordinary agent
activity does not reset waiting age. No new timestamp events are introduced.

`M-x zwanenzang-queue` uses org-ql over `zwanenzang-org-files`. Membership is
an explicit local attention tag (`needs_human` by default, configurable),
combined with an additional org-ql query (unfinished TODO by default).
Only actual active ticket headings in tracker scopes qualify; inherited
tags, document headings and archived/tombstoned tickets do not. Native Org
priority (including configured default) sorts first, oldest selected wall
time second, unknown times last within priority, stable ticket identity last.
Future clocks are visibly flagged. Across trackers, location breaks identity
ties. These are views of local projections and unsynced human edits, never a
claim of live remote knowledge.

In the view, `a` selects last-activity or waiting-for-human age interactively;
`g` rebuilds locally. Both preserve the selected ticket where possible and
write no events or source buffers. The active mode is in the header; entries
show age separately from the snapshot's local read time. Waiting age uses the current
uninterrupted attention-tag membership interval. Sync explicitly in the source
scope to refresh remote state. No per-entry CLI calls, timers, auto-clear,
stage transitions, approval gates or new completion policies are added.
org-ql retains query, saved-view and navigation capabilities; this adapter
adds no query language or generic view framework.

## Open questions

Richer dependency editing commands, displays and agenda integration remain
out of scope until daily use motivates them.
