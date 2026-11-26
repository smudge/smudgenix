--!nonstrict
-- The agents overlay (Mod+A, or the bar widget): where your threads of work
-- are, in a project (the focused window's, at first; Tab for the next, or
-- all). It shows, and takes you there; you act where the work is, with the
-- tools that already do it.
--
-- - Needs you: a permission or a question (answered in its TUI), layers to
--   review, an agent stuck (unsure, a conflict, a failure), or a failure.
-- - Working: an agent's at it.
-- - Done: back since you looked, or its agent says it's done.
-- - Idle: the rest (collapsed to a count).
--
-- Enter opens a thread, in a terminal of its own (smx ai open): its TUI, and
-- beside it a shell where its work is (smx ai shell: its stack, to diff, check
-- and approve). Agents' provisional calls, to confirm or overturn, open in a
-- terminal too (smx ai log). Nothing here changes anything: it runs smx ai
-- open and log, and nothing else.

local open = false
local selected = 1
local shown = {} -- the rows: { thread, depth, parent (a row index) } | { idle = true } | { calls = true }
local expanded = {} -- subagents shown, by thread id (nil: when one needs you)
local idleOpen = false
local spin = 0 -- the loaders' angle
local spinning = false
local scope = nil -- a project's name, or nil for all
local scopeChosen = false -- (by you, so the focused window's doesn't override it)
local stacksBy = {} -- threads' stacks, by thread id (from the last render)
local pausedBy = {} -- why each thread's agent stopped this turn, by thread id (from the last render)

-- --- Helpers -----------------------------------------------------------------

local function needsYou(session)
  return session.state == "needs-permission" or session.state == "needs-input"
end

local function ago(ms)
  if not ms then return nil end
  local s = math.max(0, (noctalia.nowMs() - ms) / 1000)
  if s < 60 then return "just now" end
  if s < 3600 then return `{math.floor(s / 60)}m ago` end
  if s < 86400 then return `{math.floor(s / 3600)}h ago` end
  return `{math.floor(s / 86400)}d ago`
end

local function chip(text, on)
  return ui.row({ padding = 4, radius = 6, fill = on and "primary/0.25" or "on_surface/0.08" }, {
    ui.label({ text = text, fontSize = 10, color = on and "on_surface" or "on_surface/0.7", maxLines = 1 }),
  })
end

local function heading(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6" })
end

-- --- Threads -----------------------------------------------------------------

-- Your threads (top-level sessions), each with its subagents; and the
-- projects they're in, most recent first.
local function threads(agents)
  local byId, children, list = {}, {}, {}
  for _, session in agents.sessions or {} do
    byId[session.id] = session
  end
  for _, session in agents.sessions or {} do -- (newest first)
    if session.parent and byId[session.parent] then
      children[session.parent] = children[session.parent] or {}
      table.insert(children[session.parent], session)
    else
      table.insert(list, session)
    end
  end
  stacksBy = {}
  for _, stack in agents.stacks or {} do
    stacksBy[stack.session] = stack
  end
  -- (A pause stands for the turn it ended: not once the agent's at it again.)
  pausedBy = {}
  for _, pause in agents.pauses or {} do
    local thread = byId[pause.thread]
    if thread and thread.state ~= "working" and (pause.time or 0) >= (thread.started or 0) then pausedBy[pause.thread] = pause end
  end
  local projects, seen = {}, {}
  for _, thread in list do
    if thread.project and not seen[thread.project] then
      seen[thread.project] = true
      table.insert(projects, { name = thread.project, dir = thread.dir })
    end
  end
  return list, children, projects
end

-- Whether any of a thread's subagents (or theirs) is so.
local function anyChild(id, children, keep)
  for _, child in children[id] or {} do
    if keep(child) or anyChild(child.id, children, keep) then return true end
  end
  return false
end

-- A thread's status: "you" (needs you), "working", "done" or "idle"; how
-- urgent among its kind (lower first); a word on it; and its glyph.
local function status(thread, children)
  if needsYou(thread) or anyChild(thread.id, children, needsYou) then
    local asking = needsYou(thread) and thread.state == "needs-input"
    return "you", 0, asking and "asks you something" or "needs your permission", asking and "help-circle" or "alert-triangle", "tertiary"
  end
  if thread.state == "working" then
    return "working", 0, "at work", "loader-2", "primary"
  end
  if anyChild(thread.id, children, function(s) return s.state == "working" end) then
    return "working", 0, "subagents at work", "loader-2", "primary"
  end
  local pause = pausedBy[thread.id]
  if pause and (pause.reason == "uncertain" or pause.reason == "conflict" or pause.reason == "failing") then
    local said = ({ uncertain = "unsure how to go on", conflict = "found a conflict", failing = "stuck on a failure" })[pause.reason]
    return "you", 1, said, "alert-circle", "tertiary"
  end
  local stack = stacksBy[thread.id]
  local n, approved, failing = 0, 0, 0
  for _, layer in stack and stack.layers or {} do
    if layer.state == "approved" then approved += 1 else n += 1 end
    if layer.check and layer.check.state == "failed" then failing += 1 end
  end
  if n > 0 then
    return "you", 2, `{n} layer{n == 1 and "" or "s"} to review`
      .. (failing > 0 and `, {failing} failing {failing == 1 and "its" or "their"} check` or "")
      .. (approved > 0 and `, {approved} approved` or ""), "stack-2", "secondary"
  end
  if thread.unseen and thread.state == "failed" then
    return "you", 1, "it failed", "x", "error"
  end
  if thread.unseen or (pause and (pause.reason == "done" or pause.reason == "lead")) then
    return "done", 0, approved > 0 and `done: {approved} layer{approved == 1 and "" or "s"} with the forge` or "done", "check", "secondary"
  end
  return "idle", 0, approved > 0 and `{approved} layer{approved == 1 and "" or "s"} with the forge` or "idle", "point", "on_surface/0.5"
end

-- What smx ai says when it can't open something, as an error (not nothing).
local function opened(result)
  if result.exitCode ~= 0 then
    local said = (result.stderr or ""):gsub("^smx ai: ", ""):gsub("%s+$", "")
    noctalia.notifyError("Couldn't open the thread", said ~= "" and said or `smx ai open exited {result.exitCode}`)
  end
end

-- Opens a thread: its TUI, and a shell where its work is.
local function enter(thread)
  noctalia.runAsync({ "smx", "ai", "open", thread.id }, opened)
  panel.close()
end

-- Agents' provisional calls, in a project (or all): to confirm or overturn,
-- in smx ai log.
local function calls(agents, project)
  local n = 0
  for _, line in (agents.decisions or {}).current or {} do
    if line.provisional and (not project or line.project == project) then n += 1 end
  end
  return n
end

-- --- Rendering ---------------------------------------------------------------

local function threadRow(entry, index, children)
  local thread = entry.thread
  local where, _, says, glyph, color = status(thread, children)
  local isSelected = index == selected

  local details = { says }
  local kids = children[thread.id]
  if kids and not expanded[thread.id] then table.insert(details, #kids == 1 and "1 subagent" or `{#kids} subagents`) end
  if not scope and thread.project then table.insert(details, thread.project) end
  local when = ago(thread.updated)
  if when then table.insert(details, when) end

  local titleColor = where == "working" and "primary" or (where == "you" or where == "done") and "on_surface" or "on_surface/0.7"
  local top = { ui.label({ text = thread.title or "(untitled)", color = titleColor, maxLines = 1, flexGrow = 1 }) }
  if thread.open then table.insert(top, ui.glyph({ name = "terminal-2", size = 14, color = "on_surface/0.6" })) end
  local lines = {
    ui.row({ gap = 8, align = "center" }, top),
    ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }),
  }
  -- Its line: why its agent stopped, if it said; else its reply, if that's
  -- news; else what it's about. (Selected: more of it.)
  local pause = pausedBy[thread.id]
  local function say(text, maxLines, tint)
    table.insert(lines, ui.label({ text = text, fontSize = 11, color = tint or "on_surface/0.75", maxLines = maxLines }))
  end
  if pause and pause.note then
    say(pause.note, 2, (pause.reason == "done" or pause.reason == "lead") and "on_surface/0.75" or "tertiary")
  elseif isSelected then
    if thread.about then say(thread.about, 2) end
    if thread.last then say((thread.about and "Last: " or "") .. thread.last, 3) end
  elseif thread.last and (thread.unseen or needsYou(thread)) then
    say(thread.last, 1)
  elseif thread.about or thread.last then
    say(thread.about or thread.last, 1)
  end

  local parts = {}
  if entry.depth > 0 then table.insert(parts, ui.box({ width = 22 * entry.depth, height = 1 })) end
  table.insert(parts, ui.glyph({ name = glyph, size = 18, color = color, rotation = glyph == "loader-2" and spin or 0 }))
  table.insert(parts, ui.column({ gap = 2, flexGrow = 1 }, lines))
  return ui.row({
    key = "row-" .. index,
    gap = 8, padding = 8, radius = 8, align = "center",
    fill = isSelected and "primary/0.15" or nil,
    onClick = function()
      selected = index
      enter(thread)
    end,
  }, parts)
end

-- A row that opens something else: the idle threads, or the calls to confirm.
local function moreRow(index, glyph, text, onClick)
  return ui.row({
    key = "row-" .. index, gap = 8, padding = 8, radius = 8, align = "center",
    fill = index == selected and "primary/0.15" or nil,
    onClick = onClick,
  }, {
    ui.glyph({ name = glyph, size = 16, color = "on_surface/0.5" }),
    ui.label({ text = text, color = "on_surface/0.7" }),
  })
end

local function openCalls()
  noctalia.runInTerminal("smx ai log --current; exec \"${SHELL:-bash}\" -i")
  panel.close()
end

function render()
  if not open then return end
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local list, children, projects = threads(agents)

  local groups = { you = {}, working = {}, done = {}, idle = {} }
  local rank = {}
  for _, thread in list do
    if not scope or thread.project == scope then
      local where, r = status(thread, children)
      rank[thread.id] = r
      table.insert(groups[where], thread)
    end
  end
  table.sort(groups.you, function(a, b)
    if rank[a.id] ~= rank[b.id] then return rank[a.id] < rank[b.id] end
    return (a.updated or 0) < (b.updated or 0) -- (waiting longest first)
  end)

  shown = {}
  spinning = #groups.working > 0
  local rows = {}
  local function add(thread, depth, parent)
    table.insert(shown, { thread = thread, depth = depth, parent = parent })
    local index = #shown
    table.insert(rows, threadRow(shown[index], index, children))
    local showKids = expanded[thread.id]
    if showKids == nil then showKids = anyChild(thread.id, children, needsYou) end
    if showKids then
      for _, child in children[thread.id] or {} do
        add(child, depth + 1, index)
      end
    end
  end
  local function section(title, items)
    if #items == 0 then return end
    table.insert(rows, heading(title))
    for _, thread in items do add(thread, 0, nil) end
  end

  if agents.server == "down" then
    table.insert(rows, ui.label({ text = "OpenCode's server isn't reachable: see smx ai doctor.", color = "error" }))
  end
  section("Needs you", groups.you)
  local n = calls(agents, scope)
  if n > 0 then
    if #groups.you == 0 then table.insert(rows, heading("Needs you")) end
    table.insert(shown, { calls = true })
    table.insert(rows, moreRow(#shown, "circle-dashed", `{n} agent call{n == 1 and "" or "s"} to confirm or overturn`, openCalls))
  end
  section("Working", groups.working)
  section("Done", groups.done)
  if #groups.idle > 0 then
    table.insert(rows, heading("Idle"))
    if idleOpen then
      for _, thread in groups.idle do add(thread, 0, nil) end
    else
      table.insert(shown, { idle = true })
      local count = #groups.idle
      table.insert(rows, moreRow(#shown, "chevron-right", `{count} idle thread{count == 1 and "" or "s"}`, function()
        idleOpen = true
        render()
      end))
    end
  end
  if #shown == 0 then
    table.insert(rows, ui.label({ text = scope and `No threads in {scope}.` or "No threads.", color = "on_surface/0.6" }))
  end
  selected = math.clamp(selected, 1, math.max(1, #shown))

  -- The projects: this one first; Tab goes round them, and all.
  local pills = {}
  for _, project in projects do
    table.insert(pills, chip(project.name, project.name == scope))
  end
  table.insert(pills, chip("All", scope == nil))

  local entry = shown[selected]
  local hint = entry and entry.thread and "Enter open its TUI and a shell  ·  Tab project  ·  Esc close"
    or entry and (entry.idle or entry.calls) and "Enter open  ·  Tab project  ·  Esc close"
    or "Tab project  ·  Esc close"
  panel.setNeedsFrameTick(spinning)
  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Threads", fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
      ui.row({ gap = 4 }, pills),
    }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "row-" .. selected }, rows),
    ui.label({ text = hint, fontSize = 11, color = "on_surface/0.5" }),
  }))
end

noctalia.state.watch("agents", render)

-- (The loaders turn, a step every tenth of a second, while any's shown.)
local sinceStep = 0
function onFrameTick(deltaMs)
  if not spinning then return end
  sinceStep += deltaMs
  if sinceStep < 100 then return end
  sinceStep = 0
  spin = (spin + 36) % 360
  render()
end

-- (The scope: a notification's thread's project; else the focused
-- window's, if it's in one; else what it was.)
function onOpen(context)
  open = true
  selected = 1
  idleOpen = false
  local agents = noctalia.state.get("agents") or {}
  if type(context) == "string" and context ~= "" then
    for _, session in agents.sessions or {} do
      if session.id == context then scope = session.project end
    end
    render()
    for index, entry in shown do
      if entry.thread and entry.thread.id == context then selected = index end
    end
    render()
    return
  end
  scopeChosen = false
  render()
  noctalia.runAsync({ "smx", "ai", "context", "--json" }, function(result)
    local said = result.exitCode == 0 and noctalia.json.decode(result.stdout or "") or nil
    if type(said) == "table" and open and not scopeChosen and said.project then
      scope = said.project
      render()
    end
  end)
end

function onClose()
  open = false
  panel.setNeedsFrameTick(false)
end

function onKey(chord, pressed)
  if not (pressed == true or pressed == "true") then return end
  local agents = noctalia.state.get("agents") or {}
  local _, children, projects = threads(agents)
  local entry = shown[selected]
  local thread = entry and entry.thread
  if chord == "Down" or chord == "j" then
    selected = math.min(selected + 1, math.max(1, #shown))
  elseif chord == "Up" or chord == "k" then
    selected = math.max(selected - 1, 1)
  elseif chord == "Tab" or chord == "Shift+Tab" or chord == "Shift+ISO_Left_Tab" then
    -- (Round the projects, then all.)
    local names = {}
    for _, project in projects do table.insert(names, project.name) end
    table.insert(names, false)
    local at = 1
    for i, name in names do
      if name == (scope or false) then at = i end
    end
    local step = chord == "Tab" and 1 or -1
    local next = names[(at - 1 + step) % #names + 1]
    scope = next or nil
    scopeChosen = true
    selected = 1
  elseif entry and entry.idle and (chord == "Return" or chord == "Right" or chord == "l") then
    idleOpen = true
  elseif entry and entry.calls and chord == "Return" then
    openCalls()
    return
  elseif not thread then
    -- (Nothing selected.)
  elseif chord == "Return" then
    enter(thread)
    return
  elseif chord == "Right" or chord == "l" then
    if children[thread.id] then expanded[thread.id] = true end
  elseif chord == "Left" or chord == "h" then
    if children[thread.id] and expanded[thread.id] ~= false then
      expanded[thread.id] = false
    elseif entry.parent then
      selected = entry.parent
    end
  end
  render()
end
