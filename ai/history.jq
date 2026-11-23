# smx ai history: your threads (top-level sessions, with their subagents)
# started since a time, newest first: when, where, how they ended (closed,
# and their review's outcome), and what they cost, subagents included.
#
# In: {since: <ms>, sessions: [OpenCode's sessions], projects: {<folder>:
# <project>}, tasks: [smx ai's tasks]}. (Deterministic: no clock, no
# time zone; `smx ai history` shows it.)

def subagents($kids; $id): [$kids[$id][]? | ., subagents($kids; .id)[]];

.since as $since | .projects as $projects
| (.tasks | group_by(.session)
   | map({key: .[0].session, value: (max_by(.updated) | {id, state, rounds: (.rounds | length)})})
   | from_entries) as $tasks
| (.sessions | unique_by(.id)) as $all
| ($all | map(select(.parentID != null)) | group_by(.parentID)
   | map({key: .[0].parentID, value: .}) | from_entries) as $kids
| [$all[] | select(.parentID == null and .time.created >= $since)
   | subagents($kids; .id) as $subs | ([.] + $subs) as $everyone
   | {id, title: (.title // null), dir: (.location.directory // null),
      project: $projects[.location.directory // ""],
      created: .time.created, updated: ([$everyone[].time.updated] | max),
      closed: (.time.archived // null),
      state: (if .time.archived then "closed"
              elif (.time.busy // 0) > (.time.idle // 0) then "at work"
              else "open" end),
      subagents: ($subs | length),
      cost: ([$everyone[].cost // 0] | add),
      tokens: ([$everyone[].tokens // {} | (.input // 0) + (.output // 0) + (.reasoning // 0)] | add),
      model: (.model.id // null),
      task: $tasks[.id]}]
| {v: 1, since: $since, threads: sort_by(-.created)}
