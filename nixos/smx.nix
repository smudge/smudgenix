# smx, the smudgenix command (see ./smx.sh), for every user.
{ config, pkgs, ... }:

{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "smx";
      runtimeInputs = [
        config.nix.package
        config.system.build.nixos-rebuild
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.direnv
      ];
      text = ''
        system=${pkgs.stdenv.hostPlatform.system}
      '' + builtins.readFile ./smx.sh;
    })
  ];
}
