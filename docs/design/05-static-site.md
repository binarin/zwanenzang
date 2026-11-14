# Static site

`zz render DIR` writes a static, self-contained HTML view of a tracker:
a list of tickets beside the selected ticket's detail, readable on desktop
and phone. It is a derived view like any other, regenerated from the log and
never read back. This is the exploratory first version of milestone 4: a
local directory opened from `file://`. Hosting it (on the tailnet, say) and
building it in forge CI are later work.

## Command

```
zz render DIR [--assets SRC]
```

- Reads replayed state directly, as `query` does: no lock, no fetch, no
  write to the tracker. A tracker selected by `--tracker-url` is cloned on
  first use as for any command.
- `DIR` is created when missing. A `DIR` inside the tracker clone is
  refused with `inside-tracker`; the output is private tracker content and
  must not be committed into the tracker by accident. Missing directories in
  `DIR` may not use `..`, so the check cannot be talked around.
- The same log and the same assets give byte-identical output: no clock, no
  machine paths, every collection in a fixed order.
- `--assets SRC` reads `index.html`, `style.css` and `app.js` from `SRC`
  (normally a checkout's `site/`) instead of the copies embedded in the
  executable, so the page can be changed without rebuilding.

## Output directory

| path | content |
|---|---|
| `index.html`, `style.css`, `app.js` | the page, from `site/` in this repository |
| `data.js` | the tracker's content, one script assignment (below) |
| `files/...` | supporting files linked from comments |
| `.zwanenzang-render.json` | the manifest: which files render generated |

A run writes only the files of its output, and replaces or removes only files
the manifest lists. A file in the way that the manifest does not list is
refused with `render-conflict` before anything is written, as is a symlink
anywhere below `DIR` on an output path. Other files in `DIR` are left alone.
Files an earlier run generated that are no longer part of the output, such
as the attachment of a ticket tombstoned since, are removed along with any
directory that leaves empty. The manifest is written first with the old and
new files together and rewritten last with the new ones, so an interrupted
run leaves nothing the next run would take for someone else's file.

Attachments are files under the tracker's `docs/` named by a comment's
`link`. Each is copied to `files/` plus its path below `docs/`. Links that
are URLs stay links; links to anything else stay text.

## data.js

```js
window.ZWANENZANG_DATA = {"format": 1, "tracker": {...}, "tickets": [...]};
```

The JSON is escaped so that it never contains `<`, U+2028 or U+2029. A
`<script src>` works from `file://` where loading JSON would not.

- `tracker`: `name`, `prefix`; `statuses`, the configured vocabulary
  followed by any other status a ticket still has; `hidden_statuses`, the
  ones whose chips start switched off (`done`, `cancelled` and `cncl`, when
  the vocabulary has them); `tags`, every tag in use.
- `tickets`: every ticket that is not tombstoned, published ones by number
  and then unpublished ones by id. Each has `id`, `display`, `number`,
  `title`, `status`, `kind`, `priority` (the Org cookie text, such as `A`),
  `tags`, `parent`, `children`, `depends_on`, `blocks`, `related`,
  `archived`, `created` and `activity` (timestamps), `branches`
  (`{repo, name, repo_url}`), `mrs` (`{repo, url}`), `documents` and
  `comments`. Relations name ticket ids and leave out tombstoned tickets.
- `documents`: the current version of each, description first and the
  rest by name: `{name, actor, ts, html, text}`. Old versions and the event
  history are not included.
- `comments`: `{actor, ts, html, text, link}`; `link` is `{label, href}`,
  with `href` null when it is neither an attachment nor an http(s) URL.

`actor` is the actor's declared name, or the first ten characters of its id.
`text` is the Org source, used for search; `html` is the same text rendered.

## Org to HTML

Tracker prose is Org. `render` converts it with its own small renderer
rather than a library or pandoc: headings, paragraphs, plain, ordered and
description lists with checkboxes, `*bold*`, `/italic/`, `_underline_`,
`+strike+`, `~code~` and `=verbatim=`, `[[links]]` and bare URLs, src,
example and quote blocks, fixed-width lines, rules and simple tables.
Other blocks, drawers and keyword lines are shown preformatted, so nothing
disappears; comment lines are dropped, as Org export drops them. Ticket
numbers in text, such as `ZZ-12` or `ZZ-0012`, link to that ticket. Links reach only
http, https and mailto targets, tickets, and the copied attachments; any
other target stays text. All text is escaped.

## The page

Hand-written HTML, CSS and JavaScript with no build step, library, network
access or external resource. The selected ticket is in the URL fragment as
its display number, so links and the back button work.

- A tree of tickets by parent, filtered by a fuzzy match on number and title
  (each word a subsequence). Tickets that do not match but have matching
  descendants stay visible, dimmed.
- Full-text search over titles, documents, comments, tags and actors. Its
  results replace the tree while the search box has text, with a snippet
  and a count of matches hidden by the filters.
- Filter chips: one per status, one per tag (all selected tags required)
  and one for archived tickets, off by default. Sort by number or by last
  activity.
- The detail pane shows status, kind, priority, tags, timestamps, links to
  parent, children, prerequisites, dependents and related tickets, branches
  and merge requests, every current document and the comments with their
  attachments.
- Below 760 pixels wide the panes become list, then detail with a back link.
