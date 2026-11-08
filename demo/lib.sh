# Shared by the demo scripts; sourced, not run.

demo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$demo_dir")
tracker=/tmp/zwanenzang-demo-test-repo

# The disposable-repo rule from AGENTS.md: refuse anything that is not under
# the system temporary directory or whose name does not end in -test-repo.
# Prints the path with symbolic links resolved, which is what scripts use.
demo_disposable() {
	local resolved tmp
	resolved=$(realpath -m "$1")
	tmp=$(realpath -m "${TMPDIR:-/tmp}")
	case "$resolved" in
	"$tmp"/*-test-repo | /tmp/*-test-repo) printf '%s\n' "$resolved" ;;
	*)
		echo "refusing to touch $resolved: not a *-test-repo under the temporary directory" >&2
		return 1
		;;
	esac
}

# No user or system git configuration reaches the tracker's commits.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.invalid
export GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.invalid
unset GIT_DIR GIT_WORK_TREE
export LC_ALL=C.UTF-8

# A flake package or an input's package, built once and without a result link.
demo_build() {
	nix build --quiet --no-link --print-out-paths "$@"
}

cli=$(demo_build "$repo#zwanenzang")/bin/zwanenzang
jq=$(demo_build --inputs-from "$repo" 'nixpkgs#jq^bin')/bin/jq

# This flake's CLI on the demo tracker, as the actor playing the agent.
zz() {
	"$cli" -C "$tracker" --actor-name demo-agent "$@"
}
