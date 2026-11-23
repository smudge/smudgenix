# AI agents, as part of the OS. OpenCode's server runs as each user's
# `opencode` service, which `opencode` starts (and uses) on demand (see
# ../ai/opencode.sh), with the session's environment minus the desktop's, so
# nothing agents run finds niri or the windows by accident. (It isn't a
# sandbox: the sockets are still there to find, as is the session bus.)
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

  theme = import ../theme pkgs;

  # `smx ai`.
  smx-ai = pkgs.writeShellApplication {
    name = "smx-ai";
    # (niri, tmux and xdg-terminal-exec: the desktop's own, from PATH.)
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.gitMinimal pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.gawk pkgs.procps pkgs.util-linux ];
    text = with theme.colors; ''
      opencode=${lib.getExe opencode}
      normalize=${../ai/normalize.jq}
      color_accent="${theme.accent}" color_dim="${base03}"
      color_red="${base08}" color_green="${base0B}" color_yellow="${base0A}"
    '' + builtins.readFile ../ai/smx-ai.sh;
  };

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
    notify = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the desktop tells you when an agent needs you or finishes
        (unless you're looking at it). Each user can change it in Noctalia's
        settings (Plugins → Agents).
      '';
    };
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
    environment.systemPackages = [ opencode smx-ai ];

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
