## Diff view: word-level rows for prose, first-change scroll/jump, transient
## auto-close.   nim c -r --hints:off src/test_diff.nim

import std/[strutils, times]
import wkbcore

var oldLines, newLines: seq[string]
for i in 1 .. 40: oldLines.add "line " & $i
newLines = oldLines
oldLines[29] = "The quick brown fox jumps over the lazy dog."
newLines[29] = "The quick red fox leaps over the lazy dog."
let oldText = oldLines.join("\n")
let newText = newLines.join("\n")

var app: App
app.ed.lang = langOrg
app.filePath = "/tmp/wkb-test-diff.org"
app.ed.setText(newText)
app.ed.gotoLine(1, 0)

showDiff(app, oldText, newText, "Claude edited x.org", app.filePath)
doAssert app.diffActive and app.diffTokens, "org diff should open word-level"
doAssert app.diffJumpLine == 29, $app.diffJumpLine
# word-level: a gap, context, then one paragraph with word changes only
var changed = ""
for row in app.diffInline:
  for s in row.segs:
    if s.kind != '=': changed.add s.kind & s.text.strip() & " "
doAssert changed.strip() == "-brown +red -jumps +leaps", changed
doAssert app.diffInline[0].gap == 27, $app.diffInline[0].gap          # lines 1..27 collapsed
echo "word-level rows ok: ", changed

# code diff: side-by-side, scrolled near the first change
showDiff(app, oldText, newText, "x.nim", "/tmp/x.nim")
doAssert not app.diffTokens and app.diffScroll == 29 - 3, $app.diffScroll
echo "side-by-side scroll ok"

# closing puts the editor cursor on the change (same file) ...
showDiff(app, oldText, newText, "x.org", app.filePath)
closeDiff(app)
doAssert app.ed.currentLine == 29, $app.ed.currentLine
# ... but not for another file
app.ed.gotoLine(1, 0)
showDiff(app, oldText, newText, "y.org", "/tmp/other.org")
closeDiff(app)
doAssert app.ed.currentLine == 0
echo "cursor jump ok"

# transient: untouched -> closes after gDiffAutoClose; pinned -> stays
gDiffAutoClose = 0.3
showDiff(app, oldText, newText, "x.org", app.filePath)
doAssert not diffAutoClose(app)
let t0 = epochTime()
while app.diffActive and epochTime() - t0 < 2: discard diffAutoClose(app)
doAssert not app.diffActive and app.ed.currentLine == 29, "auto-close"
showDiff(app, oldText, newText, "x.org", app.filePath)
app.diffPinned = true
let t1 = epochTime()
while epochTime() - t1 < 0.5: discard diffAutoClose(app)
doAssert app.diffActive, "a pinned diff must stay"
echo "auto-close ok"
echo "ALL OK"
