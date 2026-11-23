--!nonstrict
-- The agents' bar widget: what they're doing (from the service), most urgent
-- first, and nothing at all when nothing needs you, there's nothing to
-- review and none is at work (Mod+A still shows them). Click: the overlay;
-- right-click: check on them (smx ai doctor).

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
  -- To review: tasks in review, and sessions finished since you looked.
  local review = count(agents.tasks or {}, function(t) return t.state == "in-review" end)
    + count(sessions, function(s) return s.parent == nil and s.unseen end)

  barWidget.setVisible(true)
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
  elseif review > 0 then
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("secondary")
    barWidget.setText(tostring(review))
    barWidget.setTooltip(`Agents: {review} to review` .. (working > 0 and `, {working} at work` or ""))
  elseif working > 0 then
    -- (At work needs nothing from you: a quiet glyph, no count.)
    barWidget.setGlyph("robot")
    barWidget.setGlyphColor("primary")
    barWidget.setText("")
    barWidget.setTooltip(`Agents: {working} at work`)
  else
    barWidget.setVisible(false)
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
