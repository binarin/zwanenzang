# The Emacs client and its ERT suite. Built with nixpkgs-unstable's Emacs,
# because the client needs Emacs 31 and stable nixpkgs has 30; the CLI it
# calls is the one from stable nixpkgs.
{ ... }:
{
  perSystem =
    {
      pkgs,
      inputs',
      self',
      ...
    }:
    let
      emacs = inputs'.nixpkgs-unstable.legacyPackages.emacs;
      epkgs = inputs'.nixpkgs-unstable.legacyPackages.emacsPackagesFor emacs;
      zwanenzang-el = epkgs.callPackage ./_packages/zwanenzang-el.nix {
        inherit (self'.packages) zwanenzang;
      };
      tests = pkgs.lib.fileset.toSource {
        root = ../emacs/test;
        fileset = ../emacs/test;
      };

      # The ERT suite against a checkout's sources, for iterating before
      # `nix flake check`. It runs this flake's Emacs, not the one on PATH, with
      # a throwaway HOME: a personal Emacs wrapper can point the config
      # directory at a real one, and `-Q` would let a test write state there
      # (the queue test loads Tramp, which saves its cache at exit).
      emacs-test = pkgs.writeShellApplication {
        name = "zwanenzang-emacs-test";
        runtimeInputs = [
          (epkgs.withPackages (p: [ p.org-ql ]))
          pkgs.git
          self'.packages.zwanenzang
        ];
        text = ''
          if [[ $# -gt 1 || ! -f emacs/zwanenzang.el ]]; then
            echo "usage: run from the repository root: zwanenzang-emacs-test [ERT-SELECTOR-REGEXP]" >&2
            exit 2
          fi
          home=$(mktemp -d)
          trap 'rm -rf "$home"' EXIT
          export HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
            XDG_STATE_HOME="$home/.local/state" XDG_CACHE_HOME="$home/.cache"
          export ZWANENZANG_ERT_SELECTOR="''${1:-}"
          # Require rather than load: test files require each other, and
          # loading one again after that redefines its tests.
          loads=()
          for f in emacs/test/*-test.el; do
            loads+=(--eval "(require '$(basename "$f" .el))")
          done
          emacs -Q --batch -L emacs -L emacs/test "''${loads[@]}" \
            --eval '(let ((selector (getenv "ZWANENZANG_ERT_SELECTOR")))
                      (ert-run-tests-batch-and-exit (if (string-empty-p selector) t selector)))'
        '';
      };
    in
    {
      packages.zwanenzang-el = zwanenzang-el;
      apps.emacs-test = {
        type = "app";
        program = pkgs.lib.getExe emacs-test;
        meta.description = "Run the Emacs client's ERT suite against this checkout";
      };

      # Both ERT layers against the installed package, so the integration
      # tests run the CLI through the substituted `zwanenzang-program`.
      checks.zwanenzang-el =
        pkgs.runCommand "zwanenzang-el-ert"
          {
            nativeBuildInputs = [
              (epkgs.withPackages (_: [ zwanenzang-el ]))
              pkgs.git
            ];
          }
          ''
            cp -r ${tests} test
            chmod -R u+w test
            cd test
            emacs --batch -L . \
              --eval '(setq byte-compile-error-on-warn t)' \
              -f batch-byte-compile *.el
            emacs --batch -L . -l ert \
              -l zwanenzang-test -l zwanenzang-integration-test \
              -l zwanenzang-pull-test -l zwanenzang-pull-integration-test \
              -l zwanenzang-push-test -l zwanenzang-push-integration-test \
              -l zwanenzang-dependency-test -l zwanenzang-queue-test \
              -l zwanenzang-comment-test -l zwanenzang-document-test \
              -l zwanenzang-branches-test \
              --eval '(unless (file-name-absolute-p zwanenzang-program) (error "zwanenzang-program not substituted: %s" zwanenzang-program))' \
              -f ert-run-tests-batch-and-exit
            touch $out
          '';
    };
}
