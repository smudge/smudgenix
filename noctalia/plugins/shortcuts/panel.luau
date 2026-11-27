--!nonstrict
-- Super's shortcuts: while you hold it (opened and closed by the leader key,
-- nixos/desktop/leader.sh), or from a key. From the sheet smudgenix writes
-- from its binds (nixos/desktop/shortcuts.nix), and your home's over it;
-- keys are shown without "Super+". Those that open something on the bar show
-- its icon.

local sheetPath = "/etc/smudgenix/shortcuts.json"
local homeSheetPath = "~/.config/smudgenix/shortcuts.json" -- (from home-manager)
local columns = 3

local function chip(text)
  return ui.row({ paddingH = 6, paddingV = 2, radius = 6, fill = "on_surface/0.08" }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "primary", maxLines = 1 }),
  })
end

-- A line's keys: "Shift+F7 F8".
local function keysOf(line)
  local keys = {}
  for _, part in line.parts do table.insert(keys, part.key) end
  return line.prefix .. table.concat(keys, " ")
end

local function section(s)
  local rows = {
    ui.label({ text = s.title, fontSize = 11, fontWeight = "bold", color = "on_surface/0.6" }),
  }
  for _, bind in s.binds do
    local row = { ui.row({ width = 118, justify = "end" }, { chip(keysOf(bind)) }) }
    if bind.glyph then
      table.insert(row, ui.glyph({ name = bind.glyph, size = 14, color = "on_surface/0.8" }))
    end
    table.insert(row, ui.label({ text = bind.title, fontSize = 12, color = "on_surface", maxLines = 1, flexGrow = 1 }))
    table.insert(rows, ui.row({ gap = 10, align = "center" }, row))
  end
  return ui.column({ gap = 5 }, rows)
end

local function load(path)
  local raw = noctalia.readFile(path)
  local sheet = raw and noctalia.json.decode(raw) or nil
  return type(sheet) == "table" and sheet or nil
end

-- The OS's sheet, with your home's over it: its lines, less the OS's keys it
-- replaced, and its icons. (Each is worked out when it's built: this only
-- sets one over the other.)
local function merged()
  local system, home = load(sheetPath), load(homeSheetPath)
  if not home then return system end
  if not system then return home end

  local replaced = {}
  for _, key in home.replaces or {} do replaced[key] = true end
  local byTitle = {}
  for _, sheet in { system, home } do
    for _, s in sheet.sections do
      local lines = byTitle[s.title] or {}
      byTitle[s.title] = lines
      for _, line in s.binds do
        if sheet == system then
          local parts = {}
          for _, part in line.parts do
            -- (Of a family, like H J K L, the ones left.)
            local binds, members = {}, {}
            for i, key in part.binds do
              if not replaced[key] then
                table.insert(binds, key)
                table.insert(members, part.members[i])
              end
            end
            if #binds == #part.binds then
              table.insert(parts, part)
            elseif #binds > 0 then
              table.insert(parts, { key = table.concat(members, " "), binds = binds, members = members })
            end
          end
          if #parts > 0 then
            table.insert(lines, table.clone(line))
            lines[#lines].parts = parts
          end
        else
          table.insert(lines, line)
        end
      end
    end
  end

  local glyphs = table.clone(system.glyphs or {})
  for panel, glyph in home.glyphs or {} do glyphs[panel] = glyph end
  local sections = {}
  for _, title in system.order do
    local lines = byTitle[title]
    if lines and #lines > 0 then
      for _, line in lines do
        if line.panel and glyphs[line.panel] then line.glyph = glyphs[line.panel] end
      end
      table.sort(lines, function(a, b) return a.sort < b.sort end)
      table.insert(sections, { title = title, binds = lines })
    end
  end
  return { sections = sections }
end

function render()
  local sheet = merged()
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
end
