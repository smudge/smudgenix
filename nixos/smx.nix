# smx, the smudgenix command (see ./smx.sh), for every user.
{ config, pkgs, ... }:

let
  theme = import ../theme pkgs;

  smx = pkgs.writeShellApplication {
    name = "smx";
    runtimeInputs = [
      config.nix.package
      config.system.build.nixos-rebuild
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.nix-output-monitor # build progress, in a terminal
      pkgs.remarshal # TOML <-> JSON, for smudgenix.toml
      pkgs.fzf # browsing settings
      pkgs.util-linux # flock
      pkgs.direnv
    ];
    text = with theme.colors; ''
      system=${pkgs.stdenv.hostPlatform.system}
      smx_eval=${./smx-eval.nix}
      allow_unfree=${if config.nixpkgs.config.allowUnfree or false then "1" else ""}
      color_accent="${theme.accent}" color_dim="${base03}" color_raised="${base02}" color_bright="${base07}"
      color_red="${base08}" color_green="${base0B}" color_yellow="${base0A}"
    '' + builtins.readFile ./smx.sh;
  };
in
{
  environment.systemPackages = [ smx ];
  system.build.smx = smx;
}
