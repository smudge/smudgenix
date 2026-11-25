--!nonstrict
-- The agents overlay (Mod+A, or the bar widget): your threads of work, in a
-- project (the focused window's, at first; Tab for the next, or all), by
-- whose turn it is:
--
-- - To decide: what agents asked you, and their provisional calls (from the
--   decision log, smx ai log). Enter opens one with what you need to decide
--   it: its options and the agent's pick, and what already stands there.
--   Take an option (1–4) or write your own (w), then why, or leave it open
--   (o); an agent's call you confirm (c), replace (w) or withdraw (x).
-- - Your turn: it needs you (a permission, a question), or it's back: layers
--   to review (Enter opens its stack: bottom first, each layer's diff right
--   there; a approves up to one, publishing them as a chain of pull
--   requests; r has one revised), an answer, or a failure. Once they're all
--   approved, the thread waits with the forge, parked.
-- - Away: an agent's at it, in the background.
-- - Parked: open, waiting for you to pick it up (collapsed to a count).
--
-- A thread stays until you close it (c). n starts one (Enter: in the
-- background, where it comes back when it's done; Shift+Enter: in a TUI); r
-- tells one more; z parks one. Everything goes through smx ai (the service
-- publishes what it says); nothing here talks to OpenCode.

local open = false
local selected = 1
local shown = {} -- the rows: { thread | parked = true, depth, parent (a row index) }
local expanded = {} -- subagents shown, by thread id (nil: when one needs you)
local parkedOpen = false
local spin = 0 -- the loaders' angle
local spinning = false
local scope = nil -- a project's name, or nil for all
local scopeChosen = false -- (by you, so the focused window's doesn't override it)
local composing = nil -- { mode = "new" | "reply", thread?, text, key }
local composeCount = 0
local confirming = nil -- a thread being closed with layers still in its stack
local problem = nil -- the last `smx ai` failure, shown until the next key
local here = nil -- the focused window's folder, when the overlay opened (smx ai context)
local submitted = 0 -- when something was last sent (so one Enter can't also open a thread)
local deciding = nil -- what's open to decide: { brief } or { line }, by id
local writing = nil -- your line, being written: { stage = "line" | "why", kind, text, why, initial, key }
local stacking = nil -- the thread whose stack is open, by id
local layerSelected = 1
local diffs = {} -- layers' diffs, by commit: { lines, more } (or loading = true)
local diffAt = 1 -- the diff's line to show
local stacksBy = {} -- threads' stacks, by thread id (from the last render)
local publishing = nil -- what's being approved (or synced), said while it is

-- --- Helpers -----------------------------------------------------------------

local function needsYou(session)
  return session.state == "needs-permission" or session.state == "needs-input"
end

local function ago(ms)
  if not ms then return nil end
  local s = math.max(0, (noctalia.nowMs() - ms) / 1000)
  if s < 60 then return "just now" end
  if s < 3600 then return `{math.floor(s / 60)}m ago` end
  if s < 86400 then return `{math.floor(s / 3600)}h ago` end
  return `{math.floor(s / 86400)}d ago`
end

-- (For a shell command line: a terminal's command is one.)
local function quote(s)
  return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Runs `smx ai …`, saying so if it fails: at the top of the overlay, until
-- the next key (a toast goes too fast).
local function run(argv, after)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      local said = ((result.stderr or ""):gsub("\27%[[%d;]*m", ""):gsub("^smx ai: ", ""):gsub("%s+$", ""))
      problem = `smx ai {argv[3]} failed: {said ~= "" and said or ("exit " .. tostring(result.exitCode))}`
    elseif after then
      after(result)
    end
    render()
  end)
end

local function chip(text, on)
  return ui.row({ padding = 4, radius = 6, fill = on and "primary/0.25" or "on_surface/0.08" }, {
    ui.label({ text = text, fontSize = 10, color = on and "on_surface" or "on_surface/0.7", maxLines = 1 }),
  })
end

-- --- Decisions ---------------------------------------------------------------

-- What's yours to decide, in a project (or all): what agents asked you, then
-- their provisional calls, to confirm or overturn. Newest first.
local function toDecide(agents, project)
  local d = agents.decisions or {}
  local items = {}
  for _, brief in d.briefs or {} do
    if not project or brief.project == project then table.insert(items, { brief = brief }) end
  end
  table.sort(items, function(a, b) return (a.brief.time or 0) > (b.brief.time or 0) end)
  local calls = {}
  for _, line in d.current or {} do
    if line.provisional and (not project or line.project == project) then table.insert(calls, { line = line }) end
  end
  table.sort(calls, function(a, b) return (a.line.time or 0) > (b.line.time or 0) end)
  for _, item in calls do table.insert(items, item) end
  return items
end

-- The questions waiting on each thread.
local function asking(agents)
  local byThread = {}
  for _, brief in (agents.decisions or {}).briefs or {} do
    byThread[brief.thread] = byThread[brief.thread] or {}
    table.insert(byThread[brief.thread], brief)
  end
  return byThread
end

-- What stands where a question is (yours, its project's, its thread's): the
-- context to decide it in.
local function standing(agents, project, thread)
  local lines = {}
  for _, line in (agents.decisions or {}).current or {} do
    if line.scope == "you" or (line.project == project and (line.scope == "project" or line.thread == thread)) then
      table.insert(lines, line)
    end
  end
  return lines
end

local function sessionById(agents, id)
  for _, session in agents.sessions or {} do
    if session.id == id then return session end
  end
  return nil
end

-- --- Threads -----------------------------------------------------------------

-- Your threads (top-level sessions), each with its subagents; and the
-- projects they're in, most recent first.
local function threads(agents)
  local byId, children, list = {}, {}, {}
  for _, session in agents.sessions or {} do
    byId[session.id] = session
  end
  for _, session in agents.sessions or {} do -- (newest first)
    if session.parent and byId[session.parent] then
      children[session.parent] = children[session.parent] or {}
      table.insert(children[session.parent], session)
    else
      table.insert(list, session)
    end
  end
  stacksBy = {}
  for _, stack in agents.stacks or {} do
    stacksBy[stack.session] = stack
  end
  local projects, seen = {}, {}
  for _, thread in list do
    if thread.project and not seen[thread.project] then
      seen[thread.project] = true
      table.insert(projects, { name = thread.project, dir = thread.dir })
    end
  end
  return list, children, projects
end

-- Whether any of a thread's subagents (or theirs) is so.
local function anyChild(id, children, keep)
  for _, child in children[id] or {} do
    if keep(child) or anyChild(child.id, children, keep) then return true end
  end
  return false
end

-- Whose turn a thread is, and what that means: "you" (needs you, or back),
-- "away" (at work), or "parked"; with a word on it.
local function turn(thread, children, questions)
  if questions and #questions > 0 then
    return "you", 0, #questions == 1 and "asks you to decide" or `asks you to decide {#questions} things`
  end
  if needsYou(thread) or anyChild(thread.id, children, needsYou) then
    local asking = needsYou(thread) and thread or nil
    return "you", 0, asking and asking.state == "needs-input" and "asks you" or "needs your permission"
  end
  if thread.state == "working" then
    return "away", 0, "at work"
  end
  if anyChild(thread.id, children, function(s) return s.state == "working" end) then
    return "away", 0, "subagents at work"
  end
  local stack = stacksBy[thread.id]
  local n, spots, conflicted, approved, failing = 0, 0, 0, 0, 0
  for _, layer in stack and stack.layers or {} do
    if layer.state == "approved" then
      approved += 1
    else
      n += 1
      spots += #(layer.hotspots or {})
    end
    if layer.conflict then conflicted += 1 end
    if layer.check and layer.check.state == "failed" then failing += 1 end
  end
  if n > 0 then
    return "you", 1, `{n} layer{n == 1 and "" or "s"} to review` .. (spots > 0 and `, {spots} flagged` or "")
      .. (conflicted > 0 and `, {conflicted} conflicted` or "") .. (approved > 0 and `, {approved} approved` or "")
      .. (failing > 0 and `, {failing} failing {failing == 1 and "its" or "their"} check` or "")
  end
  if thread.unseen then
    return "you", 2, thread.state == "failed" and "back: it failed" or "back: it's answered"
  end
  return "parked", 0, approved > 0 and `{approved} layer{approved == 1 and "" or "s"} with the forge` or "parked"
end

local function glyphFor(thread, where, questions)
  if questions and #questions > 0 then return "help-circle", "tertiary" end
  if where == "you" and stacksBy[thread.id] and #(stacksBy[thread.id].layers or {}) > 0 then return "stack-2", "secondary" end
  if where == "away" then return "loader-2", "primary" end
  if needsYou(thread) then return "alert-triangle", "tertiary" end
  if where == "you" and thread.state == "failed" then return "x", "error" end
  if where == "you" then return "corner-down-left", "secondary" end
  return "point", "on_surface/0.5"
end

-- Answering a request (smx ai allow|deny): once, always (its save
-- patterns, in its project, from now on), or deny.
local function answer(request, how)
  if how == "deny" then
    run({ "smx", "ai", "deny", request.id })
  elseif how == "always" then
    run({ "smx", "ai", "allow", request.id, "--always" })
  else
    run({ "smx", "ai", "allow", request.id })
  end
end

-- A request, as it is (not the agent's description of it): what it'd do,
-- where, and the answers.
local function request(r)
  local always = table.concat((#(r.save or {}) > 0 and r.save) or r.resources or {}, ", ")
  local parts = { ui.label({ text = r.action .. ": " .. table.concat(r.resources or {}, ", "), fontSize = 12, maxLines = 4 }) }
  if r.cwd then table.insert(parts, ui.label({ text = "in " .. r.cwd, fontSize = 11, color = "on_surface/0.6", maxLines = 1 })) end
  table.insert(parts, ui.row({ gap = 6 }, {
    ui.button({ text = "Allow", variant = "primary", controlSize = "sm", onClick = function() answer(r, "once") end }),
    ui.button({ text = "Always", variant = "outline", controlSize = "sm", tooltip = `Allow {r.action} {always} in this project from now on`, onClick = function() answer(r, "always") end }),
    ui.button({ text = "Deny", variant = "destructive", controlSize = "sm", onClick = function() answer(r, "deny") end }),
  }))
  return ui.column({ gap = 4, padding = 8, radius = 6, fill = "tertiary/0.1" }, parts)
end

-- The first request a row's session is waiting on, if any.
local function asks(entry)
  return entry and entry.thread and entry.thread.permissions and entry.thread.permissions[1]
end

-- Opens a thread: its stack, if it has layers to review; else its TUI.
local function enter(thread)
  local stack = stacksBy[thread.id]
  if stack and #(stack.layers or {}) > 0 then
    stacking, layerSelected, diffAt = thread.id, 1, 1
    render()
  else
    noctalia.runAsync({ "smx", "ai", "open", thread.id })
    panel.close()
  end
end

local function compose(mode, thread)
  composeCount += 1
  composing = { mode = mode, thread = thread, text = "", key = "compose-" .. composeCount }
  render()
end

-- Sends what's composed: a new thread (in the background, or a TUI), or a
-- reply.
local function submit(text, inTui)
  local c = composing
  if not c or not text or text:match("^%s*$") then return end
  composing = nil
  submitted = noctalia.nowMs()
  if c.mode == "reply" and c.thread then
    run({ "smx", "ai", "reply", c.thread.id, (c.prefix or "") .. text })
  else
    local argv = { "smx", "ai", "new" }
    if c.dir then
      table.insert(argv, "--dir")
      table.insert(argv, c.dir)
    end
    if inTui then
      table.insert(argv, "--tui")
      panel.close()
    end
    table.insert(argv, text)
    run(argv)
  end
  render()
end

-- Closing a thread: at once, or (with layers in its stack) after you decide.
local function close(thread, decision)
  local stack = stacksBy[thread.id]
  if stack and #(stack.layers or {}) > 0 and not decision then
    confirming = thread
    render()
    return
  end
  confirming = nil
  local argv = { "smx", "ai", "close", thread.id }
  if decision then table.insert(argv, "--" .. decision) end
  run(argv)
end

-- --- Rendering ---------------------------------------------------------------

local function heading(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6" })
end

local function hints(entry)
  if composing then
    return composing.mode == "reply" and "Enter send  ·  Esc close"
      or "Enter start, in the background  ·  Shift+Enter start, in a TUI  ·  Esc close"
  elseif confirming then
    return "a approve its layers and close  ·  x set them aside and close  ·  any other key: don't"
  elseif entry and entry.parked then
    return "Enter or → show parked  ·  n new thread  ·  Tab project"
  elseif entry and entry.decide then
    return "Enter decide it  ·  n new thread  ·  Tab project"
  elseif asks(entry) then
    return "a allow  ·  Shift+A always  ·  d deny  ·  Enter open  ·  r reply  ·  n new"
  elseif entry and entry.thread then
    return "Enter open  ·  r reply  ·  z park  ·  c close  ·  n new  ·  Tab project"
  end
  return "n new thread  ·  Tab project  ·  Esc close"
end

local function threadRow(entry, index, children, questions)
  local thread = entry.thread
  local where, _, says = turn(thread, children, questions[thread.id])
  local glyph, color = glyphFor(thread, where, questions[thread.id])
  local isSelected = index == selected

  local details = { says }
  local kids = children[thread.id]
  if kids and not expanded[thread.id] then table.insert(details, #kids == 1 and "1 subagent" or `{#kids} subagents`) end
  if thread.open then table.insert(details, "open") end
  if not scope and thread.project then table.insert(details, thread.project) end
  local when = ago(thread.updated)
  if when then table.insert(details, when) end

  -- Away: orange (primary); your turn: white; parked: dimmer.
  local titleColor = where == "away" and "primary" or where == "you" and "on_surface" or "on_surface/0.7"
  local top = { ui.label({ text = thread.title or "(untitled)", color = titleColor, maxLines = 1, flexGrow = 1 }) }
  if thread.open then table.insert(top, ui.glyph({ name = "terminal-2", size = 14, color = "on_surface/0.6" })) end
  local lines = {
    ui.row({ gap = 8, align = "center" }, top),
    ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }),
  }
  -- Its line: the reply if that's news; else what it's about. (Selected:
  -- both.)
  local news = thread.last and (thread.unseen or needsYou(thread))
  local function say(text, maxLines)
    table.insert(lines, ui.label({ text = text, fontSize = 11, color = "on_surface/0.75", maxLines = maxLines }))
  end
  if isSelected then
    if thread.about then say(thread.about, 2) end
    if thread.last then say((thread.about and "Last: " or "") .. thread.last, 3) end
  elseif news or not thread.about then
    if thread.last then say(thread.last, 1) end
  else
    say(thread.about, 1)
  end
  for _, r in thread.permissions or {} do
    table.insert(lines, request(r))
  end
  if confirming and confirming.id == thread.id then
    table.insert(lines, ui.row({ gap = 6 }, {
      ui.label({ text = "It has layers:", fontSize = 12, color = "tertiary" }),
      ui.button({ text = "Approve them all, and close", variant = "primary", controlSize = "sm", onClick = function() close(thread, "accept") end }),
      ui.button({ text = "Set them aside, and close", variant = "outline", controlSize = "sm", onClick = function() close(thread, "discard") end }),
    }))
  end

  local parts = {}
  if entry.depth > 0 then table.insert(parts, ui.box({ width = 22 * entry.depth, height = 1 })) end
  table.insert(parts, ui.glyph({ name = glyph, size = 18, color = color, rotation = glyph == "loader-2" and spin or 0 }))
  table.insert(parts, ui.column({ gap = 2, flexGrow = 1 }, lines))
  return ui.row({
    key = "row-" .. index,
    gap = 8, padding = 8, radius = 8, align = "center",
    fill = isSelected and "primary/0.15" or nil,
    onClick = function()
      selected = index
      enter(thread)
    end,
  }, parts)
end

-- --- Stacks ------------------------------------------------------------------

local maxDiffLines = 600

-- A layer's diff (smx ai stack diff), fetched once: commits don't change.
local function loadDiff(stack, layer)
  if not layer or diffs[layer.commit] then return end
  diffs[layer.commit] = { loading = true }
  noctalia.runAsync({ "smx", "ai", "stack", "diff", stack.session, layer.change }, function(result)
    if result.exitCode ~= 0 then
      diffs[layer.commit] = { lines = { "(couldn't show it: " .. ((result.stderr or ""):gsub("%s+$", "")) .. ")" }, more = 0 }
    else
      local lines, total = {}, 0
      for line in ((result.stdout or "") .. "\n"):gmatch("(.-)\n") do
        total += 1
        if total <= maxDiffLines then table.insert(lines, line) end
      end
      if lines[#lines] == "" then table.remove(lines) end
      diffs[layer.commit] = { lines = lines, more = math.max(0, total - maxDiffLines) }
    end
    render()
  end)
end

local function diffLine(line, index)
  local color, weight = "on_surface/0.8", nil
  if line:sub(1, 4) == "diff" then
    color, weight = "on_surface", "bold"
  elseif line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" or line:sub(1, 5) == "index" or line:sub(1, 3) == "new" or line:sub(1, 7) == "deleted" then
    color = "on_surface/0.45"
  elseif line:sub(1, 2) == "@@" then
    color = "primary/0.8"
  elseif line:sub(1, 1) == "+" then
    color = "secondary"
  elseif line:sub(1, 1) == "-" then
    color = "error"
  end
  return ui.label({ key = "d-" .. index, text = line == "" and " " or line, fontSize = 11, fontWeight = weight, color = color, maxLines = 1 })
end

-- A thread's stack, reviewed from the bottom (what lands first): each
-- layer's purpose and size, and the selected one's hotspots and diff, here.
local function renderStack(agents, stack)
  local thread = sessionById(agents, stack.session)
  layerSelected = math.clamp(layerSelected, 1, math.max(1, #stack.layers))
  local selectedLayer = stack.layers[layerSelected]
  loadDiff(stack, selectedLayer)

  local rows = {}
  for i, layer in stack.layers do
    local spots = #(layer.hotspots or {})
    local facts = { `{#(layer.files or {})} file{#(layer.files or {}) == 1 and "" or "s"}`, `+{layer.added or 0} −{layer.removed or 0}` }
    if spots > 0 then table.insert(facts, `{spots} flagged`) end
    if layer.conflict then table.insert(facts, "conflicted") end
    if stack.revising == layer.change then table.insert(facts, "being revised") end
    local check = layer.check and layer.check.state
    if check == "passed" then table.insert(facts, "✓ check")
    elseif check == "failed" then table.insert(facts, "✗ check")
    elseif check == "running" then table.insert(facts, "checking…") end
    local pr = layer.published and layer.published.pr
    if layer.state == "approved" then
      table.insert(facts, pr and `approved: #{pr.number}` or "approved")
      if layer.published and layer.published.branch and not layer.pushed then table.insert(facts, "restacked: s publishes it") end
    elseif layer.state == "changed" then
      table.insert(facts, "changed since you approved it")
    end
    table.insert(rows, ui.row({
      key = "layer-" .. i, gap = 8, padding = 6, radius = 6, align = "center",
      fill = i == layerSelected and "primary/0.15" or nil,
      onClick = function() layerSelected = i; diffAt = 1; render() end,
    }, {
      layer.state == "approved" and ui.glyph({ name = "check", size = 14, color = "secondary" })
        or ui.label({ text = tostring(i), fontSize = 12, fontWeight = "bold", color = "on_surface/0.5" }),
      ui.label({ text = layer.title ~= "" and layer.title or "(no purpose given)", maxLines = 1, flexGrow = 1,
        color = layer.conflict and "error" or "on_surface" }),
      ui.label({ text = table.concat(facts, "  ·  "), fontSize = 11, color = check == "failed" and "error" or spots > 0 and "tertiary" or "on_surface/0.55" }),
    }))
  end
  if stack.uncommitted then
    table.insert(rows, ui.label({ text = "And changes it hasn't committed yet.", fontSize = 11, color = "on_surface/0.5" }))
  end

  -- The selected layer: its check, what's flagged, its calls still to settle,
  -- its diff.
  local detail = {}
  if selectedLayer then
    local check = selectedLayer.check
    local said = check and ({
      passed = { `✓ Its check passes on this layer: {check.command}`, "secondary" },
      failed = { `✗ Its check fails on this layer (exit {check.exit}): {check.command}. e shows its log; v runs it again; Shift+A approves anyway.`, "error" },
      running = { `Checking: {check.command}…`, "primary" },
      interrupted = { `Its check was interrupted: {check.command}. v runs it again.`, "tertiary" },
    })[check.state] or (selectedLayer.checkable and { "Not checked yet: it's in line (v checks it now).", "on_surface/0.6" }
      or { "No check known for this project: smx ai check <session> --command \"<check>\" sets one.", "on_surface/0.5" })
    table.insert(detail, ui.label({ text = said[1], fontSize = 11, color = said[2], maxLines = 2 }))
    for _, spot in selectedLayer.hotspots or {} do
      table.insert(detail, ui.label({ text = `⚑ {spot.path}: {spot.why}`, fontSize = 11, color = "tertiary", maxLines = 2 }))
    end
    for _, line in (agents.decisions or {}).current or {} do
      if line.provisional and line.layer == selectedLayer.change then
        table.insert(detail, ui.label({ text = `An agent's call in it, to settle first (in To decide): {line.text}`, fontSize = 11, color = "secondary", maxLines = 2 }))
      end
    end
    local diff = diffs[selectedLayer.commit]
    if not diff or diff.loading then
      table.insert(detail, ui.label({ text = "Loading its diff…", fontSize = 11, color = "on_surface/0.5" }))
    else
      for i, line in diff.lines do table.insert(detail, diffLine(line, i)) end
      if diff.more > 0 then
        table.insert(detail, ui.label({ text = `… {diff.more} more lines: Enter shows it all, in a terminal`, fontSize = 11, color = "on_surface/0.5" }))
      end
    end
  end

  local said = { stack.project, "on " .. stack.trunk }
  if (stack.merged or 0) > 0 then table.insert(said, `{stack.merged} merged`) end
  if thread and thread.state == "working" then table.insert(said, "its agent is at work") end
  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.row({ onClick = function() stacking = nil; render() end }, { ui.glyph({ name = "chevron-left", size = 16, color = "on_surface/0.6" }) }),
      ui.label({ text = thread and thread.title or "(a thread)", fontSize = 15, fontWeight = "bold", maxLines = 1, flexGrow = 1 }),
    }),
    ui.label({ text = table.concat(said, "  ·  ") .. "  ·  bottom first: it merges first", fontSize = 11, color = "on_surface/0.6" }),
    publishing and ui.label({ text = publishing, fontSize = 12, color = "primary", maxLines = 2 }) or ui.box({ height = 0 }),
    problem and ui.label({ text = problem, fontSize = 12, color = "error", maxLines = 4 }) or ui.box({ height = 0 }),
    composing and ui.input({
      key = composing.key, placeholder = composing.placeholder or "…", focus = true,
      onChange = function(text) if composing then composing.text = text end end,
      onSubmit = function(text) submit(text, false) end,
    }) or ui.box({ height = 0 }),
    ui.column({ gap = 2 }, rows),
    ui.scroll({ flexGrow = 1, gap = 0, revealKey = "d-" .. diffAt }, detail),
    ui.label({ text = "j/k layer  ·  Shift+J/K scroll  ·  a approve up to it (pull requests)  ·  r revise  ·  v check  ·  s sync  ·  Enter full diff  ·  ← back",
      fontSize = 11, color = "on_surface/0.5" }),
  }))
end

-- One thing to decide, in the list: a question, or an agent's call.
local function decideRow(entry, index, agents)
  local brief, line = entry.decide.brief, entry.decide.line
  local from = sessionById(agents, brief and brief.thread or line.thread)
  local details = { brief and "asks you" or "an agent's call: confirm or overturn" }
  if from and from.title then table.insert(details, from.title) end
  if not scope then table.insert(details, (brief or line).project) end
  local when = ago((brief or line).time)
  if when then table.insert(details, when) end
  return ui.row({
    key = "row-" .. index,
    gap = 8, padding = 8, radius = 8, align = "center",
    fill = index == selected and "primary/0.15" or nil,
    onClick = function()
      selected = index
      deciding = entry.decide
      render()
    end,
  }, {
    ui.glyph({ name = brief and "help-circle" or "circle-dashed", size = 18, color = brief and "tertiary" or "secondary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = brief and brief.question or line.text, maxLines = 2 }),
      ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }),
    }),
  })
end

-- Writing your line: what it is, then (Enter) why, then (Enter) it's in the
-- log. (Starting from an option's text, if you took one.)
local function write(kind, initial)
  composeCount += 1
  writing = { stage = "line", kind = kind, text = initial or "", initial = initial or "", key = "write-" .. composeCount }
  render()
end

local function advance(text)
  local w, d = writing, deciding
  if not w or not d or noctalia.nowMs() - submitted < 300 then return end
  submitted = noctalia.nowMs()
  if w.stage == "line" then
    if not text or text:match("^%s*$") then return end
    w.text = text
    composeCount += 1
    w.stage, w.why, w.key = "why", "", "write-" .. composeCount
    render()
    return
  end
  local argv = { "smx", "ai", "decide", w.text }
  if text and not text:match("^%s*$") then
    table.insert(argv, "--why")
    table.insert(argv, text)
  end
  if w.kind == "open" then
    table.insert(argv, "--kind")
    table.insert(argv, "open")
  end
  table.insert(argv, d.brief and "--answers" or "--supersedes")
  table.insert(argv, (d.brief or d.line).id)
  writing = nil
  run(argv, function() deciding = nil end)
end

-- A question (or a call) to decide, with what you need to decide it: its
-- options and the agent's pick, where it's from, and what already stands
-- there (direction, constraints, decisions, what's open).
local function renderDecision(agents, d)
  local brief, line = d.brief, d.line
  local item = brief or line
  local from = sessionById(agents, item.thread)
  local rows = {}
  local where = { item.project }
  if from and from.title then table.insert(where, "from " .. from.title) end
  local when = ago(item.time)
  if when then table.insert(where, when) end
  table.insert(rows, ui.label({ text = table.concat(where, "  ·  "), fontSize = 11, color = "on_surface/0.6", maxLines = 1 }))

  if brief then
    for i, option in brief.options or {} do
      local picked = brief.pick == i - 1
      table.insert(rows, ui.row({
        gap = 8, padding = 6, radius = 6, align = "center",
        fill = picked and "secondary/0.1" or "on_surface/0.04",
        onClick = function() write("decision", option.text) end,
      }, {
        ui.label({ text = tostring(i), fontSize = 12, fontWeight = "bold", color = "on_surface/0.6" }),
        ui.label({ text = option.text, maxLines = 2, flexGrow = 1 }),
        picked and ui.label({ text = "its pick", fontSize = 10, color = "secondary" }) or ui.box({ width = 0 }),
      }))
    end
  else
    table.insert(rows, ui.label({ text = (line.why and ("Why: " .. line.why) or "No why given") .. ". Provisional until you confirm it.",
      fontSize = 12, color = "on_surface/0.75", maxLines = 3 }))
  end

  if writing then
    local placeholder = writing.stage == "why" and "Why, in a few words (Enter: none)"
      or writing.kind == "open" and "What's left open, and until when"
      or (line and "Your line instead" or "Your decision, one line")
    if writing.stage == "why" then
      table.insert(rows, ui.label({ text = writing.text, fontSize = 12, color = "on_surface", maxLines = 2 }))
    end
    table.insert(rows, ui.input({
      key = writing.key, placeholder = placeholder, focus = true,
      text = writing.stage == "line" and writing.initial or nil,
      onChange = function(text) if writing then if writing.stage == "line" then writing.text = text else writing.why = text end end end,
      onSubmit = function(text) advance(text) end,
    }))
  end

  -- What stands there.
  local stands = standing(agents, item.project, item.thread)
  local titles = { direction = "Direction", constraint = "Constraints", decision = "Decisions", open = "Open, on purpose" }
  for _, kind in { "direction", "constraint", "decision", "open" } do
    local these = {}
    for _, l in stands do
      if l.kind == kind and l.id ~= item.id then table.insert(these, l) end
    end
    if #these > 0 then
      table.insert(rows, heading(titles[kind] .. (kind == "direction" and "" or ` in {item.project}`)))
      table.sort(these, function(a, b) return (a.time or 0) > (b.time or 0) end)
      for i, l in these do
        if i > 6 then
          table.insert(rows, ui.label({ text = `and {#these - 6} more (smx ai log --current)`, fontSize = 11, color = "on_surface/0.5" }))
          break
        end
        table.insert(rows, ui.label({ text = l.text .. (l.why and (": " .. l.why) or "") .. (l.provisional and "  (provisional)" or ""),
          fontSize = 12, color = "on_surface/0.75", maxLines = 2 }))
      end
    end
  end
  if #stands == 0 then
    table.insert(rows, ui.label({ text = `Nothing stands in {item.project} yet: no direction or constraints to go by.`, fontSize = 12, color = "on_surface/0.5" }))
  end

  local keys = writing and (writing.stage == "line" and "Enter next: why  ·  Esc close" or "Enter decide  ·  Esc close")
    or brief and "1–4 take an option (and edit it)  ·  w write your own  ·  o leave it open  ·  ← back"
    or "c confirm  ·  w replace it with yours  ·  x withdraw  ·  ← back"
  panel.render(ui.column({ padding = 14, gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.row({ onClick = function() deciding, writing = nil, nil; render() end }, { ui.glyph({ name = "chevron-left", size = 16, color = "on_surface/0.6" }) }),
      ui.label({ text = brief and brief.question or line.text, fontSize = 15, fontWeight = "bold", maxLines = 3, flexGrow = 1 }),
    }),
    problem and ui.label({ text = problem, fontSize = 12, color = "error", maxLines = 4 }) or ui.box({ height = 0 }),
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
    ui.label({ text = keys, fontSize = 11, color = "on_surface/0.5" }),
  }))
end

-- (Still there? Answered or confirmed elsewhere, it's gone.)
local function stillToDecide(agents, d)
  for _, item in toDecide(agents, nil) do
    if (d.brief and item.brief and item.brief.id == d.brief.id) or (d.line and item.line and item.line.id == d.line.id) then
      return item
    end
  end
  return nil
end

function render()
  if not open then return end
  local agents = noctalia.state.get("agents") or { server = "stopped", sessions = {} }
  local list, children, projects = threads(agents)
  local questions = asking(agents)

  if stacking then
    if stacksBy[stacking] and #(stacksBy[stacking].layers or {}) > 0 then
      renderStack(agents, stacksBy[stacking])
      return
    end
    stacking = nil -- (all merged, or closed)
  end

  if deciding then
    local d = stillToDecide(agents, deciding)
    if d then
      renderDecision(agents, d)
      return
    end
    deciding, writing = nil, nil
  end


  -- By whose turn, in the project.
  local yours, away, parked = {}, {}, {}
  local order = {}
  for _, thread in list do
    if not scope or thread.project == scope then
      local where, rank = turn(thread, children, questions[thread.id])
      order[thread.id] = rank
      table.insert(where == "you" and yours or where == "away" and away or parked, thread)
    end
  end
  table.sort(yours, function(a, b)
    if order[a.id] ~= order[b.id] then return order[a.id] < order[b.id] end
    return (a.updated or 0) > (b.updated or 0)
  end)

  shown = {}
  spinning = #away > 0
  local rows = {}
  local function add(thread, depth, parent)
    table.insert(shown, { thread = thread, depth = depth, parent = parent })
    local index = #shown
    table.insert(rows, threadRow(shown[index], index, children, questions))
    local showKids = expanded[thread.id]
    if showKids == nil then showKids = anyChild(thread.id, children, needsYou) end
    if showKids then
      for _, child in children[thread.id] or {} do
        add(child, depth + 1, index)
      end
    end
  end
  local function section(title, items)
    if #items == 0 then return end
    table.insert(rows, heading(title))
    for _, thread in items do add(thread, 0, nil) end
  end

  if agents.server == "down" then
    table.insert(rows, ui.label({ text = "OpenCode's server isn't reachable: see smx ai doctor.", color = "error" }))
  end
  -- First, what's yours to decide.
  local decide = toDecide(agents, scope)
  if #decide > 0 then
    table.insert(rows, heading("To decide"))
    for _, item in decide do
      table.insert(shown, { decide = item })
      table.insert(rows, decideRow(shown[#shown], #shown, agents))
    end
  end
  section("Your turn", yours)
  section("Away", away)
  if #parked > 0 then
    table.insert(rows, heading("Parked"))
    if parkedOpen then
      for _, thread in parked do add(thread, 0, nil) end
    else
      table.insert(shown, { parked = true })
      local index = #shown
      table.insert(rows, ui.row({
        key = "row-" .. index, gap = 8, padding = 8, radius = 8, align = "center",
        fill = index == selected and "primary/0.15" or nil,
        onClick = function() parkedOpen = true; render() end,
      }, {
        ui.glyph({ name = "chevron-right", size = 16, color = "on_surface/0.5" }),
        ui.label({ text = `{#parked} parked thread{#parked == 1 and "" or "s"}`, color = "on_surface/0.6" }),
      }))
    end
  end
  if #yours + #away + #parked + #decide == 0 then
    table.insert(rows, ui.label({ text = scope and `No threads in {scope}. n starts one.` or "No threads. n starts one.", color = "on_surface/0.6" }))
  end
  selected = math.clamp(selected, 1, math.max(1, #shown))

  -- The projects: this one first; Tab goes round them, and all.
  local pills = {}
  for _, project in projects do
    table.insert(pills, chip(project.name, project.name == scope))
  end
  table.insert(pills, chip("All", scope == nil))

  local top = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Threads", fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
      ui.row({ gap = 4 }, pills),
    }),
  }
  if composing then
    local where = composing.mode == "reply" and composing.thread and ("Reply to " .. (composing.thread.title or "it") .. "…")
      or ("New thread" .. (scope and (" in " .. scope) or "") .. "…")
    table.insert(top, ui.input({
      key = composing.key, placeholder = where, focus = true,
      onChange = function(text) if composing then composing.text = text end end,
      onSubmit = function(text) submit(text, false) end,
    }))
  end
  if problem then table.insert(top, ui.label({ text = problem, fontSize = 12, color = "error", maxLines = 4 })) end
  table.insert(top, ui.scroll({ flexGrow = 1, gap = 2, revealKey = "row-" .. selected }, rows))
  table.insert(top, ui.label({ text = hints(shown[selected]), fontSize = 11, color = "on_surface/0.5" }))

  panel.setNeedsFrameTick(spinning)
  panel.render(ui.column({ padding = 14, gap = 6 }, top))
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

-- (The scope: a notification's thread's project; else the focused
-- window's, if it's in one; else what it was.)
function onOpen(context)
  open = true
  selected = 1
  composing, confirming, problem, parkedOpen = nil, nil, nil, false
  deciding, writing, stacking = nil, nil, nil
  local agents = noctalia.state.get("agents") or {}
  if type(context) == "string" and context ~= "" then
    for _, session in agents.sessions or {} do
      if session.id == context then scope = session.project end
    end
    render()
    for index, entry in shown do
      if entry.thread and entry.thread.id == context then selected = index end
    end
    render()
    return
  end
  scopeChosen = false
  render()
  noctalia.runAsync({ "smx", "ai", "context", "--json" }, function(result)
    local said = result.exitCode == 0 and noctalia.json.decode(result.stdout or "") or nil
    if type(said) == "table" then
      here = said.dir
      if open and not scopeChosen and said.project then
        scope = said.project
        render()
      end
    end
  end)
end

function onClose()
  open = false
  composing, confirming, writing = nil, nil, nil
  panel.setNeedsFrameTick(false)
end

local function current()
  local agents = noctalia.state.get("agents") or {}
  local _, children, projects = threads(agents)
  return agents, children, projects
end

function onKey(chord, pressed)
  if not (pressed == true or pressed == "true") then return end
  problem = nil
  local agents, children, projects = current()

  -- Composing: Enter sends (in the background); Shift+Enter, a new thread in
  -- a TUI. (Printable keys go to the field, not here.)
  if composing then
    if chord == "Return" then
      submit(composing.text, false)
    elseif chord == "Shift+Return" then
      submit(composing.text, composing.mode == "new")
    elseif chord == "Up" or chord == "Down" or chord == "Tab" then
      composing = nil
      render()
    end
    return
  end

  -- Writing your line (or why): Enter goes on. (Printable keys go to the
  -- field.)
  if writing then
    if chord == "Return" then
      advance(writing.stage == "line" and writing.text or writing.why)
    elseif chord == "Up" or chord == "Down" or chord == "Tab" then
      writing = nil
      render()
    end
    return
  end

  -- Deciding: take an option, write your own, leave it open; or, for an
  -- agent's call, confirm, replace or withdraw it.
  if deciding then
    local d = stillToDecide(agents, deciding)
    if not d then deciding = nil; render(); return end
    local n = tonumber(chord)
    if chord == "Left" or chord == "h" then
      deciding = nil
    elseif d.brief and n and d.brief.options[n] then
      write("decision", d.brief.options[n].text)
      return
    elseif chord == "w" then
      write("decision", nil)
      return
    elseif d.brief and chord == "o" then
      write("open", nil)
      return
    elseif d.line and chord == "c" then
      run({ "smx", "ai", "confirm", d.line.id }, function() deciding = nil end)
    elseif d.line and chord == "x" then
      run({ "smx", "ai", "withdraw", d.line.id }, function() deciding = nil end)
    end
    render()
    return
  end

  -- Closing with layers not landed: land them, set them aside, or don't.
  if confirming then
    local thread = confirming
    confirming = nil
    if chord == "a" then
      close(thread, "accept")
    elseif chord == "x" then
      close(thread, "discard")
    end
    render()
    return
  end

  -- In a stack: layers from the bottom; land up to one, or have it revised.
  if stacking then
    local stack = stacksBy[stacking]
    if not stack or #(stack.layers or {}) == 0 then stacking = nil; render(); return end
    local layer = stack.layers[math.clamp(layerSelected, 1, #stack.layers)]
    if chord == "Down" or chord == "j" then
      layerSelected, diffAt = math.min(layerSelected + 1, #stack.layers), 1
    elseif chord == "Up" or chord == "k" then
      layerSelected, diffAt = math.max(layerSelected - 1, 1), 1
    elseif chord == "Shift+J" or chord == "Shift+j" then
      local diff = diffs[layer.commit]
      diffAt = math.min(diffAt + 20, math.max(1, diff and diff.lines and #diff.lines or 1))
    elseif chord == "Shift+K" or chord == "Shift+k" then
      diffAt = math.max(diffAt - 20, 1)
    elseif chord == "Left" or chord == "h" then
      stacking = nil
    elseif chord == "v" then
      run({ "smx", "ai", "check", stack.session, layer.change, "--json" })
    elseif chord == "e" then
      if layer.check and layer.check.log then
        noctalia.runInTerminal("less +G " .. quote(layer.check.log))
        panel.close() -- (so you can read it)
      end
      return
    elseif (chord == "a" or chord == "Shift+A" or chord == "Shift+a" or chord == "s") and not publishing then
      -- (It fetches and pushes: it takes a moment.)
      local approving = chord ~= "s"
      publishing = approving and `Approving up to layer {layerSelected}: publishing to its remote…` or "Syncing with its remote…"
      local argv = approving and { "smx", "ai", "approve", stack.session, layer.change } or { "smx", "ai", "sync", stack.session }
      if chord ~= "a" and approving then table.insert(argv, "--anyway") end
      noctalia.runAsync(argv, function(result)
        publishing = nil
        if result.exitCode ~= 0 then
          local said = ((result.stderr or ""):gsub("\27%[[%d;]*m", ""):gsub("^smx ai: ", ""):gsub("%s+$", ""))
          problem = `smx ai {argv[3]} failed: {said ~= "" and said or ("exit " .. tostring(result.exitCode))}`
        end
        render()
      end)
    elseif chord == "r" then
      local thread = sessionById(agents, stack.session)
      if thread then
        compose("reply", thread)
        composing.placeholder = `What to change in layer {layerSelected}: {layer.title}`
        composing.prefix = `Revise layer {layerSelected} ("{layer.title}", change {layer.change:sub(1, 12)}): call smudgenix_revise with it, change it, then smudgenix_commit. What to change: `
      end
      return
    elseif chord == "Return" then
      noctalia.runInTerminal("smx ai stack diff " .. quote(stack.session) .. " " .. quote(layer.change) .. " | less -R")
      panel.close()
      return
    end
    render()
    return
  end


  -- (The Enter that just sent something, reaching here too.)
  if chord == "Return" and noctalia.nowMs() - submitted < 400 then return end
  local entry = shown[selected]
  local thread = entry and entry.thread
  if chord == "Down" or chord == "j" then
    selected = math.min(selected + 1, math.max(1, #shown))
  elseif chord == "Up" or chord == "k" then
    selected = math.max(selected - 1, 1)
  elseif chord == "Tab" or chord == "Shift+Tab" or chord == "Shift+ISO_Left_Tab" then
    -- (Round the projects, then all.)
    local names = {}
    for _, project in projects do table.insert(names, project.name) end
    table.insert(names, false)
    local at = 1
    for i, name in names do
      if name == (scope or false) then at = i end
    end
    local step = chord == "Tab" and 1 or -1
    local next = names[(at - 1 + step) % #names + 1]
    scope = next or nil
    scopeChosen = true
    selected = 1
  elseif chord == "n" then
    compose("new")
    -- (In the project's folder; in all, where you are.)
    if composing then
      composing.dir = scope == nil and here or nil
      for _, project in projects do
        if project.name == scope then composing.dir = project.dir end
      end
    end
    return
  elseif entry and entry.parked and (chord == "Return" or chord == "Right" or chord == "l") then
    parkedOpen = true
  elseif entry and entry.decide and (chord == "Return" or chord == "Right" or chord == "l") then
    deciding = entry.decide
  elseif not thread then
    -- (Nothing selected to act on.)
  elseif (chord == "a" or chord == "Shift+A" or chord == "Shift+a" or chord == "d") and asks(entry) then
    answer(asks(entry), chord == "d" and "deny" or chord == "a" and "once" or "always")
    return
  elseif chord == "Return" then
    enter(thread)
    return
  elseif chord == "r" then
    compose("reply", thread)
    return
  elseif chord == "z" then
    run({ "smx", "ai", "park", thread.id })
  elseif chord == "c" then
    close(thread, nil)
    return
  elseif chord == "Right" or chord == "l" then
    if children[thread.id] then expanded[thread.id] = true end
  elseif chord == "Left" or chord == "h" then
    if children[thread.id] and expanded[thread.id] ~= false then
      expanded[thread.id] = false
    elseif entry.parent then
      selected = entry.parent
    end
  end
  render()
end
