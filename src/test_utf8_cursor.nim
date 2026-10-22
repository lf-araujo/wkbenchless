## test_utf8_cursor -- the cursor can never sit inside a multibyte rune:
## down() walks graphemes (the old byte-wise column walk landed mid-rune on
## lines holding "…" etc., and the next keypress spliced invalid UTF-8 into
## the buffer), gotoPos snaps a mid-rune byte offset forward, and the insert
## path clamps as a last resort.
##   nim c -r --hints:off src/test_utf8_cursor.nim
import std/strutils
import uirelays/[coords, screen, input]
import widgets/synedit

var fails = 0
template check(name: string; cond: bool; got: string = "") =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name, (if got.len > 0: "  got: " & got else: ""); inc fails

proc keyEvent(ed: var SynEdit; key: KeyCode) =
  var e: Event
  e.kind = KeyDownEvent
  e.key = key
  discard ed.draw(e, rect(0, 0, 0, 0), focused = true)

var ed = createSynEdit(Font(0))
ed.setText("alpha\nbe…ta word\ngamma\n")

# Column 4 on line 1, then Down onto a line whose 3rd grapheme is the 3-byte
# "…". The old byte-wise walk landed at byte 10 -- inside the rune; the
# grapheme walk lands after 't' (byte 12), and typing splices cleanly.
for _ in 1 .. 4: keyEvent(ed, KeyRight)
check "four Rights put the cursor at column 4", ed.currentCol() == 4
keyEvent(ed, KeyDown)
check "Down preserves the grapheme column", ed.currentCol() == 4
ed.insertText("X")
check "typing after Down on a multibyte line splices at the grapheme",
  ed.fullText() == "alpha\nbe…tXa word\ngamma\n",
  ed.fullText().replace("\n", "\\n")

# A programmatic jump to a continuation byte snaps forward past the rune.
let midRune = "alpha\nbe".len + 2          # the 0x80 inside "…"
ed.gotoPos(midRune)
ed.insertText("Y")
check "gotoPos mid-rune snaps to the next grapheme start",
  ed.fullText() == "alpha\nbe…YtXa word\ngamma\n",
  ed.fullText().replace("\n", "\\n")

if fails > 0:
  echo "test_utf8_cursor: ", fails, " FAILED"
  quit 1
echo "test_utf8_cursor: all assertions passed"
