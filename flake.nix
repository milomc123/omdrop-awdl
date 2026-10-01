{
  description = "Firmware-native AWDL for Apple Silicon Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Used only for standalone driver builds and checks. The NixOS module
    # always builds against the consuming system's boot.kernelPackages.
    nixos-apple-silicon = {
      url = "github:nix-community/nixos-apple-silicon";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-apple-silicon,
      ...
    }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.default = import ./nix/module.nix;

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          userspace = pkgs.callPackage ./nix/userspace.nix { };
        in
        {
          inherit userspace;
          default = userspace;
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          # This output has an explicit Asahi test kernel, not nixpkgs' generic
          # ARM kernel, whose headers need not match Apple's driver extensions.
          driver = pkgs.callPackage ./nix/driver.nix {
            kernel = nixos-apple-silicon.packages.${system}.linux-asahi;
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.packages.${system}) userspace;
        in
        {
          patch-series = pkgs.stdenvNoCC.mkDerivation {
            pname = "omdrop-awdl-patch-check";
            version = import ./nix/version.nix;
            src = ./kernel;
            patches = import ./nix/patches.nix { lib = nixpkgs.lib; };
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              grep -q 'module_param_named(awdl_trace' \
                drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c
              mkdir -p "$out"
              cp PROVENANCE.md "$out/"
            '';
          };
          nixos-module = import ./nix/check-module.nix {
            inherit pkgs userspace;
            lib = nixpkgs.lib;
            module = self.nixosModules.default;
          };
          userspace =
            pkgs.runCommand "omdrop-awdl-userspace-check"
              {
                nativeBuildInputs = [
                  userspace.python
                  pkgs.bash
                  pkgs.openssl
                ];
              }
              ''
                # Exercise the installed tools after clearing the caller's PATH,
                # as pkexec does, and ensure optional BLE imports are available.
                grep -qx 'pkgver=${import ./nix/version.nix}' ${./PKGBUILD}
                env -i ${userspace}/bin/send-to-peer --help >/dev/null
                env -i ${userspace}/bin/airdrop-send --help >/dev/null
                env -i ${userspace}/libexec/omdrop/brcm_iovar.py --help >/dev/null
                env -i ${userspace}/libexec/omdrop/ble-airdrop-adv.py --help >/dev/null
                env -i ${userspace}/bin/omdrop-discoverable status --json > status.json
                python3 -c 'import json; assert json.load(open("status.json"))["visible"] is False'
                grep -F '${userspace}/libexec/omdrop/omdrop-discoverable' \
                  ${userspace}/share/polkit-1/actions/org.omarchy.omdrop.policy
                python3 -c 'import libarchive, PIL, zeroconf, ifaddr, dbus; from gi.repository import GLib'
                touch "$out"
              '';
          unit-tests =
            pkgs.runCommand "omdrop-awdl-unit-tests"
              {
                nativeBuildInputs = [
                  userspace.python
                  pkgs.bash
                  pkgs.openssl
                ];
              }
              ''
                cp -r ${./userspace} userspace
                cp -r ${./tests} tests
                chmod -R u+w userspace tests
                patchShebangs userspace
                # This test writes an executable shell fixture at runtime, after
                # patchShebangs has run. Nix builders do not provide /usr/bin/env.
                substituteInPlace tests/test_supervisor_lifecycle.py \
                  --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
                python3 -m unittest discover -s tests -q
                touch "$out"
              '';
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          driver =
            let
              kernel = nixos-apple-silicon.packages.${system}.linux-asahi;
              modules = pkgs.aggregateModules [
                kernel.modules
                self.packages.${system}.driver
              ];
            in
            pkgs.runCommand "omdrop-awdl-driver-check"
              {
                nativeBuildInputs = [ pkgs.kmod ];
              }
              ''
                # Check depmod's actual selection in the combined system tree.
                for module in brcmfmac brcmutil brcmfmac-wcc brcmfmac-cyw brcmfmac-bca; do
                  modinfo -b ${modules} -k ${kernel.modDirVersion} -n "$module" \
                    | grep '/updates/omdrop-awdl/'
                done
                modinfo -b ${modules} -k ${kernel.modDirVersion} -p brcmfmac \
                  | grep '^awdl_trace:'
                modprobe -d ${modules} -S ${kernel.modDirVersion} --show-depends brcmfmac \
                  > dependencies
                grep '/updates/omdrop-awdl/' dependencies
                touch "$out"
              '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
