{
  lib,
  pkgs,
  module,
  userspace,
}:
let
  evaluate =
    settings:
    (lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        module
        {
          system.stateVersion = "26.05";
          networking.networkmanager.enable = true;
          services.avahi.enable = true;
          services.omdrop-awdl = {
            enable = true;
            driver.enable = false;
            package = userspace;
            settings = settings;
          };
        }
      ];
    }).config;
  enabled = evaluate { peer-chan = 44; };
  invalid = evaluate { "../escape" = "invalid"; };
  disabled =
    (lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        module
        { system.stateVersion = "26.05"; }
      ];
    }).config;
in
assert lib.elem "interface-name:awdl0" enabled.networking.networkmanager.unmanaged;
assert lib.elem "awdl0" enabled.services.avahi.denyInterfaces;
assert enabled.environment.etc."omdrop/peer-chan".text == "44\n";
assert
  enabled.systemd.services.awdl0.serviceConfig.ExecStart == "${userspace}/libexec/omdrop/awdl-up";
assert enabled.boot.extraModulePackages == [ ];
assert !(disabled.systemd.services ? awdl0);
assert builtins.any (
  a: !a.assertion && lib.hasInfix "configuration filenames" a.message
) invalid.assertions;
pkgs.runCommand "omdrop-awdl-module-check" { } ''
  touch "$out"
''
