# Per-host NixOS flake.
#
# This file lives (uncommitted) at /etc/nixos/flake.nix alongside the
# generated hardware-configuration.nix, and holds everything specific to this
# machine. Apply with:
#
#   sudo nixos-rebuild switch
#
# Pull in upstream changes (regenerating flake.lock from scratch) with:
#
#   /etc/nixos/rebuild_flake.sh

{
  description = "Per-host NixOS config";

  inputs.nixos.url = "github:smudge/smudgenix";

  outputs = { self, nixos }: let
    hostname = "<YOUR HOSTNAME HERE>";
  in {
    nixosConfigurations.${hostname} = nixos.lib.mkSystem {
      modules = [
        ./hardware-configuration.nix
        # nixos.hardware.nixosModules.<YOUR NIXOS HARDWARE TYPE>
        ({ config, pkgs, ... }: {
          networking.hostName = hostname;
          time.timeZone = "UTC";
          # NixOS release of this host's first install. Never change it after
          # installing (`nixos-version` shows the current release):
          system.stateVersion = "26.11";

          smudgenix = {
            user = {
              name = "<YOUR USERNAME HERE>";
              description = "<YOUR HUMAN NAME HERE>";
              # Pre-fills the git identity in the generated home flake
              # (otherwise, fill it in there after first login):
              # git = { name = "<GIT NAME>"; email = "<GIT EMAIL>"; };
            };
            hiDPI = false;
            gaming = false;
            desktop = {
              gnome.enable = true;
              # niri (scrollable tiling) with the Noctalia shell, alongside or
              # instead of GNOME:
              niri.enable = false;
              # defaultSession = "niri";
              # keyRepeat = { delay = 200; rate = 40; };
              # binds."Mod+T" = ''spawn "alacritty"'';
              # noctalia.settings.bar.main.position = "bottom";
            };
            # Daily auto-update time, in `time.timeZone` (or any systemd
            # calendar spec via `autoUpdate.dates`):
            # autoUpdate.time = "04:00";
            # Reboot after updates that need it (default: notify instead):
            # autoUpdate.reboot = true;
          };

          # Host-specific overrides & additions go here.
        })
      ];
    };
    nixosConfigurations.default = self.nixosConfigurations.${hostname};
  };
}
