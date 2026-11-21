{ vars ? {} }:
{ config, lib, ... }: let
  v = {
    # Time of day (HH:MM) to update, in the host's `timezone` if set.
    autoUpdateTime = "04:00";
    # Or any full systemd calendar spec (overrides autoUpdateTime).
    autoUpdateDates = null;
  } // vars;

  dates =
    if v.autoUpdateDates != null then v.autoUpdateDates
    else "*-*-* ${v.autoUpdateTime}:00" + lib.optionalString (v ? timezone) " ${v.timezone}";
in {
  system.autoUpgrade = {
    enable = true;
    # Track the per-host flake, refreshing its lock to whatever is upstream.
    flake = "/etc/nixos";
    flags = [ "--recreate-lock-file" ];
    allowReboot = true;
    dates = lib.mkDefault dates;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
