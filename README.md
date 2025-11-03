# Example Usage:

`/etc/nixos/flake.nix` (with customizations and example nixos.hardware choice):

```nix
{
  description = "Bootstrap flake for NixOS";

  inputs.nixos.url = "path:/home/smudge/.config/nixos";

  outputs = { self, nixos }: {
    nixosConfigurations = let
      vars = {
        hostname = "<YOUR HOSTNAME HERE>";
        timezone = "UTC";
        hiDPI = true;
        user = {
          name = "<YOUR USERNAME HERE>";
          description = "<YOUR HUMAN NAME HERE>";
        };
      };
    in {
      ${vars.hostname} = nixos.outputs.nixosConfigurations.default {
        inherit vars;
        extraModules = [
          (import "/etc/nixos/hardware-configuration.nix")
          nixos.hardware.nixosModules.<YOUR NIXOS HARDWARE TYPE>
          ({ config, pkgs, ... }: {
            console.font = "${pkgs.terminus_font}/share/consolefonts/ter-u28n.psf.gz";

            services.xserver.videoDrivers = ["modesetting"];
            services.fwupd.enable = true;
            services.tlp = {
              settings = {
                #TLP_DEFAULT_MODE = "BAT";
                #TLP_PERSISTENT_DEFAULT = 1;
                CPU_BOOST_ON_AC = 0;
                CPU_BOOST_ON_BAT = 0;
                CPU_HWP_DYN_BOOST_ON_AC=0;
                CPU_HWP_DYN_BOOST_ON_BAT=0;
                CPU_ENERGY_PERF_POLICY_ON_AC="default";
                CPU_ENERGY_PERF_POLICY_ON_BAT="power";
                CPU_SCALING_GOVERNOR_ON_BATTERY = "powersave";
                RUNTIME_PM_ON_AC = "auto";
                RUNTIME_PM_ON_BAT = "auto";
              };
            };
          })
        ];
      };
      default = self.nixosConfigurations.${vars.hostname};
    };
  };
}
```

You may keep your previously generated `hardware-configuration.nix`.

To rebuild and switch, run:

```bash
sudo nix flake update --extra-experimental-features nix-command --extra-experimental-features flakes
sudo nixos-rebuild switch --impure
```
