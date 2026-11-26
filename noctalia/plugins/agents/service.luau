--!nonstrict
-- Follows `smx ai watch`, publishing what agents are doing ("agents": the
-- server's state, its sessions, subagents' included, threads' stacks, and the
-- decision log: what stands, and what agents asked you) for
-- the widget and panel, and saying so when one needs you or fails, unless
-- you're looking at it (its TUI's window is focused). Finishing isn't urgent:
-- it waits in the overlay, to review.

local sessions = {} -- by id
local decisions = { current = {}, briefs = {} } -- what stands, and what agents asked you (smx ai log)
local stacks = {} -- threads' stacks (smx ai stack)
local pauses = {} -- each thread's latest: why its agent stopped (smx ai pause)
local asked = nil -- the questions told about, by id (nil: none yet seen)
local server = "stopped"

local function publish()
  local list = {}
  for _, session in sessions do
    table.insert(list, session)
  end
  table.sort(list, function(a, b) return (a.updated or 0) > (b.updated or 0) end) -- (newest first)
  noctalia.state.set("agents", { server = server, sessions = list, decisions = decisions, stacks = stacks, pauses = pauses })
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

-- A notification that opens its session (Open, or a click on it).
local function notify(say, summary, body, id)
  say(summary, body, {
    actions = { { id = "default" }, { id = "open", label = "Open" } },
    onAction = "onNotificationAction", context = "open:" .. id,
  })
end

-- One that opens the overlay (Mod+A), on its session if it has one (Review,
-- or a click on it): where you answer it, or can if you miss it.
local function review(say, summary, body, id)
  say(summary, body, {
    actions = { { id = "default" }, { id = "review", label = "Review" } },
    onAction = "onNotificationAction", context = "review:" .. (id or ""),
  })
end

-- Failed sessions, told together a moment after the first (so several
-- failing at once make one notification, not a pile).
local finished = {} -- ids
local finishedAt = nil
local together = 2000 -- ms

local function tellFinished()
  local still = {}
  for _, id in finished do
    local session = sessions[id]
    -- (Not if you've looked at it, or are, since.)
    if session and session.unseen and not lookingAt(session) then table.insert(still, session) end
  end
  finished, finishedAt = {}, nil
  if #still == 0 then return end
  local failed = 0
  for _, session in still do
    if session.state == "failed" then failed += 1 end
  end
  local say = failed > 0 and noctalia.notifyError or noctalia.notify
  if #still == 1 then
    local session = still[1]
    notify(say, (session.state == "done" and "Done: " or "Failed: ") .. title(session), session.last, session.id)
  else
    local titles = {}
    for _, session in still do
      table.insert(titles, (session.state == "failed" and "✗ " or "✓ ") .. title(session))
    end
    review(say, `{#still} agents failed`, table.concat(titles, "\n"))
  end
end

function update()
  if finishedAt and noctalia.nowMs() - finishedAt >= together then tellFinished() end
end
noctalia.setUpdateInterval(500)

-- A request, as it is: what it'd do, and where.
local function described(request)
  local what = request.action .. ": " .. table.concat(request.resources or {}, ", ")
  return request.cwd and (what .. "\nin " .. request.cwd) or what
end

-- What changed for you, if anything, from before to after: unless you're
-- looking at it, or said not to (the plugin's notify setting). Each new
-- request gets one, which only opens the overlay, where you answer it (so
-- one appearing as you type can't answer anything). (A subagent's finishing
-- is its parent's news, not yours.)
local function tell(before, after)
  if lookingAt(after) or noctalia.getConfig("notify") == false then return end
  local asked = {}
  for _, request in (before and before.permissions) or {} do
    asked[request.id] = true
  end
  for _, request in after.permissions or {} do
    if not asked[request.id] then
      review(noctalia.notify, "Needs permission: " .. title(after), described(request), after.id)
    end
  end
  local was = before and before.state
  if after.state == was then return end
  if after.state == "needs-input" then
    local f = after.forms[#after.forms]
    notify(noctalia.notify, "Asks: " .. title(after), f and f.title or nil, after.id)
  -- (Done is news, not urgent: it waits in the overlay, to review. Failing
  -- still says so.)
  elseif after.parent == nil and after.unseen and after.state == "failed" then
    table.insert(finished, after.id)
    finishedAt = finishedAt or noctalia.nowMs()
  end
end

-- (The context: "open:<session>" or "review:<session, or none>".)
function onNotificationAction(_action, context)
  local how, id = tostring(context or ""):match("^(%a+):(.*)$")
  if how == "open" and id ~= "" then
    noctalia.runAsync({ "smx", "ai", "open", id }, function(result)
      if result.exitCode ~= 0 then
        local said = (result.stderr or ""):gsub("^smx ai: ", ""):gsub("%s+$", "")
        noctalia.notifyError("Couldn't open the thread", said ~= "" and said or `smx ai open exited {result.exitCode}`)
      end
    end)
  elseif how == "review" then
    -- (Open, not toggle: never closing it if it's open already.)
    local open = { "noctalia", "msg", "panel-open", "smudgenix/agents:sessions" }
    if id ~= "" then table.insert(open, id) end
    noctalia.runAsync(open)
  end
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
  elseif event.type == "stacks" then
    stacks = event.stacks or {}
  elseif event.type == "pauses" then
    pauses = event.pauses or {}
  elseif event.type == "decisions" then
    decisions = { current = event.current or {}, briefs = event.briefs or {} }
    -- (A new question is news: it waits on you. Not those there at first.)
    local seen = {}
    for _, brief in decisions.briefs do
      seen[brief.id] = true
      if asked and not asked[brief.id] and noctalia.getConfig("notify") ~= false then
        local session = sessions[brief.thread] or sessions[brief.session]
        if not (session and lookingAt(session)) then
          review(noctalia.notify, "To decide: " .. (session and title(session) or brief.project or "an agent"), brief.question, brief.thread)
        end
      end
    end
    asked = seen
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
