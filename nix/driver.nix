{
  lib,
  stdenv,
  kernel,
}:

let
  driverDir = "drivers/net/wireless/broadcom/brcm80211";
in
stdenv.mkDerivation {
  pname = "brcmfmac-awdl";
  version = "${import ./version.nix}-${kernel.modDirVersion}";
  src = ../kernel;
  patches = import ./patches.nix { inherit lib; };

  nativeBuildInputs = kernel.moduleBuildDependencies;
  hardeningDisable = [ "pic" ];

  postPatch = ''
    printf 'obj-m += brcmfmac/\nobj-m += brcmutil/\n' > ${driverDir}/Makefile
  '';

  buildPhase = ''
    runHook preBuild
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      M="$PWD/${driverDir}" -j"$NIX_BUILD_CORES" \
      CONFIG_BRCMFMAC=m CONFIG_BRCMFMAC_PCIE=y CONFIG_BRCMFMAC_USB=y \
      CONFIG_BRCMUTIL=m CONFIG_BRCMFMAC_PROTO_MSGBUF=y \
      CONFIG_BRCMFMAC_PROTO_BCDC=y CONFIG_BRCMDBG=y \
      KCFLAGS='-DDEBUG -DCONFIG_BRCMDBG' modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd ${driverDir}
    # Keep every firmware-vendor companion built by brcmfmac's Makefile.
    # updates/ takes precedence over the stock modules without path collisions.
    while IFS= read -r -d "" module; do
      install -Dm644 "$module" \
        "$out/lib/modules/${kernel.modDirVersion}/updates/omdrop-awdl/''${module#./}"
    done < <(find brcmfmac brcmutil -name '*.ko' -print0)
    test -f "$out/lib/modules/${kernel.modDirVersion}/updates/omdrop-awdl/brcmfmac/brcmfmac.ko"
    test -f "$out/lib/modules/${kernel.modDirVersion}/updates/omdrop-awdl/brcmutil/brcmutil.ko"
    runHook postInstall
  '';

  enableParallelBuilding = true;
  meta = {
    description = "Firmware-native AWDL support for Apple's Broadcom Wi-Fi";
    homepage = "https://github.com/brentkearney/omdrop-awdl";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
}
