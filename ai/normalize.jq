# smx ai's normalizer: OpenCode's server events in (JSON lines, plus smx ai's
# own `smx.snapshot`, `smx.session` (one the snapshot didn't have, before its
# first event), `smx.tuis` (opencode's TUIs open now), `smx.tasks` and
# `smx.server`), smx ai's (v1) out:
#
#   {"v":1,"type":"snapshot","server":"up","sessions":[<session>…]}
#   {"v":1,"type":"session",<session>}      (whenever one changes)
#   {"v":1,"type":"removed","id":…}
#   {"v":1,"type":"server","state":"up"|"stopped"|"down"}
#   {"v":1,"type":"tasks","tasks":[<task>…]}   (smx ai's; see smx ai task --json)
#
# (Stopped: not running, as until something needs it. Down: it should be, but
# isn't reachable.)
#
# where <session> is {id, title, dir, project, parent, updated, last, about,
# open, terminals, state, unseen, permissions, forms}: its state is
# needs-permission, needs-input, working, done, failed or idle; unseen is
# whether it's finished since anyone last looked at it; updated is when (in
# ms) it last changed, or null; last is its latest reply, in a line, or null;
# about is what it's about (its latest compaction's objective), in a line, or
# null; open is whether a TUI shows it, and terminals the processes that TUI's
# on screen through (its terminal's among them), if any; and project is its
# repository's name, or null.
#
# A permission is {id, action, resources, save, cwd}: what it'd do (e.g.
# "shell" and the command, or "edit" and the files), the patterns allowing it
# "always" would save, and where it'd run (its session's folder, unless the
# call says otherwise); a form is {id, title}.
#
# A snapshot has the recent sessions (a few, any running or unseen, and those
# ones' subagents', whose parent is theirs).
#
#   jq -cn --unbuffered -f normalize.jq

def blank($id; $dir):
  {id: $id, title: null, dir: $dir, parent: null, running: false, outcome: "idle", unseen: false, updated: null, last: null, about: null, project: null, permissions: [], forms: []};

# The TUIs (of these) showing a session.
def tuis_on($tuis):
  . as $s
  | [$tuis[] | select(.id == $s.id
      or (.id == null and .title != null and $s.title != null
          and (.title as $t | if ($t | endswith("…")) then $s.title | startswith($t[:-1]) else $s.title == $t end)))];

def public($tuis):
  tuis_on($tuis) as $on
  | {id, title, dir, project, parent, updated, last, about,
   open: ($on | length > 0), terminals: ([$on[].seen[]] | unique),
   state: (if (.permissions | length) > 0 then "needs-permission"
           elif (.forms | length) > 0 then "needs-input"
           elif .running then "working"
           else .outcome end),
   unseen, permissions, forms};

# A reply, in a line: its whitespace and markup collapsed, cut short.
def summary:
  gsub("\\*\\*|`"; "") | gsub("(?<s>^|\\n)#+ (?<h>[^\\n]*?):?(?=\\n|$)"; "\(.s)\(.h):") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
  | if length > 240 then .[0:239] + "…" elif length == 0 then null else . end;

# A session as smx ai gives it (smx.snapshot, smx.session).
# What a session's about, from a compaction's summary: its "## Objective"
# (or else its first paragraph), in a line.
def objective:
  ((capture("(?s)(^|\\n)## Objective\\n+(?<o>.*?)(\\n## |$)").o) // (split("\n\n") | map(select(test("\\S"))) | first) // "")
  | gsub("(?<s>^|\\n)\\s*[-*] "; "\(.s)") | summary;

def taken:
  blank(.id; .dir) + . | .last |= (if type == "string" then summary else null end)
  | .about |= (if type == "string" then objective else null end);

def apply($e):
  if $e.type == "session.created" then
    .title = $e.data.title
    | .dir = ($e.data.location.directory // .dir)
    | .parent = ($e.data.parentID // null)
  elif $e.type == "session.renamed" then .title = $e.data.title
  elif $e.type == "session.text.ended" then .last = ($e.data.text | summary)
  elif $e.type == "session.compaction.ended" then .about = ($e.data.text | objective)
  elif $e.type == "session.execution.started" then .running = true | .unseen = false
  elif $e.type == "session.execution.succeeded" then .running = false | .outcome = "done" | .unseen = true
  elif $e.type == "session.execution.failed" then .running = false | .outcome = "failed" | .unseen = true
  elif $e.type == "session.execution.interrupted" then .running = false | .outcome = "idle"
  # (Seen in a client, e.g. the TUI.)
  elif $e.type == "session.viewed" then .unseen = false
  # (Asked again if a snapshot already had it.)
  elif $e.type == "permission.asked" then
    .dir as $dir
    | ($e.data | {id, action, resources, save: (.save // []), cwd: (.cwd // $dir)}) as $p
    | .permissions |= map(select(.id != $p.id)) + [$p]
  elif $e.type == "permission.replied" then
    .permissions |= map(select(.id != $e.data.requestID))
  elif $e.type == "form.created" then
    ($e.data.form | {id, title}) as $f
    | .forms |= map(select(.id != $f.id)) + [$f]
  elif $e.type == "form.replied" or $e.type == "form.cancelled" then
    .forms |= map(select(.id != $e.data.id))
  else . end;

def session_id($e): $e.data.sessionID // $e.data.form.sessionID // null;

foreach inputs as $e ({sessions: {}, tuis: [], emit: []};
  .emit = []
  | .tuis as $tuis
  | if $e.type == "smx.snapshot" then
      .sessions = ($e.sessions | map({key: .id, value: taken}) | from_entries)
      | .emit = [{v: 1, type: "snapshot", server: "up", sessions: [.sessions[] | public($tuis)]}]
    elif $e.type == "smx.session" then
      .sessions[$e.session.id] = ($e.session | taken)
      | .emit = [{v: 1, type: "session"} + (.sessions[$e.session.id] | public($tuis))]
    elif $e.type == "smx.tuis" then
      .tuis = $e.tuis
      | .emit = [.sessions[] | select(public($tuis) != public($e.tuis)) | {v: 1, type: "session"} + public($e.tuis)]
    elif $e.type == "smx.tasks" then
      .emit = [{v: 1, type: "tasks", tasks: $e.tasks}]
    elif $e.type == "smx.server" then
      .emit = [{v: 1, type: "server", state: $e.state}]
      | if $e.state != "up" then .sessions = {} else . end
    elif $e.type == "session.deleted" or $e.type == "session.archived" then
      session_id($e) as $id
      | if .sessions[$id] then .sessions |= del(.[$id]) | .emit = [{v: 1, type: "removed", id: $id}] else . end
    elif session_id($e) == null then .
    else
      session_id($e) as $id
      | (.sessions[$id] // blank($id; $e.location.directory)) as $before
      | ($before | apply($e)) as $changed
      | (if ($before | public($tuis) | del(.updated)) != ($changed | public($tuis) | del(.updated))
         then $changed | .updated = ($e.created // .updated) else $changed end) as $after
      | .sessions[$id] = $after
      | if ($before | public($tuis)) != ($after | public($tuis))
        then .emit = [{v: 1, type: "session"} + ($after | public($tuis))] else . end
    end;
  .emit[])
