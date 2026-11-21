{ config, lib, pkgs, ... }:

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
      # gitFull bundles the libsecret credential helper (and matches the system
      # git on smudgenix hosts).
      package = lib.mkDefault (if pkgs.stdenv.hostPlatform.isLinux then pkgs.gitFull else pkgs.git);
      settings = {
        user = { inherit (cfg) name email; };
      } // lib.mapAttrsRecursive (_: lib.mkDefault) {
        # Opinionated defaults (override any of them per-home).
        init.defaultBranch = "main";
        alias.lg = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
        push.autoSetupRemote = true;
        fetch.prune = true;
        pull.rebase = true;
        rebase.autoStash = true;
        merge.conflictStyle = "zdiff3";
        diff.colorMoved = "default";
        rerere.enabled = true;
      };

      # `nix build` output links, and (on macOS) Finder metadata.
      ignores = [ "/result" "/result-*" ]
        ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin ".DS_Store";
    };
  };
}
