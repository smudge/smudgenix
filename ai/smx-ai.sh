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
  reply <session> "<what to say>"
                          Tell it more
  park <session>          Not now (it stays open)
  close <session> [--accept | --discard]
                          End it (deciding its review, if it has one)
  context --json          Where you are: the focused window's project

  decide "<line>" [--why "<why>"] [--kind direction|constraint|decision|open]
         [--you | --project <name> | --thread <session>] [--check "<command>"]
         [--supersedes <id>] [--answers <question>]
                          Record a line of judgment (by default, a decision
                          for the project you're in), in the decision log
  reopen <id> "<what's open about it now>"
                          Unsettle a line
  confirm <id>            Make an agent's provisional call yours
  withdraw <id> ["<why>"] A line no longer stands, and nothing replaces it
  log [--project <name> | --all] [--thread <session>] [--current] [--json]
                          The decision log, newest first (--current: what
                          stands now, and what agents asked you)
  ask …                   (For agents, through smudgenix's OpenCode plugin:
                          a question for you, waiting in the log)
  stack <session> [--json] A thread's stack: its layers, bottom first
  stack diff <session> <layer>
                          A layer's change
  land <session> <layer>  Land it, and every layer below it, on your trunk
  stack commit|revise …   (For agents, through smudgenix's OpenCode plugin)

  history [--days <n> | --since <date>] [--project <name>] [--json]
                          Your threads, day by day, closed ones too (by
                          default, this week)
  status [--json]         What agents are doing now, or have open (--json:
                          and recent sessions too)
  open <session>          Show a session: its TUI's window, or a new one
  allow <request> [--always]
                          Allow what an agent asked to do (--always: and
                          the like, in its project, from now on)
  deny <request>          Don't
  allowed [--json]        What's allowed from now on
  allowed revoke <id>     Ask again for it
  review <session> [--since <commit>]
                          Make a session's work a task in review: what
                          changed (frozen), where to look, what it says
  task [<task>] [--json]  Tasks, or one, and whether a review's stale
  diff <task> [--stale] [<path>…]
                          What a review is of (--stale: what's changed since)
  accept <task>           It's good
  revise <task> "<what to change>"
                          Send it back to its session
  defer <task>            Not now
  verify <task> [--command "<check>"]
                          Run the project's check on what's in review (a
                          fresh copy of it, sandboxed), as evidence
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
      # (A session's finished: its work, if it changed anything, to review.)
      if [ "$type" = session.execution.succeeded ]; then
        review "$id" --auto >/dev/null 2>&1 &
      fi
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

# watch's tasks and decisions, while it runs: whenever they change (or a
# review goes stale), and at first (with up to 200 of each task's files).
store_changes() {
  local now last="" decided last_decided="" watcher=$$
  while [ -e "/proc/$watcher" ]; do
    now=$(task_command --json 2>/dev/null | jq -c '{type: "smx.tasks", tasks: [.tasks[] | .review |= (if . then .files |= .[:200] else . end)]}') || now=""
    [ -z "$now" ] || [ "$now" = "$last" ] || { echo "$now"; last=$now; }
    decided=$(fold 2>/dev/null | jq -c '{type: "smx.decisions", current, briefs}') || decided=""
    [ -z "$decided" ] || [ "$decided" = "$last_decided" ] || { echo "$decided"; last_decided=$decided; }
    sleep 5
  done
}

# watch: what agents are doing (see ./normalize.jq), for good: a snapshot, then
# each change; and while the server's away, that it is (then, once it's back,
# a snapshot). It retries every few seconds, which costs nothing.
watch_normalized() {
  local delay=1 last="" state
  {
    tui_changes &
    store_changes &
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

# --- tasks and review ---------------------------------------------------------

# Tasks are smx ai's own: a folder each, which agents' commands can't change
# (their sandbox hides it). SMX_AI_TASKS points elsewhere, for tests.
tasks_dir=${SMX_AI_TASKS:-${XDG_DATA_HOME:-$HOME/.local/share}/smudgenix/tasks}
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904

task_json() {
  [ -f "$tasks_dir/$1/task.json" ] || die "no task $1" 4
  cat "$tasks_dir/$1/task.json"
}

save_task() {
  local id
  id=$(jq -r .id <<<"$1")
  mkdir -p "$tasks_dir/$id"
  jq . <<<"$1" >"$tasks_dir/$id/task.json.new" && mv "$tasks_dir/$id/task.json.new" "$tasks_dir/$id/task.json"
}

now_ms() { echo $(($(date +%s%N) / 1000000)); }

# A repository's working tree as git would commit it (untracked files too,
# ignored ones not), as a tree, without touching its index or files.
worktree_tree() {
  local index
  index=$(mktemp)
  cp "$(git -C "$1" rev-parse --path-format=absolute --git-path index)" "$index" 2>/dev/null || rm -f "$index"
  GIT_INDEX_FILE=$index git -C "$1" add -A >/dev/null 2>&1 || true
  GIT_INDEX_FILE=$index git -C "$1" write-tree
  rm -f "$index"
}

# Freezes it, as a commit on HEAD (or HEAD itself, if nothing's changed) that
# a ref keeps: what a review is of. (Commits only smx ai makes, never pushed.)
freeze() {
  local repo=$1 ref=$2 title=$3 tree head parents=()
  tree=$(worktree_tree "$repo")
  if head=$(git -C "$repo" rev-parse -q --verify HEAD); then
    parents=(-p "$head")
    if [ "$(git -C "$repo" rev-parse "HEAD^{tree}")" = "$tree" ]; then
      git -C "$repo" update-ref "$ref" "$head"
      echo "$head"
      return
    fi
  fi
  commit=$(GIT_AUTHOR_NAME="smx ai" GIT_AUTHOR_EMAIL=smx-ai@localhost \
    GIT_COMMITTER_NAME="smx ai" GIT_COMMITTER_EMAIL=smx-ai@localhost \
    git -C "$repo" commit-tree "$tree" "${parents[@]}" -m "smx ai review: $title")
  git -C "$repo" update-ref "$ref" "$commit"
  echo "$commit"
}

# What a session's work is measured from: $3 if given; else where its branch
# left the default one; else (on the default branch) the last commit before
# the session began (at $2, in ms); else nothing (the empty tree).
review_base() {
  local repo=$1 since=$3 default branch base
  if [ -n "$since" ]; then
    git -C "$repo" rev-parse --verify -q "$since^{commit}" || die "no commit $since" 4
    return
  fi
  default=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || default=""
  for name in main master; do
    [ -n "$default" ] || ! git -C "$repo" rev-parse -q --verify "refs/heads/$name" >/dev/null || default=$name
  done
  branch=$(git -C "$repo" symbolic-ref -q --short HEAD) || branch=""
  if [ -n "$default" ] && [ -n "$branch" ] && [ "$branch" != "${default#origin/}" ] \
    && base=$(git -C "$repo" merge-base HEAD "$default" 2>/dev/null); then
    echo "$base"
    return
  fi
  base=$(git -C "$repo" rev-list -1 --first-parent --before="$(($2 / 1000))" HEAD 2>/dev/null || true)
  echo "${base:-$empty_tree}"
}

# A change (from $2 to $3), as ./hotspots.jq takes it: its files, with
# what's added and removed, and its added lines (at most a few thousand).
change_json() {
  local repo=$1 from=$2 to=$3
  {
    git -C "$repo" diff -M --name-status -z "$from" "$to" | while IFS= read -r -d '' status; do
      case "$status" in
        R* | C*) IFS= read -r -d '' _; IFS= read -r -d '' path ;;
        *) IFS= read -r -d '' path ;;
      esac
      jq -cn --arg s "${status:0:1}" --arg p "$path" '{status: $s, path: $p}'
    done | jq -cs '{statuses: .}'
    git -C "$repo" diff -M --numstat -z "$from" "$to" | while IFS= read -r -d '' record; do
      IFS=$'\t' read -r added removed path <<<"$record"
      if [ -z "$path" ]; then IFS= read -r -d '' _; IFS= read -r -d '' path; fi
      jq -cn --arg a "$added" --arg r "$removed" --arg p "$path" \
        '{path: $p, added: ($a | tonumber? // 0), removed: ($r | tonumber? // 0)}'
    done | jq -cs '{counts: .}'
    git -C "$repo" diff -M -U0 --no-color "$from" "$to" | awk '
      /^\+\+\+ / { path = substr($0, 7); next }
      /^@@/ { hunk = $0; sub(/ @@.*/, " @@", hunk); next }
      /^\+/ && n < 5000 { n++; print path "\t" hunk "\t" substr($0, 2, 500) }' \
      | jq -Rcs '{lines: [split("\n")[] | select(. != "") | split("\t") | {path: .[0], hunk: .[1], text: (.[2:] | join("\t"))}]}'
  } | jq -cs 'add | (.counts | map({key: .path, value: .}) | from_entries) as $c
    | {files: [.statuses[] | . + ($c[.path] // {added: 0, removed: 0})], lines}'
}

# The session's latest reply: what it says it did (a claim, not evidence).
latest_reply() {
  server_get "/api/session/$1/message?limit=10&order=desc&type=assistant" \
    | jq -c 'first(.data[].content[]? | select(.type == "text" and (.text // "") != "") | .text) // null'
}

# review: makes a session's work a task in review (or, if it is one, a new
# round of it): what changed, frozen; where to look; what it says it did.
review() {
  local session="" since="" json="" auto="" sess dir repo title created id task round
  local base candidate tree work project accepted
  local usage="usage: smx ai review <session> [--since <commit>] [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since) since=${2:-}; shift ;;
      --json) json=1 ;;
      --auto) auto=1 ;;
      -*) die "$usage" ;;
      *) session=$1 ;;
    esac
    shift
  done
  [ -n "$session" ] || die "$usage"
  # (A thread with a stack is reviewed layer by layer: smx ai stack.)
  if [ -f "$(thread_file "$session")" ]; then
    [ -z "$auto" ] || return 0
    die "$session works in a stack: its layers are reviewed one by one (smx ai stack $session)"
  fi
  [ -n "$(server_url)" ] || die "OpenCode's server isn't running" 3
  sess=$(server_get "/api/session/$session" | jq -c '.data // empty') || true
  [ -n "$sess" ] || die "no session $session" 4
  # (--auto, as watch does when a session finishes: only top-level ones',
  # only in a repository, and only if there's something new; quietly.)
  if [ -n "$auto" ] && [ -n "$(jq -r '.parentID // empty' <<<"$sess")" ]; then return; fi
  dir=$(jq -r '.location.directory // empty' <<<"$sess")
  title=$(jq -r '.title // "(untitled)"' <<<"$sess")
  created=$(jq -r '.time.created // 0' <<<"$sess")
  if ! repo=$(git -C "${dir:-/}" rev-parse --show-toplevel 2>/dev/null); then
    [ -z "$auto" ] || return 0
    die "${dir:-its folder} isn't in a git repository: nothing to review"
  fi

  # (One at a time: watch may be doing this too.)
  mkdir -p "$tasks_dir"
  exec 9>"$tasks_dir/.lock"
  flock 9

  # A session's open task gets a new round, from the same base; else a new
  # task, from where its last accepted one ended (so only new work).
  task="" accepted=""
  for file in "$tasks_dir"/*/task.json; do
    [ -f "$file" ] || continue
    if jq -e --arg s "$session" '.session == $s and (.state | IN("accepted", "discarded") | not)' "$file" >/dev/null; then
      task=$(cat "$file")
    elif jq -e --arg s "$session" '.session == $s' "$file" >/dev/null; then
      accepted=$(jq -c --argjson a "${accepted:-null}" 'if $a == null or .updated > $a.updated then . else $a end' "$file")
    fi
  done
  if [ -n "$task" ]; then
    id=$(jq -r .id <<<"$task")
    round=$(($(jq '.rounds | length' <<<"$task") + 1))
    [ -n "$since" ] || since=$(jq -r '.rounds[0].base // empty' <<<"$task")
    if [ -n "$auto" ] && [ "$(worktree_tree "$repo")" = "$(jq -r '.rounds | last | .tree // empty' <<<"$task")" ]; then
      return
    fi
  else
    id="tsk_$(date +%Y%m%d%H%M%S)_$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    round=1
    [ -n "$since" ] || [ -z "$accepted" ] || since=$(jq -r '.rounds | last | .candidate' <<<"$accepted")
    project=$(basename "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##')")
    task=$(jq -cn --arg id "$id" --arg t "$title" --arg p "$project" --arg r "$repo" --arg s "$session" --argjson now "$(now_ms)" \
      '{v: 1, id: $id, title: $t, project: $p, dir: $r, session: $s, state: "in-review", created: $now, updated: $now, rounds: []}')
  fi

  base=$(review_base "$repo" "$created" "$since")
  candidate=$(freeze "$repo" "refs/smudgenix/tasks/$id/$round" "$title")
  tree=$(git -C "$repo" rev-parse "$candidate^{tree}")
  if [ "$(git -C "$repo" rev-parse "$base^{tree}" 2>/dev/null || echo "$base")" = "$tree" ]; then
    git -C "$repo" update-ref -d "refs/smudgenix/tasks/$id/$round"
    [ -n "$auto" ] || echo "${D}Nothing to review: no changes since ${base:0:12}.${N}"
    return
  fi
  # (Through files: a change easily outgrows an argument's 128 KiB.)
  work=$(mktemp -d)
  change_json "$repo" "$base" "$candidate" >"$work/change"
  jq -c -f "$hotspots_filter" "$work/change" >"$work/hotspots"
  latest_reply "$session" >"$work/reply" 2>/dev/null || echo null >"$work/reply"
  [ -s "$work/reply" ] || echo null >"$work/reply"
  task=$(jq -c --argjson round "$round" --arg base "$base" --arg candidate "$candidate" --arg tree "$tree" \
    --slurpfile change "$work/change" --slurpfile hotspots "$work/hotspots" --slurpfile reply "$work/reply" --argjson now "$(now_ms)" \
    '.state = "in-review" | .updated = $now
     | .rounds += [{round: $round, base: $base, candidate: $candidate, tree: $tree, frozen: $now,
         outcome: (if $reply[0] then {text: $reply[0], by: "agent"} else null end),
         files: $change[0].files, hotspots: $hotspots[0]}]' <<<"$task")
  rm -rf "$work"
  save_task "$task"
  [ -z "$auto" ] || return 0
  if [ -n "$json" ]; then task_view "$id"; else show_task "$id"; fi
}

# A task, as JSON, with whether its review is stale: what's changed in its
# repository since (files, from the frozen revision to the working tree).
task_view() {
  local task repo tree last stale="[]" dead="[]" check pid
  task=$(task_json "$1")
  repo=$(jq -r .dir <<<"$task")
  last=$(jq -c '.rounds | last // empty' <<<"$task")
  if [ -n "$last" ] && [ -d "$repo" ] && tree=$(worktree_tree "$repo" 2>/dev/null) \
    && [ "$tree" != "$(jq -r .tree <<<"$last")" ]; then
    stale=$(git -C "$repo" diff --name-only -z "$(jq -r .candidate <<<"$last")" "$tree" | jq -Rcs 'split("\u0000") | map(select(. != ""))')
  fi
  # (A check still "running" whose process is gone was interrupted.)
  while read -r check pid; do
    kill -0 "$pid" 2>/dev/null || dead=$(jq -c --arg c "$check" '. + [$c]' <<<"$dead")
  done < <(jq -r '.evidence[]? | select(.exit == null and .pid) | "\(.id) \(.pid)"' <<<"${last:-null}")
  jq -c --slurpfile stale <(echo "$stale") --argjson dead "$dead" '(.rounds | last) as $r | (.rounds | length) as $n
    | del(.rounds) + {review: $r, rounds: $n, stale: (if $stale[0] == [] then null else $stale[0] end)}
    | if .review.evidence then .review.evidence |= map(if .id | IN($dead[]) then . + {interrupted: true} else . end) else . end' <<<"$task"
}

show_task() {
  local view
  view=$(task_view "$1")
  jq -r --arg home "$HOME" --arg D "$D" --arg N "$N" --arg Y "$Y" --arg A "$A" --arg G "$G" --arg R "$R" '
    def home: if startswith($home) then "~" + .[($home | length):] else . end;
    .review as $r
    | "\(.title)  \($D)\(.project)  \(.id)\($N)",
      "\(.state)\(if .stale then ", \($Y)stale\($N): \(.stale | length) file(s) changed since it was frozen" else "" end)  \($D)round \($r.round), \($r.base[0:12])..\($r.candidate[0:12])  \(.dir | home)\($N)",
      "",
      (if $r.outcome then "What it says it did \($D)(a claim, not evidence)\($N):", "  " + ($r.outcome.text | gsub("\n"; "\n  ")), "" else empty end),
      (if ($r.evidence // []) == [] then "Evidence: none yet \($D)(smx ai verify \(.id) runs a check on it)\($N)", ""
       else "Evidence \($D)(by smx ai, on this revision)\($N):",
         ($r.evidence[] | "  " + (if .exit == 0 then "\($G)✓\($N) passed"
           elif .exit != null then "\($R)✗\($N) failed (exit \(.exit))"
           elif .interrupted then "\($Y)–\($N) interrupted" else "\($A)…\($N) running" end)
           + ": \(.command)" + (if .finished then " \($D)(\((.finished - .started) / 1000 | floor)s)\($N)" else "" end)
           + "\n    \($D)its log: \(.log | home)\($N)"), "" end),
      (if ($r.hotspots | length) > 0 then "Where to look:", ($r.hotspots[] | "  \($Y)▲\($N) \(.path)\(if .hunk then " \($D)\(.hunk)\($N)" else "" end): \(.why)"), "" else "Where to look: nothing flagged mechanically (still read the diff).", "" end),
      "Changes (\($r.files | length) files):",
      ($r.files[] | "  \(.status) \(.path)  \($D)+\(.added) -\(.removed)\($N)")' <<<"$view"
}

task_command() {
  local json="" id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -*) die "usage: smx ai task [<task>] [--json]" ;;
      *) id=$1 ;;
    esac
    shift
  done
  if [ -n "$id" ]; then
    if [ -n "$json" ]; then task_view "$id"; else show_task "$id"; fi
    return
  fi
  local tasks file
  tasks=$(for file in "$tasks_dir"/*/task.json; do
    [ -f "$file" ] || continue
    task_view "$(jq -r .id "$file")"
  done | jq -cs 'sort_by(-.updated)')
  if [ -n "$json" ]; then
    jq -c '{v: 1, tasks: .}' <<<"$tasks"
  elif [ "$tasks" = "[]" ]; then
    echo "${D}No tasks. (smx ai review <session> makes one of a session's work.)${N}"
  else
    jq -r --arg D "$D" --arg N "$N" --arg Y "$Y" '.[] | "\(.state)\(if .stale then ", stale" else "" end)\t\(.title)\t\(.project)\t\(.review.hotspots | length)\t\(.id)"' <<<"$tasks" \
      | while IFS=$'\t' read -r state title project spots id; do
          printf '%-22s %s  %s\n' "$state" "$title" "${D}$project  $spots to look at  $id${N}"
        done
  fi
}

# diff: the change a task's review is of (or, with --stale, what's changed
# since it was frozen), in a pager.
diff_command() {
  local id=${1:-} task last repo from to
  [ -n "$id" ] || die "usage: smx ai diff <task> [--stale] [<path>…]"
  shift
  task=$(task_json "$id")
  last=$(jq -c '.rounds | last' <<<"$task")
  repo=$(jq -r .dir <<<"$task")
  from=$(jq -r .base <<<"$last") to=$(jq -r .candidate <<<"$last")
  if [ "${1:-}" = --stale ]; then
    shift
    from=$to to=$(worktree_tree "$repo")
  fi
  git -C "$repo" -c core.pager="less -R" diff -M "$from" "$to" -- "$@"
}

# accept|revise|defer: what you make of a review, recorded on the task. (Accepting a
# stale review is refused: you'd accept what you haven't seen.)
settle() {
  local verb=$1 id=${2:-} comments=${3:-} task view session
  [ -n "$id" ] || die "usage: smx ai $verb <task>$([ "$verb" = revise ] && echo ' "<what to change>"')"
  view=$(task_view "$id")
  task=$(task_json "$id")
  case "$verb" in
    accept)
      [ "$(jq -r .state <<<"$view")" != accepted ] || { echo "${D}Nothing to do: $id is accepted already.${N}"; return; }
      [ "$(jq -r '.stale // empty' <<<"$view")" = "" ] \
        || die "$id's review is stale: it's changed since it was frozen (smx ai review $(jq -r .session <<<"$task") again)"
      task=$(jq -c --argjson now "$(now_ms)" '.state = "accepted" | .updated = $now | .accepted = {round: (.rounds | length), at: $now}' <<<"$task")
      save_task "$task"
      echo "${G}✓${N} Accepted: $(jq -r .title <<<"$task") ${D}(round $(jq '.rounds | length' <<<"$task"), $(jq -r '.rounds | last | .candidate[0:12]' <<<"$task"))${N}"
      ;;
    revise)
      [ -n "$comments" ] || die "usage: smx ai revise <task> \"<what to change>\""
      session=$(jq -r .session <<<"$task")
      server_curl -sf --max-time 10 -X POST -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg t "Review of your work (frozen at $(jq -r '.rounds | last | .candidate[0:12]' <<<"$task")), from the person reviewing it: $comments" '{text: $t}')" \
        "$(server_url)/api/session/$session/prompt" >/dev/null || die "couldn't send it to session $session"
      task=$(jq -c --argjson now "$(now_ms)" --arg c "$comments" \
        '.state = "revising" | .updated = $now | .rounds[-1].revision = {comments: $c, at: $now}' <<<"$task")
      save_task "$task"
      echo "${G}✓${N} Sent back to its session, to revise: $(jq -r .title <<<"$task")"
      ;;
    defer)
      task=$(jq -c --argjson now "$(now_ms)" '.state = "deferred" | .updated = $now' <<<"$task")
      save_task "$task"
      echo "${D}Deferred: $(jq -r .title <<<"$task")${N}"
      ;;
  esac
}

# --- decisions: the log of your judgment ---------------------------------------

# One line per entry, append-only: nothing's edited; replacing, reopening,
# confirming and withdrawing are entries too, and what stands now is folded
# from them all (see ./decisions.jq). Agents' commands can't write it (their
# sandbox can't); they ask and decide provisionally through smudgenix's
# OpenCode plugin, as an agent.
decision_log="$(dirname "$tasks_dir")/decisions.jsonl"
brief_log="$(dirname "$tasks_dir")/briefs.jsonl"
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

# An entry, by its id or the start of it.
find_entry() {
  local found
  found=$(jq -c --arg id "$2" 'select(.id | startswith($id))' "$1" 2>/dev/null || true)
  [ -n "$found" ] || die "no $3 $2" 4
  [ "$(wc -l <<<"$found")" -eq 1 ] || die "$2 could be any of $(jq -r .id <<<"$found" | paste -sd ' '): give more of it"
  echo "$found"
}

# What stands, for a project (and thread), or everything (none given).
fold() {
  jq -cn --slurpfile e <(cat "$decision_log" 2>/dev/null || true) --slurpfile b <(cat "$brief_log" 2>/dev/null || true) \
    --arg p "${1:-}" --arg t "${2:-}" \
    '{entries: $e, briefs: $b, project: ($p | select(. != "") // null), thread: ($t | select(. != "") // null)}' \
    | jq -c -f "$decisions_filter"
}

# (A line is a line: one, short, said plainly.)
one_line() {
  [ -n "$2" ] || die "$1 is empty"
  case "$2" in *$'\n'*) die "$1 must be one line" ;; esac
  [ "${#2}" -le 200 ] || die "$1 is ${#2} characters: say it in 200 or fewer"
}

# The project (and its thread) a session's in.
session_scope() {
  local sess dir
  sess=$(server_get "/api/session/$1") || die "no session $1 (or the server's unreachable)" 4
  dir=$(jq -r '.data.location.directory // .location.directory // empty' <<<"$sess")
  [ -n "$dir" ] || die "session $1 has no folder"
  project_of "$dir"
}

# (Tells a thread's session, if it's there to tell; a decision stands either way.)
tell_thread() {
  [ -n "$1" ] || return 0
  prompt_session "$1" "$2" 2>/dev/null || say "couldn't tell its session ($1); it'll see it next time it runs"
}

# decide: a line of judgment, in a scope: you (all your projects), a project
# (by default, the one you're in), or a thread. It may replace one (a
# decision on an open question, a change of mind) or answer what an agent
# asked; a thread waiting on it is told.
decide_command() {
  local text="" why="" kind=decision scope="" project="" thread="" check="" ref="" answers="" by=you session="" json=""
  local usage="usage: smx ai decide \"<line>\" [--why \"<why>\"] [--kind direction|constraint|decision|open] [--you | --project <name> | --thread <session>] [--check \"<command>\"] [--supersedes <id>] [--answers <question>] [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --why) why=${2:-}; shift ;;
      --kind) kind=${2:-}; shift ;;
      --you) scope=you ;;
      --project) project=${2:-}; [ "$scope" = thread ] || scope=project; shift ;;
      --thread) scope=thread thread=${2:-}; shift ;;
      --check) check=${2:-}; shift ;;
      --supersedes) ref=${2:-}; shift ;;
      --answers) answers=${2:-}; shift ;;
      # (smudgenix's OpenCode plugin, for an agent's provisional call.)
      --by-agent) by=agent session=${2:-}; shift ;;
      --json) json=1 ;;
      -*) die "$usage" ;;
      *) [ -z "$text" ] || die "$usage"; text=$1 ;;
    esac
    shift
  done
  one_line "the line" "$text"
  [ -z "$why" ] || one_line "--why" "$why"
  case " $line_kinds " in *" $kind "*) ;; *) die "$usage" ;; esac

  local target="" brief=""
  if [ -n "$ref" ]; then
    target=$(find_entry "$decision_log" "$ref" decision)
    ref=$(jq -r .id <<<"$target")
    jq -e '.kind | IN("confirm", "withdraw") | not' <<<"$target" >/dev/null || die "$ref isn't a line to replace"
    [ "$(fold | jq -r --arg r "$ref" '.log[] | select(.id == $r) | .status')" = current ] \
      || die "$ref has been replaced or withdrawn already (smx ai log shows by what)"
  fi
  if [ -n "$answers" ]; then
    brief=$(find_entry "$brief_log" "$answers" question)
    answers=$(jq -r .id <<<"$brief")
    [ "$(fold | jq --arg b "$answers" '[.briefs[] | select(.id == $b)] | length')" -eq 1 ] || die "$answers has been answered already"
  fi
  # (By default, the scope of what it replaces or answers; else where you are.)
  local from=${target:-$brief}
  if [ -z "$scope" ] && [ -n "$from" ]; then
    scope=$(jq -r .scope <<<"$from") project=$(jq -r '.project // empty' <<<"$from") thread=$(jq -r '.thread // empty' <<<"$from")
  elif [ -z "$scope" ]; then
    git rev-parse --show-toplevel >/dev/null 2>&1 || die "you're not in a project: say which (--project <name>), or --you for all of them"
    scope=project project=$(project_of "$PWD")
  fi
  if [ "$scope" = thread ] && [ -z "$project" ]; then
    # (An agent's: where it runs.)
    if [ "$by" = agent ]; then project=$(project_of "$PWD"); else project=$(session_scope "$thread"); fi
  fi
  [ "$scope" != project ] || [ -n "$project" ] || die "$usage"
  [ "$by" != agent ] || [ -n "$session" ] || die "$usage"
  # (An agent's call belongs to the layer it's working on, in a stack:
  # landing that layer waits for you to settle it.)
  local layer="" t repo
  if [ "$by" = agent ] && [ -n "$thread" ] && [ -f "$(thread_file "$thread")" ]; then
    t=$(thread_json "$thread") repo=$(jq -r .repo <<<"$t")
    layer=$(jq -r '.revising // empty' <<<"$t")
    [ -n "$layer" ] || layer=$(jjr -R "$(jq -r .workspace <<<"$t")" log --no-graph -r @ -T change_id 2>/dev/null) || layer=""
  fi

  local entry
  entry=$(jq -cn --arg kind "$kind" --arg scope "$scope" --arg project "$project" --arg thread "$thread" \
    --arg text "$text" --arg why "$why" --arg by "$by" --arg session "$session" --arg check "$check" \
    --arg ref "$ref" --arg answers "$answers" --arg layer "$layer" '
    def opt: if . == "" then null else . end;
    {kind: $kind, scope: $scope, project: ($project | opt), thread: ($thread | opt), text: $text, why: ($why | opt),
     by: $by, session: ($session | opt), check: ($check | opt), ref: ($ref | opt), answers: ($answers | opt), layer: ($layer | opt)}
    | with_entries(select(.value != null))')
  entry=$(append_entry "$decision_log" d "$entry")

  # A thread waiting on it, or whose own call it replaces, hears of it.
  local said
  said="Decided ($(jq -r .id <<<"$entry")): $text${why:+ ($why)}"
  if [ -n "$brief" ]; then
    tell_thread "$(jq -r .session <<<"$brief")" "You asked: $(jq -r .question <<<"$brief") $said. Carry on, in line with it."
  elif [ -n "$target" ] && [ "$(jq -r .by <<<"$target")" = agent ] && [ "$by" = you ]; then
    tell_thread "$(jq -r .session <<<"$target")" "Your provisional call \"$(jq -r .text <<<"$target")\" is replaced. $said. Revise any work that relied on it."
  fi

  if [ -n "$json" ]; then echo "$entry"; else show_entries <<<"$entry"; fi
}

# reopen: a line no longer settled: what's open about it now.
reopen_command() {
  [ "$#" -eq 2 ] || die "usage: smx ai reopen <id> \"<what's open about it now>\""
  decide_command "$2" --kind open --supersedes "$1"
}

# confirm: an agent's provisional call, made yours.
confirm_command() {
  local target id entry
  [ "$#" -eq 1 ] || die "usage: smx ai confirm <id>"
  target=$(find_entry "$decision_log" "$1" decision)
  id=$(jq -r .id <<<"$target")
  [ "$(fold | jq -r --arg r "$id" '.log[] | select(.id == $r) | "\(.status) \(.provisional)"')" = "current true" ] \
    || die "$id isn't a provisional call that stands (smx ai log shows it)"
  entry=$(append_entry "$decision_log" d "$(jq -cn --arg r "$id" '{kind: "confirm", ref: $r, by: "you"}')")
  echo "${G}✓${N} Yours now: $(jq -r .text <<<"$target") ${D}($(jq -r .id <<<"$entry"))${N}"
}

# withdraw: a line that no longer stands, with nothing in its place.
withdraw_command() {
  local target id entry
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: smx ai withdraw <id> [\"<why>\"]"
  [ -z "${2:-}" ] || one_line "the why" "$2"
  target=$(find_entry "$decision_log" "$1" decision)
  id=$(jq -r .id <<<"$target")
  [ "$(fold | jq -r --arg r "$id" '.log[] | select(.id == $r) | .status')" = current ] \
    || die "$id doesn't stand now (smx ai log shows why)"
  entry=$(append_entry "$decision_log" d "$(jq -cn --arg r "$id" --arg w "${2:-}" '{kind: "withdraw", ref: $r, by: "you"} + (if $w == "" then {} else {why: $w} end)')")
  if [ "$(jq -r .by <<<"$target")" = agent ]; then
    tell_thread "$(jq -r .session <<<"$target")" "Your provisional call \"$(jq -r .text <<<"$target")\" is withdrawn${2:+ ($2)}. Revise any work that relied on it."
  fi
  echo "${D}Withdrawn: $(jq -r .text <<<"$target") ($(jq -r .id <<<"$entry"))${N}"
}

# Entries (JSON lines in), as the log's lines.
show_entries() {
  jq -r --arg D "$D" --arg N "$N" --arg Y "$Y" --arg A "$A" '
    def day: (.time / 1000 | strflocaltime("%Y-%m-%d"));
    def where: if .scope == "you" then "you" elif .scope == "thread" then "\(.project) (thread)" else .project // "?" end;
    "\(day)  \($D)\(where)\($N)  "
    + (if .kind == "confirm" then "\($D)confirmed:\($N) \(.target // .ref)"
       elif .kind == "withdraw" then "\($D)withdrew:\($N) \(.target // .ref)\(if .why then ": \(.why)" else "" end)"
       else (if .kind != "decision" then "\($A)\(.kind)\($N) " else "" end)
         + (if .status and .status != "current" then "\($D)\(.text)\($N)" else .text end)
         + (if .why then "\($D):\($N) \(.why)" else "" end) end)
    + (if .provisional then "  \($Y)provisional\($N)\($D) (by an agent)\($N)" else "" end)
    + (if .status and .status != "current" then "  \($D)\(.status) by \(.by_entry)\($N)" else "" end)
    + "  \($D)\(.id)\($N)"'
}

# log: the log, newest first, for the project you're in (or one, or all);
# --current: only what stands now, and what agents asked that's unanswered.
log_command() {
  local project="" all="" thread="" current="" json="" agent="" folded
  local usage="usage: smx ai log [--project <name> | --all] [--thread <session>] [--current] [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project=${2:-}; [ -n "$project" ] || die "$usage"; shift ;;
      --all) all=1 ;;
      --thread) thread=${2:-}; [ -n "$thread" ] || die "$usage"; shift ;;
      --current) current=1 ;;
      # (smudgenix's OpenCode plugin: the fold, as agents get it.)
      --for-agent) agent=1 ;;
      --json) json=1 ;;
      *) die "$usage" ;;
    esac
    shift
  done
  if [ -n "$agent" ]; then agent_context "${project:-$(project_of "$PWD")}" "$thread"; return; fi
  if [ -z "$project" ] && [ -z "$all" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then project=$(project_of "$PWD"); fi
  if [ -n "$thread" ] && [ -z "$project" ]; then project=$(session_scope "$thread"); fi
  folded=$(fold "$project" "$thread")
  if [ -n "$json" ]; then echo "$folded"; return; fi
  if [ -z "$current" ]; then
    jq -c '.log[]' <<<"$folded" | show_entries
    [ "$(jq '.log | length' <<<"$folded")" -gt 0 ] || echo "${D}Nothing decided yet${project:+ for $project}: smx ai decide \"<line>\" starts it.${N}"
    return
  fi
  jq -r --arg D "$D" --arg N "$N" --arg Y "$Y" --arg A "$A" '
    def items($k; $title): [.current[] | select(.kind == $k)] as $l
      | if $l == [] then empty else "\($A)\($title)\($N)", ($l[] | "  \(.text)\(if .why then "\($D):\($N) \(.why)" else "" end)"
          + (if .provisional then "  \($Y)provisional\($N)" else "" end) + "  \($D)\(.id)\($N)"), "" end;
    items("direction"; "Direction"), items("constraint"; "Constraints"), items("decision"; "Decisions"), items("open"; "Open, on purpose"),
    (if .briefs == [] then empty else "\($A)Asked, waiting on you\($N)",
      (.briefs[] | "  \(.question)  \($D)\(.id)\($N)",
        (.options | to_entries[] | "    \(.key + 1). \(.value.text)"),
        (if .pick != null then "    \($D)its pick: \(.pick + 1)\($N)" else empty end)) end)' <<<"$folded"
  [ "$(jq '(.current | length) + (.briefs | length)' <<<"$folded")" -gt 0 ] || echo "${D}Nothing stands yet${project:+ for $project}.${N}"
}

# ask: what an agent asks you (through smudgenix's OpenCode plugin): a
# question, its options, its pick. It waits for your answer (smx ai decide
# "<line>" --answers <id>), in the decision log.
ask_command() {
  local session="" project="" thread="" question="" pick="" serves="" options="[]" brief
  local usage="usage: smx ai ask --session <session> --thread <session> [--project <name>] --question \"<question>\" --option \"<option>[: why]\"… [--pick <n>] [--serves <id>]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) session=${2:-}; shift ;;
      --thread) thread=${2:-}; shift ;;
      --project) project=${2:-}; shift ;;
      --question) question=${2:-}; shift ;;
      --option) one_line "an option" "${2:-}"; options=$(jq -c --arg o "$2" '. + [{text: $o}]' <<<"$options"); shift ;;
      --pick) pick=${2:-}; shift ;;
      --serves) serves=${2:-}; shift ;;
      *) die "$usage" ;;
    esac
    shift
  done
  [ -n "$session" ] && [ -n "$thread" ] || die "$usage"
  [ -n "$project" ] || project=$(project_of "$PWD")
  one_line "the question" "$question"
  [ -z "$pick" ] || { [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$(jq length <<<"$options")" ]; } || die "--pick is one of the options, by number"
  brief=$(jq -cn --arg s "$session" --arg t "$thread" --arg p "$project" --arg q "$question" --argjson o "$options" \
    --arg pick "$pick" --arg serves "$serves" \
    '{session: $s, scope: "thread", project: $p, thread: $t, question: $q, options: $o,
      pick: (if $pick == "" then null else ($pick | tonumber) - 1 end)} + (if $serves == "" then {} else {serves: $serves} end)')
  append_entry "$brief_log" q "$brief"
}

# The fold, as agents get it (smudgenix's OpenCode plugin adds it to their
# context): what stands, and how to keep to it.
agent_context() {
  local folded
  folded=$(fold "$1" "${2:-}")
  jq -r '
    def items($k; $title): [.current[] | select(.kind == $k)] as $l
      | if $l == [] then empty else "\($title):", ($l[] | "- \(.text)\(if .why then " (\(.why))" else "" end)"
          + (if .provisional then " [provisional, by an agent]" else "" end) + " [\(.id)]"), "" end;
    "# The decision log for \(.project // "this work")",
    "",
    "These are the person'"'"'s decisions, folded from an append-only log: what stands now. Work within them.",
    "- Direction says where the work is going; constraints are musts; open lines are deliberately undecided: do not settle them yourself.",
    "- When a choice is a judgment call (a tradeoff the person would care about, hard to reverse, or nothing below covers it), call the smudgenix_ask tool with the question, two or three one-line options and your pick, then stop and end your turn: the answer comes back to you.",
    "- A small, reversible call within the direction and constraints: make it, and record it with smudgenix_decide (provisional until the person confirms it). If it would break a constraint, ask instead.",
    "- Never write decisions into files, plans or commit bodies: the log is where they live.",
    "",
    items("direction"; "Direction"), items("constraint"; "Constraints"), items("decision"; "Decisions"), items("open"; "Open, on purpose"),
    (if .briefs == [] then empty else "Asked, waiting on the person (do not decide these yourself):", (.briefs[] | "- \(.question) [\(.id)]"), "" end),
    (if .current == [] then "Nothing is decided yet for this project." else empty end)' <<<"$folded"
  if [ -n "${2:-}" ] && [ -f "$(thread_file "$2")" ]; then
    cat <<'EOF'

# Your stack

You work in a workspace of your own: your work becomes a stack of layers (one jj change each) that the person reviews from the bottom, and that land on their trunk as they approve them.
- Commit each layer with the smudgenix_commit tool, with its purpose as a short commit title (72 characters at most; no attribution, no body). One purpose per layer.
- Every layer must be safe to land on its own: it builds, its tests pass, nothing half-done (behind a flag if it must be).
- Put the least controversial layers first (groundwork, refactors, mechanical changes), and the ones that need the person's judgment last, so the rest can land while they think.
- To change a layer that isn't accepted yet, call smudgenix_revise with it, change the files, then smudgenix_commit: it goes into that layer, and the ones above restack on it.
- Don't run git commit, git push, git rebase or jj commands that change history: they're refused here. smudgenix_stack shows the stack; git diff and git log work.
EOF
    echo; NO_COLOR=1 stack_show "$2" 2>/dev/null || true
  fi
}

# --- verify: evidence, not claims ----------------------------------------------

# (A change to a task, under the store's lock: watch, review and other
# verifies write it too.)
amend_task() {
  local id=$1 filter=$2
  shift 2
  mkdir -p "$tasks_dir"
  (
    flock 9
    task=$(jq -c "$@" "$filter" "$tasks_dir/$id/task.json") && save_task "$task"
  ) 9>"$tasks_dir/.lock"
}

# A project's check, as its files suggest: a fresh copy has no dependencies
# installed, so those that need them install them first.
guess_check() {
  local dir=$1
  if [ -f "$dir/flake.nix" ]; then
    echo "nix flake check"
  elif [ -f "$dir/package.json" ] && jq -e '.scripts.test // empty' "$dir/package.json" >/dev/null 2>&1; then
    if [ -f "$dir/pnpm-lock.yaml" ]; then echo "pnpm install --frozen-lockfile && pnpm test"
    elif [ -f "$dir/yarn.lock" ]; then echo "yarn install --frozen-lockfile && yarn test"
    elif [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then echo "bun install --frozen-lockfile && bun run test"
    elif [ -f "$dir/package-lock.json" ]; then echo "npm ci && npm test"
    else echo "npm install && npm test"
    fi
  elif [ -f "$dir/Cargo.toml" ]; then
    echo "cargo test"
  elif [ -f "$dir/go.mod" ]; then
    echo "go test ./..."
  elif [ -f "$dir/Makefile" ] && grep -qE '^check:' "$dir/Makefile"; then
    echo "make check"
  elif [ -f "$dir/Makefile" ] && grep -qE '^test:' "$dir/Makefile"; then
    echo "make test"
  elif [ -f "$dir/pyproject.toml" ] || [ -f "$dir/pytest.ini" ]; then
    echo "python -m pytest"
  else
    return 1
  fi
}

# verify: runs the project's check on exactly what's in review (its frozen
# revision, in a fresh copy, in agents' sandbox: it's their code), and
# records the outcome and its log on the task: evidence, by smx ai, kept apart
# from what the agent says. The check is what you last gave the project
# (--command, remembered), else what its files suggest.
verify() {
  local id="" command="" json="" task last repo project round candidate checks work log check_id started status
  local usage="usage: smx ai verify <task> [--command \"<check>\"] [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command) command=${2:-}; shift; [ -n "$command" ] || die "$usage" ;;
      --json) json=1 ;;
      -*) die "$usage" ;;
      *) [ -z "$id" ] || die "$usage"; id=$1 ;;
    esac
    shift
  done
  [ -n "$id" ] || die "$usage"
  task=$(task_json "$id")
  last=$(jq -c '.rounds | last // empty' <<<"$task")
  [ -n "$last" ] || die "$id has nothing in review to verify"
  repo=$(jq -r .dir <<<"$task") project=$(jq -r '.project // "unknown"' <<<"$task")
  round=$(jq -r .round <<<"$last") candidate=$(jq -r .candidate <<<"$last")
  [ -d "$repo" ] || die "no repository $repo" 4

  # (A copy that shares the repository's objects, read-only, and has its own
  # everything else: nothing the check does reaches the repository.)
  work=$(mktemp -d "${TMPDIR:-/tmp}/smx-ai-verify.XXXXXX")
  trap 'rm -rf "${work:-}"' EXIT
  trap 'exit 130' INT TERM
  if ! git clone -q --shared --no-checkout "$repo" "$work/copy" 2>/dev/null \
    || ! git -C "$work/copy" -c advice.detachedHead=false checkout -q --detach "$candidate" 2>/dev/null; then
    rm -rf "$work"
    die "couldn't check out $candidate (round $round) from $repo"
  fi
  checks="$(dirname "$tasks_dir")/checks"
  if [ -n "$command" ]; then
    mkdir -p "$checks"
    printf '%s\n' "$command" >"$checks/$project"
  elif [ -s "$checks/$project" ]; then
    command=$(cat "$checks/$project")
  elif ! command=$(guess_check "$work/copy"); then
    rm -rf "$work"
    die "no check found for $project: give it one (it's remembered) with smx ai verify $id --command \"<check>\""
  fi

  started=$(now_ms)
  check_id="chk_$started"
  log="$tasks_dir/$id/$check_id.log"
  # shellcheck disable=SC2016 # (jq's variables)
  amend_task "$id" '.rounds |= map(if .round == $r then .evidence = ((.evidence // []) + [{id: $c, kind: "check",
      by: "smx ai", command: $cmd, candidate: $cand, started: $s, pid: $pid, log: $log, exit: null}]) else . end)' \
    --argjson r "$round" --arg c "$check_id" --arg cmd "$command" --arg cand "$candidate" \
    --argjson s "$started" --argjson pid "$$" --arg log "$log"
  [ -n "$json" ] || echo "${D}Checking round $round (${candidate:0:12}), a fresh copy, sandboxed:${N} $command"

  run_check() (
    cd "$work/copy" || exit 1
    if [ -n "$sandbox" ]; then SMX_AI_SHELL=bash exec "$sandbox" -c "$command"; else exec bash -c "$command"; fi
  )
  status=0
  if [ -z "$json" ] && [ -t 1 ]; then
    run_check 2>&1 </dev/null | tee "$log" || status=${PIPESTATUS[0]}
  else
    run_check >"$log" 2>&1 </dev/null || status=$?
  fi
  rm -rf "$work"
  trap - EXIT INT TERM
  # shellcheck disable=SC2016 # (jq's variables)
  amend_task "$id" '.rounds |= map(if .round == $r then .evidence |= map(if .id == $c then . + {exit: $x, finished: $f} | del(.pid) else . end) else . end)
    | .updated = $f' --argjson r "$round" --arg c "$check_id" --argjson x "$status" --argjson f "$(now_ms)"

  local took=$((($(now_ms) - started) / 1000))
  took=$([ "$took" -ge 60 ] && echo "$((took / 60))m $((took % 60))s" || echo "${took}s")
  if [ -n "$json" ]; then
    jq -cn --arg c "$check_id" --arg cmd "$command" --argjson x "$status" --arg log "$log" '{v: 1, id: $c, command: $cmd, exit: $x, log: $log}'
  elif [ "$status" -eq 0 ]; then
    echo "${G}✓${N} Passed: $command ${D}($took, on ${candidate:0:12}; its log: $log)${N}"
  fi
  [ "$status" -eq 0 ] || die "the check failed (exit $status, after $took): $command; its log: $log"
}

# --- stacks: a thread's work, as layers ----------------------------------------

# A thread in a repository works in its own jj workspace (a git worktree too),
# in smudgenix's store, off your trunk: its work, a stack of layers (one jj
# change each, each safe to land), that you review from the bottom, and that
# land on your trunk as you approve them. Your checkout stays yours, and git's:
# jj's repository is in the store, backed by your repository's git.
#
# Agents' commands can't change history (their sandbox has the store and your
# repository's git read-only); smudgenix's OpenCode plugin commits, revises and
# shows layers for them (stack commit|revise|show), so its rules are kept.
stacks_dir="$(dirname "$tasks_dir")/stacks"
threads_dir="$(dirname "$tasks_dir")/threads"

# jj, quiet, as you (your repository's git identity), never paging.
jjr() {
  "$jj" --no-pager --color=never --quiet \
    --config "user.name=$(git -C "$repo" config user.name 2>/dev/null || echo smx)" \
    --config "user.email=$(git -C "$repo" config user.email 2>/dev/null || echo smx@localhost)" "$@"
}

# A repository's trunk: its remote's default branch, else main or master, else
# the branch it's on.
trunk_of() {
  local head
  if head=$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then echo "${head#origin/}"; return; fi
  for head in main master; do
    git -C "$1" show-ref --verify --quiet "refs/heads/$head" && { echo "$head"; return; }
  done
  git -C "$1" branch --show-current
}

thread_file() { echo "$threads_dir/$1.json"; }
thread_json() {
  [ -f "$(thread_file "$1")" ] || die "$1 has no stack (only threads started in a repository with smx ai new do)" 4
  cat "$(thread_file "$1")"
}
save_thread() {
  mkdir -p "$threads_dir"
  jq . <<<"$2" >"$(thread_file "$1").new" && mv "$(thread_file "$1").new" "$(thread_file "$1")"
}

# A workspace for a new thread in a repository, off its trunk (its jj
# repository made first, if it's the first): prints {jj, workspace, trunk}.
stack_create() {
  local repo=$1 common key jjrepo trunk name ws
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
  key="$(basename "$repo")-$(printf '%s' "$repo" | sha256sum | cut -c1-8)"
  jjrepo="$stacks_dir/$key/repo"
  if [ ! -d "$jjrepo/.jj" ]; then
    mkdir -p "$stacks_dir/$key"
    jjr git init --git-repo "$common" "$jjrepo" >/dev/null 2>&1 || die "couldn't make a jj repository for $repo"
  fi
  trunk=$(trunk_of "$repo")
  [ -n "$trunk" ] || die "$repo has no branch to work from"
  jjr -R "$jjrepo" git import >/dev/null 2>&1 || true
  name="t$(date +%Y%m%d%H%M%S)$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  ws="$stacks_dir/$key/$name"
  jjr -R "$jjrepo" workspace add --colocate --name "$name" -r "$(git -C "$repo" rev-parse "refs/heads/$trunk")" "$ws" >/dev/null 2>&1 \
    || die "couldn't make a workspace for the thread in $stacks_dir/$key"
  jq -cn --arg j "$jjrepo" --arg w "$ws" --arg t "$trunk" --arg n "$name" '{jj: $j, workspace: $w, trunk: $t, name: $n}'
}

# A thread's stack: its layers, bottom first, and what's not committed yet.
stack_view() {
  local thread repo ws trunk layers accepted
  thread=$(thread_json "$1")
  repo=$(jq -r .repo <<<"$thread") ws=$(jq -r .workspace <<<"$thread") trunk=$(jq -r .trunk <<<"$thread")
  [ -d "$ws" ] || die "its workspace is gone ($ws)" 4
  jjr -R "$ws" git import >/dev/null 2>&1 || true
  # shellcheck disable=SC2016 # (jj's template)
  layers=$(jjr -R "$ws" log --no-graph --reversed -r "(::@ ~ ::$trunk)::" \
    -T '"{\"c\":" ++ json(self) ++ ",\"empty\":" ++ json(empty) ++ ",\"conflict\":" ++ json(conflict) ++ ",\"wc\":" ++ json(current_working_copy) ++ "}\n"' 2>/dev/null) \
    || die "couldn't read the stack in $ws"
  accepted=$(jq -c '.accepted // []' <<<"$thread")
  jq -cs --argjson thread "$thread" --argjson accepted "$accepted" --arg repo "$repo" '
    map({change: .c.change_id, commit: .c.commit_id, title: (.c.description | split("\n")[0]),
         empty, conflict, working: .wc})
    | (map(select(.working | not)) | to_entries | map(.value + {layer: (.key + 1)})) as $layers
    | (map(select(.working)) | first) as $wc
    | {v: 1, session: $thread.session, project: $thread.project, repo: $repo, trunk: $thread.trunk,
       workspace: $thread.workspace, revising: ($thread.revising // null),
       layers: [$layers[] | . + {state: (if .change | IN($accepted[]) then "accepted" else "to review" end)}],
       uncommitted: ($wc != null and ($wc.empty | not))}' <<<"$layers"
}

# A layer's diff (git's format), by its number or change id.
layer_of() {
  jq -c --arg l "$2" '.layers[] | select((.layer | tostring) == $l or (.change | startswith($l)))' <<<"$1" | head -1
}

# stack: a thread's layers (or, with a verb, what smudgenix's OpenCode plugin
# does for its agent: commit, revise, show).
stack_command() {
  local verb=${1:-}
  case "$verb" in
    commit) shift; stack_commit "$@" ;;
    revise) shift; stack_revise "$@" ;;
    diff) shift; stack_diff "$@" ;;
    "" | -*) die "usage: smx ai stack <session> [--json] | stack diff <session> <layer>" ;;
    *) stack_show "$@" ;;
  esac
}

stack_show() {
  local session=$1 json="" view
  [ "${2:-}" != --json ] || json=1
  view=$(stack_view "$session")
  if [ -n "$json" ]; then echo "$view"; return; fi
  jq -r --arg D "$D" --arg N "$N" --arg G "$G" --arg Y "$Y" --arg R "$R" '
    "\($D)on \(.trunk), in \(.workspace)\($N)",
    (if .layers == [] then "\($D)No layers yet.\($N)" else empty end),
    (.layers[] | "  \(.layer). \(.title | if . == "" then "(no purpose given)" else . end)"
      + (if .state == "accepted" then "  \($G)accepted\($N)" else "" end)
      + (if .conflict then "  \($R)conflicted\($N)" else "" end)
      + (if .empty then "  \($Y)empty\($N)" else "" end)
      + "  \($D)\(.change[0:8])\($N)"),
    (if .revising then "\($Y)Revising layer \(.revising[0:8]).\($N)" else empty end),
    (if .uncommitted then "\($D)And changes not committed yet.\($N)" else empty end)' <<<"$view"
}

stack_diff() {
  local session=${1:-} which=${2:-} view layer thread
  [ -n "$session" ] && [ -n "$which" ] || die "usage: smx ai stack diff <session> <layer>"
  view=$(stack_view "$session")
  layer=$(layer_of "$view" "$which")
  [ -n "$layer" ] || die "no layer $which" 4
  thread=$(thread_json "$session") repo=$(jq -r .repo <<<"$thread")
  jjr -R "$(jq -r .workspace <<<"$thread")" diff --git --ignore-working-copy -r "$(jq -r .change <<<"$layer")"
}

# (A purpose is a commit's title: one line, short, and nobody's attribution.)
purpose_ok() {
  one_line "the purpose" "$1"
  [ "${#1}" -le 72 ] || die "the purpose is ${#1} characters: say it in 72 or fewer, as a commit title"
  ! grep -qiE 'co-authored-by|generated (with|by)|signed-off-by' <<<"$1" || die "no attribution in a purpose: say what the layer is for"
}

# commit: what the agent's changed, as a new layer on top, with its purpose;
# or, revising a layer, into it (the layers above restack on it).
stack_commit() {
  local session="" purpose="" thread repo ws target top view
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) session=${2:-}; shift ;;
      *) [ -z "$purpose" ] || die "usage: smx ai stack commit --session <session> \"<purpose>\""; purpose=$1 ;;
    esac
    shift
  done
  [ -n "$session" ] || die "usage: smx ai stack commit --session <session> \"<purpose>\""
  thread=$(thread_json "$session")
  repo=$(jq -r .repo <<<"$thread") ws=$(jq -r .workspace <<<"$thread") target=$(jq -r '.revising // empty' <<<"$thread")
  [ -n "$(jjr -R "$ws" diff --summary -r @)" ] || die "nothing's changed since the last layer: nothing to commit"
  if [ -n "$target" ]; then
    # (Into the layer being revised; then back to the top.)
    if [ -n "$purpose" ]; then purpose_ok "$purpose"; jjr -R "$ws" squash --from @ --into "$target" -m "$purpose" >/dev/null
    else jjr -R "$ws" squash --from @ --into "$target" -u >/dev/null; fi
    top=$(jjr -R "$ws" log --no-graph -r "heads((::$target | $target::) ~ ::$(jq -r .trunk <<<"$thread")) ~ @" -T 'change_id ++ "\n"' | head -1)
    jjr -R "$ws" new "${top:-$target}" >/dev/null
    save_thread "$session" "$(jq -c 'del(.revising)' <<<"$thread")"
  else
    purpose_ok "$purpose"
    jjr -R "$ws" commit -m "$purpose" >/dev/null
  fi
  view=$(stack_view "$session")
  if [ -n "$target" ]; then
    jq -c --arg t "$target" '{v: 1, revised: (.layers[] | select(.change == $t)), conflicted: [.layers[] | select(.conflict) | .layer], layers: (.layers | length)}' <<<"$view"
  else
    jq -c '{v: 1, committed: .layers[-1], layers: (.layers | length)}' <<<"$view"
  fi
}

# revise: start changing a layer (one not accepted yet): what's committed next
# goes into it.
stack_revise() {
  local session="" which="" thread ws view layer
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) session=${2:-}; shift ;;
      *) which=$1 ;;
    esac
    shift
  done
  [ -n "$session" ] && [ -n "$which" ] || die "usage: smx ai stack revise --session <session> <layer>"
  thread=$(thread_json "$session") repo=$(jq -r .repo <<<"$thread") ws=$(jq -r .workspace <<<"$thread")
  view=$(stack_view "$session")
  layer=$(layer_of "$view" "$which")
  [ -n "$layer" ] || die "no layer $which" 4
  [ "$(jq -r .state <<<"$layer")" != accepted ] || die "layer $which is accepted: only its person changes it now"
  [ "$(jq -r .uncommitted <<<"$view")" = false ] || die "commit (or undo) what's changed first: it'd go into layer $which"
  jjr -R "$ws" new "$(jq -r .change <<<"$layer")" >/dev/null
  save_thread "$session" "$(jq -c --arg c "$(jq -r .change <<<"$layer")" '.revising = $c' <<<"$thread")"
  jq -c '{v: 1, revising: .}' <<<"$layer"
}

# land: your trunk, fast-forwarded to a layer (and so every layer below it),
# in your checkout if it's on it (as git would: your uncommitted work stays);
# the stack, rebased onto your trunk first if it's moved on.
land_command() {
  local session=${1:-} which=${2:-} thread repo ws trunk view layer commit branch head
  [ -n "$session" ] && [ -n "$which" ] || die "usage: smx ai land <session> <layer>"
  thread=$(thread_json "$session") repo=$(jq -r .repo <<<"$thread") ws=$(jq -r .workspace <<<"$thread") trunk=$(jq -r .trunk <<<"$thread")
  view=$(stack_view "$session")
  layer=$(layer_of "$view" "$which")
  [ -n "$layer" ] || die "no layer $which" 4
  [ "$(jq -r .conflict <<<"$layer")" = false ] || die "layer $which is conflicted: it can't land"
  # (Not with its own calls unsettled: approving never decides for you.)
  local unsettled
  unsettled=$(fold | jq -r --argjson upto "$(jq -c '[.layers[] | select(.layer <= ($l | tonumber)) | .change]' --arg l "$(jq -r .layer <<<"$layer")" <<<"$view")" \
    '[.current[] | select(.provisional and .layer != null and (.layer | IN($upto[])))] | map("\(.id) \(.text)") | join("; ")')
  [ -z "$unsettled" ] || die "these calls made in it are still provisional: $unsettled (confirm, replace or withdraw them first)"

  head=$(git -C "$repo" rev-parse "refs/heads/$trunk")
  commit=$(jq -r .commit <<<"$layer")
  if ! git -C "$repo" merge-base --is-ancestor "$head" "$commit"; then
    # (Your trunk's moved on: the stack goes onto it, then lands if it's clean.)
    jjr -R "$ws" rebase -s "roots((::@ ~ ::$trunk)::)" -d "$trunk" >/dev/null 2>&1 || die "couldn't rebase the stack onto $trunk"
    view=$(stack_view "$session")
    layer=$(layer_of "$view" "$(jq -r .change <<<"$layer")")
    [ "$(jq -r .conflict <<<"$layer")" = false ] || die "$trunk has moved on, and the stack conflicts with it now: it's rebased; the agent can fix it"
    commit=$(jq -r .commit <<<"$layer")
  fi
  branch=$(git -C "$repo" branch --show-current)
  if [ "$branch" = "$trunk" ]; then
    git -C "$repo" merge -q --ff-only "$commit" 2>/dev/null \
      || die "couldn't fast-forward your $trunk (in $repo) to it: it'd overwrite uncommitted changes there"
  else
    git -C "$repo" update-ref "refs/heads/$trunk" "$commit" "$head"
  fi
  jjr -R "$ws" git import >/dev/null 2>&1 || true
  save_thread "$session" "$(jq -c --argjson l "$(jq -c '[.layers[] | select(.layer <= ($n | tonumber)) | {change, commit, title}]' --arg n "$(jq -r .layer <<<"$layer")" <<<"$view")" \
    --argjson t "$(now_ms)" '.landed = ((.landed // []) + [$l[] | . + {at: $t}])' <<<"$thread")"
  echo "${G}✓${N} Landed on $trunk, up to: $(jq -r .title <<<"$layer") ${D}(${commit:0:12})${N}"
}

# --- threads: new, reply, close, park, context --------------------------------

# (A session's task that's still open: not accepted, discarded or closed.)
open_task_of() {
  local file
  for file in "$tasks_dir"/*/task.json; do
    [ -f "$file" ] || continue
    jq -ce --arg s "$1" 'select(.session == $s and (.state | IN("accepted", "discarded") | not))' "$file" && return
  done
  return 1
}

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
  # (In a repository: in a workspace of its own, its work a stack of layers;
  # never editing your checkout.)
  local repo stack="" body
  body=$(jq -cn --arg d "$dir" '{location: {directory: $d}}')
  if repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    stack=$(stack_create "$repo")
    body=$(jq -cn --arg d "$(jq -r .workspace <<<"$stack")" --arg r "$repo" \
      '{location: {directory: $d}, permissions: [{action: "edit", resource: ($r + "/**"), effect: "deny"}]}')
  fi
  session=$(server_curl -sf --max-time 15 -X POST -H 'Content-Type: application/json' \
    -d "$body" "$(server_url)/api/session" \
    | jq -r '.data.id // .id // empty') || true
  [ -n "$session" ] || die "couldn't start a session in $dir"
  if [ -n "$stack" ]; then
    save_thread "$session" "$(jq -c --arg s "$session" --arg r "$repo" --arg p "$(project_of "$repo")" --argjson t "$(now_ms)" \
      '{v: 1, session: $s, repo: $r, project: $p, created: $t} + .' <<<"$stack")"
    dir=$(jq -r .workspace <<<"$stack")
    # (What you asked for, if it's a line, is where the thread's going.)
    case "$prompt" in *$'\n'*) ;; *) [ "${#prompt}" -gt 200 ] || decide_command "$prompt" --kind direction --thread "$session" --project "$(project_of "$repo")" --json >/dev/null ;; esac
  fi
  prompt_session "$session" "$prompt" || die "couldn't give session $session its prompt"
  if [ -n "$json" ]; then
    jq -cn --arg s "$session" --arg d "$dir" '{v: 1, session: $s, dir: $d}'
  else
    echo "${G}✓${N} Started, in the background: $session ${D}($dir)${N}"
  fi
  [ -z "$tui" ] || open_session "$session"
}

# reply: tells a thread more (it goes back to work).
reply() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$#" -eq 2 ] || die "usage: smx ai reply <session> \"<what to say>\""
  need_server
  server_get "/api/session/$1" >/dev/null || die "no session $1" 4
  prompt_session "$1" "$2" || die "couldn't send it to session $1"
  echo "${G}✓${N} Sent: it's back at work."
}

# park: not now: it's seen (so not news), and its review deferred.
park() {
  local session=${1:-} sess task
  [ -n "$session" ] && [ "$#" -eq 1 ] || die "usage: smx ai park <session>"
  need_server
  sess=$(server_get "/api/session/$session" | jq -c '.data // empty') || true
  [ -n "$sess" ] || die "no session $session" 4
  if [ "$(jq '(.time.busy // 0) > (.time.idle // 0)' <<<"$sess")" = true ]; then
    echo "${D}Nothing to do: it's at work, and comes back when it's done.${N}"
    return
  fi
  server_curl -sf --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson i "$(jq '.time.idle // 0' <<<"$sess")" '{idle: $i}')" \
    "$(server_url)/api/session/$session/view" >/dev/null || die "couldn't park session $session"
  if task=$(open_task_of "$session"); then
    save_task "$(jq -c --argjson now "$(now_ms)" '.state = "deferred" | .updated = $now' <<<"$task")"
  fi
  echo "${D}Parked: $(jq -r '.title // .id' <<<"$sess")${N}"
}

# close: ends a thread (OpenCode archives its session). Work waiting for
# review needs a decision first: --accept it, or --discard the review (the
# changes stay as they are either way; nothing's undone).
close_thread() {
  local session="" decision="" sess task
  local usage="usage: smx ai close <session> [--accept | --discard]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --accept | --discard) decision=${1#--} ;;
      -*) die "$usage" ;;
      *) session=$1 ;;
    esac
    shift
  done
  [ -n "$session" ] || die "$usage"
  need_server
  sess=$(server_get "/api/session/$session" | jq -c '.data // empty') || true
  [ -n "$sess" ] || die "no session $session" 4
  if task=$(open_task_of "$session"); then
    case "$decision" in
      accept) settle accept "$(jq -r .id <<<"$task")" >/dev/null ;;
      discard) save_task "$(jq -c --argjson now "$(now_ms)" '.state = "discarded" | .updated = $now' <<<"$task")" ;;
      *) die "$(jq -r .title <<<"$task") has work waiting for review: close it with --accept or --discard" ;;
    esac
  fi
  if [ "$(jq -r '.time.archived // empty' <<<"$sess")" != "" ]; then
    echo "${D}Nothing to do: it's closed already.${N}"
    return
  fi
  server_curl -sf --max-time 10 -X PATCH -H 'Content-Type: application/json' -d '{"archived": true}' \
    "$(server_url)/api/session/$session" >/dev/null || die "couldn't close session $session"
  echo "${G}✓${N} Closed: $(jq -r '.title // .id' <<<"$sess")${decision:+ (${decision}ed)}"
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

# --- history ------------------------------------------------------------------

# history: your threads, day by day, closed ones too (without reopening
# them): when, where, how they ended, and what they cost.
history_command() {
  local days=7 since="" project="" json="" since_ms work page cursor="" dir
  local usage="usage: smx ai history [--days <n> | --since <date>] [--project <name>] [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) days=${2:-}; shift; [[ "$days" =~ ^[1-9][0-9]*$ ]] || die "$usage" ;;
      --since) since=${2:-}; shift; [ -n "$since" ] || die "$usage" ;;
      --project) project=${2:-}; shift; [ -n "$project" ] || die "$usage" ;;
      --json) json=1 ;;
      *) die "$usage" ;;
    esac
    shift
  done
  if [ -n "$since" ]; then
    since_ms=$(date -d "$since" +%s 2>/dev/null) || die "not a date: $since"
  else
    since_ms=$(date -d "$(date +%F) -$((days - 1)) days" +%s)
  fi
  since_ms=$((since_ms * 1000))
  need_server
  work=$(mktemp -d)
  # (Newest-updated first: a thread started since then was updated since.)
  while :; do
    page=$(server_get "/api/session?limit=100${cursor:+&cursor=$cursor}") || { rm -rf "$work"; die "couldn't list sessions"; }
    jq -c '.data[]' <<<"$page" >>"$work/sessions"
    [ "$(jq --argjson s "$since_ms" '.data | length > 0 and (map(.time.updated) | min) >= $s' <<<"$page")" = true ] || break
    cursor=$(jq -r '.cursor.next // empty' <<<"$page")
    [ -n "$cursor" ] || break
  done
  jq -r '.location.directory // empty' "$work/sessions" | sort -u | while IFS= read -r dir; do
    printf '%s\t%s\n' "$dir" "$(project_of "$dir")"
  done | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' >"$work/projects"
  for dir in "$tasks_dir"/*/task.json; do [ -f "$dir" ] && cat "$dir"; done | jq -cs . >"$work/tasks"
  jq -s . "$work/sessions" >"$work/all"
  jq -c -n --argjson since "$since_ms" --arg p "$project" \
    --slurpfile s "$work/all" --slurpfile pr "$work/projects" --slurpfile t "$work/tasks" \
    '{since: $since, sessions: $s[0], projects: $pr[0], tasks: $t[0]}' >"$work/in"
  jq -c --arg p "$project" -f "$history_filter" "$work/in" \
    | jq -c --arg p "$project" 'if $p == "" then . else .threads |= map(select(.project == $p)) end' >"$work/out"
  if [ -n "$json" ]; then cat "$work/out"; rm -rf "$work"; return; fi
  jq -r --arg A "$A" --arg D "$D" --arg G "$G" --arg Y "$Y" --arg N "$N" --arg p "$project" '
    def secs: . / 1000 | floor;
    def day: secs | strflocaltime("%a %-d %b");
    def clock: secs | strflocaltime("%H:%M");
    def money: if . == 0 then null else (. * 100 | round) as $c
      | "$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)" end;
    def count: if . >= 1000000 then "\(. / 100000 | round / 10)M" elif . >= 1000 then "\(. / 1000 | round)k" else tostring end;
    def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
    def totals: [plural(length; "thread"),
      (([.[].tokens] | add) as $t | if $t > 0 then "\($t | count) tokens" else empty end),
      ([.[].cost] | add | money // empty)] | join(" · ");
    def outcome: {"in-review": "in review", revising: "revising", deferred: "parked, to review",
      accepted: "accepted", discarded: "review discarded"}[.state] // .state;
    def span: (.created | clock) as $from | (.updated | clock) as $to
      | if (.created | secs | strflocaltime("%F")) != (.updated | secs | strflocaltime("%F"))
        then "\($from)–\(.updated | day) \($to)"
        elif $from == $to then "\($from)      " else "\($from)–\($to)" end;
    .threads as $all
    | if $all == [] then "\($D)No threads since \(.since | day)\(if $p == "" then "" else " in \($p)" end).\($N)"
      else
        ($all | group_by(.created | secs | strflocaltime("%F")) | reverse[]
         | sort_by(-.created)
         | "\($A)\(.[0].created | day)\($N)  \($D)\(totals)\($N)",
           (.[] | "  \(span)  \(.title // "(untitled)")\(if $p == "" and .project then "  \($A)\(.project)\($N)" else "" end)",
             "               \($D)\([
               (if .state == "at work" then "\($Y)at work\($D)" elif .state == "closed" then "closed" else "\($N)open\($D)" end),
               (.task | if . then outcome + (if .rounds > 1 then " (\(.rounds) rounds)" else "" end) else empty end),
               (if .subagents > 0 then plural(.subagents; "subagent") else empty end),
               (if .tokens > 0 then "\(.tokens | count) tokens" else empty end),
               (.cost | money // empty),
               (.model // empty)] | join(" · "))\($N)"),
           ""),
        "\($D)Since \(.since | day): \($all | totals), \($all | map(select(.state == "closed")) | length) closed\($N)"
      end' "$work/out"
  rm -rf "$work"
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
  allow) shift; allow "$@" ;;
  deny) shift; [ "$#" -le 1 ] || die "usage: smx ai deny <request>"; answer deny reject "${1:-}" ;;
  allowed) shift; allowed "$@" ;;
  review) shift; review "$@" ;;
  task) shift; task_command "$@" ;;
  diff) shift; diff_command "$@" ;;
  accept) shift; [ "$#" -le 1 ] || die "usage: smx ai accept <task>"; settle accept "${1:-}" ;;
  revise) shift; [ "$#" -le 2 ] || die "usage: smx ai revise <task> \"<what to change>\""; settle revise "${1:-}" "${2:-}" ;;
  defer) shift; [ "$#" -le 1 ] || die "usage: smx ai defer <task>"; settle defer "${1:-}" ;;
  verify) shift; verify "$@" ;;
  decide) shift; decide_command "$@" ;;
  reopen) shift; reopen_command "$@" ;;
  confirm) shift; confirm_command "$@" ;;
  withdraw) shift; withdraw_command "$@" ;;
  log) shift; log_command "$@" ;;
  ask) shift; ask_command "$@" ;;
  stack) shift; stack_command "$@" ;;
  land) shift; land_command "$@" ;;
  new) shift; new_thread "$@" ;;
  reply) shift; reply "$@" ;;
  park) shift; park "$@" ;;
  close) shift; close_thread "$@" ;;
  context) shift; context "$@" ;;
  history) shift; history_command "$@" ;;
  "" | help | -h | --help) usage ;;
  *) say "unknown command '$1'"; usage >&2; exit 1 ;;
esac
