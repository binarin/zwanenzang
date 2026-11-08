#!/usr/bin/env bash
# Run demo/pull.el with this flake's client and nixpkgs-unstable's Emacs 31.
# Usage: demo/pull.sh N, which writes demo/pull-N-report.txt.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tracker=$(demo_disposable "$tracker")
emacs=$(demo_build --inputs-from "$repo" 'nixpkgs-unstable#emacs^out')/bin/emacs
client=$(demo_build "$repo#zwanenzang-el")/share/emacs/site-lisp

"$emacs" --batch -Q -L "$client" -l "$demo_dir/pull.el" "pull-$1-report.txt"
