{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  python3,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  iproute2,
  iputils,
  iw,
  kmod,
  procps,
  util-linux,
  systemd,
  keyutils,
  openssl,
  networkmanager,
  avahi,
}:

let
  python = python3.withPackages (ps: with ps; [
    libarchive-c
    pillow
    zeroconf
    ifaddr
    dbus-python
    pygobject3
  ]);
  runtimePath = lib.makeBinPath [
    bash
    python
    coreutils
    gnugrep
    gnused
    gawk
    iproute2
    iputils
    iw
    kmod
    procps
    util-linux
    systemd
    keyutils
    openssl
    networkmanager
    avahi
  ];
in
stdenvNoCC.mkDerivation {
  pname = "omdrop-awdl-userspace";
  version = import ./version.nix;
  src = ../userspace;
  nativeBuildInputs = [ makeWrapper bash python ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    libexec="$out/libexec/omdrop"
    mkdir -p "$libexec" "$out/bin" "$out/share/polkit-1/actions"
    cp *.py awdl-up omdrop-discoverable send-to-peer awdl-resolve "$libexec/"
    chmod 755 "$libexec/awdl-up" "$libexec/omdrop-discoverable"
    patchShebangs "$libexec"

    # Keep the original script names: the discoverability supervisor compares
    # its exact argv against SELF, and Python helpers execute sibling .py files.
    # A fixed PATH also applies after pkexec sanitises the caller's environment.
    for script in awdl-up omdrop-discoverable; do
      substituteInPlace "$libexec/$script" --replace-fail \
        'set -uo pipefail' \
        'set -uo pipefail
    export PATH=${runtimePath}
    export OMDROP_MANAGE_NM_CONFIG=0'
      ln -s "$libexec/$script" "$out/bin/$script"
    done

    # pkexec must come from NixOS's setuid wrapper directory. It is only used
    # by unprivileged entry points, never by the privileged shell helpers.
    for script in send-to-peer awdl-resolve; do
      makeWrapper ${python}/bin/python3 "$out/bin/$script" \
        --add-flags "$libexec/$script" \
        --set PATH "${runtimePath}:/run/wrappers/bin"
    done
    makeWrapper ${python}/bin/python3 "$out/bin/airdrop-send" \
      --add-flags "$libexec/airdrop-send.py" \
      --set PATH "${runtimePath}:/run/wrappers/bin"

    substitute ${../packaging/org.omarchy.omdrop.policy} \
      "$out/share/polkit-1/actions/org.omarchy.omdrop.policy" \
      --replace-fail /usr/lib/omdrop/omdrop-discoverable "$libexec/omdrop-discoverable"
    runHook postInstall
  '';

  meta = {
    description = "AWDL radio management and AirDrop sending helpers";
    homepage = "https://github.com/brentkearney/omdrop-awdl";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
