# Reads `libinput debug-events` (which shows letters, digits and punctuation
# only as ***), and passes on just enough for ./leader.sh:
#
#   down   Super was pressed
#   up     Super was released
#   other  something else was pressed with it (once per press of Super)
#
# Nothing about other keys gets out while Super is up, so it gives away no
# typing, not even its timing.

function send(what) { print what; fflush() }

/KEYBOARD_KEY/ {
  if ($0 ~ /KEY_(LEFT|RIGHT)META \(12[56]\) pressed/) {
    if (supers++ == 0) {
      other = 0
      send("down")
      # (Held already, like Shift: a chord, not Super alone.)
      if (keys > 0) { other = 1; send("other") }
    }
  } else if ($0 ~ /KEY_(LEFT|RIGHT)META \(12[56]\) released/) {
    if (supers > 0 && --supers == 0) send("up")
  } else if ($0 ~ / pressed$/) {
    keys++
    if (supers > 0 && !other) { other = 1; send("other") }
  } else if ($0 ~ / released$/ && keys > 0) {
    keys--
  }
  next
}

# Clicks, scrolls, swipes and touches count too (like Super+drag); a finger
# resting on the touchpad (a "hold" gesture) doesn't.
/POINTER_BUTTON.* pressed|POINTER_SCROLL_|GESTURE_(SWIPE|PINCH)_BEGIN|TOUCH_DOWN|TABLET_TOOL_TIP/ {
  if (supers > 0 && !other) { other = 1; send("other") }
}
