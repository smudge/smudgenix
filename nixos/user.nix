{ config, lib, options, ... }:

let
  cfg = config.smudgenix.user;
in
{
  options.smudgenix.user = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Login name of the primary user.";
    };
    description = lib.mkOption {
      type = lib.types.str;
      default = cfg.name;
      defaultText = lib.literalExpression "config.smudgenix.user.name";
      description = "Full name of the primary user.";
    };
  };

  config = {
    assertions = [{
      # NixOS only warns when this is unset; smudgenix requires it.
      assertion = options.system.stateVersion.highestPrio != (lib.mkOptionDefault { }).priority;
      message = ''
        smudgenix: set `system.stateVersion` in your host flake to the NixOS
        release this machine was first installed with (for a fresh install:
        "${config.system.nixos.release}").
      '';
    }];

    users.users.${cfg.name} = {
      isNormalUser = true;
      description = cfg.description;
      extraGroups = [ "networkmanager" "wheel" "lp" "input" "video" ];
    };
  };
}
