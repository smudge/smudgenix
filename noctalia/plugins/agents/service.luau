--!nonstrict
-- Follows `smx ai watch`, publishing what agents are doing ("agents": the
-- server's state, and its sessions, subagents' included) for the widget and
-- panel, and saying so when one needs you or finishes, unless you're looking
-- at it (its TUI's window is focused).

local sessions = {} -- by id
local server = "stopped"

local function publish()
  local list = {}
  for _, session in sessions do
    table.insert(list, session)
  end
  table.sort(list, function(a, b) return (a.updated or 0) > (b.updated or 0) end) -- (newest first)
  noctalia.state.set("agents", { server = server, sessions = list })
end

-- The focused window's process, from niri's events (nil if none, or not niri).
local windows = {} -- pid by window id
local focused = nil -- window id

noctalia.compositor.subscribe(nil, function(event, data)
  if event == "reset" then
    windows, focused = {}, nil
  elseif event == "WindowsChanged" then
    windows = {}
    for _, window in data.windows or {} do
      windows[window.id] = window.pid
      if window.is_focused then focused = window.id end
    end
  elseif event == "WindowOpenedOrChanged" and data.window then
    windows[data.window.id] = data.window.pid
    if data.window.is_focused then focused = data.window.id end
  elseif event == "WindowClosed" then
    windows[data.id] = nil
    if focused == data.id then focused = nil end
  elseif event == "WindowFocusChanged" then
    focused = data.id
  end
end)

local function lookingAt(session)
  local pid = focused and windows[focused]
  if not pid then return false end
  for _, p in session.terminals or {} do
    if p == pid then return true end
  end
  return false
end

local function title(session)
  return session.title or "An agent"
end

local function notify(say, summary, body, id)
  say(summary, body, { actions = { { id = "open", label = "Open" } }, onAction = "onNotificationAction", context = id })
end

-- What changed for you, if anything, from before to after. (A subagent's
-- finishing is its parent's news, not yours.)
local function tell(before, after)
  local was = before and before.state
  if after.state == was or lookingAt(after) then return end
  if after.state == "needs-permission" then
    local p = after.permissions[#after.permissions]
    notify(noctalia.notify, "Needs permission: " .. title(after), p and (p.action .. " " .. table.concat(p.resources or {}, ", ")) or nil, after.id)
  elseif after.state == "needs-input" then
    local f = after.forms[#after.forms]
    notify(noctalia.notify, "Asks: " .. title(after), f and f.title or nil, after.id)
  elseif after.parent == nil and after.unseen and (after.state == "done" or after.state == "failed") then
    local done = after.state == "done"
    notify(done and noctalia.notify or noctalia.notifyError, (done and "Done: " or "Failed: ") .. title(after), after.last, after.id)
  end
end

function onNotificationAction(_action, id)
  if id then noctalia.runAsync({ "smx", "ai", "open", id }) end
end

local function onLine(line)
  local event = noctalia.json.decode(line)
  if type(event) ~= "table" or event.v ~= 1 then return end
  if event.type == "snapshot" then
    -- (Not news: what you'd already know about, or missed.)
    server = "up"
    sessions = {}
    for _, session in event.sessions or {} do
      sessions[session.id] = session
    end
  elseif event.type == "session" then
    tell(sessions[event.id], event)
    sessions[event.id] = event
  elseif event.type == "removed" then
    sessions[event.id] = nil
  elseif event.type == "server" then
    server = event.state
    if server ~= "up" then sessions = {} end
  end
  publish()
end

publish()
-- (Again if it ever stops: each start begins with a snapshot.)
noctalia.runStream("trap 'kill $w 2>/dev/null; exit' TERM INT HUP; while :; do smx ai watch & w=$!; wait $w; sleep 2; done", onLine)
