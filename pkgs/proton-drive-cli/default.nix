{ lib
, stdenv
, fetchurl
, makeWrapper
, glib
, libsecret
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "proton-drive-cli";
  version = "0.8.0";

  src = fetchurl {
    url = "https://proton.me/download/drive/cli/${finalAttrs.version}/linux-x64/proton-drive";
    hash = "sha512-z2HCaIxF4QVdit1iIdlHGlpbZL87zbhkYPXLGEFFlsxN8822YnyQl8lL7DKjyZFa2jIR7yrlvjPEbrvJlsyqKA==";
  };

  dontUnpack = true;

  # This is a `bun build --compile` executable: bun appends the bundled app
  # as a trailer at the file's true EOF and detects it's a standalone app by
  # reading that trailer from the end of the file. Both autoPatchelfHook and
  # stdenv's default `strip` rewrite the ELF from its section table and
  # silently drop that trailer (since it isn't covered by any section) --
  # the binary then just behaves like plain upstream bun instead of
  # proton-drive. So leave the ELF itself completely untouched and rely on
  # nix-ld (programs.nix-ld.enable, already on system-wide) for the
  # interpreter/libc instead.
  dontPatchELF = true;
  noAutoPatchelf = true;
  dontStrip = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/proton-drive
    runHook postInstall
  '';

  # libsecret/glib aren't in the binary's NEEDED list -- it dlopen()s them at
  # runtime to store credentials in the system keyring, falling back to
  # ("libsecret not available") without them. wrapProgram only renames the
  # original binary and adds a shell shim, it doesn't touch its ELF bytes.
  postFixup = ''
    wrapProgram $out/bin/proton-drive \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ glib libsecret ]}
  '';

  meta = {
    description = "Command-line interface for Proton Drive";
    homepage = "https://proton.me/drive";
    changelog = "https://proton.me/download/drive/cli/index.html";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "proton-drive";
  };
})
