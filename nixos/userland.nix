{ vars ? {} }:
{ config, pkgs, lib, ... }: let
  v = {
    user = {
      # A home-manager flake providing `templates.default` and `lib.mkHome`.
      dotfiles = "github:smudge/dotfiles?dir=home-manager";
    } // (vars.user or {});
  } // (builtins.removeAttrs vars [ "user" ]);

  system = pkgs.stdenv.hostPlatform.system;

  # Builds & activates the per-host home flake in ~/.config/home-manager,
  # without depending on a (possibly version-mismatched) home-manager CLI.
  activate = ''
    cd "$HOME/.config/home-manager"
    out=$(nix build --no-link --print-out-paths ".#homeConfigurations.\"$USER\".activationPackage")
    HOME_MANAGER_BACKUP_EXT=hm-bak "$out/activate"
  '';

  common = {
    path = [ config.nix.package pkgs.git pkgs.gnused pkgs.coreutils ];
    unitConfig = {
      ConditionUser = v.user.name;
    };
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5min";
    };
  };
in {
  # On first login, generate an uncommitted per-host home flake from the
  # dotfiles template (never cloning or overwriting anything), then apply it.
  systemd.user.services.home-manager-bootstrap = lib.recursiveUpdate common {
    description = "Bootstrap per-host home-manager flake";
    wantedBy = [ "default.target" ];
    unitConfig.ConditionPathExists = "!%h/.config/home-manager/flake.nix";
    script = ''
      set -euo pipefail
      mkdir -p "$HOME/.config/home-manager"
      cd "$HOME/.config/home-manager"
      nix flake init -t '${v.user.dotfiles}'
      # Fill in the placeholders, and follow the system's pinned nixpkgs (so
      # home and system share one nixpkgs, in lockstep).
      sed -i \
        -e "s|@username@|$USER|g" \
        -e 's|@system@|${system}|g' \
        -e 's|^\( *\)# \(system\.url = "path:/etc/nixos";\)|\1\2|' \
        -e 's|^\( *\)# \(dotfiles\.inputs\.nixpkgs\.follows = "system/nixos/nixpkgs";\)|\1\2|' \
        flake.nix
      ${activate}
    '';
  };

  # Keep userland current with whatever has been pushed upstream.
  systemd.user.services.home-manager-auto-update = lib.recursiveUpdate common {
    description = "Update & apply per-host home-manager flake";
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
}
