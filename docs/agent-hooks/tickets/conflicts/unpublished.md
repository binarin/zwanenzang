# Write not published

A write exited 0 but its `sync.error` is set: the remote could not be reached,
the rebase conflicted or the push failed. The events are committed in this
clone only.

- Do not cite a ticket number from it; a new ticket has none yet. Use the short
  id (`zz agent-hooks show-document tickets/numbers`).
- Run `zz sync` once the cause is fixed. It exits 1 while the problem persists,
  with `sync.error` saying why. The next write that changes something also
  retries.
- Do not reset, reclone or edit the clone's git state to get past it; that
  loses the unpublished events.
