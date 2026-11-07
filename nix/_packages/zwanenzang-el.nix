# The Emacs client, for any Emacs package set (it needs Emacs 31).
# `zwanenzang` is the CLI whose store path becomes the default of
# `zwanenzang-program`.
{
  lib,
  trivialBuild,
  zwanenzang,
}:
trivialBuild {
  pname = "zwanenzang";
  inherit (zwanenzang) version;
  src = lib.fileset.toSource {
    root = ../../emacs;
    fileset = ../../emacs/zwanenzang.el;
  };
  postPatch = ''
    substituteInPlace zwanenzang.el --replace-fail \
      '(defcustom zwanenzang-program "zwanenzang"' \
      '(defcustom zwanenzang-program "${lib.getExe zwanenzang}"'
  '';
  turnCompilationWarningToError = true;
  passthru.cli = zwanenzang;
}
