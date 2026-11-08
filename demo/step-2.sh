#!/usr/bin/env bash
# For the third commit: after the first pull, an agent works through the CLI
# while the human edits the Org file, then the second pull meets both.
# Ticket numbers are fixed by the fixture's order; see build-tracker.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tracker=$(demo_disposable "$tracker")
org=$demo_dir/scope.org
grep -q '^:ZWANENZANG_SYNC:' "$org" || {
	echo "scope.org has no pulled tickets: run build-tracker.sh and pull.sh 1 first" >&2
	exit 1
}

# The agent. A status change, shown through the keyword map.
zz status ZZ-0009 doing >/dev/null

# A new version of a named document, against the version it read.
base=$(zz doc get ZZ-0003 plan | "$jq" -r .version)
printf 'Second plan: order the sprockets from the forge.\nCutting by hand was too slow.\n' |
	zz doc set ZZ-0003 plan --base "$base" >/dev/null

zz comment ZZ-0001 "Counted the widgets again: still correct." >/dev/null

# A move under another parent, and a new ticket under that same parent.
zz parent ZZ-0006 ZZ-0003 >/dev/null
zz create "Measure the sprocket tolerance" --status todo --parent ZZ-0003 --tag sprockets >/dev/null

# The title the human is about to change too.
zz title ZZ-0008 "Change both repositories in one go" >/dev/null

# The human, in Org: same ticket, same field, another value.
sed -i 's/^\(\*\+ WAIT \)Change two repositories at once$/\1Split the two-repository change/' "$org"
grep -q '^\*\+ WAIT Split the two-repository change$' "$org" || {
	echo "the human edit found no heading to change" >&2
	exit 1
}

"$demo_dir/pull.sh" 2
