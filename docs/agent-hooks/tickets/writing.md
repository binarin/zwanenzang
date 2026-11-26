# Changing tickets

An agent passes `--actor-name agent` on every write; the tool refuses a write
naming no identity or one the tracker does not list. See
`zz agent-hooks show-document selection`.

```sh
zz --actor-name agent create "A title" --status todo --tag example
zz --actor-name agent status ZZ-42 agnt
zz --actor-name agent priority ZZ-42 65   # Native Org A
zz --actor-name agent priority ZZ-42 --clear
zz --actor-name agent schedule ZZ-42 2026-12-03
zz --actor-name agent schedule ZZ-42 --clear
zz --actor-name agent mr ZZ-42 app https://forge.example/app/pulls/7
zz --actor-name agent depend ZZ-43 ZZ-42
```

An unknown status or kind is refused, and so is a status the tracker retired
(`retired-status`: old tickets may still show it, but pick a current one); an
unknown repository alias is written anyway and only `lint` reports it.

Priority is separate from tags and title. Native Org values are numeric 0–64 or
letter codes 65–90 (A–Z). Batch `priority` takes a required nullable `to`.

`schedule T VALUE` sets the ticket's Org SCHEDULED date, which reaches the
human's Org agenda; `--clear` removes it. `VALUE` is a date `2026-12-03`,
optionally with a time `10:00` or `10:00-11:30`, a repeater `+1w` and a delay
`-2d`, or a relative date `today`, `tomorrow`, `+3d`, `+2w`, `+1m`, `+1y`,
optionally with a time. Relative dates are resolved against the local date
where the command runs. The result's `message` echoes the date with its
weekday; check it. Impossible dates are refused with `invalid-timestamp`.
Batch `scheduled` takes a required nullable `to` with the same input.

When a comment or document says to check back on a date ("look again once
the upstream fix is released, around 2027-01-15"), also run `schedule` for
that date, so it shows on the human's agenda. Relative input is fine; when
the prose names a date, schedule that absolute date. Nothing clears the date
by itself, not even `done`.

`depend T P` records T's prerequisite P; `--remove` removes it. Self-edges and
local cycles are refused; cycles formed concurrently survive sync and are
reported by `lint`. Dependencies never veto status changes.

A ticket tagged `PROJ` is a project; its subtree (children, their children
and so on) is its work. While any of them is unfinished (not `done` or
`cncl`), every status change of the project is refused with
`proj-hierarchy`; once all are, it may only become `done` or `cncl`.
Reopening a finished project to an unfinished status is always allowed.
This binds every writer. Finish the subtree first, or in the same `apply`.
Tombstoned tickets do not count; archived ones count by their status.
Reopening a child or adding one under a finished project is not refused,
and `lint` reports it.

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
