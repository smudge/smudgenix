# smx, the smudgenix command (see ./smx.sh), for every user.
{ config, pkgs, ... }:

let
  smx = pkgs.writeShellApplication {
    name = "smx";
    runtimeInputs = [
      config.nix.package
      config.system.build.nixos-rebuild
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.util-linux # flock
      pkgs.direnv
    ];
    text = ''
      system=${pkgs.stdenv.hostPlatform.system}
    '' + builtins.readFile ./smx.sh;
  };
in
{
  environment.systemPackages = [ smx ];
  system.build.smx = smx;
}
