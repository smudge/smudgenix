# Each terminal gets its own tmux session. Closing a terminal snapshots and
# ends its session (or leaves it running, if busy), and `tmux-snap reopen`
# (Mod+Shift+Return in niri) brings back the most recently closed one, even
# after a reboot. See ./tmux-snap.sh.
{ config, pkgs, lib, ... }:

let
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  snap = pkgs.writeShellApplication {
    name = "tmux-snap";
    runtimeInputs = with pkgs; [ config.programs.tmux.package coreutils findutils gawk gnugrep gnused ]
      ++ lib.optionals isLinux [ procps libnotify ];
    text = builtins.readFile ./tmux-snap.sh;
  };
  snapExe = lib.getExe snap;
in
{
  home.packages = [ snap ];

  programs.bash.initExtra = ''
    if type tmux &>/dev/null && [ -z "$TMUX" ]; then
      if [ "$TERM" == "xterm-256color" ] || [ "$TERM" == "alacritty" ]; then
        exec tmux new-session
      fi
    fi
  '';

  # Snapshot open terminals every few minutes, to restore them after a reboot.
  systemd.user = lib.mkIf isLinux {
    services.tmux-snap = {
      Unit.Description = "Snapshot open tmux sessions";
      Service = { Type = "oneshot"; ExecStart = "${snapExe} save"; };
    };
    timers.tmux-snap = {
      Unit.Description = "Snapshot open tmux sessions periodically";
      Timer = { OnStartupSec = "5min"; OnUnitActiveSec = "5min"; };
      Install.WantedBy = [ "timers.target" ];
    };
  };

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

      # Snapshot (and end) a session when its terminal closes; forget a
      # session's snapshot when it ends normally. (The server stays up when
      # its last session ends, so that hook gets to run.)
      set -s exit-empty off
      set-hook -g client-detached 'run-shell -b "${snapExe} closed #{q:hook_session_name}"'
      set-hook -g session-closed 'run-shell -b "${snapExe} forget #{q:start_time}-#{q:hook_session_name}"'

      bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
      bind -n WheelDownPane select-pane -t= \; send-keys -M

      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R
      bind -n C-S-Left previous-window
      bind -n C-S-Right next-window

      # Split side-by-side (Alt+d) or stacked (Alt+Shift+d), in the same dir.
      bind -n M-d split-window -h -c "#{pane_current_path}"
      bind -n M-D split-window -v -c "#{pane_current_path}"

      # New window (Alt+t), in the same dir.
      bind -n M-t new-window -c "#{pane_current_path}"

      # Close the pane (Alt+w); closing a window's last pane closes it too.
      bind -n M-w kill-pane

      # Ctrl+hjkl focuses panes (and nvim splits, via vim-tmux-navigator);
      # Alt+arrows does the same.
      bind -n M-Left select-pane -L
      bind -n M-Down select-pane -D
      bind -n M-Up select-pane -U
      bind -n M-Right select-pane -R

      # Alt+Shift+arrows (and Ctrl+Shift+hjkl, which alacritty translates)
      # moves the pane, stopping at the window's edge.
      bind -n M-S-Left if -F "#{pane_at_left}" "" 'swap-pane -d -t "{left-of}"'
      bind -n M-S-Down if -F "#{pane_at_bottom}" "" 'swap-pane -d -t "{down-of}"'
      bind -n M-S-Up if -F "#{pane_at_top}" "" 'swap-pane -d -t "{up-of}"'
      bind -n M-S-Right if -F "#{pane_at_right}" "" 'swap-pane -d -t "{right-of}"'
    '';
  };
}
