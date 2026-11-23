# opencode, using the server of the `opencode` user service (see
# ../nixos/ai.nix), where there is one: otherwise, opencode starts its own,
# with this terminal's environment (and so with its access to the desktop),
# for every agent it runs. Elsewhere, it's just opencode.
#
#   opencode service start|stop|restart   the service (and any other server)

unit=opencode.service

ctl() { command systemctl --user "$@"; }

if ! command -v systemctl >/dev/null || ! ctl cat "$unit" &>/dev/null; then
  exec "$opencode" "$@"
fi

# Explicitly a server of its own.
for arg in "$@"; do
  case "$arg" in --standalone | --server | --server=*) exec "$opencode" "$@" ;; esac
done

start() {
  ctl start "$unit" 2>/dev/null && return
  if [ "$("$opencode" service status 2>/dev/null)" != stopped ]; then
    echo "opencode: another server is running, outside $unit (with this desktop's access); replace it with \`opencode service restart\`" >&2
  else
    echo "opencode: $unit didn't start; see \`journalctl --user -u $unit\`" >&2
  fi
  return 1
}

stop() {
  ctl stop "$unit"
  # (And any other server.)
  "$opencode" service stop >/dev/null
}

case "${1:-}" in
  serve) exec "$opencode" "$@" ;;
  service)
    case "${2:-}" in
      start) start; exit ;;
      stop) stop; exit ;;
      restart) stop; start; exit ;;
      *) exec "$opencode" "$@" ;;
    esac
    ;;
esac

start || true
exec "$opencode" "$@"
