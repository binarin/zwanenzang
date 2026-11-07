{ ... }:
{
  perSystem =
    { pkgs, self', ... }:
    {
      packages.zwanenzang = pkgs.callPackage ./_packages/zwanenzang.nix { };
      packages.default = self'.packages.zwanenzang;

      checks.zwanenzang = self'.packages.zwanenzang;

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
