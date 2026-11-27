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

  new [--dir <folder>] ["<what to do>"]
                          Start a session in a folder (by default this one),
                          and open it (as open does)
  close <session> [--tab] End it (OpenCode archives it), and close its tab
                          (--tab: only close its tab)
  context --json          Where you are: the focused window's project

  decide "<line>" [--why "<why>"] [--kind direction|constraint|decision|open]
         [--you | --project <name>] [--supersedes <id>]
                          Record a line of judgment (by default, a decision
                          for the project you're in), in your decision log
  reopen <id> "<what's open about it now>"
                          Unsettle a line
  withdraw <id> ["<why>"] A line no longer stands, and nothing replaces it
  log [--project <name> | --all] [--current] [--json]
                          Your decision log, newest first (--current: what
                          stands now)

  status [--json]         What agents are doing now, or have open (--json:
                          and recent sessions too)
  open <session>          A session, on its tab in its project's window: a
                          tmux session of the project's own, its OpenCode
                          TUI and a shell side by side (that window, or a
                          new one)
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

# A session from the server, as smx ai's normalizer takes it (./normalize.jq).
# shellcheck disable=SC2016
shape='def shape:
  (.time.busy // 0) as $busy | (.time.idle // 0) as $idle
  | ($busy > $idle) as $running
  | {id, title, dir: .location.directory, parent: .parentID, updated: .time.updated, running: $running,
     started: (if $busy > 0 then $busy else null end),
     outcome: ({succeeded: "done", failed: "failed"}[.outcome // ""] // "idle"),
     unseen: ((($running | not) and $idle > (.time.viewed // 0)) and .outcome != "interrupted")};'

# Sessions (JSON lines in and out), filled in: their project (the name of
# their folder's repository, its main checkout's, or else of the folder) and
# its folder (root), their
# latest reply and compaction, and what the running ones wait on.
filled() {
  local session id dir running project reply compaction requests
  local -A projects=() roots=()
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    IFS=$'\t' read -r id dir running < <(jq -r '[.id, (.dir // ""), .running] | @tsv' <<<"$session")
    if [ -z "${projects[$dir]+x}" ]; then
      project=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && project=${project%/.git} || project=$dir
      roots[$dir]=$project
      if [ "$project" = "$HOME" ]; then projects[$dir]="~"; else projects[$dir]=$(basename "$project"); fi
    fi
    reply=$(server_get "/api/session/$id/message?limit=10&order=desc&type=assistant" \
      | jq -c 'first(.data[].content[]? | select(.type == "text" and (.text // "") != "") | .text) [0:4000] // null' 2>/dev/null) || reply=null
    compaction=$(server_get "/api/session/$id/message?limit=3&order=desc&type=compaction" \
      | jq -c 'first(.data[] | select(.status == "completed") | .summary) [0:8000] // null' 2>/dev/null) || compaction=null
    session=$(jq -c --arg p "${projects[$dir]}" --arg root "${roots[$dir]}" --argjson r "${reply:-null}" --argjson c "${compaction:-null}" \
      '. + {project: (if $p == "" or $p == "." then null else $p end), root: ($root | select(. != "") // null), last: $r, about: $c}' <<<"$session")
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
  sessions=$(server_get "/api/session?limit=50&archived=false" | jq -c "$shape"' [.data[] | shape] as $all
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

# The projects open now, in tmux sessions of their own (smx ai open), as an
# smx.tuis: for each, its folder, and the processes it's shown through, its
# terminals' up (so the terminals are among them), if any shows it.
tuis() {
  local procs sessions clients
  procs=$(ps -u "$(id -u)" -o pid=,ppid=)
  sessions=$(tmux list-sessions -F '#{session_name}	#{@smx_root}' 2>/dev/null || true)
  clients=$(tmux list-clients -F '#{client_pid}	#{session_name}' 2>/dev/null || true)
  jq -cn --arg procs "$procs" --arg sessions "$sessions" --arg clients "$clients" '
    ($procs | split("\n") | map(select(. != "") | [splits(" +") | select(. != "") | tonumber])
      | map({key: (.[0] | tostring), value: .[1]}) | from_entries) as $parent
    | def up: [recurse(($parent[tostring] // 1) | select(. > 1))];
    ($clients | split("\n") | map(select(. != "") | split("\t") | {pid: (.[0] | tonumber), session: .[1]})) as $client
    | {type: "smx.tuis", tuis: [$sessions | split("\n")[] | split("\t") | select(.[0] | startswith("smx-")) | select((.[1] // "") != "")
        | .[0] as $name | {root: .[1], seen: [$client[] | select(.session == $name) | .pid | up[]]}]}'
}

# watch's TUIs, while it runs: whenever they change (and at first).
# The TUIs' tabs, as an smx.tabs: for each project's folder, the sessions in
# the tabs of the TUIs started in it (or in a folder of it), in order.
# (OpenCode keeps them in $tabs_file, for each folder a TUI's started in.)
tabs_file="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/latest/tui/tabs.json"
tabs() {
  local dirs dir root_by="{}"
  dirs=$(jq -r '.cwd // {} | keys[]' "$tabs_file" 2>/dev/null) || dirs=""
  while IFS= read -r dir; do
    # (Not folders that are gone, nor smx ai's own probe's.)
    [ -d "$dir" ] && [ "$dir" != "$probe_dir" ] || continue
    root_by=$(jq -c --arg d "$dir" --arg r "$(root_of "$dir")" '. + {($d): $r}' <<<"$root_by")
  done <<<"$dirs"
  jq -c --argjson roots "$root_by" '{type: "smx.tabs", tabs: (reduce ((.cwd // {}) | to_entries[]) as $e ({};
      if $roots[$e.key] == null then . else .[$roots[$e.key]] += [$e.value.tabs[]? | {id: .sessionID, title}] end)
    | with_entries(select(.value != [])))}' "$tabs_file" 2>/dev/null || echo '{"type":"smx.tabs","tabs":{}}'
}

# watch's projects and tabs, while it runs: at first, and whenever they change.
tui_changes() {
  local now last="" stamp last_stamp="-"
  local watcher=$$
  while [ -e "/proc/$watcher" ]; do
    now=$(tuis)
    [ "$now" = "$last" ] || { echo "$now"; last=$now; }
    stamp=$(stat -c %Y.%s "$tabs_file" 2>/dev/null) || stamp=""
    [ "$stamp" = "$last_stamp" ] || { tabs; last_stamp=$stamp; }
    sleep 1
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

# A folder's project's folder: its repository's (main checkout's), else its own.
root_of() {
  local root
  root=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && root=${root%/.git} || root=$1
  echo "$root"
}

# A project's own tmux session: its OpenCode TUI (started in its folder, so its
# tabs are the project's sessions) and a shell beside it, in one terminal.
# smx ai opens only these, never guessing at TUIs you opened yourself (and
# tmux-snap leaves them be). Its options: @smx_root, the project's folder, and
# @smx_tui, the TUI's pane.
tmux_session_of() {
  local base=${1##*/}
  echo "smx-${base//[^A-Za-z0-9_-]/_}-$(printf %s "$1" | md5sum | cut -c1-6)"
}

# The niri window showing a tmux session (its client's terminal), if any.
window_of_tmux_session() {
  local windows client p
  windows=$(niri msg --json windows 2>/dev/null) || return 1
  for client in $(tmux list-clients -t "=$1" -F '#{client_pid}' 2>/dev/null); do
    for p in $(ancestors "$client"); do
      jq -e --argjson p "$p" 'first(.[] | select(.pid == $p) | .id)' <<<"$windows" && return
    done
  done
  return 1
}

# A session's folder.
work_dir() {
  local dir session
  session=$(server_curl -sf --max-time 10 "$(server_url)/api/session/$1" | jq -c '.data // empty') || true
  [ -n "$session" ] || die "no session $1 (or OpenCode's server isn't reachable)" 4
  dir=$(jq -r '.location.directory // empty' <<<"$session")
  [ -n "$dir" ] && [ -d "$dir" ] || die "session $1's folder (${dir:-none}) isn't there" 4
  echo "$dir"
}

# Asks the TUIs in a project's folder ($2), through smudgenix's OpenCode
# plugin, to open ($1) a session's tab (or a new session: none given), or to
# close one.
tell_tuis() {
  server_curl -sf --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg s "${3:-}" '{input: (if $s == "" then {} else {session: $s} end)}')" \
    "$(server_url)/api/rpc/smudgenix/$1?location%5Bdirectory%5D=$(jq -rn --arg r "$2" '$r | @uri')" >/dev/null
}

# A project's tmux session (made if it isn't there), with its TUI running
# (started if it isn't, on a session if given one): sets the caller's $tui
# (its pane) and $started (if it was just started).
project_tui() {
  local root=$1 session=${2:-} name
  local tui_command=("$opencode")
  [ -z "$session" ] || tui_command+=(-s "$session")
  name=$(tmux_session_of "$root")
  tui="" started=""
  if ! tmux has-session -t "=$name" 2>/dev/null; then
    tui=$(tmux new-session -d -P -F '#{pane_id}' -s "$name" -c "$root" -x 200 -y 50 "${tui_command[@]}") \
      || die "couldn't start tmux session $name"
    tmux set-option -t "=$name:" @smx_root "$root"
    tmux split-window -h -d -l 40% -t "$tui" -c "$root" || true
    started=1
  else
    tui=$(tmux show-options -v -t "=$name:" @smx_tui 2>/dev/null) || tui=""
    if [ -z "$tui" ] || ! tmux list-panes -s -t "=$name" -F '#{pane_id}' | grep -qxF -- "$tui"; then
      # (Its TUI's gone: a new one, on the left.)
      tui=$(tmux split-window -h -b -P -F '#{pane_id}' -l 60% -t "=$name:" -c "$root" "${tui_command[@]}") \
        || die "couldn't start a TUI in $name"
      started=1
    fi
  fi
  tmux set-option -t "=$name:" @smx_tui "$tui"
}

# A project, on screen: its TUI on a session's tab (or a new session: none
# given), in its tmux session; its window, if it's on screen, else a new
# terminal.
open_project() {
  local root=$1 session=${2:-} name tui started window
  [ -n "${NIRI_SOCKET:-}" ] || die "smx ai open needs the desktop (run it from your session, not an agent)"
  name=$(tmux_session_of "$root")
  project_tui "$root" "$session"
  if [ -z "$started" ]; then
    tell_tuis open "$root" "$session" || die "couldn't reach $name's TUI (through OpenCode's server)"
  fi
  tmux select-window -t "$tui" \; select-pane -t "$tui" 2>/dev/null || true
  if window=$(window_of_tmux_session "$name"); then
    niri msg action focus-window --id "$window"
    return
  fi
  # (Its own app-id, so niri opens it full width: see ../nixos/desktop/niri.nix.)
  setsid -f xdg-terminal-exec --app-id=smudgenix.agent tmux attach-session -t "=$name" </dev/null &>/dev/null
}

# open: a session, on its tab in its project's TUI.
open_session() {
  [ -n "${1:-}" ] && [ "$#" -eq 1 ] || die "usage: smx ai open <session>"
  open_project "$(root_of "$(work_dir "$1")")" "$1"
}

# --- the store ----------------------------------------------------------------

# smx ai's own: what agents' commands can't change (their sandbox has it
# read-only, as all but their project). SMX_AI_STORE points elsewhere, for tests.
store_dir=${SMX_AI_STORE:-${XDG_DATA_HOME:-$HOME/.local/share}/smudgenix}

now_ms() { echo $(($(date +%s%N) / 1000000)); }

# --- decisions: the log of your judgment ---------------------------------------

# Only yours: one line per entry, append-only. Nothing's edited: replacing,
# reopening and withdrawing are entries too, and what stands now is folded
# from them all (see ./decisions.jq).
decision_log="$store_dir/decisions.jsonl"
line_kinds="direction constraint decision open"

# A new entry, with an id nothing in the file has, and the time; printed.
append_entry() {
  local file=$1 prefix=$2 entry=$3
  mkdir -p "$(dirname "$file")"
  (
    flock 9
    local id
    while :; do
      id="$prefix$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
      grep -q "\"id\":\"$id\"" "$file" 2>/dev/null || break
    done
    jq -c --arg id "$id" --argjson t "$(now_ms)" '{id: $id, time: $t} + .' <<<"$entry" | tee -a "$file"
  ) 9>"$(dirname "$file")/.$(basename "$file").lock"
}

# A line, by its id or the start of it (of those that stand or did).
find_entry() {
  local found
  found=$(fold | jq -c --arg id "$1" '.log[] | select(.kind != "withdraw" and (.id | startswith($id)))')
  [ -n "$found" ] || die "no decision $1" 4
  [ "$(wc -l <<<"$found")" -eq 1 ] || die "$1 could be any of $(jq -r .id <<<"$found" | paste -sd ' '): give more of it"
  echo "$found"
}

# What stands, for a project, or everything (none given).
fold() {
  jq -cn --slurpfile e <(cat "$decision_log" 2>/dev/null || true) --arg p "${1:-}" \
    '{entries: $e, project: ($p | select(. != "") // null)}' \
    | jq -c -f "$decisions_filter"
}

# (A line is a line: one, short, said plainly.)
one_line() {
  [ -n "$2" ] || die "$1 is empty"
  case "$2" in *$'\n'*) die "$1 must be one line" ;; esac
  [ "${#2}" -le 200 ] || die "$1 is ${#2} characters: say it in 200 or fewer"
}

# decide: a line of judgment, yours (all your projects) or a project's (by
# default, the one you're in). It may replace one (a decision on an open
# question, a change of mind).
decide_command() {
  local text="" why="" kind=decision scope="" project="" ref="" json=""
  local usage="usage: smx ai decide \"<line>\" [--why \"<why>\"] [--kind direction|constraint|decision|open] [--you | --project <name>] [--supersedes <id>] [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --why) why=${2:-}; shift ;;
      --kind) kind=${2:-}; shift ;;
      --you) scope=you ;;
      --project) project=${2:-}; scope=project; shift ;;
      --supersedes) ref=${2:-}; shift ;;
      --json) json=1 ;;
      -*) die "$usage" ;;
      *) [ -z "$text" ] || die "$usage"; text=$1 ;;
    esac
    shift
  done
  one_line "the line" "$text"
  [ -z "$why" ] || one_line "--why" "$why"
  case " $line_kinds " in *" $kind "*) ;; *) die "$usage" ;; esac

  local target=""
  if [ -n "$ref" ]; then
    target=$(find_entry "$ref")
    ref=$(jq -r .id <<<"$target")
    [ "$(jq -r .status <<<"$target")" = current ] || die "$ref has been replaced or withdrawn already (smx ai log shows by what)"
  fi
  # (By default, the scope of what it replaces; else where you are.)
  if [ -z "$scope" ] && [ -n "$target" ]; then
    scope=$(jq -r .scope <<<"$target") project=$(jq -r '.project // empty' <<<"$target")
  elif [ -z "$scope" ]; then
    git rev-parse --show-toplevel >/dev/null 2>&1 || die "you're not in a project: say which (--project <name>), or --you for all of them"
    scope=project project=$(project_of "$PWD")
  fi
  [ "$scope" != project ] || [ -n "$project" ] || die "$usage"

  local entry
  entry=$(jq -cn --arg kind "$kind" --arg scope "$scope" --arg project "$project" \
    --arg text "$text" --arg why "$why" --arg ref "$ref" '
    def opt: if . == "" then null else . end;
    {kind: $kind, scope: $scope, project: (if $scope == "you" then null else $project | opt end),
     text: $text, why: ($why | opt), by: "you", ref: ($ref | opt)}
    | with_entries(select(.value != null))')
  entry=$(append_entry "$decision_log" d "$entry")
  if [ -n "$json" ]; then echo "$entry"; else show_entries <<<"$entry"; fi
}

# reopen: a line no longer settled: what's open about it now.
reopen_command() {
  [ "$#" -eq 2 ] || die "usage: smx ai reopen <id> \"<what's open about it now>\""
  decide_command "$2" --kind open --supersedes "$1"
}

# withdraw: a line that no longer stands, with nothing in its place.
withdraw_command() {
  local target id entry
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: smx ai withdraw <id> [\"<why>\"]"
  [ -z "${2:-}" ] || one_line "the why" "$2"
  target=$(find_entry "$1")
  id=$(jq -r .id <<<"$target")
  [ "$(jq -r .status <<<"$target")" = current ] || die "$id doesn't stand now (smx ai log shows why)"
  entry=$(append_entry "$decision_log" d "$(jq -cn --arg r "$id" --arg w "${2:-}" '{kind: "withdraw", ref: $r, by: "you"} + (if $w == "" then {} else {why: $w} end)')")
  echo "${D}Withdrawn: $(jq -r .text <<<"$target") ($(jq -r .id <<<"$entry"))${N}"
}

# Entries (JSON lines in), as the log's lines.
show_entries() {
  jq -r --arg D "$D" --arg N "$N" --arg A "$A" '
    def day: (.time / 1000 | strflocaltime("%Y-%m-%d"));
    def where: if .scope == "you" then "you" else .project // "?" end;
    "\(day)  \($D)\(where)\($N)  "
    + (if .kind == "withdraw" then "\($D)withdrew:\($N) \(.target // .ref)\(if .why then ": \(.why)" else "" end)"
       else (if .kind != "decision" then "\($A)\(.kind)\($N) " else "" end)
         + (if .status and .status != "current" then "\($D)\(.text)\($N)" else .text end)
         + (if .why then "\($D):\($N) \(.why)" else "" end) end)
    + (if .status and .status != "current" then "  \($D)\(.status) by \(.by_entry)\($N)" else "" end)
    + "  \($D)\(.id)\($N)"'
}

# log: the log, newest first, for the project you're in (or one, or all);
# --current: only what stands now.
log_command() {
  local project="" all="" current="" json="" folded
  local usage="usage: smx ai log [--project <name> | --all] [--current] [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project=${2:-}; [ -n "$project" ] || die "$usage"; shift ;;
      --all) all=1 ;;
      --current) current=1 ;;
      --json) json=1 ;;
      *) die "$usage" ;;
    esac
    shift
  done
  if [ -z "$project" ] && [ -z "$all" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then project=$(project_of "$PWD"); fi
  folded=$(fold "$project")
  if [ -n "$json" ]; then echo "$folded"; return; fi
  if [ -z "$current" ]; then
    jq -c '.log[]' <<<"$folded" | show_entries
    [ "$(jq '.log | length' <<<"$folded")" -gt 0 ] || echo "${D}Nothing decided yet${project:+ for $project}: smx ai decide \"<line>\" starts it.${N}"
    return
  fi
  jq -r --arg D "$D" --arg N "$N" --arg A "$A" '
    def items($k; $title): [.current[] | select(.kind == $k)] as $l
      | if $l == [] then empty else "\($A)\($title)\($N)", ($l[] | "  \(.text)\(if .why then "\($D):\($N) \(.why)" else "" end)  \($D)\(.id)\($N)"), "" end;
    items("direction"; "Direction"), items("constraint"; "Constraints"), items("decision"; "Decisions"), items("open"; "Open, on purpose")' <<<"$folded"
  [ "$(jq '.current | length' <<<"$folded")" -gt 0 ] || echo "${D}Nothing stands yet${project:+ for $project}.${N}"
}

# --- threads: new, close, context --------------------------------

need_server() {
  if [ -z "$(server_url)" ] || ! server_get "/api/session?limit=1" >/dev/null; then die "OpenCode's server isn't reachable" 3; fi
}

prompt_session() {
  server_curl -sf --max-time 15 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg t "$2" '{text: $t}')" "$(server_url)/api/session/$1/prompt" >/dev/null
}

# new: starts a session in a folder (by default this one), with what to do if
# you say, and opens it (on the desktop: see open). On the desktop, with
# nothing to do yet, its project's TUI starts it (in the project's folder).
new_thread() {
  local dir=$PWD prompt="" session
  local usage="usage: smx ai new [--dir <folder>] [\"<what to do>\"]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) dir=${2:-}; shift ;;
      -*) die "$usage" ;;
      *) [ -z "$prompt" ] || die "$usage"; prompt=$1 ;;
    esac
    shift
  done
  [ -d "$dir" ] || die "no folder $dir" 4
  dir=$(cd "$dir" && pwd)
  need_server
  if [ -z "$prompt" ] && [ -n "${NIRI_SOCKET:-}" ]; then
    open_project "$(root_of "$dir")"
    return
  fi
  session=$(server_curl -sf --max-time 15 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg d "$dir" '{location: {directory: $d}}')" "$(server_url)/api/session" \
    | jq -r '.data.id // .id // empty') || true
  [ -n "$session" ] || die "couldn't start a session in $dir"
  if [ -n "$prompt" ]; then
    prompt_session "$session" "$prompt" || die "couldn't give session $session its prompt"
  fi
  echo "${G}✓${N} Started: $session ${D}($dir)${N}"
  [ -z "${NIRI_SOCKET:-}" ] || open_session "$session"
}

# The folder of the TUI whose tabs have a session's, if any.
tab_dir() {
  jq -r --arg id "$1" 'first(.cwd // {} | to_entries[] | select(any(.value.tabs[]?; .sessionID == $id)) | .key) // empty' "$tabs_file" 2>/dev/null || true
}

# close --tab: closes a session's tab (it's still there, to open again), in
# the TUIs that have it: its project's own (started, in the background, if
# it's not running), or one you started in its folder.
close_tab() {
  local session=$1 dir tui started i
  dir=$(tab_dir "$session")
  if [ -z "$dir" ]; then echo "${D}Nothing to do: it's not in a tab.${N}"; return; fi
  need_server
  for i in $(seq 40); do
    tell_tuis close "$dir" "$session" || die "couldn't reach its TUI (through OpenCode's server)"
    sleep 0.5
    if [ -z "$(tab_dir "$session")" ]; then echo "${G}✓${N} Closed its tab"; return; fi
    # (No TUI there took it: the project's own, started.)
    if [ "$i" -eq 3 ]; then
      [ "$(root_of "$dir")" = "$dir" ] || die "its tab is in a TUI started in $dir: close it there"
      project_tui "$dir"
    fi
  done
  die "its TUI didn't close its tab"
}

# close: ends a session (OpenCode archives it), and closes its tab; --tab:
# only closes its tab.
close_thread() {
  local session="" tab="" sess dir
  local usage="usage: smx ai close <session> [--tab]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tab) tab=1 ;;
      -*) die "$usage" ;;
      *) [ -z "$session" ] || die "$usage"; session=$1 ;;
    esac
    shift
  done
  [ -n "$session" ] || die "$usage"
  if [ -n "$tab" ]; then close_tab "$session"; return; fi
  need_server
  sess=$(server_get "/api/session/$session" | jq -c '.data // empty') || true
  [ -n "$sess" ] || die "no session $session" 4
  if [ "$(jq -r '.time.archived // empty' <<<"$sess")" != "" ]; then
    echo "${D}Nothing to do: it's closed already.${N}"
    return
  fi
  server_curl -sf --max-time 10 -X PATCH -H 'Content-Type: application/json' -d '{"archived": true}' \
    "$(server_url)/api/session/$session" >/dev/null || die "couldn't close session $session"
  echo "${G}✓${N} Closed: $(jq -r '.title // .id' <<<"$sess")"
  # (And its tab, in the TUI that has it, if that's running.)
  dir=$(tab_dir "$session")
  [ -z "$dir" ] || tell_tuis close "$dir" "$session" || true
}

# A folder's project, as watch names them: its repository's (main checkout's)
# folder, else its own; ~ for your home.
project_of() {
  local project
  project=$(root_of "$1")
  if [ "$project" = "$HOME" ]; then echo "~"; else basename "$project"; fi
}

# context: where you are: the focused window's folder (a terminal's: its
# tmux pane's, or its shell's), and so its project; nulls if it's not a
# terminal, or unknown.
context() {
  local window pid client session dir="" child
  [ "${1:-}" = --json ] || die "usage: smx ai context --json"
  if [ -n "${NIRI_SOCKET:-}" ] && window=$(niri msg --json focused-window 2>/dev/null) \
    && pid=$(jq -re '.pid // empty' <<<"$window"); then
    # (A tmux client in it: its session's current pane. Else its shell's.)
    for client in $(tmux list-clients -F '#{client_pid}' 2>/dev/null); do
      if ancestors "$client" | grep -qx "$pid"; then
        session=$(tmux list-clients -F '#{client_pid} #{session_name}' | awk -v c="$client" '$1 == c { print $2 }')
        dir=$(tmux display-message -p -t "$session" '#{pane_current_path}' 2>/dev/null) || dir=""
        break
      fi
    done
    if [ -z "$dir" ] && child=$(pgrep -P "$pid" | head -1) && [ -n "$child" ]; then
      dir=$(readlink "/proc/$child/cwd" 2>/dev/null) || dir=""
    fi
  fi
  local root
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    root=$(root_of "$dir")
    jq -cn --arg d "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")" --arg p "$(project_of "$dir")" --arg r "$root" \
      '{v: 1, dir: $d, project: $p, root: $r}'
  else
    echo '{"v":1,"dir":null,"project":null,"root":null}'
  fi
}

# --- doctor -----------------------------------------------------------------

failed=""
ok() { echo "${G}✓${N} $1"; }
bad() { echo "${R}✗${N} $1"; shift; for l in "$@"; do echo "  $l"; done; failed=1; }
skip() { echo "${D}- $1${N}"; }

# Runs a shell command in a throwaway session, given these variables (a JSON
# object, as a client would give them), and prints the session's messages
# once its output has the marker (probe:done; never in the command itself).
probe_shell() {
  local vars=$1 command=$2 sid messages=""
  mkdir -p "$probe_dir"
  sid=$(api POST /api/session -d "$(jq -n --arg d "$probe_dir" \
    '{title: "smx ai doctor", location: {directory: $d}}')" | jq -r '.data.id // .id // empty') || return 1
  [ -n "$sid" ] || return 1
  api PUT "/api/session/$sid/environment" -d "$(jq -n --argjson v "$vars" '{variables: $v}')" >/dev/null
  api POST "/api/session/$sid/shell" -d "$(jq -n --arg c "$command" '{command: $c}')" >/dev/null
  for _ in $(seq 50); do
    messages=$(api GET "/api/session/$sid/message" 2>/dev/null)
    grep -q 'probe:done' <<<"$messages" && break
    sleep 0.2
  done
  api DELETE "/api/session/$sid" >/dev/null 2>&1 || true
  grep -q 'probe:done' <<<"$messages" || return 1
  echo "$messages"
}

# The probe's shell command prints, for each desktop variable it has, its
# name (and then a marker, once done). Neither appears in the command itself.
probe_command() {
  local alt=${1// /\\|}
  printf '%s\n' "env | sed -n 's/^\\($alt\\)=.*/le''ak:\\1/p'; echo pro''be:done"
}

# Runs the probe given these variables (as a client would pass them), and
# prints the ones its command still had.
probe_agent_env() {
  local names=$1 vars messages
  vars=$(jq -n --arg names "$names" --arg path "$PATH" \
    '($names | split(" ") | map({key: ., value: "smx-ai-probe"}) | from_entries) + {PATH: $path}')
  messages=$(probe_shell "$vars" "$(probe_command "$names")") || return 1
  { grep -oE 'leak:[A-Z_]+' <<<"$messages" || true; } | sed 's/^leak://' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# What an agent's command can reach of what it shouldn't (see ../nixos/ai.nix:
# server.runtimeDir and readOnly, and sandbox), by name: the desktop's sockets
# (found without the variables), the user manager's, X11's; changing what runs
# at login, or the rest of your home; gaining privileges; OpenCode's password,
# or its server's process; `systemd-run --user`, over the bus.
probe_reach() {
  local messages
  # shellcheck disable=SC2016
  messages=$(probe_shell "$(jq -n --arg p "$PATH" --arg h "$HOME" '{PATH: $p, HOME: $h}')" '
    r=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    ls "$r"/niri.*.sock >/dev/null 2>&1 && echo re""ach:niri
    ls "$r"/wayland-* >/dev/null 2>&1 && echo re""ach:wayland
    ls /tmp/.X11-unix/X* >/dev/null 2>&1 && echo re""ach:x11
    [ -S "$r/systemd/io.systemd.Manager" ] && echo re""ach:user-manager
    ls "$r"/pipewire-* >/dev/null 2>&1 && echo re""ach:audio
    for d in '"$(printf '%q ' "${read_only[@]}")"'; do
      [ -e "$HOME/$d" ] || continue
      t="$HOME/$d/.smx-ai-probe"; if touch "$t" 2>/dev/null; then rm -f "$t"; echo "re""ach:write:$d"; fi
    done
    grep -q "^NoNewPrivs:[[:space:]]*0" /proc/self/status && echo re""ach:new-privileges
    [ -r "${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json" ] && echo re""ach:opencode-password
    [ -e /proc/'"$main"' ] && echo re""ach:server-process
    t="$HOME/.smx-ai-probe"; if touch "$t" 2>/dev/null; then rm -f "$t"; echo re""ach:write:home; fi
    systemd-run --user --quiet --collect --wait true >/dev/null 2>&1 && echo re""ach:systemd-run
    echo pro""be:done') || return 1
  { grep -oE 'reach:[a-z0-9:./-]+' <<<"$messages" || true; } | sed 's/^reach://' | sort -u | tr '\n' ' ' | sed 's/ $//'
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

  read_only=()
  for path in $(ctl show "$unit" -p ReadOnlyPaths --value); do
    path=${path#-}
    read_only+=("${path#"$HOME"/}")
  done
  # (Or, on a server from before it had any, smudgenix's defaults.)
  [ "${#read_only[@]}" -gt 0 ] || read_only=(.config/systemd .config/autostart .config/environment.d)
  # (Sandboxed, by smudgenix's OpenCode plugin, unless smudgenix.ai.sandbox is
  # off: then only the rest's checked.)
  config=$(ctl show "$unit" -p Environment --value | tr ' ' '\n' | sed -n 's/^OPENCODE_CONFIG=//p')
  sandboxed=$(jq -r '[.plugins[]?.options.sandbox // empty] | first // empty' "$config" 2>/dev/null || true)
  what="Agents' commands are sandboxed: no desktop, nothing outside the project to change, no OpenCode password, server or systemd-run"
  [ -n "$sandboxed" ] || what="Agents' commands can't reach the desktop, or change what runs at login"
  if [ "$used" != "$main" ]; then
    skip "$what (not checked: opencode uses another server)"
  elif ! reached=$(probe_reach); then
    bad "$what" "Couldn't run a command in a test session."
  else
    if [ -z "$sandboxed" ]; then
      reached=$(tr ' ' '\n' <<<"$reached" | grep -vxE 'opencode-password|server-process|write:home|systemd-run' | tr '\n' ' ' | sed 's/ $//' || true)
    fi
    if [ -z "$reached" ]; then
      ok "$what"
      [ -n "$sandboxed" ] || skip "Agents' commands aren't sandboxed (smudgenix.ai.sandbox.enable is off): they share the server's files"
    else
      bad "$what" \
        "They can reach: $reached." \
        "After updating the OS, \`opencode service restart\` (which disconnects its sessions)."
    fi
  fi

  [ -z "$failed" ]
}

case "${1:-}" in
  doctor) doctor ;;
  watch) shift; watch_command "$@" ;;
  status) shift; status "$@" ;;
  open) shift; open_session "$@" ;;
  decide) shift; decide_command "$@" ;;
  reopen) shift; reopen_command "$@" ;;
  withdraw) shift; withdraw_command "$@" ;;
  log) shift; log_command "$@" ;;
  new) shift; new_thread "$@" ;;
  close) shift; close_thread "$@" ;;
  context) shift; context "$@" ;;
  "" | help | -h | --help) usage ;;
  *) say "unknown command '$1'"; usage >&2; exit 1 ;;
esac
