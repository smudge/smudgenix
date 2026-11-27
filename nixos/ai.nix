# AI agents, as part of the OS. OpenCode's server runs as each user's
# `opencode` service, from login (and `opencode` starts it if it's stopped,
# and uses it: see ../ai/opencode.sh), with the session's environment minus the desktop's, out of
# reach of its sockets and of what runs at login; and each of agents' shell
# commands runs in a sandbox (../ai/sandbox.sh), away from the server's own
# files and processes, the rest of the bus, and all but the project.
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
      options = {
        inherit (cfg.server) unsetEnvironment;
        sandbox = if cfg.sandbox.enable then lib.getExe smx-ai-sandbox else null;
        smxAi = lib.getExe smx-ai;
      };
    }];
  });

  # The shell agents' commands run in (see ../ai/sandbox.sh).
  smx-ai-sandbox = pkgs.writeShellApplication {
    name = "smx-ai-sandbox";
    runtimeInputs = [ pkgs.bubblewrap pkgs.xdg-dbus-proxy pkgs.coreutils pkgs.getent pkgs.gitMinimal ];
    text = ''
      writable=(${lib.escapeShellArgs cfg.sandbox.writable})
      hidden=(${lib.escapeShellArgs cfg.sandbox.hidden})
      bus_talk=(${lib.escapeShellArgs cfg.sandbox.busTalk})
    '' + builtins.readFile ../ai/sandbox.sh;
  };

  theme = import ../theme pkgs;

  # `smx ai`.
  smx-ai = pkgs.writeShellApplication {
    name = "smx-ai";
    # (niri, tmux and xdg-terminal-exec: the desktop's own, from PATH.)
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.gitMinimal pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.gawk pkgs.procps pkgs.util-linux ];
    text = with theme.colors; ''
      opencode=${lib.getExe opencode}
      normalize=${../ai/normalize.jq}
      decisions_filter=${../ai/decisions.jq}
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
    server.runtimeDir = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "bus" "ssh-agent" "gnupg" ];
      example = [ "bus" ];
      description = ''
        What of `$XDG_RUNTIME_DIR` OpenCode's server, and so agents' commands,
        can reach (where it exists): by default the session bus, the SSH agent
        and GnuPG's sockets. The rest (niri's and Wayland's sockets, the user
        manager's, audio, …) is out of reach: unsetting variables only hides
        them, as they're easily guessed.
      '';
    };
    sandbox = {
      enable = lib.mkEnableOption "a sandbox for each of agents' shell commands (see ../ai/sandbox.sh)" // { default = true; };
      writable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ".cache" ".cargo" ".rustup" ".npm" ".local/share/pnpm" "go" ".opencode/plan" ];
        description = ''
          What in your home (besides the project) agents' commands can
          change: by default, tools' caches, and OpenCode's plans (where its
          plan mode writes them).
        '';
      };
      hidden = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          ".local/share/opencode" ".local/state/opencode" ".local/share/keyrings"
          ".gnupg/private-keys-v1.d" ".password-store" ".mozilla" ".config/chromium" ".config/google-chrome"
        ];
        description = ''
          What in your home agents' commands can't see at all: by default,
          OpenCode's own files (its password, and saved permissions), keyrings
          and private keys, and browsers' profiles. (Of ~/.ssh, they only
          ever see public keys, known hosts and config.)
        '';
      };
      busTalk = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "org.freedesktop.secrets" ];
        description = ''
          What on the session bus agents' commands can reach: by default the
          keyring, which git's and gh's credentials need (and which has every
          other secret too). Not `systemd-run --user`, notifications or
          portals.
        '';
      };
    };
    server.readOnly = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ".config/systemd" ".config/autostart" ".config/environment.d" ];
      description = ''
        What in your home OpenCode's server, and so agents' commands, can't
        change: by default what runs things at login (user units, autostart,
        the session's environment). Created first if missing.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ opencode smx-ai ];

    systemd.user.services.opencode = {
      description = "OpenCode server, for agents";
      unitConfig.ConditionUser = "!@system";
      # Running from login (the graphical session's, once niri's passed its
      # environment on, so agents' tools are on PATH), not only when something
      # needs it: the bar follows it, and work in the background goes on.
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      # The session's PATH (the user's tools, for agents), not a unit's.
      environment.PATH = lib.mkForce null;
      environment.OPENCODE_CONFIG = "${opencodeConfig}";
      serviceConfig = {
        Type = "exec";
        ExecStartPre = [ checkFree "${pkgs.coreutils}/bin/mkdir -p ${lib.concatMapStringsSep " " (p: "%h/${p}") cfg.server.readOnly}" ];
        ExecStart = "${unwrapped} serve --service";
        ExecStartPost = awaitReady;
        UnsetEnvironment = cfg.server.unsetEnvironment;
        # (See server.runtimeDir and server.readOnly. Only these paths: the
        # bus still reaches `systemd-run --user`, outside them, and agents'
        # commands share the server's files.)
        TemporaryFileSystem = "%t";
        BindPaths = map (p: "-%t/${p}") cfg.server.runtimeDir;
        InaccessiblePaths = [ "-/tmp/.X11-unix" ];
        ReadOnlyPaths = map (p: "-%h/${p}") cfg.server.readOnly;
        NoNewPrivileges = true;
        # (Its exit on SIGTERM.)
        SuccessExitStatus = 143;
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStartSec = 45;
      };
    };
  };
}
