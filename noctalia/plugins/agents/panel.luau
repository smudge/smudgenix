--!nonstrict
-- The agents overlay (Mod+A, or the bar widget): a launcher. Your active
-- projects, those with tabs open in their OpenCode TUIs, each with those
-- tabs' sessions, in order (and, rarely, one at work or needing you without
-- a tab), marked when an agent's at work or needs you. The focused window's
-- project comes first, even if it's not active. Tab: every recent project
-- too (to start a session in one that isn't active). x: close a session's
-- tab (smx ai close --tab).
-- Enter on a project starts a session there; on a session, opens it: either
-- in the project's window, its OpenCode TUI (on that session's tab) and a
-- shell side by side (smx ai new and open). That's all it does.

local open = false
local selected = 1
local rows = {} -- what Enter does on each: { project } | { session }
local here = nil -- the focused window's project: { name, root }
local all = false -- every recent project shown (Tab), not only the active
local spin = 0 -- the loaders' angle
local spinning = false -- (whether any's shown)

-- --- Helpers -----------------------------------------------------------------

local function ago(ms)
  if not ms then return nil end
  local s = math.max(0, (noctalia.nowMs() - ms) / 1000)
  if s < 60 then return "just now" end
  if s < 3600 then return `{math.floor(s / 60)}m ago` end
  if s < 86400 then return `{math.floor(s / 3600)}h ago` end
  return `{math.floor(s / 86400)}d ago`
end

local function home(path)
  local ok, h = pcall(function() return os.getenv("HOME") end)
  if not ok then return path end
  if h and path and path:sub(1, #h) == h then return "~" .. path:sub(#h + 1) end
  return path
end

-- Runs smx ai, and says why if it couldn't (what: what it was doing).
local function run(argv, what)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      local said = (result.stderr or ""):gsub("^smx ai: ", ""):gsub("%s+$", "")
      noctalia.notifyError(`Couldn't {what}`, said ~= "" and said or `{table.concat(argv, " ")} exited {result.exitCode}`)
    end
  end)
end

-- (Opening it: it's on screen next, so this closes.)
local function smx(argv)
  run(argv, "open it")
  panel.close()
end

-- An agent's state, as a mark: at work, or needs you; else none.
local function mark(session)
  if session.state == "needs-permission" or session.state == "needs-input" then
    return ui.glyph({ name = "alert-triangle", size = 14, color = "tertiary" })
  elseif session.state == "working" then
    spinning = true
    return ui.glyph({ name = "loader-2", size = 14, color = "primary", rotation = spin })
  end
  return ui.box({ width = 14, height = 14 })
end

-- A project's name: its folder's (~ for your home).
local function nameOf(root)
  local ok, h = pcall(function() return os.getenv("HOME") end)
  if ok and root == h then return "~" end
  return root:match("([^/]+)/?$") or root
end

local function active(session)
  return session.state == "working" or session.state == "needs-permission" or session.state == "needs-input"
end

-- The active projects (the focused window's first), most recently at work
-- first, each with the sessions in its tabs, in order, then any top-level
-- one at work or needing you without a tab; then, with every one shown
-- (Tab), the rest, most recent first, without their sessions.
local function projects(agents)
  local list, byRoot, byId = {}, {}, {}
  for _, session in agents.sessions or {} do
    byId[session.id] = session
  end
  local function project(root, name)
    if not byRoot[root] then
      byRoot[root] = { name = name or nameOf(root), root = root, sessions = {}, has = {}, latest = 0 }
      table.insert(list, byRoot[root])
    end
    return byRoot[root]
  end
  local function add(p, session)
    if p.has[session.id] then return end
    p.has[session.id] = true
    table.insert(p.sessions, session)
    p.latest = math.max(p.latest, session.updated or 0)
  end
  for root, tabs in agents.tabs or {} do
    local p = project(root)
    for _, tab in tabs do
      add(p, byId[tab.id] or { id = tab.id, title = tab.title })
    end
  end
  for _, session in agents.sessions or {} do
    local root = session.root or session.dir
    if session.parent == nil and root and active(session) then add(project(root, session.project), session) end
  end
  table.sort(list, function(a, b) return a.latest > b.latest end)
  if all then
    for _, session in agents.sessions or {} do -- (newest first)
      local root = session.root or session.dir
      if session.parent == nil and root and not byRoot[root] then project(root, session.project) end
    end
  end
  if here then
    local p = byRoot[here.root]
    if p then table.remove(list, table.find(list, p)) else p = { name = here.name, root = here.root, sessions = {} } end
    table.insert(list, 1, p)
  end
  return list
end

-- --- Rendering ---------------------------------------------------------------

local function row(index, onClick, children)
  return ui.row({
    key = "row-" .. index, gap = 8, padding = 8, radius = 8, align = "center",
    fill = index == selected and "primary/0.15" or nil,
    onClick = function()
      selected = index
      onClick()
    end,
  }, children)
end

local function activate(entry)
  if entry.project then
    smx({ "smx", "ai", "new", "--dir", entry.project.root })
  elseif entry.session then
    smx({ "smx", "ai", "open", entry.session.id })
  end
end

function render()
  if not open then return end
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  rows = {}
  spinning = false
  local shown = {}
  local function add(entry, children)
    table.insert(rows, entry)
    local index = #rows
    table.insert(shown, row(index, function() activate(entry) end, children))
  end

  if agents.server == "down" then
    table.insert(shown, ui.label({ text = "OpenCode's server isn't reachable: see smx ai doctor.", color = "error" }))
  end
  for _, project in projects(agents) do
    add({ project = project }, {
      ui.glyph({ name = "folder", size = 16, color = "on_surface/0.7" }),
      ui.label({ text = project.name, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = home(project.root), fontSize = 11, color = "on_surface/0.5", maxLines = 1, flexGrow = 1 }),
      ui.label({ text = "new session", fontSize = 11, color = "on_surface/0.5" }),
    })
    for _, session in project.sessions do
      add({ session = session }, {
        ui.box({ width = 16, height = 1 }),
        mark(session),
        ui.label({ text = session.title or "(untitled)", maxLines = 1, flexGrow = 1 }),
        ui.label({ text = ago(session.updated) or "", fontSize = 11, color = "on_surface/0.5" }),
      })
    end
  end
  if #rows == 0 and all then
    table.insert(shown, ui.label({ text = "No projects yet: open Mod+A from a terminal in one.", color = "on_surface/0.6" }))
  elseif #rows == 0 then
    table.insert(shown, ui.label({ text = "No projects open: Tab shows every recent one.", color = "on_surface/0.6" }))
  end
  selected = math.clamp(selected, 1, math.max(1, #rows))

  panel.setNeedsFrameTick(spinning)
  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.label({ text = all and "Agents: every recent project" or "Agents", fontSize = 15, fontWeight = "bold" }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "row-" .. selected }, shown),
    ui.label({ text = "Enter new session, or open  ·  x close tab  ·  Tab " .. (all and "active projects" or "every project") .. "  ·  Esc", fontSize = 11, color = "on_surface/0.5" }),
  }))
end

noctalia.state.watch("agents", render)

-- (The loaders turn, a step every tenth of a second, while any's shown.)
local sinceStep = 0
function onFrameTick(deltaMs)
  if not (open and spinning) then return end
  sinceStep += deltaMs
  if sinceStep < 100 then return end
  sinceStep = 0
  spin = (spin + 36) % 360
  render()
end

-- (A session given, from a notification: it's selected. Else the focused
-- window's project is, once smx ai says which it is.)
function onOpen(context)
  open = true
  all = false
  selected = 1
  render()
  if type(context) == "string" and context ~= "" then
    for index, entry in rows do
      if entry.session and entry.session.id == context then selected = index end
    end
    render()
    return
  end
  noctalia.runAsync({ "smx", "ai", "context", "--json" }, function(result)
    local said = result.exitCode == 0 and noctalia.json.decode(result.stdout or "") or nil
    if type(said) == "table" and said.dir and said.project and open then
      here = { name = said.project, root = said.root or said.dir }
      selected = 1
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
  if chord == "Down" or chord == "j" then
    selected = math.min(selected + 1, math.max(1, #rows))
  elseif chord == "Up" or chord == "k" then
    selected = math.max(selected - 1, 1)
  elseif chord == "Return" then
    if rows[selected] then activate(rows[selected]) end
    return
  elseif chord == "Tab" then
    all = not all
    selected = 1
  elseif chord == "x" then
    local entry = rows[selected]
    if entry and entry.session then run({ "smx", "ai", "close", "--tab", entry.session.id }, "close its tab") end
    return
  end
  render()
end
