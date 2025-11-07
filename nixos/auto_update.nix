{ vars ? {} }:
{ config, ... }: let
  v = vars // {
  };
in {
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "8:00";
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
