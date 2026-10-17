## test_hist -- the history restore mechanic: replaceTextUndoable makes a
## time-jump ONE undoable edit (C-z returns to the pre-restore text, C-y
## re-lands on the restored version), and undoRecords/loadUndoRecords
## round-trip the stack.
import std/[strutils]
import uirelays/screen
import widgets/synedit

var ed = createSynEdit(Font(0))
ed.setText("line one\nline two\nline three\n")
doAssert ed.fullText() == "line one\nline two\nline three\n"

# type a bit (real undoable edits)
ed.gotoPos(5)
ed.insertText("XX")
doAssert "line XXone" in ed.fullText()

# time-jump: replace the whole buffer as one undoable edit
ed.replaceTextUndoable("REPLACED ENTIRELY\nnew body\n")
doAssert ed.fullText() == "REPLACED ENTIRELY\nnew body\n"
doAssert ed.undoDepth() >= 1

# C-z: back to the pre-restore text (with the typed edit intact)
ed.undo()
doAssert ed.fullText() == "line XXone\nline two\nline three\n",
        "undo after restore gives: " & ed.fullText().replace("\n", "\\n")

# C-y: re-land on the restored version
ed.redo()
doAssert ed.fullText() == "REPLACED ENTIRELY\nnew body\n"

# records round-trip: dump, wipe, reload, undo still works
let recs = ed.undoRecords()
let idx = ed.undoIndex()
ed.setText("fresh buffer\n")            # clears the stack
doAssert ed.undoDepth() == 0
ed.loadUndoRecords(recs, idx)
ed.undo()                                # undoes the restore
doAssert ed.fullText() == "line XXone\nline two\nline three\n",
        "reloaded undo gives: " & ed.fullText().replace("\n", "\\n")

echo "test_hist: all assertions passed"
