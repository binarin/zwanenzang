# The CLI, in callPackage form so the flake's packages and its overlay
# build it the same way.
{
  lib,
  rustPlatform,
  git,
  makeWrapper,
}:
let
  cargoToml = builtins.fromTOML (builtins.readFile ../../Cargo.toml);
in
rustPlatform.buildRustPackage {
  pname = "zwanenzang";
  inherit (cargoToml.package) version;
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../src
      ../../tests
    ];
  };
  cargoLock.lockFile = ../../Cargo.lock;
  # The test suite runs in checkPhase; `nix flake check` builds this.
  doCheck = true;
  # Every write commits and syncs through the git binary, and the
  # tests drive real repositories.
  nativeCheckInputs = [ git ];
  nativeBuildInputs = [ makeWrapper ];
  # A git on the caller's PATH is used first; this one is the fallback.
  postInstall = ''
    wrapProgram $out/bin/zwanenzang --suffix PATH : ${lib.makeBinPath [ git ]}
  '';
  meta.mainProgram = "zwanenzang";
}
