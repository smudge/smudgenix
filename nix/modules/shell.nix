{ lib, ... }:

{
  # (EDITOR and the vi/vim aliases come from nixvim.)
  home.sessionVariables.BROWSER = lib.mkDefault "firefox";

  programs.bash = {
    enable = true;
    enableCompletion = true;
    shellAliases = {
      ls = "eza";
      cat = "bat --paging=never --style=plain";
      du = "ncdu --color dark -rr -x --exclude .git --exclude node_modules";
    };
    initExtra = ''
      if type tmux &>/dev/null; then
        if [ "$TERM" == "xterm-256color" ] || [ "$TERM" == "alacritty" ]; then
          [ -z "$TMUX"  ] && { exec tmux new-session && exit; }
        fi
      fi
    '';
  };
}
