# The leader key: Super (niri's Mod) does things on its own, which niri binds
# can't (they run on presses, and Super is part of every one). Tapped alone,
# it opens the Control Center; held, the bar peeks out, then its shortcuts
# show (a Noctalia panel: ../../noctalia/plugins/shortcuts), until it's
# released. See ./leader.sh.
#
# A system service reads input events (with libinput, as a throwaway user
# in the `input` group), and passes on only Super's presses and releases,
# and whether something else was pressed with it (./leader-events.awk). Each
# session's user service connects to its socket, and acts on them.
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) desktop;
  cfg = desktop.leader;
  socket = "/run/smudgenix-leader.sock";
  shortcuts = import ./shortcuts.nix { inherit lib; } { inherit (desktop) binds; inherit (cfg) onBar; };

  leader = pkgs.writeShellApplication {
    name = "smudgenix-leader";
    runtimeInputs = [ pkgs.socat pkgs.jq config.programs.noctalia.package config.programs.niri.package ];
    text = ''
      socket=${socket}
      peek_after=${toString cfg.peekAfter}
      overlay_after=${toString cfg.overlayAfter}
      tap=${lib.escapeShellArg (if cfg.tap == null then "" else cfg.tap)}
      hinted=(${lib.escapeShellArgs cfg.hinted})
    '' + builtins.readFile ./leader.sh;
  };
in
{
  options.smudgenix.desktop.leader = {
    enable = lib.mkEnableOption "Super on its own: tapped, or held" // {
      default = desktop.noctalia.enable;
      defaultText = lib.literalExpression "config.smudgenix.desktop.noctalia.enable";
    };
    tap = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "control-center";
      example = "launcher";
      description = ''
        The Noctalia panel that tapping Super alone opens (or closes), or
        null for none.
      '';
    };
    peekAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Milliseconds Super is held alone before the bar peeks out (until
        it's released). Released sooner, it's a tap.
      '';
    };
    onBar = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = ''
        Panels the bar has a button for (from ./noctalia.nix), whose
        shortcuts show there, not on the sheet.
      '';
    };
    hinted = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = ''
        Noctalia plugin widgets (as `author/plugin:entry`) that show their
        shortcut with the rest of Super's, on a "hints" event.
      '';
    };
    overlayAfter = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2000;
      description = ''
        Milliseconds Super is held alone before its shortcuts show, until
        it's released (0 for never). (Super+Shift+/ shows niri's list of
        all of them, any time.)
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = desktop.noctalia.enable;
      message = "smudgenix: `desktop.leader` needs `desktop.noctalia.enable`.";
    }];

    # One reader per session that connects.
    systemd.sockets.smudgenix-leader = {
      description = "Super's presses, for the leader key";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = socket;
        Accept = true;
        MaxConnections = 8;
        SocketGroup = "users";
        SocketMode = "0660";
      };
    };

    systemd.services."smudgenix-leader@" = {
      description = "Super's presses, for the leader key";
      path = [ pkgs.libinput pkgs.gawk ];
      script = "libinput debug-events | awk -f ${./leader-events.awk}";
      serviceConfig = {
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        DynamicUser = true;
        SupplementaryGroups = [ "input" ];
        # Input devices (libinput opens them read-write), and udev's view of
        # them; nothing else.
        DevicePolicy = "closed";
        DeviceAllow = [ "char-input rw" ];
        # (Not PrivateNetwork: udev's news of new devices comes over netlink,
        # in the host's network namespace.)
        RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];
        IPAddressDeny = "any";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
      };
    };

    # The shortcuts sheet, for ../../noctalia/plugins/shortcuts.
    environment.etc."smudgenix/shortcuts.json".text =
      builtins.toJSON shortcuts.sheet;

    systemd.user.services.smudgenix-leader = {
      description = "Super on its own: tapped, or held";
      partOf = [ "niri.service" ];
      after = [ "niri.service" "noctalia.service" ];
      wantedBy = [ "niri.service" ];
      serviceConfig = {
        ExecStart = lib.getExe leader;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
