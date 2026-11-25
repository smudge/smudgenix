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
-- - Your turn: it needs you (a permission, a question), or it's back: work
--   to review (Enter opens the review: its files, flagged first, each to its
--   diff), an answer, or a failure.
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
local confirming = nil -- a thread being closed with work in review
local reviewing = nil -- the task whose review is open, by id
local fileSelected = 1
local reviewFiles = {} -- the open review's files, in order
local problem = nil -- the last `smx ai` failure, shown until the next key
local here = nil -- the focused window's folder, when the overlay opened (smx ai context)
local submitted = 0 -- when something was last sent (so one Enter can't also open a thread)
local deciding = nil -- what's open to decide: { brief } or { line }, by id
local writing = nil -- your line, being written: { stage = "line" | "why", kind, text, why, initial, key }

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

-- A task's change, or one file of it, in a terminal (smx ai diff).
local function inspect(task, path)
  local command = "smx ai diff " .. quote(task.id)
  if path then command ..= " -- " .. quote(path) end
  noctalia.runInTerminal(command)
end

-- A review's latest check (smx ai verify), if any, and what it says.
local function lastCheck(task)
  local evidence = task and task.review and task.review.evidence or {}
  local check = evidence[#evidence]
  if not check then return nil, nil end
  if check.exit == 0 then return check, "passed" end
  if check.exit ~= nil then return check, "failed" end
  if check.interrupted then return check, "interrupted" end
  return check, "running"
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

-- Your threads (top-level sessions), each with its subagents and its open
-- task, if any; and the projects they're in, most recent first.
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
  local tasks = {}
  for _, task in agents.tasks or {} do
    if task.state == "in-review" or task.state == "revising" or task.state == "deferred" then
      tasks[task.session] = tasks[task.session] or task
    end
  end
  local projects, seen = {}, {}
  for _, thread in list do
    if thread.project and not seen[thread.project] then
      seen[thread.project] = true
      table.insert(projects, { name = thread.project, dir = thread.dir })
    end
  end
  return list, children, tasks, projects
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
local function turn(thread, children, task, questions)
  if questions and #questions > 0 then
    return "you", 0, #questions == 1 and "asks you to decide" or `asks you to decide {#questions} things`
  end
  if needsYou(thread) or anyChild(thread.id, children, needsYou) then
    local asking = needsYou(thread) and thread or nil
    return "you", 0, asking and asking.state == "needs-input" and "asks you" or "needs your permission"
  end
  if thread.state == "working" or (task and task.state == "revising" and thread.state == "working") then
    return "away", 0, "at work"
  end
  if anyChild(thread.id, children, function(s) return s.state == "working" end) then
    return "away", 0, "subagents at work"
  end
  if task and task.state == "in-review" then
    local review = task.review or {}
    local files = type(review.files) == "table" and #review.files or review.files or 0
    local spots = #(review.hotspots or {})
    local _, checked = lastCheck(task)
    return "you", 1, `back: {files} file{files == 1 and "" or "s"} to review` .. (spots > 0 and `, {spots} flagged` or "")
      .. (checked == "passed" and ", checks pass" or checked == "failed" and ", its check failed" or checked == "running" and ", checking" or "")
      .. (task.stale and " (stale)" or "")
  end
  if thread.unseen then
    return "you", 2, thread.state == "failed" and "back: it failed" or "back: it's answered"
  end
  return "parked", 0, task and task.state == "deferred" and "parked, with work to review" or "parked"
end

local function glyphFor(thread, where, task, questions)
  if questions and #questions > 0 then return "help-circle", "tertiary" end
  if where == "away" then return "loader-2", "primary" end
  if needsYou(thread) then return "alert-triangle", "tertiary" end
  if where == "you" and task and task.state == "in-review" then return "git-pull-request", "secondary" end
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

-- Opens a thread: its review, if it has work in review; else its TUI.
local function enter(thread, task)
  if task and (task.state == "in-review" or task.state == "deferred") then
    reviewing = task.id
    fileSelected = 1
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
    run({ "smx", "ai", "reply", c.thread.id, text })
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

-- Closing a thread: at once, or (with work in review) after you decide.
local function close(thread, task, decision)
  if task and task.state ~= "revising" and not decision then
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
    return "a accept and close  ·  x discard the review and close  ·  any other key: don't"
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

local function threadRow(entry, index, children, tasks, questions)
  local thread = entry.thread
  local task = tasks[thread.id]
  local where, _, says = turn(thread, children, task, questions[thread.id])
  local glyph, color = glyphFor(thread, where, task, questions[thread.id])
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
      ui.label({ text = "It has work in review:", fontSize = 12, color = "tertiary" }),
      ui.button({ text = "Accept and close", variant = "primary", controlSize = "sm", onClick = function() close(thread, task, "accept") end }),
      ui.button({ text = "Discard the review, and close", variant = "outline", controlSize = "sm", onClick = function() close(thread, task, "discard") end }),
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
      enter(thread, task)
    end,
  }, parts)
end

-- One task's review: a summary, what it says it did (one line), and its
-- files, flagged ones first, each to open.
local function renderReview(task)
  local review = task.review or {}
  local byPath = {}
  for _, spot in review.hotspots or {} do
    byPath[spot.path] = byPath[spot.path] or {}
    if not table.find(byPath[spot.path], spot.why) then table.insert(byPath[spot.path], spot.why) end
  end
  reviewFiles = {}
  local flagged, rest = {}, {}
  for _, file in (type(review.files) == "table" and review.files) or {} do
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
  -- Evidence (by smx ai, on this revision), apart from what it says.
  local check, checked = lastCheck(task)
  local said = ({
    passed = check and { `✓ Its check passes on this revision: {check.command}`, "secondary" },
    failed = check and { `✗ Its check failed (exit {check.exit}): {check.command}. e shows its log; v runs it again.`, "error" },
    interrupted = check and { `Its check was interrupted: {check.command}. v runs it again.`, "tertiary" },
    running = check and { `Checking: {check.command}…`, "primary" },
  })[checked or ""] or { "Not checked yet: v runs the project's check on this revision.", "on_surface/0.6" }
  table.insert(rows, ui.label({ text = said[1], fontSize = 12, color = said[2], maxLines = 2 }))
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
    problem and ui.label({ text = problem, fontSize = 12, color = "error", maxLines = 4 }) or ui.box({ height = 0 }),
    ui.scroll({ flexGrow = 1, gap = 2, revealKey = "file-" .. fileSelected }, rows),
    ui.label({ text = (task.stale and "p review again" or "a accept") .. "  ·  Enter its diff  ·  v check  ·  e its log  ·  r reply  ·  z park  ·  ← back",
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
  local list, children, tasks, projects = threads(agents)
  local questions = asking(agents)

  if deciding then
    local d = stillToDecide(agents, deciding)
    if d then
      renderDecision(agents, d)
      return
    end
    deciding, writing = nil, nil
  end

  if reviewing then
    for _, task in agents.tasks or {} do
      if task.id == reviewing then
        renderReview(task)
        return
      end
    end
    reviewing = nil -- (gone: accepted elsewhere, say)
  end

  -- By whose turn, in the project.
  local yours, away, parked = {}, {}, {}
  local order = {}
  for _, thread in list do
    if not scope or thread.project == scope then
      local where, rank = turn(thread, children, tasks[thread.id], questions[thread.id])
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
    table.insert(rows, threadRow(shown[index], index, children, tasks, questions))
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
  reviewing, composing, confirming, problem, parkedOpen = nil, nil, nil, nil, false
  deciding, writing = nil, nil
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
  local _, children, tasks, projects = threads(agents)
  return agents, children, tasks, projects
end

function onKey(chord, pressed)
  if not (pressed == true or pressed == "true") then return end
  problem = nil
  local agents, children, tasks, projects = current()

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

  -- Closing with work in review: accept, discard, or don't.
  if confirming then
    local thread = confirming
    confirming = nil
    if chord == "a" then
      close(thread, tasks[thread.id], "accept")
    elseif chord == "x" then
      close(thread, tasks[thread.id], "discard")
    end
    render()
    return
  end

  -- In a review.
  if reviewing then
    local task = nil
    for _, t in agents.tasks or {} do
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
    elseif chord == "a" then
      run({ "smx", "ai", "accept", task.id })
      reviewing = nil
    elseif chord == "z" then
      run({ "smx", "ai", "park", task.session })
      reviewing = nil
    elseif chord == "p" then
      run({ "smx", "ai", "review", task.session })
    elseif chord == "v" then
      run({ "smx", "ai", "verify", task.id, "--json" })
    elseif chord == "e" then
      local check = lastCheck(task)
      if check and check.log then noctalia.runInTerminal("less +G " .. quote(check.log)) end
      return
    elseif chord == "r" then
      reviewing = nil
      for _, session in agents.sessions or {} do
        if session.id == task.session then compose("reply", session) end
      end
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
    enter(thread, tasks[thread.id])
    return
  elseif chord == "r" then
    compose("reply", thread)
    return
  elseif chord == "z" then
    run({ "smx", "ai", "park", thread.id })
  elseif chord == "c" then
    close(thread, tasks[thread.id], nil)
    return
  elseif chord == "p" then
    run({ "smx", "ai", "review", thread.id }) -- (review it now)
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
