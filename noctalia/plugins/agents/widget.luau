--!nonstrict
-- The agents' bar widget: what they're doing (from the service), most urgent
-- first. Click: the sessions; right-click: check on them (smx ai doctor).

local function count(sessions, keep)
  local n = 0
  for _, session in sessions do
    if keep(session) then n += 1 end
  end
  return n
end

local function render(agents)
  agents = agents or noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local sessions = agents.sessions or {}
  local needYou = count(sessions, function(s) return s.state == "needs-permission" or s.state == "needs-input" end)
  local working = count(sessions, function(s) return s.state == "working" end)
  local unseen = count(sessions, function(s) return s.unseen end)

  if agents.server == "down" then
    barWidget.setGlyph("robot-off")
    barWidget.setGlyphColor("error")
    barWidget.setText("")
    barWidget.setTooltip("Agents: OpenCode's server isn't reachable (right-click to check)")
  elseif needYou > 0 then
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("tertiary")
    barWidget.setText(tostring(needYou))
    barWidget.setTooltip(`Agents: {needYou} waiting on you`)
  elseif working > 0 then
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("primary")
    barWidget.setText(tostring(working))
    barWidget.setTooltip(`Agents: {working} at work` .. (unseen > 0 and `, {unseen} finished` or ""))
  elseif unseen > 0 then
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("secondary")
    barWidget.setText(tostring(unseen))
    barWidget.setTooltip(`Agents: {unseen} finished`)
  else
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("on_surface/0.6")
    barWidget.setText("")
    barWidget.setTooltip("Agents: none at work")
  end
end

noctalia.state.watch("agents", render)
render()

function onClick()
  noctalia.togglePanel("smudgenix/agents:sessions")
end

function onRightClick()
  noctalia.runInTerminal("smx ai doctor; read -rsn1 -p 'Press any key to close.'")
end
