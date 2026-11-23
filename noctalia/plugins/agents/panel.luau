--!nonstrict
-- The agents' sessions (from the service): click one to show it.

local open = false

local marks = {
  ["needs-permission"] = { glyph = "alert-triangle", color = "tertiary", says = "needs permission" },
  ["needs-input"] = { glyph = "message-question", color = "tertiary", says = "asks you" },
  working = { glyph = "loader", color = "primary", says = "at work" },
  done = { glyph = "check", color = "secondary", says = "done" },
  failed = { glyph = "x", color = "error", says = "failed" },
  idle = { glyph = "point", color = "on_surface/0.6", says = "idle" },
}

-- (A project's folder name says enough here.)
local function project(dir)
  return dir and dir:match("([^/]+)/*$") or ""
end

local function row(session)
  local mark = marks[session.state] or marks.idle
  local says = mark.says .. (session.unseen and ", new" or "")
  return ui.row({ key = session.id, gap = 10, padding = 8, radius = 8, align = "center", onClick = function()
    noctalia.runAsync({ "smx", "ai", "open", session.id })
    panel.close()
  end }, {
    ui.glyph({ name = mark.glyph, size = 18, color = mark.color }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = session.title or "(untitled)", maxLines = 1 }),
      ui.label({ text = says .. "  ·  " .. project(session.dir), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }),
    }),
  })
end

local function render()
  if not open then return end
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local rows = {}
  if agents.server == "down" then
    table.insert(rows, ui.label({ text = "OpenCode's server isn't reachable: see smx ai doctor.", color = "error" }))
  elseif #(agents.sessions or {}) == 0 then
    table.insert(rows, ui.label({ text = "No agents at work.", color = "on_surface/0.6" }))
  else
    for _, session in agents.sessions do
      table.insert(rows, row(session))
    end
  end
  panel.render(ui.column({ padding = 12, gap = 4 }, {
    ui.label({ text = "Agents", fontSize = 15, fontWeight = "bold" }),
    ui.scroll({ flexGrow = 1, gap = 2 }, rows),
  }))
end

noctalia.state.watch("agents", render)

function onOpen()
  open = true
  render()
end

function onClose()
  open = false
end
