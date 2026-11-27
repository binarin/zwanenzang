# Tickets

A ticket reference is a prefixed number such as `ZZ-42`, a full ULID, or a
unique case-insensitive ULID prefix of at least 4 characters. Bare decimal
input is not ticket-number syntax, but may match a ULID prefix. The prefix is
the tracker's own; numbers are shown without padding, and letter case and
leading zeros do not matter when typing them, so `zz-0042` is `ZZ-42`.

Read-only commands answer from the clone and do not fetch, so run `zz sync`
first when current state matters. Every write commits and then syncs.

Status and kind names, and the repository aliases that `branch` and `mr` take,
are in the clone's `zwanenzang.toml`.

## Topics

- `zz agent-hooks show-document tickets/reading`: `show`, `list`, `query` and
  `doc get`.
- `zz agent-hooks show-document tickets/writing`: changing tickets, and what a
  write reports.
- `zz agent-hooks show-document tickets/prose`: comments and named documents,
  and which of the two a text belongs in.
- `zz agent-hooks show-document tickets/brief`: what the `brief` document
  covers.
- `zz agent-hooks show-document tickets/statuses`: what the statuses and
  workflow tags mean, when an agent changes them, and how it advances a
  ticket.
- `zz agent-hooks show-document tickets/numbers`: when a ticket gets its
  number.
- `zz agent-hooks show-document tickets/conflicts`: when a write meets another
  clone's concurrent work.
