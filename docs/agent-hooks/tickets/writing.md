# Changing tickets

An agent passes `--actor-name` on every write; see
`zz agent-hooks show-document selection`.

```sh
zz create "A title" --status todo --tag example
zz status ZZ-42 agnt
zz priority ZZ-42 65   # Native Org A
zz priority ZZ-42 --clear
zz mr ZZ-42 app https://forge.example/app/pulls/7
zz depend ZZ-43 ZZ-42
```

An unknown status or kind is refused, and so is a status the tracker retired
(`retired-status`: old tickets may still show it, but pick a current one); an
unknown repository alias is written anyway and only `lint` reports it.

Priority is separate from tags and title. Native Org values are numeric 0–64 or
letter codes 65–90 (A–Z). Batch `priority` takes a required nullable `to`.

`depend T P` records T's prerequisite P; `--remove` removes it. Self-edges and
local cycles are refused; cycles formed concurrently survive sync and are
reported by `lint`. Dependencies never veto status changes.

Use `depend` only when T cannot be finished without P. For any other
connection between two tickets use `relate T U`, which has no direction.
Record links with these commands rather than in comment text.

When to change a status, and the two workflow tags, are in
`zz agent-hooks show-document tickets/statuses`.

## What a write reports

Every write commits and then syncs. Output is one JSON value on stdout.

- A refused command prints `{"error": {"code": ..., "message": ...}}` and exits
  1. Nothing was written.
- A write that could not reach the remote still succeeds and exits 0. It is
  committed locally, `sync.error` says what went wrong, and the next write that
  changes something, or `sync`, pushes it. Until then it exists only in this
  clone.
- `sync` itself exits 1 in that case, also reporting it in `sync.error`, with
  no top-level `error`.
- `"written": false` means the write would change nothing. No event was written
  and no sync ran.

Comments and documents are in `zz agent-hooks show-document tickets/prose`.
