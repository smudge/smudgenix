{ config, lib, ... }:

let
  cfg = config.smudgenix.git;
  isPlaceholder = v: builtins.match "@.*@" v != null;
in
{
  options.smudgenix.git = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Name to author git commits with.";
    };
    email = lib.mkOption {
      type = lib.types.str;
      description = "Email to author git commits with.";
    };
  };

  config = {
    assertions = [{
      assertion = !(isPlaceholder cfg.name || isPlaceholder cfg.email);
      message = ''
        smudgenix: fill in `smudgenix.git.name` and `smudgenix.git.email` in
        ~/.config/home-manager/flake.nix.
      '';
    }];

    programs.git = {
      enable = true;
      settings = {
        user = { inherit (cfg) name email; };
        init.defaultBranch = "main";
      };
    };
  };
}
