# Concurrent changes

Clones write independently and meet on sync. Nothing is merged by hand: the
event log keeps every write, and replay decides what is current. Most
concurrent changes need no action; the cases below do.

- `zz agent-hooks show-document tickets/conflicts/stale-doc-base`: `doc set`
  was refused because someone wrote a newer version.
- `zz agent-hooks show-document tickets/conflicts/lost-document`: a document
  version was written, but another clone's concurrent version stayed current.
- `zz agent-hooks show-document tickets/conflicts/unpublished`: a write
  succeeded locally but could not be pushed.
