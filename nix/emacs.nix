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
    in
    {
      packages.zwanenzang-el = zwanenzang-el;

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
              --eval '(unless (file-name-absolute-p zwanenzang-program) (error "zwanenzang-program not substituted: %s" zwanenzang-program))' \
              -f ert-run-tests-batch-and-exit
            touch $out
          '';
    };
}
