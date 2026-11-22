{ pkgs, ... }:

let
  # Every terminal shares one tmux session ("main"), each in its own grouped
  # session so it can show its own window. A new terminal picks up a window
  # no other terminal is showing (e.g. one whose terminal was closed), or
  # opens a new one; `exit` closes a window for good.
  attach = pkgs.writeShellApplication {
    name = "tmux-attach";
    text = ''
      tmux has-session -t main 2>/dev/null || tmux new-session -d -s main
      shown=$(tmux list-clients -F '#{window_id}')
      free=$(tmux list-windows -t main -F '#{window_id}' | grep -vxF -e "$shown" | head -n1 || true)
      if [ -n "$free" ]; then
        exec tmux new-session -t main \; set-option destroy-unattached on \; select-window -t "$free"
      else
        exec tmux new-session -t main \; set-option destroy-unattached on \; new-window
      fi
    '';
  };
in
{
  home.packages = [ attach ];

  programs.bash.initExtra = ''
    if type tmux &>/dev/null && [ -z "$TMUX" ]; then
      if [ "$TERM" == "xterm-256color" ] || [ "$TERM" == "alacritty" ]; then
        exec tmux-attach
      fi
    fi
  '';

  programs.tmux = {
    enable = true;
    plugins = with pkgs.tmuxPlugins; [
      sensible
      vim-tmux-navigator
    ];
    extraConfig = ''
      set -g mouse on
      set -g status off
      set -ga terminal-overrides ',*256col*:Tc'
      set -g default-terminal "screen-256color"
      set -g set-clipboard on
      set-option -s escape-time 10
      set -ga update-environment " WAYLAND_DISPLAY WAYLAND_SOCKET XDG_RUNTIME_DIR"

      bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
      bind -n WheelDownPane select-pane -t= \; send-keys -M

      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R
      bind -n C-S-Left previous-window
      bind -n C-S-Right next-window
    '';
  };
}
