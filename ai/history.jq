# smx ai history: your threads (top-level sessions, with their subagents)
# started since a time, newest first: when, where, how they ended (closed,
# and what came of their stacks), and what they cost, subagents included.
#
# In: {since: <ms>, sessions: [OpenCode's sessions], projects: {<folder>:
# <project>}, stacks: [smx ai's thread records]}. (Deterministic: no clock, no
# time zone; `smx ai history` shows it.)

def subagents($kids; $id): [$kids[$id][]? | ., subagents($kids; .id)[]];

.since as $since | .projects as $projects
| ((.stacks // []) | map({key: .session, value: {landed: (.landed // [] | length), closing: (.closing // null)}})
   | from_entries) as $stacks
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
      stack: $stacks[.id]}]
| {v: 1, since: $since, threads: sort_by(-.created)}
