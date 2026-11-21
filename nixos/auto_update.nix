{ config, lib, pkgs, ... }:

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
    reboot = lib.mkEnableOption ''
      rebooting automatically when an update needs it. Otherwise, the primary
      user gets a desktop notification that a reboot is pending
    '';
  };

  config = {
    system.autoUpgrade = {
      enable = true;
      flake = "/etc/nixos";
      allowReboot = cfg.reboot;
      dates = lib.mkDefault (
        if cfg.dates != null then cfg.dates
        else "*-*-* ${cfg.time}:00" + lib.optionalString (tz != null) " ${tz}"
      );
    };

    # Track the per-host flake, refreshing its lock to whatever is upstream.
    systemd.services.nixos-upgrade.preStart =
      "${config.nix.package}/bin/nix flake update --flake /etc/nixos";

    # Without auto-reboot, notify the primary user (once per system generation)
    # when the installed system needs a reboot: a new kernel, initrd or kernel
    # modules, the same check auto-reboot uses.
    systemd.user.services.smudgenix-reboot-check = lib.mkIf (!cfg.reboot) {
      description = "Notify when a reboot is needed to finish updating";
      unitConfig.ConditionUser = config.smudgenix.user.name;
      path = [ pkgs.coreutils pkgs.libnotify ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        parts() { readlink "$1"/{initrd,kernel,kernel-modules}; }
        [ "$(parts /run/booted-system)" != "$(parts /run/current-system)" ] || exit 0

        state="''${XDG_STATE_HOME:-$HOME/.local/state}/smudgenix/reboot-notified"
        current=$(readlink /run/current-system)
        [ "$(cat "$state" 2>/dev/null)" != "$current" ] || exit 0

        notify-send --app-name=smudgenix --icon=system-reboot \
          "Restart to finish updating" \
          "An installed system update takes effect after a reboot."
        mkdir -p "$(dirname "$state")"
        echo "$current" > "$state"
      '';
    };
    systemd.user.timers.smudgenix-reboot-check = lib.mkIf (!cfg.reboot) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnStartupSec = "2min";
        OnUnitActiveSec = "1h";
      };
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
}
