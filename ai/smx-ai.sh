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

  new [--dir <folder>] [--tui] "<what to do>"
                          Start a thread of work, in the background (or a TUI)
  close <session>         End it (OpenCode archives it)
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
  open <session>          A thread, in a tmux session of its own: its TUI,
                          and a shell where its work is (its window, or a
                          new one)
  shell <session>         A shell where a thread's work is: its folder
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
      | jq -c 'first(.data[].content[]? | select(.type == "text" and (.text // "") != "") | .text) [0:4000] // null' 2>/dev/null) || reply=null
    compaction=$(server_get "/api/session/$id/message?limit=3&order=desc&type=compaction" \
      | jq -c 'first(.data[] | select(.status == "completed") | .summary) [0:8000] // null' 2>/dev/null) || compaction=null
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

# The threads open now, in tmux sessions of their own (smx ai open), as an
# smx.tuis: for each, its session, and the processes it's shown through, its
# terminals' up (so the terminals are among them), if any shows it.
tuis() {
  local procs sessions clients
  procs=$(ps -u "$(id -u)" -o pid=,ppid=)
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  clients=$(tmux list-clients -F '#{client_pid}	#{session_name}' 2>/dev/null || true)
  jq -cn --arg procs "$procs" --arg sessions "$sessions" --arg clients "$clients" '
    ($procs | split("\n") | map(select(. != "") | [splits(" +") | select(. != "") | tonumber])
      | map({key: (.[0] | tostring), value: .[1]}) | from_entries) as $parent
    | def up: [recurse(($parent[tostring] // 1) | select(. > 1))];
    ($clients | split("\n") | map(select(. != "") | split("\t") | {pid: (.[0] | tonumber), session: .[1]})) as $client
    | {type: "smx.tuis", tuis: [$sessions | split("\n")[] | select(startswith("smx-")) as $name
        | {id: $name[4:], title: null, seen: [$client[] | select(.session == $name) | .pid | up[]]}]}'
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

# A thread's own tmux session: its TUI and a shell where its work is, side by
# side, in one terminal. smx ai opens only these, never guessing at TUIs you
# opened yourself (and tmux-snap leaves them be).
tmux_session_of() { echo "smx-$1"; }

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

# Where a thread's work is: its session's folder.
work_dir() {
  local dir session
  session=$(server_curl -sf --max-time 10 "$(server_url)/api/session/$1" | jq -c '.data // empty') || true
  [ -n "$session" ] || die "no session $1 (or OpenCode's server isn't reachable)" 4
  dir=$(jq -r '.location.directory // empty' <<<"$session")
  [ -n "$dir" ] && [ -d "$dir" ] || die "session $1's folder (${dir:-none}) isn't there" 4
  echo "$dir"
}

# open: a thread, in its own tmux session (made the first time: its TUI, and
# smx ai shell beside it): its window if it's on screen, else in a new
# terminal.
open_session() {
  local id=${1:-} name dir window self
  [ -n "$id" ] && [ "$#" -eq 1 ] || die "usage: smx ai open <session>"
  [ -n "${NIRI_SOCKET:-}" ] || die "smx ai open needs the desktop (run it from your session, not an agent)"
  name=$(tmux_session_of "$id")
  if ! tmux has-session -t "=$name" 2>/dev/null; then
    dir=$(work_dir "$id")
    self=$(readlink -f "$0" 2>/dev/null) && [ -x "$self" ] || self=$(command -v smx-ai)
    tmux new-session -d -s "$name" -c "$dir" -x 200 -y 50 "$opencode" -s "$id" \
      || die "couldn't start tmux session $name"
    tmux split-window -h -d -l 40% -t "=$name:" -c "$dir" "$self" shell "$id" || true
  fi
  if window=$(window_of_tmux_session "$name"); then
    niri msg action focus-window --id "$window"
    return
  fi
  setsid -f xdg-terminal-exec tmux attach-session -t "=$name" </dev/null &>/dev/null
}

# shell: a shell where a thread's work is: its folder.
shell_command() {
  local id=${1:-} dir
  [ -n "$id" ] && [ "$#" -eq 1 ] || die "usage: smx ai shell <session>"
  dir=$(work_dir "$id")
  cd "$dir" || die "no folder $dir" 4
  exec "${SHELL:-bash}" -i
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

# new: starts a thread of work in a folder (by default this one), in the
# background (it comes back when it's done, or needs you), or --tui in a
# terminal too.
new_thread() {
  local dir=$PWD tui="" json="" prompt="" session
  local usage="usage: smx ai new [--dir <folder>] [--tui] [--json] \"<what to do>\""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) dir=${2:-}; shift ;;
      --tui) tui=1 ;;
      --json) json=1 ;;
      -*) die "$usage" ;;
      *) [ -z "$prompt" ] || die "$usage"; prompt=$1 ;;
    esac
    shift
  done
  [ -n "$prompt" ] || die "$usage"
  [ -d "$dir" ] || die "no folder $dir" 4
  dir=$(cd "$dir" && pwd)
  need_server
  local body
  body=$(jq -cn --arg d "$dir" '{location: {directory: $d}}')
  session=$(server_curl -sf --max-time 15 -X POST -H 'Content-Type: application/json' \
    -d "$body" "$(server_url)/api/session" \
    | jq -r '.data.id // .id // empty') || true
  [ -n "$session" ] || die "couldn't start a session in $dir"
  prompt_session "$session" "$prompt" || die "couldn't give session $session its prompt"
  if [ -n "$json" ]; then
    jq -cn --arg s "$session" --arg d "$dir" '{v: 1, session: $s, dir: $d}'
  else
    echo "${G}✓${N} Started, in the background: $session ${D}($dir)${N}"
  fi
  [ -z "$tui" ] || open_session "$session"
}

# close: ends a thread (OpenCode archives its session).
close_thread() {
  local session=${1:-} sess
  [ -n "$session" ] && [ "$#" -eq 1 ] || die "usage: smx ai close <session>"
  need_server
  sess=$(server_get "/api/session/$session" | jq -c '.data // empty') || true
  [ -n "$sess" ] || die "no session $session" 4
  if [ "$(jq -r '.time.archived // empty' <<<"$sess")" != "" ]; then
    echo "${D}Nothing to do: it's closed already.${N}"
    tmux kill-session -t "=$(tmux_session_of "$session")" 2>/dev/null || true
    return
  fi
  server_curl -sf --max-time 10 -X PATCH -H 'Content-Type: application/json' -d '{"archived": true}' \
    "$(server_url)/api/session/$session" >/dev/null || die "couldn't close session $session"
  echo "${G}✓${N} Closed: $(jq -r '.title // .id' <<<"$sess")"
  # (Its tmux session too, last: you may be in it.)
  tmux kill-session -t "=$(tmux_session_of "$session")" 2>/dev/null || true
}

# A folder's project, as watch names them: its repository's (main checkout's)
# folder, else its own; ~ for your home.
project_of() {
  local project
  project=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && project=${project%/.git} || project=$1
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
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    jq -cn --arg d "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")" --arg p "$(project_of "$dir")" \
      '{v: 1, dir: $d, project: $p}'
  else
    echo '{"v":1,"dir":null,"project":null}'
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
  shell) shift; shell_command "$@" ;;
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
