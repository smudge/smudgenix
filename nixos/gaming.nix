{ config, lib, ... }:

{
  options.smudgenix.gaming = lib.mkEnableOption "Steam (and controller support)";

  # Firewall openings for Remote Play or dedicated servers are left to
  # per-host config.
  config = lib.mkIf config.smudgenix.gaming {
    programs.steam.enable = true;
    hardware.steam-hardware.enable = true;
  };
}
