# tmux-snap: snapshots of terminals' tmux sessions, so closed (or rebooted-
# away) terminals can be restored. Each snapshot keeps a session's windows,
# pane layout, directories & scrollback, and reopens editors/pagers.
#
#   tmux-snap closed <session>  a terminal closed (tmux's client-detached hook)
#   tmux-snap forget <key>      a session ended (tmux's session-closed hook)
#   tmux-snap save              snapshot every open session (run periodically)
#   tmux-snap reopen            reopen the most recently closed terminal
#
# A closed terminal whose panes are all idle (a shell prompt, or something
# safe to relaunch) is snapshotted and ended. One still running something is
# left running, with a notification, and is the first to be reopened.

# Snapshots include scrollback, so keep them private.
umask 077

state="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-snap"
open="$state/open"     # latest snapshot of each live session
closed="$state/closed" # closed terminals, newest first by name
keep=10                # closed snapshots to keep
lines=2000             # scrollback lines per pane
mkdir -p "$open" "$closed"

# Programs that are safe to end and relaunch; anything else is "busy".
relaunch='^(nvim|vim|vi|less|man|htop|btop|top)$'
shells='^-?(bash|zsh|fish|sh)$'

server_start() { tmux display-message -p '#{start_time}' 2>/dev/null || true; }

# The foreground command of a pane's shell, quoted for the shell, without
# arguments that pin it to a Nix store path (e.g. nixvim's --cmd flags).
pane_command() {
  local fg
  fg=$(ps -o tpgid= -p "$1" | tr -d ' ')
  [ -n "$fg" ] && [ "$fg" != "$1" ] && [ -r "/proc/$fg/cmdline" ] || return 0
  local -a argv out=()
  mapfile -d '' argv < "/proc/$fg/cmdline"
  out+=("$(basename "${argv[0]}")")
  local i=1
  while [ "$i" -lt "${#argv[@]}" ]; do
    case "${argv[$i]}" in
      --cmd | -u | -c | --clean)
        if [[ "${argv[$((i + 1))]:-}" == *"/nix/store/"* ]]; then
          i=$((i + 2))
          continue
        fi
        ;;
    esac
    out+=("${argv[$i]}")
    i=$((i + 1))
  done
  printf '%q ' "${out[@]}"
}

# snapshot <session> <dir>: write the session's snapshot to <dir>.
snapshot() {
  local session=$1 dir=$2 tmp w p active pid cmd path
  tmp=$(mktemp -d "$state/.tmp.XXXXXX")
  tmux list-windows -t "=$session:" -F '#{window_index}	#{window_active}	#{window_layout}' > "$tmp/windows"
  tmux list-panes -s -t "=$session:" \
    -F '#{window_index}	#{pane_index}	#{pane_active}	#{pane_pid}	#{pane_current_command}	#{pane_current_path}' |
    while IFS=$'\t' read -r w p active pid cmd path; do
      tmux capture-pane -p -e -J -S "-$lines" -t "=$session:$w.$p" |
        awk '{ buf[NR] = $0 } /[^[:space:]]/ { last = NR } END { for (i = 1; i <= last; i++) print buf[i] }' \
        > "$tmp/scroll-$w-$p"
      run=""
      if [[ "$cmd" =~ $relaunch ]]; then run=$(pane_command "$pid"); fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$w" "$p" "$active" "$path" "$run"
    done > "$tmp/panes"
  rm -rf "$dir"
  mv "$tmp" "$dir"
}

# Whether every pane of a session is idle (safe to end).
idle() {
  ! tmux list-panes -s -t "=$1:" -F '#{pane_current_command}' |
    grep -vqE -e "$shells" -e "$relaunch"
}

# Snapshots of sessions from an earlier tmux server (e.g. before a reboot)
# become closed snapshots, and only the newest $keep are kept.
tidy() {
  local start snap
  start=$(server_start)
  for snap in "$open"/*; do
    [ -d "$snap" ] || continue
    [ -n "$start" ] && [[ "$(basename "$snap")" == "$start"-* ]] && continue
    mv "$snap" "$closed/$(stat -c %Y "$snap")-$(basename "$snap")"
  done
  find "$closed" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((keep + 1)) | xargs -r rm -rf
}

# restore <dir>: rebuild a snapshot as a new (detached) session; print its name.
restore() {
  local snap=$1 session="" w wactive layout p active path run window pane show select_window="" select_pane=""
  while IFS=$'\t' read -r w wactive layout; do
    window=""
    while IFS=$'\t' read -r p active path run; do
      [ -d "$path" ] || path=$HOME
      show="cat $(printf '%q' "$snap/scroll-$w-$p") 2>/dev/null; printf '\\033[0m'; exec \"\${SHELL:-bash}\""
      if [ -z "$session" ]; then
        read -r session window pane < <(tmux new-session -d -P -F '#{session_name} #{window_id} #{pane_id}' -c "$path" "$show")
      elif [ -z "$window" ]; then
        read -r window pane < <(tmux new-window -d -P -F '#{window_id} #{pane_id}' -t "=$session:" -c "$path" "$show")
      else
        pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$window" -c "$path" "$show")
      fi
      if [ -n "$run" ]; then tmux send-keys -t "$pane" -l "$run" \; send-keys -t "$pane" Enter; fi
      if [ "$active" = 1 ]; then select_pane="$select_pane $pane"; fi
    done < <(awk -F '\t' -v w="$w" '$1 == w { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$snap/panes")
    tmux select-layout -t "$window" "$layout" 2>/dev/null || true
    if [ "$wactive" = 1 ]; then select_window=$window; fi
  done < "$snap/windows"
  for pane in $select_pane; do tmux select-pane -t "$pane"; done
  if [ -n "$select_window" ]; then tmux select-window -t "$select_window"; fi
  echo "$session"
}

case "${1:-}" in
  closed)
    session=$2
    [ "$(tmux display-message -p -t "=$session:" '#{session_attached}' 2>/dev/null)" = 0 ] || exit 0
    if idle "$session"; then
      snapshot "$session" "$closed/$(date +%s)-$(server_start)-$session"
      tmux kill-session -t "=$session:"
      tidy
    else
      tmux set-option -t "=$session:" @closed_at "$(date +%s)"
      busy=$(tmux list-panes -s -t "=$session:" -F '#{pane_current_command}' |
        grep -vE -e "$shells" -e "$relaunch" | sort -u | paste -sd, - | sed 's/,/, /g')
      if command -v notify-send >/dev/null; then
        notify-send -a Terminal "Still running: $busy" "Mod+Shift+Return reopens the terminal." || true
      fi
    fi
    ;;

  forget)
    rm -rf "${open:?}/$2"
    ;;

  save)
    start=$(server_start)
    if [ -n "$start" ]; then
      tmux list-sessions -F '#{session_name}' | while read -r session; do
        snapshot "$session" "$open/$start-$session"
      done
    fi
    tidy
    ;;

  reopen)
    tidy
    # The most recently closed: a terminal left running, or a snapshot.
    live=$(tmux list-sessions -F '#{session_attached}	#{@closed_at}	#{session_name}' 2>/dev/null |
      awk -F '\t' '$1 == 0 && $2 != "" { print $2 "\t" $3 }' | sort -rn | head -n1 || true)
    snap=$(find "$closed" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -n1)
    if [ -n "$live" ] && { [ -z "$snap" ] || [ "${live%%	*}" -ge "${snap%%-*}" ]; }; then
      tmux set-option -t "=${live#*	}:" -u @closed_at
      exec tmux attach-session -t "=${live#*	}:"
    elif [ -n "$snap" ]; then
      # Claim the snapshot (so it's restored once), then rebuild it.
      work=$(mktemp -d "${TMPDIR:-/tmp}/tmux-snap.XXXXXX")
      if mv "$closed/$snap" "$work/snap" 2>/dev/null; then
        exec tmux attach-session -t "=$(restore "$work/snap"):"
      fi
    fi
    exec tmux new-session
    ;;

  *)
    echo "usage: tmux-snap closed <session> | forget <key> | save | reopen" >&2
    exit 1
    ;;
esac
