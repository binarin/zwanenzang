# Lost document version

The base check only sees what the clone has. A write that raced a version from
another clone exits 0 all the same, and when the two meet, the one with the
lower id stays current and the other is marked `lost: true`.

After `doc set`, compare `event.id` with `ticket.documents.<name>.current` in
the output. If they differ, treat it as a stale base: follow
`zz agent-hooks show-document tickets/conflicts/stale-doc-base`.

This can still happen after a successful write, when another clone's earlier
offline version arrives in a later sync. `zz lint` lists these under
`lost_documents`, with the lost version's `event` and the `current` version
it lost to. If the lost version was yours, merge your change into the current
text in the same way.
