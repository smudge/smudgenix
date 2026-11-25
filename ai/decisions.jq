# smx ai's decision log, folded: what's decided now (for a project, a
# thread, or everything), the log itself annotated with what replaced what,
# and the questions agents asked that nothing has answered yet.
#
# The log is append-only. An entry is one of:
#   direction | constraint | decision | open   (a line of judgment; `ref`, if
#                                              any, is the entry it replaces)
#   confirm                                    (`ref`: an agent's provisional
#                                              line, now yours)
#   withdraw                                   (`ref`: no longer stands, and
#                                              nothing replaces it)
# with {id, time, kind, scope: you|project|thread, project, thread, text,
# why, by: you|agent, session, check, answers: <brief id>}.
#
# In: {entries: [...], briefs: [...], project: <name>|null, thread:
# <session>|null}. Deterministic: no clock.

def lines: ["direction", "constraint", "decision", "open"];

# (Thread lines belong to their project too; with a thread given, only its.)
def inscope($project; $thread):
  $project == null
  or .scope == "you"
  or (.project == $project
      and (.scope == "project" or $thread == null or .thread == $thread));

.project as $project | .thread as $thread
| (.entries // []) as $entries
| ($entries | map({key: .id, value: .}) | from_entries) as $byid
| ($entries | map(select(.ref != null and .kind != "confirm"))
   | map({key: .ref, value: {id, kind}}) | from_entries) as $replaced
| ($entries | map(select(.kind == "confirm") | .ref) | unique) as $confirmed
| ($entries | map(select(.answers != null) | {key: .answers, value: .id}) | from_entries) as $answered
| def annotated:
    . + {provisional: (.by == "agent" and (.id | IN($confirmed[]) | not))}
    + (if $replaced[.id] then
         {status: (if $replaced[.id].kind == "withdraw" then "withdrawn"
                   elif $replaced[.id].kind == "open" and .kind != "open" then "reopened"
                   else "replaced" end),
          by_entry: $replaced[.id].id}
       else {status: "current"} end);
  ($entries | map(if .ref and (.kind | IN("confirm", "withdraw")) then
                    . + {scope: $byid[.ref].scope, project: $byid[.ref].project,
                         thread: $byid[.ref].thread, target: $byid[.ref].text}
                  else . end)
            | map(select(inscope($project; $thread)))) as $scoped
| {v: 1, project: $project, thread: $thread,
   current: [$scoped[] | select(.kind | IN(lines[])) | annotated | select(.status == "current")],
   briefs: [(.briefs // [])[] | select(inscope($project; $thread)) | select($answered[.id] == null)],
   log: [$scoped[] | if .kind | IN(lines[]) then annotated else . end] | sort_by(-.time)}
