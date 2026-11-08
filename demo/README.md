# Demo: what `zwanenzang-pull` does to an Org file

A throwaway demonstration, never to be merged. The commits on this branch are
the point: read each one's diff of `demo/scope.org`.

| Commit | `demo/scope.org` | How it is produced |
|---|---|---|
| 1 | a human's file with one scope and no tickets | `demo/build-tracker.sh` |
| 2 | the first pull inserts every ticket | `demo/pull.sh 1` |
| 3 | the second pull meets an agent's and a human's changes | `demo/step-2.sh` |

Everything uses this flake's CLI and client, and nixpkgs-unstable's Emacs 31,
built on demand. The tickets are the synthetic ones in
`tests/fixtures/ai-workflow/`. The tracker lives in
`/tmp/zwanenzang-demo-test-repo`; the scripts refuse any path that is not a
`*-test-repo` directory under the temporary directory, and wipe only that one.

## Reproducing

From the root of the repository, on a clean checkout of the branch:

```sh
demo/build-tracker.sh   # commit 1
demo/pull.sh 1          # commit 2
demo/step-2.sh          # commit 3
```

Each script takes the file where the one before it left it, so run them in
this order; `build-tracker.sh` starts again from nothing. To see one pull's
diff, commit or `git add` between the steps. Compared with the committed
files, only ULIDs, cursors and timestamps differ between runs.

### 1. `build-tracker.sh`

Wipes and recreates the tracker with `init --prefix ZZ`, declares the
repository aliases the fixture uses (`app`, `docs-site`) in `zwanenzang.toml`
and runs `import ai-workflow tests/fixtures/ai-workflow`. There is no remote,
so the tickets are numbered at once, `ZZ-0001` to `ZZ-0009` in file order.

The importer writes only descriptions, so the script also gives `ZZ-0003` two
named documents: `plan`, and `status`, which the scope hides. Finally it
restores `demo/scope.org` to its state before any pull, because a pulled file
is bound to the tracker it was pulled from.

The scope root in that file names the tracker, maps the whole default status
vocabulary to TODO keywords (`TODO` shows both `todo` and `draft`) and hides
the document `status`. Above, inside and below the scope are headings of the
human's own, which the tracker never sees.

### 2. `pull.sh 1`

Runs `pull.el` under `emacs --batch`: visit the file, go to the scope root, run
`zwanenzang-pull`, save, and dump the `*zwanenzang*` buffer to
`demo/pull-1-report.txt`.

### 3. `step-2.sh`

Plays an agent through the CLI: a status change on `ZZ-0009`, a new `plan`
version on `ZZ-0003`, a comment on `ZZ-0001`, `ZZ-0006` moved under `ZZ-0003`,
a new ticket under `ZZ-0003`, and a new title on `ZZ-0008`. Then it plays the
human, changing `ZZ-0008`'s title in the Org file with `sed`, and runs
`pull.sh 2`, which writes `demo/pull-2-report.txt`.
