{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.omdrop-awdl;
in
{
  options.services.omdrop-awdl = {
    enable = lib.mkEnableOption "firmware-native AWDL on Apple Broadcom Wi-Fi";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./userspace.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./userspace.nix { }";
      description = "AWDL userspace helpers and their polkit policy.";
    };

    driver = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install the replacement brcmfmac modules. Disable this when the
          selected kernel already includes this repository's AWDL patches.
        '';
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = config.boot.kernelPackages.callPackage ./driver.nix { };
        defaultText = lib.literalExpression "config.boot.kernelPackages.callPackage ./driver.nix { }";
        description = "AWDL driver built for the selected kernel.";
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.int);
      default = { };
      example = {
        infra-iface = "wlan0";
        peer-chan = 44;
      };
      description = ''
        One-line tunables written under /etc/omdrop. See the README's
        Configuration table. Identities and private keys do not belong here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.driver.enable || pkgs.stdenv.hostPlatform.system == "aarch64-linux";
        message = "omdrop-awdl's replacement driver supports aarch64-linux Apple Silicon systems.";
      }
      {
        assertion = builtins.all (name: builtins.match "[a-z][a-z0-9-]*" name != null) (
          builtins.attrNames cfg.settings
        );
        message = "services.omdrop-awdl.settings keys must be simple omdrop configuration filenames.";
      }
      {
        assertion = builtins.all (value: !lib.hasInfix "\n" (toString value)) (
          builtins.attrValues cfg.settings
        );
        message = "services.omdrop-awdl.settings values must be single lines.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
    environment.etc = lib.mapAttrs' (name: value: lib.nameValuePair "omdrop/${name}" {
      text = "${toString value}\n";
    }) cfg.settings;

    boot.extraModulePackages = lib.mkIf cfg.driver.enable [ cfg.driver.package ];
    boot.kernelModules = [ "brcmfmac" ];
    boot.extraModprobeConfig = ''
      options brcmfmac debug=0x1000
    '';

    security.polkit.enable = true;
    networking.networkmanager.unmanaged = lib.mkIf config.networking.networkmanager.enable [
      "interface-name:awdl0"
    ];
    # Avoid Avahi interpreting its own AWDL multicast echo as a name conflict.
    services.avahi.denyInterfaces = lib.mkIf config.services.avahi.enable [ "awdl0" ];

    systemd.services.awdl0 = {
      description = "Create and configure firmware-native awdl0";
      after = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/sys/module/brcmfmac";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/libexec/omdrop/awdl-up";
        TimeoutStartSec = 180;
        Restart = "no";
      };
    };
  };
}
