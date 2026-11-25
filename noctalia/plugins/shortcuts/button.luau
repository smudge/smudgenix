--!nonstrict
-- A bar button, in place of Noctalia's launcher, clipboard and Control
-- Center pills: a glyph, and what clicking it does (its `actions`, like any
-- widget's). While Super is held, it also shows its shortcut: the leader key
-- (nixos/desktop/leader.sh) sends "hints" "on", then "off".
--
-- (Ours only because Noctalia's widgets can't show a key. A key hint on any
-- widget, upstream, would make these unnecessary: worth revisiting.)

local hints = false

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph"))
  local keys = noctalia.getConfig("keys") or ""
  if hints and keys ~= "" then
    barWidget.setColor("primary")
    barWidget.setText(keys)
  else
    barWidget.setText("")
  end
  local tooltip = noctalia.getConfig("tooltip") or ""
  if tooltip ~= "" then barWidget.setTooltip(tooltip) else barWidget.clearTooltip() end
end

render()

function onIpc(event, payload)
  if event == "hints" then
    hints = payload == "on"
    render()
  end
end

function onConfigChanged()
  render()
end
