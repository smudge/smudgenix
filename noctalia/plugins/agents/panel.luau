--!nonstrict
-- The agents overlay (Mod+A, or the bar widget): what they're doing now, and
-- recent sessions to return to (from the service). ↑/↓ (or k/j) choose,
-- Enter or a click shows one (smx ai open).

local open = false
local selected = 1
local shown = {} -- the rows' sessions, in order

local marks = {
  ["needs-permission"] = { glyph = "alert-triangle", color = "tertiary", says = "needs permission" },
  ["needs-input"] = { glyph = "message-question", color = "tertiary", says = "asks you" },
  working = { glyph = "loader", color = "primary", says = "at work" },
  done = { glyph = "check", color = "secondary", says = "done" },
  failed = { glyph = "x", color = "error", says = "failed" },
  idle = { glyph = "point", color = "on_surface/0.6", says = "idle" },
}

local function isNow(session)
  return session.unseen or session.state == "working" or session.state == "needs-permission" or session.state == "needs-input"
end

-- (A project's folder name says enough here.)
local function project(dir)
  return dir and dir:match("([^/]+)/*$") or ""
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

local function row(session, index)
  local mark = marks[session.state] or marks.idle
  local details = { mark.says .. (session.unseen and ", new" or ""), project(session.dir) }
  local when = ago(session.updated)
  if when then table.insert(details, when) end
  return ui.row({
    key = "row-" .. index,
    gap = 10, padding = 8, radius = 8, align = "center",
    fill = index == selected and "primary/0.15" or nil,
    onClick = function() show(session) end,
  }, {
    ui.glyph({ name = mark.glyph, size = 18, color = mark.color }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = session.title or "(untitled)", maxLines = 1 }),
      ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }),
    }),
  })
end

local function heading(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6" })
end

local function render()
  if not open then return end
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local now, recent = {}, {}
  for _, session in agents.sessions or {} do
    table.insert(isNow(session) and now or recent, session)
  end
  -- (Now: what needs you first.)
  table.sort(now, function(a, b)
    local an = a.state:sub(1, 6) == "needs-"
    local bn = b.state:sub(1, 6) == "needs-"
    if an ~= bn then return an end
    return (a.updated or 0) > (b.updated or 0)
  end)

  shown = {}
  local rows = {}
  local function section(title, sessions)
    if #sessions == 0 then return end
    table.insert(rows, heading(title))
    for _, session in sessions do
      table.insert(shown, session)
      table.insert(rows, row(session, #shown))
    end
  end

  if agents.server == "down" then
    table.insert(rows, ui.label({ text = "OpenCode's server isn't reachable: see smx ai doctor.", color = "error" }))
  else
    if #now == 0 then
      table.insert(rows, heading("Now"))
      table.insert(rows, ui.label({ text = agents.server == "up" and "No agents at work." or "No agents: OpenCode's server isn't running.", color = "on_surface/0.6" }))
    else
      section("Now", now)
    end
    section("Recent", recent)
  end
  selected = math.clamp(selected, 1, math.max(1, #shown))

  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.label({ text = "Agents", fontSize = 15, fontWeight = "bold" }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "row-" .. selected }, rows),
    ui.label({ text = "↑↓ choose  ·  Enter open  ·  Esc close", fontSize = 11, color = "on_surface/0.5" }),
  }))
end

noctalia.state.watch("agents", render)

function onOpen()
  open = true
  selected = 1
  render()
end

function onClose()
  open = false
end

function onKey(chord, pressed)
  if not (pressed == true or pressed == "true") then return end
  if chord == "Down" or chord == "j" then
    selected = math.min(selected + 1, math.max(1, #shown))
  elseif chord == "Up" or chord == "k" then
    selected = math.max(selected - 1, 1)
  elseif chord == "Return" then
    if shown[selected] then show(shown[selected]) end
    return
  end
  render()
end
