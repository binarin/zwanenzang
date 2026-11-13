#!/usr/bin/env bash
# Exercise the installed entry points, including the git wrapper (not cargo run).
set -euo pipefail
package=$1
export REAL_GIT=$2
for command in zz zwanenzang; do
    test -x "$package/bin/$command"
done

system_tmp=$(realpath "${TMPDIR:-/tmp}")
root=$(mktemp -d "$system_tmp/zz-command.XXXXXX-test-repo")
repo=$root
trap 'rm -rf "$root"' EXIT
assert_disposable() {
    case "$(realpath "$repo")" in
        "$system_tmp/"*-test-repo) ;;
        *) echo "refusing non-disposable repository: $repo" >&2; exit 1 ;;
    esac
}
assert_disposable
# Never open an enclosing tracker, even before init.
parent=$(dirname "$repo")
while :; do
    test ! -f "$parent/zwanenzang.toml"
    test "$parent" != / || break
    parent=$(dirname "$parent")
done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE
export HOME="$repo"
"$REAL_GIT" init --quiet --bare "$repo/remote-test-repo.git"
cli() {
    assert_disposable
    local command=$1
    shift
    env PATH="$cli_path" "$package/bin/$command" -C "$repo" \
        --actor-name 'installed command test' "$@"
}

# With no caller git, both installed paths must retain the packaged fallback.
cli_path=
cli zz init "$repo/tracker-test-repo" --remote "$repo/remote-test-repo.git?ref=main" \
    --prefix TEST > "$repo/init.json" 2> "$repo/stderr"
test ! -s "$repo/stderr"
grep -F '"prefix": "TEST"' "$repo/init.json"
grep -F '"branch": "main"' "$repo/init.json"
repo="$repo/tracker-test-repo"
cli zz create 'A title with spaces and '\''quotes'\''' > "$repo/create.json"
cli zz list > "$repo/zz.json"
cli zwanenzang list > "$repo/long.json"
cmp "$repo/zz.json" "$repo/long.json"
grep -F "A title with spaces and 'quotes'" "$repo/zz.json"
printf '{}\n' | cli zz read > "$repo/zz.json"
printf '{}\n' | cli zwanenzang read > "$repo/long.json"
cmp "$repo/zz.json" "$repo/long.json"
grep -F '"tickets": [' "$repo/zz.json"

for command in zz zwanenzang; do
    if cli "$command" show TEST-9999 > "$repo/$command.error" 2> "$repo/stderr"; then
        exit 1
    else
        test "$?" = 1
    fi
    test ! -s "$repo/stderr"
    grep -F '"code": "unknown-ticket"' "$repo/$command.error"
    if cli "$command" --not-an-option > "$repo/stdout" 2> "$repo/stderr"; then
        exit 1
    else
        test "$?" = 2
    fi
    test ! -s "$repo/stdout"
    grep -F -- '--not-an-option' "$repo/stderr"
    cli "$command" --version > "$repo/$command.version"
    cli "$command" --help > "$repo/$command.help"
    grep -F -- '--tracker-url' "$repo/$command.help"
done
cmp "$repo/zz.error" "$repo/zwanenzang.error"

# Bundled instructions are plain text served by both names, with no store paths.
for command in zz zwanenzang; do
    cli "$command" agent-hooks show-document tickets/conflicts/stale-doc-base \
        > "$repo/$command.doc" 2> "$repo/stderr"
    test ! -s "$repo/stderr"
    grep -F 'stale-doc-base' "$repo/$command.doc"
    cli "$command" agent-hooks show-document overview > "$repo/$command.overview"
    if grep -F /nix/store "$repo/$command.overview"; then exit 1; fi
    cli "$command" agent-hooks init > "$repo/$command.bootstrap"
    grep -F '`TEST-0042`' "$repo/$command.bootstrap"
    grep -F '`zz agent-hooks show-document overview`' "$repo/$command.bootstrap"
    if grep -F / "$repo/$command.bootstrap"; then exit 1; fi
done
cmp "$repo/zz.doc" "$repo/zwanenzang.doc"
cmp "$repo/zz.bootstrap" "$repo/zwanenzang.bootstrap"
cmp "$repo/zz.version" "$repo/zwanenzang.version"

# A git supplied by the caller must still take precedence over the fallback.
mkdir "$repo/caller-bin"
printf '#!%s\nprintf "called\\n" >> "$GIT_CALL_LOG"\nexec "$REAL_GIT" "$@"\n' \
    "$BASH" > "$repo/caller-bin/git"
chmod +x "$repo/caller-bin/git"
cli_path="$repo/caller-bin"
export GIT_CALL_LOG="$repo/git-calls"
for command in zz zwanenzang; do
    : > "$GIT_CALL_LOG"
    cli "$command" sync > "$repo/$command.json"
    test -s "$GIT_CALL_LOG"
done
cmp "$repo/zz.json" "$repo/zwanenzang.json"
echo 'Installed zz and zwanenzang: forwarding, JSON, exits and git PATH passed'
