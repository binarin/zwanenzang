# For consumers such as swan-lake-common: the CLI as `pkgs.zwanenzang`,
# and the Emacs client as `epkgs.zwanenzang` in every Emacs package set,
# so it works with whichever (31+) Emacs the consumer builds.
{ self, ... }:
{
  flake.overlays.default = final: prev: {
    zwanenzang = final.callPackage ./_packages/zwanenzang.nix {
      rev = self.shortRev or null;
      lastModifiedDate = self.lastModifiedDate or null;
    };
    emacsPackagesFor =
      emacs:
      (prev.emacsPackagesFor emacs).overrideScope (
        efinal: _eprev: {
          zwanenzang = efinal.callPackage ./_packages/zwanenzang-el.nix {
            inherit (final) zwanenzang;
          };
        }
      );
  };
}
