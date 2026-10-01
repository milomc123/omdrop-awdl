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
                env -i ${userspace}/libexec/omdrop/radio/probe --json > probe.json
                python3 -c 'import json; assert json.load(open("probe.json"))["version"] == "${import ./nix/version.nix}"'
                # A hook must load its sibling library under pkexec's empty PATH.
                # Missing arguments fail before root checks or radio operations.
                set +e
                env -i ${userspace}/libexec/omdrop/radio/read > hook.out 2>&1
                hook_status=$?
                set -e
                test "$hook_status" -eq 2
                grep -q 'usage:' hook.out
                ! grep -q 'cannot read' hook.out
                # Exercise root's directory-repair path as the build user,
                # under the exact PATH exported by the installed helper.
                # run_dir intentionally treats its caller as the owner.
                helper_path=$(sed -n 's/^export PATH=//p' ${userspace}/bin/omdrop-discoverable)
                env -i PATH="$helper_path" bash -c '
                  set -euo pipefail
                  . ${userspace}/libexec/omdrop/omdrop-broadcom.sh
                  RUN="$PWD/run-dir-test"
                  LOG="$RUN/log"
                  mkdir -m 777 "$RUN"
                  touch "$RUN/untrusted"
                  chmod 666 "$RUN/untrusted"
                  ln -s /nonexistent "$RUN/link"
                  need_run_dir
                  test ! -e "$RUN/untrusted"
                  test ! -L "$RUN/link"
                  test "$(stat -c %a "$RUN")" = 755
                '
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
                  pkgs.util-linux
                ];
              }
              ''
                cp -r ${./userspace} userspace
                cp -r ${./tests} tests
                cp -r ${./packaging} packaging
                cp ${./PKGBUILD} PKGBUILD
                cp ${./dkms.conf.in} dkms.conf.in
                cp ${./README.md} README.md
                chmod -R u+w userspace tests
                patchShebangs userspace
                # This test writes an executable shell fixture at runtime, after
                # patchShebangs has run. Nix builders do not provide /usr/bin/env.
                substituteInPlace tests/test_supervisor_lifecycle.py tests/test_radio_hooks.py \
                  --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
                substituteInPlace tests/test_radio_hooks.py \
                  --replace-fail '#!/usr/bin/env python3' '#!${userspace.python}/bin/python3'
                substituteInPlace tests/test_dkms_conf.py \
                  --replace-fail '#!/bin/bash' '#!${pkgs.bash}/bin/bash'
                substituteInPlace tests/test_core_coexistence.py \
                  --replace-fail '/usr/bin/sleep' '${pkgs.coreutils.override { singleBinary = false; }}/bin/sleep'
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
