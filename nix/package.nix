{ ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      cargoToml = builtins.fromTOML (builtins.readFile ../Cargo.toml);
      src = pkgs.lib.fileset.toSource {
        root = ../.;
        fileset = pkgs.lib.fileset.unions [
          ../Cargo.toml
          ../Cargo.lock
          ../src
          ../tests
        ];
      };
    in
    {
      packages.zwanenzang = pkgs.rustPlatform.buildRustPackage {
        pname = "zwanenzang";
        inherit (cargoToml.package) version;
        inherit src;
        cargoLock.lockFile = ../Cargo.lock;
        # The test suite runs in checkPhase; `nix flake check` builds this.
        doCheck = true;
        # Every write commits and syncs through the git binary, and the
        # tests drive real repositories.
        nativeCheckInputs = [ pkgs.git ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        # A git on the caller's PATH is used first; this one is the fallback.
        postInstall = ''
          wrapProgram $out/bin/zwanenzang --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.git ]}
        '';
        meta.mainProgram = "zwanenzang";
      };
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
