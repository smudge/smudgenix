--!nonstrict
-- Agents' sessions in the launcher (from the service): behind /ai, all of
-- them, most urgent first; in its plain search, those that match. Picking one
-- shows it (smx ai open).

local marks = {
  ["needs-permission"] = { glyph = "alert-triangle", says = "needs permission", rank = 4 },
  ["needs-input"] = { glyph = "message-question", says = "asks you", rank = 4 },
  working = { glyph = "loader", says = "at work", rank = 3 },
  failed = { glyph = "x", says = "failed", rank = 2 },
  done = { glyph = "check", says = "done", rank = 1 },
  idle = { glyph = "point", says = "idle", rank = 0 },
}

local lastQuery = nil

local function project(dir)
  return dir and dir:match("([^/]+)/*$") or ""
end

local function answer(text)
  lastQuery = text
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local query = noctalia.string.trim(text or "")
  local results = {}

  for _, session in agents.sessions or {} do
    local mark = marks[session.state] or marks.idle
    local title = session.title or "(untitled)"
    local score = 0
    if query ~= "" then
      score = noctalia.fuzzyScore(query, title .. " " .. project(session.dir))
    end
    if score ~= nil then
      table.insert(results, {
        id = session.id,
        title = title,
        subtitle = "Agent " .. mark.says .. (session.unseen and ", new" or "") .. " · " .. project(session.dir),
        glyph = mark.glyph,
        -- (Behind /ai, by urgency; in a search, by match, urgency breaking ties.)
        score = (query == "" and mark.rank * 1000 or score) + mark.rank,
      })
    end
  end

  if query == "" then
    if agents.server == "down" then
      table.insert(results, { id = "doctor", title = "OpenCode's server isn't reachable", subtitle = "Check on agents (smx ai doctor)", glyph = "robot-off" })
    elseif #results == 0 then
      table.insert(results, { id = "panel", title = agents.server == "up" and "No agents at work" or "No agents (OpenCode's server isn't running)", subtitle = "Agents panel", glyph = "robot" })
    end
  end

  launcher.setResults(text, results)
end

function onQuery(text)
  answer(text)
end

function onActivate(id)
  if id == "doctor" then
    noctalia.runInTerminal("smx ai doctor; read -rsn1 -p 'Press any key to close.'")
  elseif id == "panel" then
    noctalia.togglePanel("smudgenix/agents:sessions")
  else
    noctalia.runAsync({ "smx", "ai", "open", id })
  end
end

-- (Kept current while the launcher shows them.)
noctalia.state.watch("agents", function()
  if lastQuery ~= nil then answer(lastQuery) end
end)
