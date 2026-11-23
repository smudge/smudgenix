# smx ai's normalizer: OpenCode's server events in (JSON lines, plus smx ai's
# own `smx.snapshot` and `smx.server`), smx ai's (v1) out:
#
#   {"v":1,"type":"snapshot","server":"up","sessions":[<session>…]}
#   {"v":1,"type":"session",<session>}      (whenever one changes)
#   {"v":1,"type":"removed","id":…}
#   {"v":1,"type":"server","state":"up"|"stopped"|"down"}
#
# (Stopped: not running, as until something needs it. Down: it should be, but
# isn't reachable.)
#
# where <session> is {id, title, dir, parent, state, unseen, permissions,
# forms}, its state is needs-permission, needs-input, working, done, failed or
# idle, and unseen is whether it's finished since anyone last looked at it.
#
#   jq -cn --unbuffered -f normalize.jq

def blank($id; $dir):
  {id: $id, title: null, dir: $dir, parent: null, running: false, outcome: "idle", unseen: false, permissions: [], forms: []};

def public:
  {id, title, dir, parent,
   state: (if (.permissions | length) > 0 then "needs-permission"
           elif (.forms | length) > 0 then "needs-input"
           elif .running then "working"
           else .outcome end),
   unseen, permissions, forms};

def apply($e):
  if $e.type == "session.created" then
    .title = $e.data.title
    | .dir = ($e.data.location.directory // .dir)
    | .parent = ($e.data.parentID // null)
  elif $e.type == "session.renamed" then .title = $e.data.title
  elif $e.type == "session.execution.started" then .running = true | .unseen = false
  elif $e.type == "session.execution.succeeded" then .running = false | .outcome = "done" | .unseen = true
  elif $e.type == "session.execution.failed" then .running = false | .outcome = "failed" | .unseen = true
  elif $e.type == "session.execution.interrupted" then .running = false | .outcome = "idle"
  # (Seen in a client, e.g. the TUI.)
  elif $e.type == "session.viewed" then .unseen = false
  # (Asked again if a snapshot already had it.)
  elif $e.type == "permission.asked" then
    ($e.data | {id, action, resources, save: (.save // [])}) as $p
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

foreach inputs as $e ({sessions: {}, emit: []};
  .emit = []
  | if $e.type == "smx.snapshot" then
      .sessions = ($e.sessions | map({key: .id, value: (blank(.id; .dir) + .)}) | from_entries)
      | .emit = [{v: 1, type: "snapshot", server: "up", sessions: [.sessions[] | public]}]
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
      | ($before | apply($e)) as $after
      | .sessions[$id] = $after
      | if ($before | public) != ($after | public)
        then .emit = [{v: 1, type: "session"} + ($after | public)] else . end
    end;
  .emit[])
