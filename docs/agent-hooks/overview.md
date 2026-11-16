# Using a zwanenzang tracker

For an agent whose project keeps its tickets in a zwanenzang tracker. This
covers how to use the tool and its rules of use: identifying agent writes,
where prose belongs, how tickets link, and what the default statuses and
workflow tags mean. Project process beyond that, such as what to track and
when, is up to the project, whose own instructions take precedence.

## The command

`zz` and `zwanenzang` are the same command; where only `zwanenzang` is
installed, use it wherever these documents say `zz`. Without either, run it
from its flake, keeping the `--`:

```sh
nix run git+https://forgejo.lynx-lizard.ts.net/binarin/zwanenzang#zwanenzang -- <arguments>
```

Every tracker command prints one JSON value on stdout. A refused command prints
`{"error": {"code": ..., "message": ...}}` and exits 1. Wrong arguments are a
message on stderr and exit status 2. `zz agent-hooks` is the exception: it
prints plain text, such as this document.

## Topics

Read the ones the task needs:

- `zz agent-hooks show-document selection`: which tracker a command uses, and
  what to do when its clone cannot be provisioned.
- `zz agent-hooks show-document tickets`: reading and changing tickets,
  comments and documents, statuses and workflow tags.

Before any write, read `selection` for the mandatory `--actor-name`, and
`tickets/prose` before writing comments or documents.
- `zz agent-hooks show-document cli-json`: the full JSON contract, with every
  command, field and error code.
