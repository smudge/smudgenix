--!nonstrict
-- The agents' bar widget: what they're doing (from the service), most urgent
-- first, and greyed out when nothing needs you and none is at work. Click:
-- the overlay (as Mod+A); right-click: check on them (smx ai doctor).
--
-- While Super's shortcuts show, it shows its own instead (the leader key sends
-- "hints" "on", then "off": see nixos/desktop/leader.sh).

local hints = false

local function count(list, keep)
  local n = 0
  for _, item in list do
    if keep(item) then n += 1 end
  end
  return n
end

local function render(agents)
  agents = agents or noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local sessions = agents.sessions or {}
  local needYou = count(sessions, function(s) return s.state == "needs-permission" or s.state == "needs-input" end)
  -- (A subagent's work is its parent's; what one needs from you is yours.)
  local working = count(sessions, function(s) return s.parent == nil and s.state == "working" end)

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
    -- (At work needs nothing from you: a quiet glyph, no count.)
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("primary")
    barWidget.setText("")
    barWidget.setTooltip(`Agents: {working} at work`)
  else
    -- (Nothing for you: there, but quiet.)
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("on_surface/0.35")
    barWidget.setText("")
    barWidget.setTooltip(agents.server == "up" and "Agents: nothing needs you (click to see them)" or "Agents: none (OpenCode's server isn't running; click to see them)")
  end

  local keys = noctalia.getConfig("keys") or ""
  if hints and keys ~= "" then
    barWidget.setColor("primary")
    barWidget.setText(keys)
  else
    barWidget.setColor("on_surface")
  end
end

noctalia.state.watch("agents", render)
render()

function onIpc(event, payload)
  if event == "hints" then
    hints = payload == "on"
    render()
  end
end

function onClick()
  noctalia.togglePanel("smudgenix/agents:sessions")
end

function onRightClick()
  noctalia.runInTerminal("smx ai doctor; read -rsn1 -p 'Press any key to close.'")
end
