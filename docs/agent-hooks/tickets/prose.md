# Comments and documents

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
zz comment ZZ-0042 --file note.org
```

Writing a document names the version it is based on: `version` from `doc get`,
or `none` for a new document. The text comes from `--file` or stdin. Run
`sync` before the `doc get`, since the base check only sees what the clone has.

```sh
zz doc set ZZ-0042 plan --base <version> --file plan.org
```

When the base is not current, or another clone wrote a version at the same
time, see `zz agent-hooks show-document tickets/conflicts`.
