{ vars ? {} }:
{ config, ... }: let
  v = vars // {
  };
in {
  system.autoUpgrade = {
    enable = true;
    # Track the per-host flake, refreshing its lock to whatever is upstream.
    flake = "/etc/nixos";
    flags = [ "--recreate-lock-file" ];
    allowReboot = true;
    dates = "8:00";
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
