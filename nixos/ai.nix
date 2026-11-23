# AI agents, as part of the OS. OpenCode's server runs as each user's
# `opencode` service, which `opencode` starts (and uses) on demand (see
# ../ai/opencode.sh), with the session's environment, but without access to
# the desktop: agents can't drive niri, or read or type into windows.
{ config, lib, pkgs, ... }:

let
  cfg = config.smudgenix.ai;
  opencode = import ../ai/opencode.nix pkgs;
  unwrapped = lib.getExe opencode.unwrapped;
  stateFile = ''"''${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"'';

  # Over each user's own config. (A session's shell commands get its client's
  # environment, not the server's, so the plugin unsets the same there.)
  opencodeConfig = pkgs.writeText "opencode.json" (builtins.toJSON {
    plugins = [{
      package = "${../ai/opencode-plugin}";
      options = { inherit (cfg.server) unsetEnvironment; };
    }];
  });

  # (opencode won't share its port, and otherwise reports a clash only once
  # it's "started".)
  checkFree = pkgs.writeShellScript "opencode-check-free" ''
    if [ "$(${unwrapped} service status)" != stopped ]; then
      echo "another opencode server is running; stop it with \`opencode service stop\`" >&2
      exit 1
    fi
  '';

  # Started once it's what opencode finds, so `opencode` never starts its own.
  awaitReady = pkgs.writeShellScript "opencode-await-ready" ''
    for _ in $(${pkgs.coreutils}/bin/seq 150); do
      [ "$(${lib.getExe pkgs.jq} -r .pid ${stateFile} 2>/dev/null)" = "$MAINPID" ] && exit 0
      ${pkgs.coreutils}/bin/sleep 0.2
    done
    echo "opencode's server didn't come up" >&2
    exit 1
  '';
in
{
  options.smudgenix.ai = {
    enable = lib.mkEnableOption "AI agents (OpenCode), with a server per user" // { default = true; };
    server.unsetEnvironment = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "NIRI_SOCKET" "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY" ];
      example = [ "NIRI_SOCKET" "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY" "DBUS_SESSION_BUS_ADDRESS" "SSH_AUTH_SOCK" ];
      description = ''
        Environment variables OpenCode's server, and every agent's shell
        command (whatever its client's environment), run without. By default, the desktop's (niri, and Wayland and X11
        windows). The session bus (which reaches the unlocked keyring, and
        so `gh`'s and git's credentials) and the SSH agent stay.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ opencode ];

    systemd.user.services.opencode = {
      description = "OpenCode server, for agents";
      unitConfig.ConditionUser = "!@system";
      # The session's PATH (the user's tools, for agents), not a unit's.
      environment.PATH = lib.mkForce null;
      environment.OPENCODE_CONFIG = "${opencodeConfig}";
      serviceConfig = {
        Type = "exec";
        ExecStartPre = checkFree;
        ExecStart = "${unwrapped} serve --service";
        ExecStartPost = awaitReady;
        UnsetEnvironment = cfg.server.unsetEnvironment;
        # (Its exit on SIGTERM.)
        SuccessExitStatus = 143;
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStartSec = 45;
      };
    };
  };
}
