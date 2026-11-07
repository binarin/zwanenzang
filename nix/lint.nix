{ ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      package = self'.packages.zwanenzang;
    in
    {
      # Formatting needs no dependencies, only the sources the package builds.
      checks.fmt =
        pkgs.runCommand "zwanenzang-fmt"
          {
            nativeBuildInputs = [
              pkgs.cargo
              pkgs.rustfmt
            ];
          }
          ''
            cd ${package.src}
            cargo fmt --check
            touch $out
          '';

      # Reuse the package derivation for its vendored dependencies, but run
      # Clippy instead of building and testing.
      checks.clippy = package.overrideAttrs (old: {
        pname = "${old.pname}-clippy";
        nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
        buildPhase = ''
          runHook preBuild
          cargo clippy --offline --all-targets -- -D warnings
          runHook postBuild
        '';
        doCheck = false;
        dontCargoInstall = true;
        installPhase = ''
          touch $out
        '';
        postInstall = "";
        dontFixup = true;
      });
    };
}
