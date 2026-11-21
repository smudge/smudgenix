{ config, lib, ... }:

let
  cfg = config.smudgenix.autoUpdate;
  tz = config.time.timeZone;
in
{
  options.smudgenix.autoUpdate = {
    time = lib.mkOption {
      type = lib.types.strMatching "[0-9]{2}:[0-9]{2}";
      default = "04:00";
      description = "Time of day (HH:MM) to update, in `time.timeZone` if set.";
    };
    dates = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Sun 03:00";
      description = "Any systemd calendar spec to update at (overrides `time`).";
    };
  };

  config = {
    system.autoUpgrade = {
      enable = true;
      # Track the per-host flake, refreshing its lock to whatever is upstream.
      flake = "/etc/nixos";
      flags = [ "--recreate-lock-file" ];
      allowReboot = true;
      dates = lib.mkDefault (
        if cfg.dates != null then cfg.dates
        else "*-*-* ${cfg.time}:00" + lib.optionalString (tz != null) " ${tz}"
      );
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
}
