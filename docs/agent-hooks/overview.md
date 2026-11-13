# Using a zwanenzang tracker

For an agent whose project keeps its tickets in a zwanenzang tracker. This
covers how to use the tool. It sets no process: what to record and when is up
to the project, whose own instructions take precedence.

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
  comments and documents.
- `zz agent-hooks show-document cli-json`: the full JSON contract, with every
  command, field and error code.
