#!/usr/bin/env bash
# For the first commit: a fresh tracker holding the synthetic fixture, and demo/scope.org
# back in its state before any pull.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tracker=$(demo_disposable "$tracker")
rm -rf "$tracker"
mkdir -p "$tracker"

zz init --prefix ZZ --name "Demo tracker" >/dev/null

# Every alias the fixture's branches and merge requests use.
cat >>"$tracker/zwanenzang.toml" <<'TOML'

[repos.app]
url = "https://forge.example/owner/app"

[repos.docs-site]
url = "https://forge.example/owner/docs-site"
TOML

# No remote, so the import's sync numbers its tickets at once, in file order.
(cd "$repo" && zz import ai-workflow tests/fixtures/ai-workflow) |
	"$jq" -r '.imported[] | "imported \(.source) as \(.status): \(.title)"'

# The importer writes descriptions only. Sprockets (ZZ-0003) gets two named
# documents, so the first pull shows a document subheading and a hidden-document
# link, and the agent has a version to replace in step-2.sh.
printf 'First plan: cut the sprockets by hand.\n' |
	zz doc set ZZ-0003 plan --base none >/dev/null
printf 'Hidden status summary, not for Org.\n' |
	zz doc set ZZ-0003 status --base none >/dev/null

# The scope binds to this tracker's id on first pull, so a new tracker needs
# the Org file as it was.
cat >"$demo_dir/scope.org" <<ORG
#+TITLE: What zwanenzang-pull does to an Org file
#+TODO: TODO NEXT WAIT REVIEW | DONE CNCL

* Notes of my own
Above the scope. The tracker never sees this heading.

* Work
** Tracked projects
Still above the scope; only grouping for me.
*** Widgets and sprockets
:PROPERTIES:
:ZWANENZANG: $tracker
:ZWANENZANG_KEYWORDS: TODO=todo,draft NEXT=doing WAIT=blocked REVIEW=review DONE=done CNCL=cancelled
:ZWANENZANG_HIDE_DOCS: status
:END:
The scope root. Everything beneath it syncs with the tracker.
**** Things to look at some day
A heading with no keyword or id inside the scope: my own structure.

* Notes after the scope
Pull must not touch this either.
ORG
