# smx ai: agents, as part of the desktop. (Packaged by ../nixos/ai.nix,
# which sets $opencode and the colors; `smx ai …` runs it.)
#
# Exit codes: 0 ok, 1 error, 3 the server is unreachable, 4 not found.

unit=opencode.service
state_file="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"
probe_dir="${XDG_STATE_HOME:-$HOME/.local/state}/smudgenix/ai-probe"

fancy=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then fancy=1; fi
rgb() { printf '\033[38;2;%d;%d;%dm' "0x${1:1:2}" "0x${1:3:2}" "0x${1:5:2}"; }
A="" D="" R="" G="" Y="" N=""
if [ -n "$fancy" ]; then
  A=$(rgb "$color_accent") D=$(rgb "$color_dim") R=$(rgb "$color_red")
  G=$(rgb "$color_green") Y=$(rgb "$color_yellow") N=$'\033[0m'
fi

say() { echo "${D}smx ai:${N} $*" >&2; }
die() { echo "${R}smx ai:${N} $1" >&2; exit "${2:-1}"; }

ctl() { systemctl --user "$@"; }
api() { "$opencode" api "$@"; }

usage() {
  cat <<EOF
Usage: smx ai <command>

Agents (OpenCode), as part of the desktop.

  status [--json]         What agents are doing now, or have open (--json:
                          and recent sessions too)
  open <session>          Show a session: its TUI's window, or a new one
  allow <request> [--always]
                          Allow what an agent asked to do (--always: and
                          the like, in its project, from now on)
  deny <request>          Don't
  allowed [--json]        What's allowed from now on
  allowed revoke <id>     Ask again for it
  watch                   What agents are doing: a snapshot, then each
                          change, as JSON lines
  watch --raw             The server's own events, as JSON lines
  watch --replay <file>   Recorded server events, as \`watch\` would show them
  doctor                  Check that agents run as they should: on the
                          $unit server, without the desktop
  help                    Show this help
EOF
}

# --- The server ---------------------------------------------------------------

# Its URL and password, from where opencode finds them.
server_url() { jq -r '.url // empty' "$state_file" 2>/dev/null; }

# curl, as the server's client (its password kept off the command line).
server_curl() {
  local password
  password=$(jq -r '.password // empty' "$state_file" 2>/dev/null) || return 3
  curl -K <(printf 'user = "opencode:%s"\n' "$password") "$@"
}

server_get() { server_curl -sf --max-time 10 "$(server_url)$1"; }

# Its event stream, as JSON lines, from now until it ends (at once, if it's
# down): of these types, or all of them.
server_events() {
  local url query=""
  url=$(server_url)
  [ -n "$url" ] || return 3
  if [ "$#" -gt 0 ]; then query="?$(printf 'types=%s&' "$@")"; query=${query%&}; fi
  server_curl -sfN -H 'Accept: text/event-stream' "$url/api/event$query" | sed -un 's/^data: //p'
}

# --- watch --------------------------------------------------------------------

# watch --raw: the server's events, as it sends them, for good (reconnecting
# when it restarts). For recording fixtures.
watch_raw() {
  while true; do
    server_events || true
    sleep 1
  done
}


# A session from the server, as smx ai's normalizer takes it (./normalize.jq).
# shellcheck disable=SC2016
shape='def shape:
  (.time.busy // 0) as $busy | (.time.idle // 0) as $idle
  | ($busy > $idle) as $running
  | {id, title, dir: .location.directory, parent: .parentID, updated: .time.updated, running: $running,
     outcome: ({succeeded: "done", failed: "failed"}[.outcome // ""] // "idle"),
     unseen: ((($running | not) and $idle > (.time.viewed // 0)) and .outcome != "interrupted")};'

# Sessions (JSON lines in and out), filled in: their project (the name of
# their folder's repository, its main checkout's, or else of the folder), their
# latest reply and compaction, and what the running ones wait on.
filled() {
  local session id dir running project reply compaction requests
  local -A projects=()
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    IFS=$'\t' read -r id dir running < <(jq -r '[.id, (.dir // ""), .running] | @tsv' <<<"$session")
    if [ -z "${projects[$dir]+x}" ]; then
      project=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && project=${project%/.git} || project=$dir
      if [ "$project" = "$HOME" ]; then projects[$dir]="~"; else projects[$dir]=$(basename "$project"); fi
    fi
    reply=$(server_get "/api/session/$id/message?limit=10&order=desc&type=assistant" \
      | jq -c 'first(.data[].content[]? | select(.type == "text" and (.text // "") != "") | .text) // null' 2>/dev/null) || reply=null
    compaction=$(server_get "/api/session/$id/message?limit=3&order=desc&type=compaction" \
      | jq -c 'first(.data[] | select(.status == "completed") | .summary) // null' 2>/dev/null) || compaction=null
    session=$(jq -c --arg p "${projects[$dir]}" --argjson r "${reply:-null}" --argjson c "${compaction:-null}" \
      '. + {project: (if $p == "" or $p == "." then null else $p end), last: $r, about: $c}' <<<"$session")
    if [ "$running" = true ]; then
      requests=$(server_get "/api/session/$id/permission" | jq -c '.data[]' | with_cwd "$dir" | jq -cs .) || requests='[]'
      jq -c --argjson p "$requests" \
        --argjson f "$(server_get "/api/session/$id/form" || echo '{"data":[]}')" \
        '. + {permissions: [$p[] | {id, action, resources, save: (.save // []), cwd}],
              forms: [$f.data[] | {id, title}]}' <<<"$session"
    else
      echo "$session"
    fi
  done
}

# The server's state now, as an smx.snapshot: its recent sessions, any older
# ones running or finished since anyone looked at them, and those ones'
# subagents' (of the recent ones).
snapshot() {
  local sessions
  sessions=$(server_get "/api/session?limit=50" | jq -c "$shape"' [.data[] | shape] as $all
    | ([$all[] | select(.parent == null)] | sort_by(-(.updated // 0)) | to_entries
       | map(select(.key < 15 or .value.running or .value.unseen) | .value)) as $roots
    | [$roots, [$all[] | select(.parent != null)]]
    | until(([.[0][].id] | unique) as $kept | [.[1][] | select(.parent as $p | $kept | index($p))] | length == 0;
        ([.[0][].id]) as $kept
        | [.[0] + [.[1][] | select(.parent as $p | $kept | index($p))],
           [.[1][] | select(.parent as $p | $kept | index($p) | not)]])
    | .[0][]') || return 1
  filled <<<"$sessions" | jq -cs '{type: "smx.snapshot", sessions: .}'
}

# One session, as an smx.session (for one the snapshot didn't have).
session_event() {
  server_get "/api/session/$1" | jq -c "$shape"' .data | shape' | filled \
    | jq -c '{type: "smx.session", session: .}'
}

# The server's events that watch uses.
watched=(
  session.created session.renamed session.deleted session.archived session.viewed
  session.text.ended session.compaction.ended
  session.execution.started session.execution.succeeded session.execution.failed
  session.execution.interrupted permission.asked permission.replied
  form.created form.replied form.cancelled
)

# The server's events, from a snapshot on, until it goes away. (Connected
# first, so nothing between the snapshot and the stream is missed; and each
# session's first event, if the snapshot didn't have it, after the session.)
connected_events() {
  server_events "${watched[@]}" | {
    read -r _ || return 1
    snap=$(snapshot) || return 1
    echo "$snap"
    known=" $(jq -r '.sessions[].id' <<<"$snap" | tr '\n' ' ') "
    while IFS= read -r line; do
      IFS=$'\t' read -r type id < <(jq -r '[.type, (.data.sessionID // .data.form.sessionID // "-")] | @tsv' <<<"$line")
      # (Where a request would run, from the call itself.)
      if [ "$type" = permission.asked ]; then
        asked=$(jq -c .data <<<"$line" | with_cwd "$(jq -r '.location.directory // ""' <<<"$line")" \
          | jq -c --argjson e "$line" '$e + {data: .}') && [ -n "$asked" ] && line=$asked
      fi
      if [ "$id" != - ] && [[ $known != *" $id "* ]]; then
        known+="$id "
        case "$type" in
          session.deleted | session.archived) ;;
          *) session_event "$id" || true ;;
        esac
      fi
      printf '%s\n' "$line"
    done
  }
}

server_state() {
  if ctl is-active --quiet "$unit" || ctl is-failed --quiet "$unit"; then echo down; else echo stopped; fi
}

# opencode's TUIs open now, as an smx.tuis: for each, its session (if it was
# started with -s), its tmux pane's title (which the TUI sets to "OC | <its
# session's title>", maybe cut short with "…"), and the processes it's
# shown through, itself up (so its terminal's among them), if you can see it:
# not in a tmux window that isn't the current one, or a tmux session with no
# client.
tuis() {
  local procs panes clients pid argv i id
  procs=$(ps -u "$(id -u)" -o pid=,ppid=)
  panes=$(tmux list-panes -a -F '#{pane_pid}	#{session_name}	#{window_active}	#{pane_title}' 2>/dev/null || true)
  clients=$(tmux list-clients -F '#{client_pid}	#{session_name}' 2>/dev/null || true)
  for pid in $(pgrep -u "$(id -u)" opencode || true); do
    mapfile -d '' argv < "/proc/$pid/cmdline" 2>/dev/null || continue
    case "$(basename "${argv[0]:-}")" in opencode | .opencode-wrapped) ;; *) continue ;; esac
    id=""
    for ((i = 1; i < ${#argv[@]}; i++)); do
      case "${argv[i]}" in
        serve | run | attach | acp | mcp | auth | api | service | models | export | import | stats | upgrade) continue 2 ;;
        -s | --session) id=${argv[i + 1]:-} ;;
        --session=*) id=${argv[i]#--session=} ;;
      esac
    done
    printf '%s\t%s\n' "$pid" "$id"
  done | jq -Rcn --arg procs "$procs" --arg panes "$panes" --arg clients "$clients" '
    ($procs | split("\n") | map(select(. != "") | [splits(" +") | select(. != "") | tonumber])
      | map({key: (.[0] | tostring), value: .[1]}) | from_entries) as $parent
    | def up: [recurse(($parent[tostring] // 1) | select(. > 1))];
    ($panes | split("\n") | map(select(. != "") | split("\t")
      | {key: .[0], value: {session: .[1], active: (.[2] == "1"), title: .[3]}}) | from_entries) as $pane
    | ($clients | split("\n") | map(select(. != "") | split("\t") | {pid: (.[0] | tonumber), session: .[1]})) as $client
    | {type: "smx.tuis", tuis: [inputs | split("\t") | (.[0] | tonumber) as $pid | ($pid | up) as $up
        | (first($up[] | $pane[tostring] // empty) // null) as $p
        | {id: (if .[1] == "" then null else .[1] end),
           title: ($p.title // null | if . and startswith("OC | ") then .[5:] else null end),
           seen: (if $p == null then $pid | up
                  elif $p.active then [$client[] | select(.session == $p.session) | .pid | up[]]
                  else [] end)}]}'
}

# watch's TUIs, while it runs: whenever they change (and at first).
tui_changes() {
  local now last=""
  local watcher=$$
  while [ -e "/proc/$watcher" ]; do
    now=$(tuis)
    [ "$now" = "$last" ] || { echo "$now"; last=$now; }
    sleep 2
  done
}

# watch: what agents are doing (see ./normalize.jq), for good: a snapshot, then
# each change; and while the server's away, that it is (then, once it's back,
# a snapshot). It retries every few seconds, which costs nothing.
watch_normalized() {
  local delay=1 last="" state
  {
    tui_changes &
    while true; do
      if connected_events; then delay=1; last=up; fi
      state=$(server_state)
      if [ "$state" != "$last" ]; then
        jq -cn --arg s "$state" '{type: "smx.server", state: $s}'
        last=$state
      fi
      sleep "$delay"
      delay=$((delay < 5 ? delay * 2 : 5))
    done
  } | jq -cn --unbuffered -f "$normalize"
}

watch_command() {
  case "${1:-}" in
    "") watch_normalized ;;
    --raw) watch_raw ;;
    --replay)
      [ -f "${2:-}" ] || die "usage: smx ai watch --replay <events.jsonl>"
      jq -cn -f "$normalize" < "$2"
      ;;
    *) die "usage: smx ai watch [--raw | --replay <events.jsonl>]" ;;
  esac
}

# --- status -------------------------------------------------------------------

# The first line of `watch`: a snapshot, or (if the server's away) that.
current() {
  local snap
  if [ -n "$(server_url)" ] && snap=$(snapshot) && [ -n "$snap" ]; then
    { tuis; echo "$snap"; } | jq -cn -f "$normalize"
  else
    jq -cn --arg s "$(server_state)" '{v: 1, type: "server", state: $s}'
  fi
}

status() {
  local now
  now=$(current)
  if [ "${1:-}" = --json ]; then
    echo "$now"
  elif [ "$(jq -r .type <<<"$now")" = server ]; then
    if [ "$(jq -r .state <<<"$now")" = stopped ]; then
      echo "${D}No agents: OpenCode's server isn't running (opencode starts it).${N}"
    else
      say "OpenCode's server isn't reachable; see \`smx ai doctor\`"
    fi
  elif [ "$(jq '[.sessions[] | select(.parent == null and (.open or .unseen or (.state | test("^(working|needs-)"))))] | length' <<<"$now")" = 0 ]; then
    echo "${D}No agents at work.${N}"
  else
    jq -r --arg home "$HOME" '.sessions[] | select(.parent == null and (.open or .unseen or (.state | test("^(working|needs-)"))))
      | [.state, ([if .unseen then "new" else empty end, if .open then "open" else empty end] | join(", ") | if . == "" then "-" else . end), .id, (.title // "(untitled)"),
         ((.dir // "") | if startswith($home) then "~" + .[($home | length):] else . end)] | @tsv' <<<"$now" \
      | while IFS=$'\t' read -r state flags id title dir; do
          case "$state" in
            working) mark="${A}●${N}" ;;
            needs-*) mark="${Y}▲${N}" ;;
            done) mark="${G}✓${N}" ;;
            failed) mark="${R}✗${N}" ;;
            *) mark="${D}-${N}" ;;
          esac
          printf '%s %-22s %s  %s\n' "$mark" "$state$([ "$flags" = - ] || echo ", $flags")" "$title" "${D}$dir  $id${N}"
          # (What it asks: smx ai allow|deny <request>.)
          jq -c --arg id "$id" '.sessions[] | select(.id == $id) | .permissions[]' <<<"$now" \
            | while IFS= read -r request; do
                printf '    %s  %s\n' "$(described <<<"$request")" "${D}$(jq -r .id <<<"$request")${N}"
              done
        done
  fi
  [ "$(jq -r '.state // "up"' <<<"$now")" != down ] || exit 3
}

# --- open ---------------------------------------------------------------------

# A process's ancestors, from itself up.
ancestors() {
  local p=$1
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    echo "$p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
}

# opencode TUIs on a session (started with -s/--session <id>).
tuis_on() {
  local pid argv i
  for pid in $(pgrep -u "$(id -u)" -f -- "$1" || true); do
    mapfile -d '' argv < "/proc/$pid/cmdline" 2>/dev/null || continue
    case "$(basename "${argv[0]:-}")" in opencode | .opencode-wrapped) ;; *) continue ;; esac
    for ((i = 1; i < ${#argv[@]}; i++)); do
      case "${argv[i]}" in
        -s | --session) [ "${argv[i + 1]:-}" = "$1" ] && echo "$pid" ;;
        --session="$1") echo "$pid" ;;
      esac
    done
  done
}

# The tmux pane (session:window.pane) a process runs in, if any.
pane_of() {
  local panes p
  panes=$(tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || return 1
  for p in $(ancestors "$1"); do
    awk -v p="$p" '$1 == p { print $2; found = 1; exit } END { exit !found }' <<<"$panes" && return
  done
  return 1
}

# The niri window showing a tmux session (its client's terminal), if any.
window_of_tmux_session() {
  local windows client p
  windows=$(niri msg --json windows 2>/dev/null) || return 1
  for client in $(tmux list-clients -t "$1" -F '#{client_pid}' 2>/dev/null); do
    for p in $(ancestors "$client"); do
      jq -e --argjson p "$p" 'map(select(.pid == $p)) | first | .id' <<<"$windows" && return
    done
  done
  return 1
}

# tmux panes showing a session's TUI by title (one started without -s): "OC |
# <its title>", maybe cut short with "…".
panes_titled() {
  local pane title
  [ -n "$1" ] || return 0
  tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{pane_title}' 2>/dev/null \
    | while IFS=$'\t' read -r pane title; do
        case "$title" in "OC | "*) title=${title#OC | } ;; *) continue ;; esac
        if [ "${title%…}" != "$title" ]; then
          [[ $1 == "${title%…}"* ]] && echo "$pane"
        elif [ "$1" = "$title" ]; then
          echo "$pane"
        fi
      done
}

# Shows a tmux pane, in its client's window, if it has one.
focus_pane() {
  local window
  window=$(window_of_tmux_session "${1%%:*}") || return 1
  tmux select-window -t "${1%.*}" && tmux select-pane -t "$1"
  niri msg action focus-window --id "$window"
}

open_session() {
  local id=${1:-} session dir pid pane panes
  [ -n "$id" ] || die "usage: smx ai open <session>"
  [ -n "${NIRI_SOCKET:-}" ] || die "smx ai open needs the desktop (run it from your session, not an agent)"
  session=$(server_curl -sf --max-time 10 "$(server_url)/api/session/$id" | jq -c '.data // empty') || true
  [ -n "$session" ] || die "no session $id" 4
  dir=$(jq -r '.location.directory // empty' <<<"$session")

  panes=$(for pid in $(tuis_on "$id"); do pane_of "$pid" || true; done; panes_titled "$(jq -r '.title // empty' <<<"$session")")
  for pane in $panes; do
    focus_pane "$pane" && return
  done

  # (Not on screen: in a new terminal, its TUI if it has one.)
  for pane in $panes; do
    { tmux select-window -t "${pane%.*}" && tmux select-pane -t "$pane"; } || continue
    setsid -f xdg-terminal-exec tmux attach-session -t "${pane%%:*}" </dev/null &>/dev/null
    return
  done
  cd "${dir:-$HOME}" 2>/dev/null || cd "$HOME"
  setsid -f xdg-terminal-exec tmux new-session "$opencode" -s "$id" </dev/null &>/dev/null
}

# --- allow, deny, allowed -----------------------------------------------------

# Permission requests (JSON lines in and out, as the server has them), with
# where they'd run: the shell call's own workdir (not the agent's description
# of it), against the session's folder ($1), or else that folder.
with_cwd() {
  local request session message call input
  while IFS= read -r request; do
    [ -n "$request" ] || continue
    IFS=$'\t' read -r session message call < <(jq -r '[.sessionID, (.source.messageID // "-"), (.source.id // "-")] | @tsv' <<<"$request")
    input=$(server_get "/api/session/$session/message/$message" | jq -c --arg call "$call" \
      'first(.data.content[]? | select(.type == "tool" and .id == $call) | .state.input) // {}' 2>/dev/null) || input=""
    [ -n "$input" ] || input='{}'
    jq -c --argjson i "$input" --arg d "$1" \
      '. + {cwd: ($i.workdir // null | if . == null then $d elif startswith("/") then . else $d + "/" + . end)}' <<<"$request"
  done
}

# A request waiting on you (any running session's), by its id.
pending_request() {
  local session
  for session in $(server_get "/api/session?limit=50" | jq -r '.data[] | select((.time.busy // 0) > (.time.idle // 0)) | .id'); do
    server_get "/api/session/$session/permission" | jq -ce --arg r "$1" 'first(.data[] | select(.id == $r))' && return
  done
  return 1
}

# A request, in a line: what it'd do, and where.
described() {
  jq -r --arg home "$HOME" '"\(.action) \(.resources | join(", "))"
    + (if .cwd then "  (in \(.cwd | if startswith($home) then "~" + .[($home | length):] else . end))" else "" end)'
}

# allow|deny: answers a request. (Safe to repeat: one that's not waiting is
# already answered, so there's nothing to do.)
answer() {
  local verb=$1 decision=$2 id=${3:-} request session
  [ -n "$id" ] || die "usage: smx ai $verb <request>"
  if [ -z "$(server_url)" ] || ! server_get "/api/session?limit=1" >/dev/null; then die "OpenCode's server isn't reachable" 3; fi
  if ! request=$(pending_request "$id"); then
    echo "${D}Nothing to do: $id isn't waiting (answered already, or never asked).${N}"
    return
  fi
  session=$(jq -r .sessionID <<<"$request")
  server_curl -sf --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg d "$decision" '{decision: $d}')" \
    "$(server_url)/api/session/$session/permission/$id/reply" >/dev/null || die "couldn't answer $id"
  request=$(with_cwd "$(server_get "/api/session/$session" | jq -r '.data.location.directory // ""')" <<<"$request")
  case "$decision" in
    once) echo "${G}✓${N} Allowed: $(described <<<"$request")" ;;
    always) echo "${G}✓${N} Allowed, and from now on: $(jq -r '"\(.action) \((.save // .resources) | join(", "))"' <<<"$request")" ;;
    reject) echo "${R}✗${N} Denied: $(described <<<"$request")" ;;
  esac
}

allow() {
  local id="" decision=once
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --always) decision=always ;;
      -*) die "usage: smx ai allow <request> [--always]" ;;
      *) id=$1 ;;
    esac
    shift
  done
  answer allow "$decision" "$id"
}

# allowed: what's allowed from now on (OpenCode's saved permissions: per
# project, an action and a pattern), and revoking it.
allowed() {
  local saved projects project code
  case "${1:-}" in
    revoke)
      [ -n "${2:-}" ] || die "usage: smx ai allowed revoke <id>"
      # (The server takes a repeat without saying so.)
      if allowed --json | jq -e --arg id "$2" '.allowed | any(.id == $id)' >/dev/null; then
        code=$(server_curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X DELETE "$(server_url)/api/permission/saved/$2") || die "OpenCode's server isn't reachable" 3
      else
        code=404
      fi
      case "$code" in
        2??) echo "${G}✓${N} Revoked $2" ;;
        404) echo "${D}Nothing to do: $2 isn't allowed (revoked already, or never was).${N}" ;;
        *) die "couldn't revoke $2 (HTTP $code)" ;;
      esac
      return
      ;;
    "" | --json) ;;
    *) die "usage: smx ai allowed [--json | revoke <id>]" ;;
  esac
  # (The server lists them per project.)
  projects=$(server_get /api/project) || die "OpenCode's server isn't reachable" 3
  saved=$(for project in $(jq -r '.[].id' <<<"$projects"); do server_get "/api/permission/saved?projectID=$project" | jq -c '.data[]'; done | jq -cs .)
  saved=$(jq -c --argjson p "$projects" '($p | map({key: .id, value: .canonical}) | from_entries) as $where
    | {v: 1, allowed: [.[] | {id, project: $where[.projectID], action, resource, created: .time.created}]}' <<<"$saved")
  if [ "${1:-}" = --json ]; then
    echo "$saved"
  elif [ "$(jq '.allowed | length' <<<"$saved")" = 0 ]; then
    echo "${D}Nothing's allowed from now on: agents ask (as their rules say).${N}"
  else
    jq -r --arg home "$HOME" '.allowed[] | [.action, .resource,
        ((.project // "?") | if startswith($home) then "~" + .[($home | length):] else . end), .id] | @tsv' <<<"$saved" \
      | while IFS=$'\t' read -r action resource project id; do
          printf '%s %s  %s\n' "$action" "$resource" "${D}$project  $id${N}"
        done
  fi
}

# --- doctor -----------------------------------------------------------------

failed=""
ok() { echo "${G}✓${N} $1"; }
bad() { echo "${R}✗${N} $1"; shift; for l in "$@"; do echo "  $l"; done; failed=1; }
skip() { echo "${D}- $1${N}"; }

# The probe's shell command prints, for each desktop variable it has, its
# name (and then a marker, once done). Neither appears in the command itself.
probe_command() {
  local alt=${1// /\\|}
  printf '%s\n' "env | sed -n 's/^\\($alt\\)=.*/le''ak:\\1/p'; echo pro''be:done"
}

# Runs the probe in a throwaway session, given these variables (as a client
# would), and prints the ones its command still had.
probe_agent_env() {
  local names=$1 sid vars messages
  mkdir -p "$probe_dir"
  sid=$(api POST /api/session -d "$(jq -n --arg d "$probe_dir" \
    '{title: "smx ai doctor", location: {directory: $d}}')" | jq -r '.data.id // .id // empty') || return 1
  [ -n "$sid" ] || return 1
  vars=$(jq -n --arg names "$names" --arg path "$PATH" \
    '($names | split(" ") | map({key: ., value: "smx-ai-probe"}) | from_entries) + {PATH: $path}')
  api PUT "/api/session/$sid/environment" -d "$(jq -n --argjson v "$vars" '{variables: $v}')" >/dev/null
  api POST "/api/session/$sid/shell" -d "$(jq -n --arg c "$(probe_command "$names")" '{command: $c}')" >/dev/null
  for _ in $(seq 50); do
    messages=$(api GET "/api/session/$sid/message" 2>/dev/null)
    grep -q 'probe:done' <<<"$messages" && break
    sleep 0.2
  done
  api DELETE "/api/session/$sid" >/dev/null 2>&1 || true
  grep -q 'probe:done' <<<"$messages" || return 1
  { grep -oE 'leak:[A-Z_]+' <<<"$messages" || true; } | sed 's/^leak://' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

doctor() {
  if ! ctl cat "$unit" &>/dev/null; then
    bad "OpenCode's server runs as $unit" "There's no $unit here (smudgenix.ai.enable, on the OS)."
    exit 1
  fi
  if ! ctl is-active --quiet "$unit"; then
    say "starting $unit…"
    ctl start "$unit" 2>/dev/null || true
  fi
  if ! ctl is-active --quiet "$unit"; then
    bad "OpenCode's server runs as $unit" "It didn't start: see \`journalctl --user -u $unit\`."
    exit 3
  fi
  ok "OpenCode's server runs as $unit"

  main=$(ctl show "$unit" -p MainPID --value)
  used=$(jq -r '.pid // empty' "$state_file" 2>/dev/null || true)
  if [ "$used" = "$main" ]; then
    ok "It's the server opencode uses"
  else
    bad "It's the server opencode uses" \
      "opencode uses another server (pid ${used:-unknown}), with a terminal's access to the desktop." \
      "Replace it with \`opencode service restart\` (which disconnects its sessions)."
  fi

  names=$(ctl show "$unit" -p UnsetEnvironment --value)
  if [ -z "$names" ]; then
    skip "Nothing to keep from agents (smudgenix.ai.server.unsetEnvironment is empty)"
    [ -z "$failed" ]; exit
  fi

  server_has=()
  for name in $names; do
    tr '\0' '\n' <"/proc/$main/environ" 2>/dev/null | grep -q "^$name=" && server_has+=("$name")
  done
  if [ "${#server_has[@]}" = 0 ]; then
    ok "The server runs without the desktop ${D}($names)${N}"
  else
    bad "The server runs without the desktop" "It has ${server_has[*]}."
  fi

  if [ "$used" != "$main" ]; then
    skip "Agents' commands run without the desktop (not checked: opencode uses another server)"
  elif ! leaked=$(probe_agent_env "$names"); then
    bad "Agents' commands run without the desktop" "Couldn't run a command in a test session."
  elif [ -z "$leaked" ]; then
    ok "Agents' commands run without the desktop, even given it by a client"
  else
    bad "Agents' commands run without the desktop" \
      "They get $leaked from their client (the server lacks smudgenix's OpenCode plugin?)." \
      "After updating the OS, \`opencode service restart\` (which disconnects its sessions)."
  fi

  [ -z "$failed" ]
}

case "${1:-}" in
  doctor) doctor ;;
  watch) shift; watch_command "$@" ;;
  status) shift; status "$@" ;;
  open) shift; open_session "$@" ;;
  allow) shift; allow "$@" ;;
  deny) shift; [ "$#" -le 1 ] || die "usage: smx ai deny <request>"; answer deny reject "${1:-}" ;;
  allowed) shift; allowed "$@" ;;
  "" | help | -h | --help) usage ;;
  *) say "unknown command '$1'"; usage >&2; exit 1 ;;
esac
