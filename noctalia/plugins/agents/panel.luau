--!nonstrict
-- The agents overlay (Mod+A, or the bar widget): work to review (smx ai
-- review, which watch does when a session finishes; Enter opens one: its
-- files, flagged first, each to its diff), what agents are doing now (or
-- have open in a TUI), and recent sessions to return to (from the service),
-- with subagents under the sessions that started them. ↑/↓ (or k/j) choose,
-- →/← (or l/h) open and close a session's subagents, Enter or a click shows
-- one (smx ai open).

local open = false
local selected = 1
local shown = {} -- the rows, in order: { session, depth, parent (a row index) }
local expanded = {} -- by id: true, false, or nil (open if a subagent's at work)
local spin = 0 -- the loaders' angle
local spinning = false
local reviewing = nil -- the task whose review is open, by id
local fileSelected = 1
local reviewFiles = {} -- the open review's rows' files, in order

local marks = {
  ["needs-permission"] = { glyph = "alert-triangle", color = "tertiary", says = "needs permission" },
  ["needs-input"] = { glyph = "message-question", color = "tertiary", says = "asks you" },
  working = { glyph = "loader-2", color = "primary", says = "at work" },
  done = { glyph = "check", color = "secondary", says = "done" },
  failed = { glyph = "x", color = "error", says = "failed" },
  idle = { glyph = "point", color = "on_surface/0.6", says = "idle" },
}

local function needsYou(session)
  return session.state == "needs-permission" or session.state == "needs-input"
end

local function busy(session)
  return needsYou(session) or session.state == "working"
end

local function ago(ms)
  if not ms then return nil end
  local s = math.max(0, (noctalia.nowMs() - ms) / 1000)
  if s < 60 then return "just now" end
  if s < 3600 then return `{math.floor(s / 60)}m ago` end
  if s < 86400 then return `{math.floor(s / 3600)}h ago` end
  return `{math.floor(s / 86400)}d ago`
end

local function show(session)
  noctalia.runAsync({ "smx", "ai", "open", session.id })
  panel.close()
end

-- The sessions as trees: the top-level ones, and each one's subagents.
local function trees(sessions)
  local byId, children, roots = {}, {}, {}
  for _, session in sessions do
    byId[session.id] = session
  end
  for _, session in sessions do -- (newest first)
    if session.parent and byId[session.parent] then
      children[session.parent] = children[session.parent] or {}
      table.insert(children[session.parent], session)
    else
      table.insert(roots, session)
    end
  end
  return roots, children
end

-- Whether any of a session's subagents (or theirs) is at work, or needs you.
local function anyBusy(id, children, keep)
  for _, child in children[id] or {} do
    if keep(child) or anyBusy(child.id, children, keep) then return true end
  end
  return false
end

local function isExpanded(session, children)
  local e = expanded[session.id]
  if e == nil then return anyBusy(session.id, children, busy) end
  return e
end

local function chip(text)
  return ui.row({ padding = 4, radius = 6, fill = "on_surface/0.08" }, {
    ui.label({ text = text, fontSize = 10, color = "on_surface/0.7", maxLines = 1 }),
  })
end

-- Answering a request (smx ai allow|deny): once, always (its save patterns,
-- in its project, from now on), or deny.
local function answer(request, how)
  if how == "deny" then
    noctalia.runAsync({ "smx", "ai", "deny", request.id })
  elseif how == "always" then
    noctalia.runAsync({ "smx", "ai", "allow", request.id, "--always" })
  else
    noctalia.runAsync({ "smx", "ai", "allow", request.id })
  end
end

-- A request, as it is (not the agent's description of it): what it'd do,
-- where, and the answers.
local function request(r)
  local always = table.concat((#(r.save or {}) > 0 and r.save) or r.resources or {}, ", ")
  return ui.column({ gap = 4, padding = 8, radius = 6, fill = "tertiary/0.1" }, {
    ui.label({ text = r.action .. ": " .. table.concat(r.resources or {}, ", "), fontSize = 12, maxLines = 4 }),
    r.cwd and ui.label({ text = "in " .. r.cwd, fontSize = 11, color = "on_surface/0.6", maxLines = 1 }) or ui.box({ height = 0 }),
    ui.row({ gap = 6 }, {
      ui.button({ text = "Allow", variant = "primary", controlSize = "sm", onClick = function() answer(r, "once") end }),
      ui.button({ text = "Always", variant = "outline", controlSize = "sm", tooltip = `Allow {r.action} {always} in this project from now on`, onClick = function() answer(r, "always") end }),
      ui.button({ text = "Deny", variant = "destructive", controlSize = "sm", onClick = function() answer(r, "deny") end }),
    }),
  })
end

local function row(entry, index, children, now)
  local session, depth = entry.session, entry.depth
  local mark = marks[session.state] or marks.idle
  local kids = children[session.id]
  local isSelected = index == selected

  local details = { mark.says .. (session.unseen and ", new" or "") }
  if session.open then table.insert(details, "open") end
  if kids and not isExpanded(session, children) then
    table.insert(details, #kids == 1 and "1 subagent" or `{#kids} subagents`)
  end
  local when = ago(session.updated)
  if when then table.insert(details, when) end

  -- Running: orange (primary); open, or in Now: white; the rest, dimmer.
  local titleColor = session.state == "working" and "primary"
    or (session.open or now) and "on_surface"
    or "on_surface/0.75"

  local top = { ui.label({ text = session.title or "(untitled)", color = titleColor, maxLines = 1, flexGrow = 1 }) }
  if session.open then table.insert(top, ui.glyph({ name = "terminal-2", size = 14, color = "on_surface/0.6" })) end
  if session.project then table.insert(top, chip(session.project)) end
  local lines = {
    ui.row({ gap = 8, align = "center" }, top),
    ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }),
  }
  -- Its line: its latest reply if that's news (finished unseen, or asking
  -- you), else what it's about (from its latest compaction), else that reply.
  -- (Selected: both.)
  local news = session.last and (session.unseen or needsYou(session))
  local function say(text, maxLines)
    table.insert(lines, ui.label({ text = text, fontSize = 11, color = "on_surface/0.75", maxLines = maxLines }))
  end
  if isSelected then
    if session.about then say(session.about, 3) end
    if session.last then say((session.about and "Last: " or "") .. session.last, 3) end
  elseif news or not session.about then
    if session.last then say(session.last, 1) end
  else
    say(session.about, 1)
  end

  local toggle = kids and ui.row({
    onClick = function()
      expanded[session.id] = not isExpanded(session, children)
      render()
    end,
  }, { ui.glyph({ name = isExpanded(session, children) and "chevron-down" or "chevron-right", size = 14, color = "on_surface/0.6" }) })
    or ui.box({ width = 14, height = 14 })

  for _, r in session.permissions or {} do
    table.insert(lines, request(r))
  end

  local parts = {}
  if depth > 0 then table.insert(parts, ui.box({ width = 22 * depth, height = 1 })) end
  table.insert(parts, toggle)
  table.insert(parts, ui.glyph({ name = mark.glyph, size = 18, color = mark.color, rotation = session.state == "working" and spin or 0 }))
  table.insert(parts, ui.column({ gap = 2, flexGrow = 1 }, lines))
  return ui.row({
    key = "row-" .. index,
    gap = 8, padding = 8, radius = 8, align = "center",
    fill = isSelected and "primary/0.15" or nil,
    onClick = function() show(session) end,
  }, parts)
end

-- The first request a row's session is waiting on, if any.
local function asks(entry)
  return entry and entry.session and entry.session.permissions and entry.session.permissions[1]
end

-- (For a shell command line: a terminal's command is one.)
local function quote(s)
  return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Runs `smx ai …`, saying so if it fails (e.g. accepting a stale review).
local function run(argv)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError("smx ai " .. argv[3], ((result.stderr or ""):gsub("^smx ai: ", "")))
    end
  end)
end

-- A task's change, or one file of it, in a terminal (smx ai diff).
local function inspect(task, path)
  local command = "smx ai diff " .. quote(task.id)
  if path then command ..= " -- " .. quote(path) end
  noctalia.runInTerminal(command)
end

-- A task in review, in the list: how much there is to look at (and,
-- selected, what it says it did). Enter or a click opens its review.
local function taskRow(entry, index)
  local task = entry.task
  local review = task.review or {}
  local spots = review.hotspots or {}
  local isSelected = index == selected
  local stale = task.stale ~= nil

  local details = { task.state == "revising" and "revising" or "in review" }
  if stale then table.insert(details, "stale: changed since it was frozen") end
  table.insert(details, #spots == 0 and "nothing flagged" or #spots == 1 and "1 place to look" or `{#spots} places to look`)
  local when = ago(task.updated)
  if when then table.insert(details, when) end

  local top = { ui.label({ text = task.title or "(untitled)", maxLines = 1, flexGrow = 1 }) }
  if task.project then table.insert(top, chip(task.project)) end
  local lines = {
    ui.row({ gap = 8, align = "center" }, top),
    ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = stale and "tertiary" or "on_surface/0.6", maxLines = 1 }),
  }
  if isSelected and review.outcome and review.outcome.text then
    table.insert(lines, ui.label({ text = "It says: " .. (review.outcome.text:gsub("%s+", " ")), fontSize = 11, color = "on_surface/0.75", maxLines = 2 }))
  end

  return ui.row({
    key = "row-" .. index,
    gap = 8, padding = 8, radius = 8, align = "center",
    fill = isSelected and "primary/0.15" or nil,
    onClick = function() reviewing = task.id; fileSelected = 1; render() end,
  }, {
    ui.box({ width = 14, height = 14 }),
    ui.glyph({ name = "git-pull-request", size = 18, color = stale and "tertiary" or "secondary" }),
    ui.column({ gap = 2, flexGrow = 1 }, lines),
  })
end

-- One task's review (opened from its row): a summary, what it says it did
-- (one line), and its files, flagged ones first, each to open.
local function flags(task)
  local byPath = {}
  for _, spot in (task.review and task.review.hotspots) or {} do
    byPath[spot.path] = byPath[spot.path] or {}
    local whys = byPath[spot.path]
    local seen = false
    for _, why in whys do
      if why == spot.why then seen = true end
    end
    if not seen then table.insert(whys, spot.why) end
  end
  return byPath
end

local function renderReview(task)
  local review = task.review or {}
  local byPath = flags(task)
  reviewFiles = {}
  local flagged, rest = {}, {}
  for _, file in review.files or {} do
    table.insert(byPath[file.path] and flagged or rest, file)
  end
  for _, file in flagged do table.insert(reviewFiles, file) end
  for _, file in rest do table.insert(reviewFiles, file) end
  fileSelected = math.clamp(fileSelected, 1, math.max(1, #reviewFiles))

  local added, removed = 0, 0
  for _, file in reviewFiles do
    added += file.added or 0
    removed += file.removed or 0
  end
  local summary = { `{#reviewFiles} file{#reviewFiles == 1 and "" or "s"}, +{added} −{removed}`,
    #flagged == 0 and "nothing flagged" or `{#flagged} flagged` }
  if (review.round or 1) > 1 then table.insert(summary, `round {review.round}`) end
  if task.project then table.insert(summary, task.project) end

  local rows = {}
  if task.stale then
    table.insert(rows, ui.label({ text = "Stale: it's changed since this was frozen. p reviews it again.", fontSize = 12, color = "tertiary" }))
  end
  if review.outcome and review.outcome.text then
    table.insert(rows, ui.label({ text = "It says: " .. (review.outcome.text:gsub("%s+", " ")), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }))
  end
  for index, file in reviewFiles do
    local whys = byPath[file.path]
    local lines = {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = file.status or "M", fontSize = 11, color = "on_surface/0.5" }),
        ui.label({ text = file.path, maxLines = 1, flexGrow = 1 }),
        ui.label({ text = `+{file.added or 0} −{file.removed or 0}`, fontSize = 11, color = "on_surface/0.5" }),
      }),
    }
    for _, why in whys or {} do
      table.insert(lines, ui.label({ text = why, fontSize = 11, color = "tertiary", maxLines = 1 }))
    end
    table.insert(rows, ui.row({
      key = "file-" .. index,
      gap = 8, padding = 6, radius = 6, align = "center",
      fill = index == fileSelected and "primary/0.15" or nil,
      onClick = function() inspect(task, file.path) end,
    }, {
      ui.glyph({ name = whys and "alert-triangle" or "file", size = 14, color = whys and "tertiary" or "on_surface/0.5" }),
      ui.column({ gap = 2, flexGrow = 1 }, lines),
    }))
  end

  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.row({ onClick = function() reviewing = nil; render() end }, { ui.glyph({ name = "chevron-left", size = 16, color = "on_surface/0.6" }) }),
      ui.label({ text = task.title or "(untitled)", fontSize = 15, fontWeight = "bold", maxLines = 1, flexGrow = 1 }),
    }),
    ui.label({ text = table.concat(summary, "  ·  "), fontSize = 11, color = "on_surface/0.6" }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "file-" .. fileSelected }, rows),
    ui.label({ text = (task.stale and "p review again" or "a accept") .. "  ·  Enter its diff  ·  r tell it what to change  ·  d defer  ·  ← back",
      fontSize = 11, color = "on_surface/0.5" }),
  }))
end

-- What the keys do, on this row.
local function hints(entry)
  if entry and entry.task then
    return "Enter review  ·  " .. (entry.task.stale and "p review again" or "a accept") .. "  ·  r tell it what to change  ·  d defer  ·  Esc close"
  elseif asks(entry) then
    return "a allow  ·  Shift+A always  ·  d deny  ·  ↑↓ choose  ·  Enter open  ·  Esc close"
  end
  return "↑↓ choose  ·  →← subagents  ·  p prepare for review  ·  Enter open  ·  Esc close"
end

local function heading(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6" })
end

function render()
  if not open then return end
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  if reviewing then
    for _, task in agents.tasks or {} do
      if task.id == reviewing then
        renderReview(task)
        return
      end
    end
    reviewing = nil -- (gone: accepted elsewhere, say)
  end
  local roots, children = trees(agents.sessions or {})

  -- Now: what's at work, needs you, finished unseen, or open in a TUI.
  local inReview = {}
  for _, task in agents.tasks or {} do
    if task.state == "in-review" then inReview[task.session] = true end
  end
  local now, recent = {}, {}
  for _, root in roots do
    local isBusy = busy(root) or anyBusy(root.id, children, busy)
    local isNow = isBusy or ((root.open or root.unseen) and not inReview[root.id])
    table.insert(isNow and now or recent, root)
  end
  -- (What needs you first.)
  local function waits(s) return needsYou(s) or anyBusy(s.id, children, needsYou) end
  table.sort(now, function(a, b)
    local an, bn = waits(a), waits(b)
    if an ~= bn then return an end
    return (a.updated or 0) > (b.updated or 0)
  end)

  shown = {}
  spinning = false
  local rows = {}
  local reviewing = {}
  for _, task in agents.tasks or {} do
    if task.state == "in-review" or task.state == "revising" then table.insert(reviewing, task) end
  end
  if #reviewing > 0 then
    table.insert(rows, heading("To review"))
    for _, task in reviewing do
      table.insert(shown, { task = task, depth = 0 })
      table.insert(rows, taskRow(shown[#shown], #shown))
    end
  end
  local function add(session, depth, parent, isNow)
    table.insert(shown, { session = session, depth = depth, parent = parent })
    local index = #shown
    if session.state == "working" then spinning = true end
    table.insert(rows, row(shown[index], index, children, isNow))
    if isExpanded(session, children) then
      for _, child in children[session.id] or {} do
        add(child, depth + 1, index, isNow)
      end
    end
  end
  local function section(title, sessions, isNow)
    if #sessions == 0 then return end
    table.insert(rows, heading(title))
    for _, session in sessions do
      add(session, 0, nil, isNow)
    end
  end

  if agents.server == "down" then
    table.insert(rows, ui.label({ text = "OpenCode's server isn't reachable: see smx ai doctor.", color = "error" }))
  else
    if #now == 0 then
      table.insert(rows, heading("Now"))
      table.insert(rows, ui.label({ text = agents.server == "up" and "No agents at work." or "No agents: OpenCode's server isn't running.", color = "on_surface/0.6" }))
    else
      section("Now", now, true)
    end
    section("Recent", recent, false)
  end
  selected = math.clamp(selected, 1, math.max(1, #shown))
  panel.setNeedsFrameTick(spinning)

  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.label({ text = "Agents", fontSize = 15, fontWeight = "bold" }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "row-" .. selected }, rows),
    ui.label({ text = hints(shown[selected]), fontSize = 11, color = "on_surface/0.5" }),
  }))
end

noctalia.state.watch("agents", render)

-- (The loaders turn, a step every tenth of a second, while any's shown.)
local sinceStep = 0
function onFrameTick(deltaMs)
  if not spinning then return end
  sinceStep += deltaMs
  if sinceStep < 100 then return end
  sinceStep = 0
  spin = (spin + 36) % 360
  render()
end

-- (From a notification: on its session, given as the context.)
function onOpen(context)
  open = true
  selected = 1
  reviewing = nil
  render()
  if type(context) == "string" and context ~= "" then
    for index, entry in shown do
      if entry.session and entry.session.id == context then
        selected = index
        render()
        break
      end
    end
  end
end

function onClose()
  open = false
  panel.setNeedsFrameTick(false)
end

function onKey(chord, pressed)
  if not (pressed == true or pressed == "true") then return end
  -- (In a review.)
  if reviewing then
    local task = nil
    for _, t in (noctalia.state.get("agents") or {}).tasks or {} do
      if t.id == reviewing then task = t end
    end
    if not task then reviewing = nil; render(); return end
    if chord == "Down" or chord == "j" then
      fileSelected = math.min(fileSelected + 1, math.max(1, #reviewFiles))
    elseif chord == "Up" or chord == "k" then
      fileSelected = math.max(fileSelected - 1, 1)
    elseif chord == "Left" or chord == "h" then
      reviewing = nil
    elseif chord == "Return" then
      if reviewFiles[fileSelected] then inspect(task, reviewFiles[fileSelected].path) end
      return
    elseif chord == "a" or chord == "d" then
      run({ "smx", "ai", chord == "a" and "accept" or "defer", task.id })
      reviewing = nil
    elseif chord == "r" then
      noctalia.runAsync({ "smx", "ai", "open", task.session }) -- (to say what to change)
      panel.close()
      return
    elseif chord == "p" then
      run({ "smx", "ai", "review", task.session })
    end
    render()
    return
  end
  local entry = shown[selected]
  local task = entry and entry.task
  if task and (chord == "Right" or chord == "l" or chord == "Return") then
    reviewing = task.id
    fileSelected = 1
    render()
    return
  end
  if task and (chord == "a" or chord == "d" or chord == "r" or chord == "p") then
    if chord == "a" then
      run({ "smx", "ai", "accept", task.id })
    elseif chord == "d" then
      run({ "smx", "ai", "defer", task.id })
    elseif chord == "r" then
      noctalia.runAsync({ "smx", "ai", "open", task.session }) -- (to say what to change)
      panel.close()
    else
      run({ "smx", "ai", "review", task.session }) -- (again: a new round)
    end
    return
  end
  local session = entry and entry.session
  if chord == "Down" or chord == "j" then
    selected = math.min(selected + 1, math.max(1, #shown))
  elseif chord == "Up" or chord == "k" then
    selected = math.max(selected - 1, 1)
  elseif (chord == "Right" or chord == "l") and session then
    local _, children = trees((noctalia.state.get("agents") or {}).sessions or {})
    if children[entry.session.id] then
      if isExpanded(entry.session, children) then
        selected += 1 -- (to its first subagent)
      else
        expanded[entry.session.id] = true
      end
    end
  elseif (chord == "Left" or chord == "h") and session then
    local _, children = trees((noctalia.state.get("agents") or {}).sessions or {})
    if children[entry.session.id] and isExpanded(entry.session, children) then
      expanded[entry.session.id] = false
    elseif entry.parent then
      selected = entry.parent
    end
  elseif (chord == "a" or chord == "Shift+A" or chord == "Shift+a" or chord == "d") and asks(entry) then
    answer(asks(entry), chord == "d" and "deny" or chord == "a" and "once" or "always")
    return
  elseif chord == "p" and session then
    run({ "smx", "ai", "review", session.id }) -- (prepare it for review)
    return
  elseif chord == "Return" then
    if session then show(session) end
    return
  end
  render()
end
