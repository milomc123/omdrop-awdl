{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  python3,
  coreutils,
  findutils,
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
  python = python3.withPackages (
    ps: with ps; [
      libarchive-c
      pillow
      zeroconf
      ifaddr
      dbus-python
      pygobject3
    ]
  );
  runtimePath = lib.makeBinPath [
    bash
    python
    coreutils
    findutils
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
  nativeBuildInputs = [
    makeWrapper
    bash
    python
  ];
  dontBuild = true;
  passthru.python = python;

  installPhase = ''
    runHook preInstall
    libexec="$out/libexec/omdrop"
    mkdir -p "$libexec" "$out/bin" "$out/share/polkit-1/actions"
    cp *.py omdrop-broadcom.sh awdl-up omdrop-discoverable send-to-peer awdl-resolve "$libexec/"
    cp -r radio "$libexec/"
    chmod 755 "$libexec/awdl-up" "$libexec/omdrop-discoverable"
    patchShebangs "$libexec"
    substituteInPlace "$libexec/omdrop-discoverable" "$libexec/awdl-peer-watch.py" \
      --replace-fail /usr/lib/omdrop "$libexec"
    substituteInPlace "$libexec/radio/probe" \
      --replace-fail '@VERSION@' '${import ./version.nix}'

    # Keep the original script names: the discoverability supervisor compares
    # its exact argv against SELF, and Python helpers execute sibling .py files.
    # A fixed PATH also applies after pkexec sanitises the caller's environment.
    for script in awdl-up omdrop-discoverable radio/*; do
      substituteInPlace "$libexec/$script" --replace-fail \
        'set -uo pipefail' \
        'set -uo pipefail
    export PATH=${runtimePath}
    export OMDROP_MANAGE_NM_CONFIG=0'
    done
    for script in awdl-up omdrop-discoverable; do
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
