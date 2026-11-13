# Refused document write: stale-doc-base

`doc set` failed with code `stale-doc-base`: the `--base` given is not the
document's current version in this clone. Nothing was written.

1. `zz sync`, so the clone has everything published.
2. `zz doc get TICKET NAME` and read the new text.
3. Merge your change into it, keeping what the other writer added.
4. `zz doc set TICKET NAME --base VERSION --file FILE`, with the `version` just
   read.

Do not retry with the old base or overwrite the newer text unread. How
documents are written is in `zz agent-hooks show-document tickets/prose`.
