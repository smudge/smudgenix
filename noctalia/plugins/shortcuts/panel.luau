--!nonstrict
-- Super's shortcuts: while you hold it (opened and closed by the leader key,
-- nixos/desktop/leader.sh), or from a key. From the sheet smudgenix writes
-- from its binds (nixos/desktop/shortcuts.nix); keys are shown without
-- "Super+". While it's open, the bar's buttons show theirs too.

local sheetPath = "/etc/smudgenix/shortcuts.json"
local columns = 3

local function chip(text)
  return ui.row({ paddingH = 6, paddingV = 2, radius = 6, fill = "on_surface/0.08" }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "primary", maxLines = 1 }),
  })
end

local function section(s)
  local rows = {
    ui.label({ text = s.title, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6" }),
  }
  for _, bind in s.binds do
    table.insert(rows, ui.row({ gap = 10, align = "center" }, {
      ui.row({ width = 118, justify = "end" }, { chip(bind.keys) }),
      ui.label({ text = bind.title, fontSize = 12, color = "on_surface", maxLines = 1, flexGrow = 1 }),
    }))
  end
  return ui.column({ gap = 5 }, rows)
end

local function load()
  local raw = noctalia.readFile(sheetPath)
  local sheet = raw and noctalia.json.decode(raw) or nil
  return type(sheet) == "table" and sheet or nil
end

-- Tells the bar's buttons (sheet.hinted, plugin widgets) to show their keys.
local function hints(state)
  local sheet = load()
  if not sheet then return end
  for _, widget in sheet.hinted do
    noctalia.runAsync({ sheet.noctalia, "msg", "plugin", widget, "all", "hints", state })
  end
end

function render()
  local sheet = load()
  if not sheet then
    panel.render(ui.column({ padding = 14 }, {
      ui.label({ text = `No shortcuts at {sheetPath}`, color = "on_surface/0.7" }),
    }))
    return
  end

  -- Sections into columns, each to the shortest so far.
  local cols, heights = {}, {}
  for i = 1, columns do
    cols[i], heights[i] = {}, 0
  end
  for _, s in sheet.sections do
    local shortest = 1
    for i = 2, columns do
      if heights[i] < heights[shortest] then shortest = i end
    end
    table.insert(cols[shortest], section(s))
    heights[shortest] += #s.binds + 2
  end

  local row = {}
  for i = 1, columns do
    table.insert(row, ui.column({ gap = 16, flexGrow = 1 }, cols[i]))
  end
  panel.render(ui.row({ padding = 16, gap = 20, align = "start" }, row))
end

function onOpen()
  render()
  hints("on")
end

function onClose()
  hints("off")
end
