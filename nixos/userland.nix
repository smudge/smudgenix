{ config, pkgs, lib, ... }:

let
  cfg = config.smudgenix.user;

  system = pkgs.stdenv.hostPlatform.system;

  # sed expressions pre-filling the home template's git identity, if known.
  fillGit = lib.concatMapStrings (p: lib.optionalString (p.value != null)
    " -e ${lib.escapeShellArg "s|@${p.key}@|${p.value}|g"}") [
      { key = "gitName"; value = cfg.git.name; }
      { key = "gitEmail"; value = cfg.git.email; }
    ];

  # Use the gh login (if any) for GitHub API access.
  githubToken = ''
    if token=$(gh auth token 2>/dev/null); then
      export NIX_CONFIG="access-tokens = github.com=$token"
    fi
  '';

  # Runs `smx <command>` on the per-home flake in ~/.config/home-manager.
  # Skips (with a desktop notification) while the flake still has unfilled
  # @placeholders@, e.g. a git identity the bootstrap could not fill in.
  smx = command: ''
    cd "$HOME/.config/home-manager"
    if grep -q '"@[A-Za-z]*@"' flake.nix; then
      notify-send --app-name=smudgenix "Finish setting up home-manager" \
        "Fill in the @placeholders@ in ~/.config/home-manager/flake.nix; it is applied on the next update." || true
      exit 0
    fi
    ${config.system.build.smx}/bin/smx ${command}
  '';

  common = {
    path = [ config.nix.package pkgs.git pkgs.gnused pkgs.gnugrep pkgs.coreutils pkgs.libnotify pkgs.gh ];
    unitConfig = {
      # Every regular (non-system) user gets their own home.
      ConditionUser = "!@system";
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5min";
    };
  };
in
{
  options.smudgenix.user = {
    homeTemplate = lib.mkOption {
      type = lib.types.str;
      default = "github:smudge/smudgenix#home";
      description = "Flake template used to generate ~/.config/home-manager on first login.";
    };
    git = {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Git name to pre-fill in the primary user's generated home flake.";
      };
      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Git email to pre-fill in the primary user's generated home flake.";
      };
    };
  };

  config = {
    # On first login, generate an uncommitted per-home flake from the
    # smudgenix home template (never cloning or overwriting anything), then apply it.
    systemd.user.services.home-manager-bootstrap = lib.recursiveUpdate common {
      description = "Bootstrap per-home home-manager flake";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionPathExists = "!%h/.config/home-manager/flake.nix";
      script = ''
        set -euo pipefail
        ${githubToken}
        mkdir -p "$HOME/.config/home-manager"
        cd "$HOME/.config/home-manager"
        nix flake init -t '${cfg.homeTemplate}'
        # Fill in the placeholders, and follow the system's smudgenix (so home
        # and system share one smudgenix & nixpkgs, in lockstep).
        sed -i \
          -e "s|@username@|$USER|g" \
          -e 's|@system@|${system}|g' \
          -e 's|@stateVersion@|${config.system.nixos.release}|g' \
          -e '/^ *smudgenix\.url = /,/^ *# smudgenix\.follows = /c\
            # Follow the system smudgenix (and its nixpkgs), so home and\
            # system update in lockstep:\
            system.url = "path:/etc/nixos";\
            smudgenix.follows = "system/nixos";' \
          flake.nix
        ${lib.optionalString (fillGit != "") ''
          if [ "$USER" = ${lib.escapeShellArg cfg.name} ]; then
            sed -i${fillGit} flake.nix
          fi
        ''}
        ${smx "config apply"}
      '';
    };

    # Keep userland current with whatever has been pushed upstream.
    systemd.user.services.home-manager-auto-update = lib.recursiveUpdate common {
      description = "Update & apply per-home home-manager flake";
      # (Paused while you've reverted to an earlier generation.)
      unitConfig.ConditionPathExists = [
        "%h/.config/home-manager/flake.nix"
        "!%S/smudgenix/home-reverted"
      ];
      script = ''
        set -euo pipefail
        ${smx "update"}
      '';
    };
    # ...and catch up right after each system switch, since homes follow the
    # system's smudgenix. (Path units can't watch the /run/current-system
    # symlink being swapped, so activation also writes it to a plain file.)
    system.activationScripts.smudgenix-current-system = ''
      mkdir -p /run/smudgenix
      readlink -f "$systemConfig" > /run/smudgenix/current-system
    '';
    systemd.user.paths.home-manager-auto-update = {
      description = "Update per-home home-manager flake after a system switch";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = "!@system";
      pathConfig.PathChanged = "/run/smudgenix/current-system";
    };
    systemd.user.timers.home-manager-auto-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
