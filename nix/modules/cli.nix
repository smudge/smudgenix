{ pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    jq
    bat
    eza
    fzf
    fd
    gh
    ncdu
    ripgrep
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    wl-clipboard
  ];

  programs.autojump.enable = true;
  programs.autojump.enableBashIntegration = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
  programs.git.ignores = [ ".direnv/" ];
}
