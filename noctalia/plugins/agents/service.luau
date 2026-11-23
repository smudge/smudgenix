--!nonstrict
-- Follows `smx ai watch`, publishing what agents are doing ("agents": the
-- server's state, and its sessions) for the widget and panel, and saying so
-- when one needs you or finishes.

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

local function title(session)
  return session.title or "An agent"
end

-- What changed for you, if anything, from before to after.
local function tell(before, after)
  local was = before and before.state
  if after.state == was then return end
  local body
  if after.state == "needs-permission" then
    local p = after.permissions[#after.permissions]
    body = p and (p.action .. " " .. table.concat(p.resources or {}, ", ")) or nil
    noctalia.notify("Needs permission: " .. title(after), body, { actions = { { id = "open", label = "Open" } }, onAction = "onNotificationAction", context = after.id })
  elseif after.state == "needs-input" then
    local f = after.forms[#after.forms]
    noctalia.notify("Asks: " .. title(after), f and f.title or nil, { actions = { { id = "open", label = "Open" } }, onAction = "onNotificationAction", context = after.id })
  elseif after.unseen and (after.state == "done" or after.state == "failed") then
    local notify = after.state == "done" and noctalia.notify or noctalia.notifyError
    notify((after.state == "done" and "Done: " or "Failed: ") .. title(after), nil, { actions = { { id = "open", label = "Open" } }, onAction = "onNotificationAction", context = after.id })
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
    if event.parent == nil then
      tell(sessions[event.id], event)
      sessions[event.id] = event
    end
  elseif event.type == "removed" then
    sessions[event.id] = nil
  elseif event.type == "server" then
    server = event.state
    if server ~= "up" then sessions = {} end
  end
  publish()
end

publish()
noctalia.runStream("smx ai watch", onLine)
