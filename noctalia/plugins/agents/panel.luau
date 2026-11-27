--!nonstrict
-- The agents overlay (Mod+A, or the bar widget): a launcher. Your recent
-- projects (the focused window's first, even if it has no sessions yet), each
-- with its recent sessions, marked when an agent's at work or needs you.
-- Enter on a project starts a session there; on a session, opens it: either
-- in a terminal of its own, its OpenCode TUI and a shell side by side (smx ai
-- new and open). That's all it does.

local open = false
local selected = 1
local rows = {} -- what Enter does on each: { project } | { session }
local here = nil -- the focused window's project: { name, root }
local perProject = 3 -- sessions shown under each project

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

-- Runs smx ai, and says why if it couldn't.
local function smx(argv)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      local said = (result.stderr or ""):gsub("^smx ai: ", ""):gsub("%s+$", "")
      noctalia.notifyError("Couldn't open it", said ~= "" and said or `{table.concat(argv, " ")} exited {result.exitCode}`)
    end
  end)
  panel.close()
end

-- An agent's state, as a mark: at work, or needs you; else none.
local function mark(session)
  if session.state == "needs-permission" or session.state == "needs-input" then
    return ui.glyph({ name = "alert-triangle", size = 14, color = "tertiary" })
  elseif session.state == "working" then
    return ui.glyph({ name = "loader-2", size = 14, color = "primary" })
  end
  return ui.box({ width = 14, height = 14 })
end

-- Projects, most recent first (the focused window's first), each with its
-- sessions (top-level ones), newest first.
local function projects(agents)
  local list, byRoot = {}, {}
  local function project(name, root)
    if not byRoot[root] then
      byRoot[root] = { name = name, root = root, sessions = {} }
      table.insert(list, byRoot[root])
    end
    return byRoot[root]
  end
  if here then project(here.name, here.root) end
  for _, session in agents.sessions or {} do -- (newest first)
    local root = session.root or session.dir
    if session.parent == nil and root then
      table.insert(project(session.project or root, root).sessions, session)
    end
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
    for i, session in project.sessions do
      if i > perProject then break end
      add({ session = session }, {
        ui.box({ width = 16, height = 1 }),
        mark(session),
        ui.label({ text = session.title or "(untitled)", maxLines = 1, flexGrow = 1 }),
        ui.label({ text = ago(session.updated) or "", fontSize = 11, color = "on_surface/0.5" }),
      })
    end
  end
  if #rows == 0 then
    table.insert(shown, ui.label({ text = "No projects yet: open Mod+A from a terminal in one.", color = "on_surface/0.6" }))
  end
  selected = math.clamp(selected, 1, math.max(1, #rows))

  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.label({ text = "Agents", fontSize = 15, fontWeight = "bold" }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "row-" .. selected }, shown),
    ui.label({ text = "Enter: a new session in a project, or open a session  ·  Esc close", fontSize = 11, color = "on_surface/0.5" }),
  }))
end

noctalia.state.watch("agents", render)

-- (A session given, from a notification: it's selected. Else the focused
-- window's project is, once smx ai says which it is.)
function onOpen(context)
  open = true
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
  end
  render()
end
