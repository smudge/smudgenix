--!nonstrict
-- The agents overlay (Mod+A, or the bar widget): what they're doing now (or
-- have open in a TUI), and recent sessions to return to (from the service),
-- with subagents under the sessions that started them. ↑/↓ (or k/j) choose,
-- →/← (or l/h) open and close a session's subagents, Enter or a click shows
-- one (smx ai open).

local open = false
local selected = 1
local shown = {} -- the rows, in order: { session, depth, parent (a row index) }
local expanded = {} -- by id: true, false, or nil (open if a subagent's at work)
local spin = 0 -- the loaders' angle
local spinning = false

local marks = {
  ["needs-permission"] = { glyph = "alert-triangle", color = "tertiary", says = "needs permission" },
  ["needs-input"] = { glyph = "message-question", color = "tertiary", says = "asks you" },
  working = { glyph = "loader-2", color = "primary", says = "at work" },
  done = { glyph = "check", color = "secondary", says = "done" },
  failed = { glyph = "x", color = "error", says = "failed" },
  idle = { glyph = "point", color = "on_surface/0.6", says = "idle" },
}

local function needsYou(session)
  return session.state == "needs-permission" or session.state == "needs-input"
end

local function busy(session)
  return needsYou(session) or session.state == "working"
end

local function ago(ms)
  if not ms then return nil end
  local s = math.max(0, (noctalia.nowMs() - ms) / 1000)
  if s < 60 then return "just now" end
  if s < 3600 then return `{math.floor(s / 60)}m ago` end
  if s < 86400 then return `{math.floor(s / 3600)}h ago` end
  return `{math.floor(s / 86400)}d ago`
end

local function show(session)
  noctalia.runAsync({ "smx", "ai", "open", session.id })
  panel.close()
end

-- The sessions as trees: the top-level ones, and each one's subagents.
local function trees(sessions)
  local byId, children, roots = {}, {}, {}
  for _, session in sessions do
    byId[session.id] = session
  end
  for _, session in sessions do -- (newest first)
    if session.parent and byId[session.parent] then
      children[session.parent] = children[session.parent] or {}
      table.insert(children[session.parent], session)
    else
      table.insert(roots, session)
    end
  end
  return roots, children
end

-- Whether any of a session's subagents (or theirs) is at work, or needs you.
local function anyBusy(id, children, keep)
  for _, child in children[id] or {} do
    if keep(child) or anyBusy(child.id, children, keep) then return true end
  end
  return false
end

local function isExpanded(session, children)
  local e = expanded[session.id]
  if e == nil then return anyBusy(session.id, children, busy) end
  return e
end

local function chip(text)
  return ui.row({ padding = 4, radius = 6, fill = "on_surface/0.08" }, {
    ui.label({ text = text, fontSize = 10, color = "on_surface/0.7", maxLines = 1 }),
  })
end

local function row(entry, index, children, now)
  local session, depth = entry.session, entry.depth
  local mark = marks[session.state] or marks.idle
  local kids = children[session.id]
  local isSelected = index == selected

  local details = { mark.says .. (session.unseen and ", new" or "") }
  if session.open then table.insert(details, "open") end
  if kids and not isExpanded(session, children) then
    table.insert(details, #kids == 1 and "1 subagent" or `{#kids} subagents`)
  end
  local when = ago(session.updated)
  if when then table.insert(details, when) end

  -- Running: orange (primary); open, or in Now: white; the rest, dimmer.
  local titleColor = session.state == "working" and "primary"
    or (session.open or now) and "on_surface"
    or "on_surface/0.75"

  local top = { ui.label({ text = session.title or "(untitled)", color = titleColor, maxLines = 1, flexGrow = 1 }) }
  if session.open then table.insert(top, ui.glyph({ name = "terminal-2", size = 14, color = "on_surface/0.6" })) end
  if session.project then table.insert(top, chip(session.project)) end
  local lines = {
    ui.row({ gap = 8, align = "center" }, top),
    ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }),
  }
  -- Its line: its latest reply if that's news (finished unseen, or asking
  -- you), else what it's about (from its latest compaction), else that reply.
  -- (Selected: both.)
  local news = session.last and (session.unseen or needsYou(session))
  local function say(text, maxLines)
    table.insert(lines, ui.label({ text = text, fontSize = 11, color = "on_surface/0.75", maxLines = maxLines }))
  end
  if isSelected then
    if session.about then say(session.about, 3) end
    if session.last then say((session.about and "Last: " or "") .. session.last, 3) end
  elseif news or not session.about then
    if session.last then say(session.last, 1) end
  else
    say(session.about, 1)
  end

  local toggle = kids and ui.row({
    onClick = function()
      expanded[session.id] = not isExpanded(session, children)
      render()
    end,
  }, { ui.glyph({ name = isExpanded(session, children) and "chevron-down" or "chevron-right", size = 14, color = "on_surface/0.6" }) })
    or ui.box({ width = 14, height = 14 })

  local parts = {}
  if depth > 0 then table.insert(parts, ui.box({ width = 22 * depth, height = 1 })) end
  table.insert(parts, toggle)
  table.insert(parts, ui.glyph({ name = mark.glyph, size = 18, color = mark.color, rotation = session.state == "working" and spin or 0 }))
  table.insert(parts, ui.column({ gap = 2, flexGrow = 1 }, lines))
  return ui.row({
    key = "row-" .. index,
    gap = 8, padding = 8, radius = 8, align = "center",
    fill = isSelected and "primary/0.15" or nil,
    onClick = function() show(session) end,
  }, parts)
end

local function heading(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6" })
end

function render()
  if not open then return end
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local roots, children = trees(agents.sessions or {})

  -- Now: what's at work, needs you, finished unseen, or open in a TUI.
  local now, recent = {}, {}
  for _, root in roots do
    local isNow = root.open or root.unseen or busy(root) or anyBusy(root.id, children, busy)
    table.insert(isNow and now or recent, root)
  end
  -- (What needs you first.)
  local function waits(s) return needsYou(s) or anyBusy(s.id, children, needsYou) end
  table.sort(now, function(a, b)
    local an, bn = waits(a), waits(b)
    if an ~= bn then return an end
    return (a.updated or 0) > (b.updated or 0)
  end)

  shown = {}
  spinning = false
  local rows = {}
  local function add(session, depth, parent, isNow)
    table.insert(shown, { session = session, depth = depth, parent = parent })
    local index = #shown
    if session.state == "working" then spinning = true end
    table.insert(rows, row(shown[index], index, children, isNow))
    if isExpanded(session, children) then
      for _, child in children[session.id] or {} do
        add(child, depth + 1, index, isNow)
      end
    end
  end
  local function section(title, sessions, isNow)
    if #sessions == 0 then return end
    table.insert(rows, heading(title))
    for _, session in sessions do
      add(session, 0, nil, isNow)
    end
  end

  if agents.server == "down" then
    table.insert(rows, ui.label({ text = "OpenCode's server isn't reachable: see smx ai doctor.", color = "error" }))
  else
    if #now == 0 then
      table.insert(rows, heading("Now"))
      table.insert(rows, ui.label({ text = agents.server == "up" and "No agents at work." or "No agents: OpenCode's server isn't running.", color = "on_surface/0.6" }))
    else
      section("Now", now, true)
    end
    section("Recent", recent, false)
  end
  selected = math.clamp(selected, 1, math.max(1, #shown))
  panel.setNeedsFrameTick(spinning)

  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.label({ text = "Agents", fontSize = 15, fontWeight = "bold" }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "row-" .. selected }, rows),
    ui.label({ text = "↑↓ choose  ·  →← subagents  ·  Enter open  ·  Esc close", fontSize = 11, color = "on_surface/0.5" }),
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

function onOpen()
  open = true
  selected = 1
  render()
end

function onClose()
  open = false
  panel.setNeedsFrameTick(false)
end

function onKey(chord, pressed)
  if not (pressed == true or pressed == "true") then return end
  local entry = shown[selected]
  if chord == "Down" or chord == "j" then
    selected = math.min(selected + 1, math.max(1, #shown))
  elseif chord == "Up" or chord == "k" then
    selected = math.max(selected - 1, 1)
  elseif (chord == "Right" or chord == "l") and entry then
    local _, children = trees((noctalia.state.get("agents") or {}).sessions or {})
    if children[entry.session.id] then
      if isExpanded(entry.session, children) then
        selected += 1 -- (to its first subagent)
      else
        expanded[entry.session.id] = true
      end
    end
  elseif (chord == "Left" or chord == "h") and entry then
    local _, children = trees((noctalia.state.get("agents") or {}).sessions or {})
    if children[entry.session.id] and isExpanded(entry.session, children) then
      expanded[entry.session.id] = false
    elseif entry.parent then
      selected = entry.parent
    end
  elseif chord == "Return" then
    if entry then show(entry.session) end
    return
  end
  render()
end
