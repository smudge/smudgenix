# smx ai's decision log, folded: what's decided now (for a project, or
# everything), and the log itself annotated with what replaced what.
#
# The log is append-only, and only yours (what you write with smx ai decide).
# An entry is one of:
#   direction | constraint | decision | open   (a line of judgment; `ref`, if
#                                              any, is the entry it replaces)
#   withdraw                                   (`ref`: no longer stands, and
#                                              nothing replaces it)
# with {id, time, kind, scope: you|project, project, text, why, by: you}.
# (Older logs have agents' calls and threads' lines, written for you; they're
# left out, as are confirmations of agents' calls.)
#
# In: {entries: [...], project: <name>|null}. Deterministic: no clock.

def lines: ["direction", "constraint", "decision", "open"];

def inscope($project): $project == null or .scope == "you" or .project == $project;

.project as $project
| [(.entries // [])[] | select(.by != "agent" and .scope != "thread" and .kind != "confirm")] as $entries
| ($entries | map({key: .id, value: .}) | from_entries) as $byid
| ($entries | map(select(.ref != null)) | map({key: .ref, value: {id, kind}}) | from_entries) as $replaced
| def annotated:
    . + (if $replaced[.id] then
           {status: (if $replaced[.id].kind == "withdraw" then "withdrawn"
                     elif $replaced[.id].kind == "open" and .kind != "open" then "reopened"
                     else "replaced" end),
            by_entry: $replaced[.id].id}
         else {status: "current"} end);
  ($entries | map(select(.kind != "withdraw" or $byid[.ref] != null)
                  | if .kind == "withdraw" then . + {scope: $byid[.ref].scope, project: $byid[.ref].project, target: $byid[.ref].text} else . end)
            | map(select(inscope($project)))) as $scoped
| {v: 1, project: $project,
   current: [$scoped[] | select(.kind | IN(lines[])) | annotated | select(.status == "current")],
   log: [$scoped[] | if .kind | IN(lines[]) then annotated else . end] | sort_by(-.time)}
