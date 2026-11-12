{ ... }:
{
  perSystem =
    { pkgs, self', ... }:
    {
      packages.zwanenzang = pkgs.callPackage ./_packages/zwanenzang.nix { };
      packages.default = self'.packages.zwanenzang;

      checks.zwanenzang = self'.packages.zwanenzang;
      checks.installed-command = pkgs.runCommand "zwanenzang-installed-command" { } ''
        bash ${../tests/installed-command.sh} ${self'.packages.zwanenzang} ${pkgs.git}/bin/git
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
