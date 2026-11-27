# The CLI, in callPackage form so the flake's packages and its overlay
# build it the same way. `rev` and `lastModifiedDate` are the flake's
# `self.shortRev` and `self.lastModifiedDate` (YYYYMMDDhhmmss, UTC), shown
# by `--version`; without a rev it says `(unknown)`. `passthru.versionLine`
# is the line `--version` should print, for the installed-command check.
{
  lib,
  rustPlatform,
  git,
  makeWrapper,
  rev ? null,
  lastModifiedDate ? null,
}:
let
  cargoToml = builtins.fromTOML (builtins.readFile ../../Cargo.toml);
  hasSource = rev != null && lastModifiedDate != null;
  date = lib.concatStringsSep "-" [
    (builtins.substring 0 4 lastModifiedDate)
    (builtins.substring 4 2 lastModifiedDate)
    (builtins.substring 6 2 lastModifiedDate)
  ];
in
rustPlatform.buildRustPackage {
  pname = "zwanenzang";
  inherit (cargoToml.package) version;
  src = lib.fileset.toSource {
    root = ../..;
    # scripts/check-version-bump.py lists the same paths: a change to any
    # of them needs a version bump.
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../build.rs
      # Bundled into the executable for `agent-hooks show-document`.
      ../../docs/agent-hooks
      # The page `render` writes, embedded with include_str!.
      ../../site
      ../../src
      ../../tests
    ];
  };
  cargoLock.lockFile = ../../Cargo.lock;
  env = lib.optionalAttrs hasSource {
    ZWANENZANG_REV = rev;
    ZWANENZANG_DATE = date;
  };
  passthru.versionLine = "zwanenzang ${cargoToml.package.version} (${
    if hasSource then "${rev} ${date}" else "unknown"
  })";
  # The test suite runs in checkPhase; `nix flake check` builds this.
  doCheck = true;
  # Every write commits and syncs through the git binary, and the
  # tests drive real repositories.
  nativeCheckInputs = [ git ];
  # The unit tests run the library's gits in this environment; give them
  # the configuration the integration tests pass explicitly, without
  # automatic maintenance (see the file).
  preCheck = ''
    export GIT_CONFIG_GLOBAL=$PWD/tests/fixtures/gitconfig
    test -f "$GIT_CONFIG_GLOBAL"
  '';
  nativeBuildInputs = [ makeWrapper ];
  # A git on the caller's PATH is used first; this one is the fallback.
  postInstall = ''
    wrapProgram $out/bin/zwanenzang --suffix PATH : ${lib.makeBinPath [ git ]}
    ln -s zwanenzang $out/bin/zz
  '';
  meta.mainProgram = "zwanenzang";
}
