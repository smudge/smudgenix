# smx-ai-sandbox: the shell agents' commands run in. (smudgenix's OpenCode
# plugin makes it theirs; see ../nixos/ai.nix and ./opencode-plugin.) Run as
# `smx-ai-sandbox -c <command>`, it runs the command in the real shell
# ($SMX_AI_SHELL) inside bubblewrap, where:
#
# - everything is read-only but the project (the repository the command runs
#   in, and its main checkout's, for a worktree; else its directory), /tmp,
#   and $writable (caches, under your home);
# - $hidden (under your home: OpenCode's own files, so its password and
#   saved permissions; keyrings, private keys, browsers' profiles) isn't
#   there at all (of ~/.ssh, only public keys, known hosts and config are);
# - it has its own processes (so it can't see, or trace, the server's);
# - of $XDG_RUNTIME_DIR, it has the SSH agent's and GnuPG's sockets, and a
#   session bus that only reaches $bus_talk (by default, the keyring, which
#   git's and gh's credentials need: not `systemd-run --user`, notifications
#   or portals).
#
# (Expects $writable, $hidden and $bus_talk, arrays, set before this.)

if [ "${1:-}" != -c ] || [ "$#" -ne 2 ]; then echo "usage: smx-ai-sandbox -c <command>" >&2; exit 2; fi
command=$2
shell=${SMX_AI_SHELL:-bash}
unset SMX_AI_SHELL
# (Some clients give no HOME.)
if [ -z "${HOME:-}" ]; then HOME=$(getent passwd "$(id -u)" | cut -d: -f6); export HOME; fi
runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
cwd=$PWD

args=(
  --ro-bind / / --dev /dev --unshare-pid --proc /proc --unshare-ipc --unshare-uts
  --die-with-parent --bind /tmp /tmp
)

# The project.
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || top=$cwd
args+=(--bind "$top" "$top")
if common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  && [ "${common#"$top"/}" = "$common" ]; then
  args+=(--bind "$common" "$common")
fi

for path in "${writable[@]}"; do
  args+=(--bind-try "$HOME/$path" "$HOME/$path")
done

for path in "${hidden[@]}"; do
  path=$HOME/$path
  if [ -d "$path" ]; then
    args+=(--tmpfs "$path")
  elif [ -e "$path" ]; then
    args+=(--ro-bind /dev/null "$path")
  fi
done
if [ -d "$HOME/.ssh" ]; then
  args+=(--tmpfs "$HOME/.ssh")
  for path in "$HOME"/.ssh/*.pub "$HOME"/.ssh/known_hosts "$HOME"/.ssh/config; do
    [ -e "$path" ] && args+=(--ro-bind "$path" "$path")
  done
fi

args+=(--tmpfs "$runtime" --bind-try "$runtime/ssh-agent" "$runtime/ssh-agent" --bind-try "$runtime/gnupg" "$runtime/gnupg")

# The bus, through a proxy that ends when the sandbox does (when its end of
# the pipe closes), outside the sandbox's view.
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  proxy=$(mktemp -d "$runtime/smx-ai-bus.XXXXXX")
  trap 'rm -rf "$proxy"' EXIT
  mkfifo "$proxy/ready"
  filter=(--filter)
  for name in "${bus_talk[@]}"; do filter+=("--talk=$name"); done
  xdg-dbus-proxy --fd=3 "$DBUS_SESSION_BUS_ADDRESS" "$proxy/bus" "${filter[@]}" 3>"$proxy/ready" &
  exec 4<"$proxy/ready"
  read -r -N 1 _ <&4 || { echo "smx-ai-sandbox: the bus's proxy didn't start" >&2; exit 1; }
  args+=(--bind "$proxy/bus" "$runtime/bus" --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$runtime/bus")
fi

args+=(--chdir "$cwd")
bwrap "${args[@]}" -- "$shell" -c "$command"
