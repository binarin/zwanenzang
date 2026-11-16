{ ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      self',
      ...
    }:
    {
      packages.zwanenzang = pkgs.callPackage ./_packages/zwanenzang.nix { };
      packages.default = self'.packages.zwanenzang;

      checks.zwanenzang = self'.packages.zwanenzang;
      checks.installed-command = pkgs.runCommand "zwanenzang-installed-command" { } ''
        bash ${../tests/installed-command.sh} ${self'.packages.zwanenzang} ${pkgs.git}/bin/git
        touch $out
      '';
      # The one-off identity migration, against disposable trackers.
      checks.assign-identities =
        pkgs.runCommand "zwanenzang-assign-identities"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.git
            ];
          }
          ''
            python3 -I ${../scripts}/test_assign_identities.py ${lib.getExe self'.packages.zwanenzang}
            touch $out
          '';

      devShells.default = pkgs.mkShell {
        inputsFrom = [ self'.packages.zwanenzang ];
        packages = with pkgs; [
          cargo
          rustc
          rustfmt
          clippy
          rust-analyzer
        ];
      };
    };
}
