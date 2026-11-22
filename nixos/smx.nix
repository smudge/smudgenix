# smx, the smudgenix command (see ./smx.sh), for every user.
{ config, pkgs, ... }:

let
  smx = pkgs.writeShellApplication {
    name = "smx";
    runtimeInputs = [
      config.nix.package
      config.system.build.nixos-rebuild
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.remarshal # TOML <-> JSON, for smudgenix.toml
      pkgs.fzf # browsing settings
      pkgs.util-linux # flock
      pkgs.direnv
    ];
    text = ''
      system=${pkgs.stdenv.hostPlatform.system}
      smx_eval=${./smx-eval.nix}
    '' + builtins.readFile ./smx.sh;
  };
in
{
  environment.systemPackages = [ smx ];
  system.build.smx = smx;
}
