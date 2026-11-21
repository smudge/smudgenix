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

  # Builds & activates the per-home flake in ~/.config/home-manager,
  # without depending on a (possibly version-mismatched) home-manager CLI.
  # Skips (with a desktop notification) while the flake still has unfilled
  # @placeholders@, e.g. a git identity the bootstrap could not fill in.
  activate = ''
    cd "$HOME/.config/home-manager"
    if grep -q '"@[A-Za-z]*@"' flake.nix; then
      notify-send --app-name=smudgenix "Finish setting up home-manager" \
        "Fill in the @placeholders@ in ~/.config/home-manager/flake.nix; it is applied on the next daily update." || true
      exit 0
    fi
    out=$(nix build --no-link --print-out-paths ".#homeConfigurations.\"$USER\".activationPackage")
    HOME_MANAGER_BACKUP_EXT=hm-bak "$out/activate"
  '';

  common = {
    path = [ config.nix.package pkgs.git pkgs.gnused pkgs.gnugrep pkgs.coreutils pkgs.libnotify ];
    unitConfig = {
      ConditionUser = cfg.name;
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
        description = "Git name to pre-fill in the generated home flake.";
      };
      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Git email to pre-fill in the generated home flake.";
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
        mkdir -p "$HOME/.config/home-manager"
        cd "$HOME/.config/home-manager"
        nix flake init -t '${cfg.homeTemplate}'
        # Fill in the placeholders, and follow the system's pinned nixpkgs (so
        # home and system share one nixpkgs, in lockstep).
        sed -i \
          -e "s|@username@|$USER|g" \
          -e 's|@system@|${system}|g' \
          -e 's|@stateVersion@|${config.system.nixos.release}|g'${fillGit} \
          -e 's|^\( *\)# \(system\.url = "path:/etc/nixos";\)|\1\2|' \
          -e 's|^\( *\)# \(smudgenix\.inputs\.nixpkgs\.follows = "system/nixos/nixpkgs";\)|\1\2|' \
          flake.nix
        ${activate}
      '';
    };

    # Keep userland current with whatever has been pushed upstream.
    systemd.user.services.home-manager-auto-update = lib.recursiveUpdate common {
      description = "Update & apply per-home home-manager flake";
      unitConfig.ConditionPathExists = "%h/.config/home-manager/flake.nix";
      script = ''
        set -euo pipefail
        cd "$HOME/.config/home-manager"
        nix flake update
        ${activate}
      '';
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
