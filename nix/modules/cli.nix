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
    # `use devshell ruby postgres ...` (what `smx env` writes), from your
    # devshells flake, if you have one.
    stdlib = ''
      _devshells=''${SMX_DEVSHELLS:-$HOME/.config/devshells}
      if [[ -f $_devshells/direnvrc ]]; then source "$_devshells/direnvrc"; fi
      unset _devshells
    '';
  };
  programs.git.ignores = [ ".direnv/" ];
}
