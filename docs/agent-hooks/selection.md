# Selecting a tracker

A code repository names its external tracker in local git configuration. This
is one-time setup, not committed:

```sh
git config --local zwanenzang.trackerUrl https://forge.example/owner/tracker.git?ref=tickets
zz sync
zz show ZZ-0042
```

Or pass `--tracker-url URL` on each command, from anywhere. Both take a
locator: the origin URL with an optional `?ref=BRANCH` selector naming the
branch the tracker lives on. Without a selector, the remote's default
branch is used. The CLI provisions and reuses one durable clone per
locator automatically; do not clone per workspace or session. Use the
project's exact canonical URL spelling, without credentials. An existing
clone can be selected with `-C DIR`, which disables URL discovery.
Inside a tracker, commands use that tracker directly.

Creating a tracker is distinct from opening one: `zz init DIRECTORY
--remote LOCATOR --prefix PREFIX` creates a standalone checkout and
publishes it as a new branch of the remote. It refuses a branch that
already exists, so never run it against a tracker that is already
published; open that one instead.

If provisioning reports incomplete storage or an origin mismatch, stop and
inspect; do not delete, reset or reclone it. It may hold unpublished work. The
clone is persistent data, not a cache: leave it alone during workspace
cleanup. Where it lives and how it is validated is in the "URL-selected
storage" section of `zz agent-hooks show-document cli-json`.

Pass a stable `--actor-name` on writes if desired. The actor belongs to the
clone, not the session; its name defaults to `$USER` or `unknown` on the first
write. Concurrent writes and syncs wait on the clone lock. Do not manually
change git state or configuration while clients use it. Reads are unlocked:
retry reads that overlap writes.

Git credentials must work non-interactively. After initial provisioning,
offline writes remain local until a successful sync.
