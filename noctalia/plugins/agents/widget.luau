--!nonstrict
-- The agents' bar widget. (For now, it only checks on them.)

barWidget.setGlyph("robot")
barWidget.setTooltip("Agents")

function onClick()
  noctalia.runInTerminal("smx ai doctor; read -rsn1 -p 'Press any key to close.'")
end
