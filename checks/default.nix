# Builds an example host and home from the templates' shape, so a broken push
# fails `nix flake check` instead of a machine's next daily update.
{ self, nixpkgs }:

let
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};

  host = self.lib.mkSystem {
    modules = [
      ({ ... }: {
        nixpkgs.hostPlatform = system;
        fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
        networking.hostName = "example";
        system.stateVersion = "26.11";
        smudgenix.user.name = "example";
      })
    ];
  };

  home = self.lib.mkHome {
    username = "example";
    inherit system;
    stateVersion = "26.11";
    modules = [{
      smudgenix.git = { name = "Example"; email = "example@example.com"; };
    }];
  };
in
{
  ${system} = {
    host = host.config.system.build.toplevel;
    home = home.activationPackage;
  };
}
