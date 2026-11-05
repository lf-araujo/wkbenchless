## The cursor reaches `cols` after a character lands in the last column (pending
## wrap). Drawing the block cursor at that moment indexed one past the end of the
## row, which aborted the whole editor whenever output stopped exactly at the
## pane's edge.
##   nim c -r --hints:off src/test_vterm.nim

import std/strutils
import uirelays
import wkbvterm

proc term(cols: int): VTerm =
  newVTerm(5, cols, color(255, 255, 255), color(0, 0, 0))

block:  # a full line leaves the cursor pending, and cursorCol stays on the row
  let t = term(10)
  t.write("x".repeat(10))
  doAssert t.cx == 10, $t.cx
  doAssert t.cursorCol == 9, $t.cursorCol
  doAssert t.grid[t.cy][t.cursorCol].ch == "x"

block:  # the next character still wraps, and \r still returns to column 0
  let t = term(10)
  t.write("x".repeat(10) & "y")
  doAssert t.cy == 1 and t.cx == 1
  doAssert t.grid[1][0].ch == "y"
  let u = term(10)
  u.write("x".repeat(10) & "\r")
  doAssert u.cy == 0 and u.cursorCol == 0

block:  # a padded \r progress line ending on the edge (what OpenMx prints)
  let t = term(73)
  for _ in 1 .. 50:
    t.write("\r" & "Running model".alignLeft(73))
    doAssert t.grid[t.cy][t.cursorCol].ch.len >= 0

block:  # insert-chars (ESC[@) while pending acts on the last cell
  let t = term(10)
  t.write("x".repeat(10) & "\e[@")
  doAssert t.grid[0][9].ch == ""
  doAssert t.grid[0][8].ch == "x"

block:  # shrinking the pane with a pending cursor stays in bounds
  let t = term(10)
  t.write("x".repeat(10))
  t.resize(5, 4)
  doAssert t.cursorCol < t.cols

block:  # symbols a TUI prints are one column; only true wide glyphs take two
  for sym in ["●", "⏺", "❯", "✓", "✗", "▶", "■", "⚠", "★", "✻", "⏵", "→", "─"]:
    let t = term(20)
    t.write(sym & "x")
    doAssert t.cx == 2, sym & " advanced " & $t.cx
    doAssert t.grid[0][1].ch == "x", sym
  for sym in ["✅", "❌", "⭐", "⚡", "😀", "你"]:
    let t = term(20)
    t.write(sym & "x")
    doAssert t.cx == 3, sym & " advanced " & $t.cx
    doAssert t.grid[0][2].ch == "x", sym

block:  # a redraw at an absolute column lands on the same cell as the producer's
  let t = term(20)
  t.write("● hello")
  t.write("\e[1;3HHELLO")          # column 3: just past "● "
  var line = ""
  for c in t.grid[0][0 ..< 7]: line.add (if c.ch.len == 0: " " else: c.ch)
  doAssert line == "● HELLO", line

echo "test_vterm: ok"
