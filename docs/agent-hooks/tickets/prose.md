# Comments and documents

The CLI stores whatever text it is given and checks none of the rules below;
following them is up to the writer.

- All prose is Org, not Markdown.
- The `description` document belongs to the human. Agents read it and do not
  write it.
- Comments are append-only: they can be neither edited nor removed. A
  correction is a new comment.
- Named documents are versioned and can be rewritten, with a compare-and-set
  base (below).

## Comment or document

The shape of the text decides, not where an instruction says to put it. When
the human asks for something "in the comments", record it on the ticket and
choose the form by these rules.

- A comment is a short delta: a decision and what it supersedes, a status
  change and why, an outcome, or a pointer. As a rough guide, up to about ten
  lines, with no sub-headings and no tables.
- Anything longer or structured goes into a named document: material with
  sub-headings or tables, open questions, or anything that will be revised.
  Announce a new or substantially changed document with a one-line comment.
- Bulky material that belongs to a code repository, such as research notes or
  a handoff file, lives in that repository. Point to it with a
  one-line `zz comment T "what it is" --link URL`, not with a bare path in
  the text.
- Do not restate in prose what ticket fields already hold: links to other
  tickets, status, tags.

A comment written in a role may start with a heading naming it, such as
`* Review: ...`, `* Plan: ...` or `* Outcome: ...`.

Use these document names, and avoid inventing others:

- `summary`: a short, self-contained statement of the ticket, for readers
  who will not read further.
- `brief`: the current state and plan: goal, scope, decisions, open
  questions, next step. Readers look here first for what is current.
- `notes`: research, findings and evidence that support the brief.

Another name is fine when none of these fit; announce it in a comment. An
older ticket may hold its brief as `implementation-brief`; read that when
there is no `brief`.

## Writing

Org lists start with `-`, which the argument parser rejects as a comment
argument, so pass prose with `--file` or on stdin:

```sh
zz comment ZZ-42 --file note.org
```

Writing a document names the version it is based on: `version` from `doc get`,
or `none` for a new document. The text comes from `--file` or stdin. Run
`sync` before the `doc get`, since the base check only sees what the clone has.

```sh
zz doc set ZZ-42 brief --base <version> --file brief.org
```

When the base is not current, or another clone wrote a version at the same
time, see `zz agent-hooks show-document tickets/conflicts`.
