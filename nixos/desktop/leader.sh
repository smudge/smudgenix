# leader: what holding or tapping Super (niri's Mod key) does, in a niri
# session. (Packaged by ./leader.nix, which sets the settings above.) It
# reads "down", "up" and "other" (another key or click with Super) from
# ./leader-events.awk, on $socket:
#
#   - Tapped alone: opens $tap (a Noctalia panel).
#   - Held alone for $peek_after ms: the bar peeks out, until it's released.
#   - Still held at $overlay_after ms: its shortcuts (a Noctalia panel,
#     ../../noctalia/plugins/shortcuts), until it's released. (Not if a
#     panel's open already.)

sheet=smudgenix/shortcuts:keys

exec 3< <(socat -u "UNIX-CONNECT:$socket" STDOUT)

clock() { t=${EPOCHREALTIME/[.,]/}; now=$((t / 1000)); }

# Noctalia's state, as "<barVisible> <panelOpen> <locked>".
state() {
  noctalia msg status 2>/dev/null | jq -r '"\(.barVisible) \(.panelOpen) \(.locked)"' 2>/dev/null \
    || echo "true true true"
}

held="" other="" peeked="" shown="" hide=""

deadline() {
  if [ -z "$peeked" ]; then
    peeked=1
    read -r visible _ locked <<<"$(state)"
    if [ "$locked" = true ]; then
      other=1 # (Nothing more until it's released.)
    elif [ "$visible" != true ]; then
      hide=1
      noctalia msg bar-show >/dev/null
    fi
  else
    read -r _ panel _ <<<"$(state)"
    if [ "$panel" != true ]; then
      shown=1
      noctalia msg panel-open "$sheet" >/dev/null
    fi
    shown=${shown:-skipped}
  fi
}

released() {
  [ "$shown" != 1 ] || noctalia msg panel-close "$sheet" >/dev/null
  if [ -z "$other" ] && [ -z "$peeked" ]; then
    [ -n "$tap" ] || return 0
    read -r _ _ locked <<<"$(state)"
    [ "$locked" = true ] || noctalia msg panel-toggle "$tap" >/dev/null
  elif [ -n "$hide" ]; then
    # Back to hiding, unless a panel opened meanwhile (like Super+Space's
    # launcher): the bar hides itself when that closes. (And Noctalia keeps
    # it on an empty workspace.)
    read -r _ panel _ <<<"$(state)"
    [ "$panel" = true ] || noctalia msg bar-hide >/dev/null
  fi
}

while :; do
  wait_for=()
  if [ -n "$held" ] && [ -z "$other" ]; then
    next=""
    if [ -z "$peeked" ]; then
      next=$peek_after
    elif [ -z "$shown" ] && [ "$overlay_after" -gt 0 ]; then
      next=$overlay_after
    fi
    if [ -n "$next" ]; then
      clock
      left=$((start + next - now))
      [ "$left" -ge 1 ] || left=1
      wait_for=(-t "$((left / 1000)).$(printf '%03d' $((left % 1000)))")
    fi
  fi

  if read -r -u 3 "${wait_for[@]}" event; then
    case "$event" in
      down) clock; start=$now held=1 other="" peeked="" shown="" hide="" ;;
      other) other=1 ;;
      up) [ -z "$held" ] || released; held="" ;;
    esac
  elif [ $? -gt 128 ]; then
    deadline
  else
    echo "leader: lost $socket" >&2
    exit 1
  fi
done
