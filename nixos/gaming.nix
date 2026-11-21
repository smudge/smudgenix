{ vars ? {} }:
{ config, lib, ... }: let
  v = { gaming = false; } // vars;
in lib.mkIf v.gaming {
  # Steam (and controller support). Firewall openings for Remote Play or
  # dedicated servers are left to per-host config.
  programs.steam.enable = true;
  hardware.steam-hardware.enable = true;
}
