## Included by synedit.nim: undo history for the editor's persistence. wkbenchless only; kept out of
## that file so a sync with focim stays small.

type UndoRecord* = object
  ## A serializable copy of one Action, for the per-file history sidecar.
  k*: int          ## ActionKind ordinal (ins..delFinished)
  pos*: int
  version*: int
  word*: string
  time*: float

proc undoRecords*(s: SynEdit): seq[UndoRecord] =
  ## The whole undo stack (including the redo tail past undoIdx), with the
  ## current index, so a reloaded session continues C-z exactly where it
  ## stopped. Callers persist this next to the file and reload with
  ## `loadUndoRecords`.
  for a in s.actions:
    result.add UndoRecord(k: a.k.ord, pos: a.pos, version: a.version,
                          word: a.word, time: a.time)

proc undoIndex*(s: SynEdit): int = s.undoIdx

proc loadUndoRecords*(s: var SynEdit; recs: seq[UndoRecord]; undoAt: int) =
  ## Replace the undo stack with RECS, positioning the index at UNDOAT. Only
  ## for a freshly loaded buffer whose content matches what the records were
  ## taken against -- the caller guards that (file mtime/size) or the undo
  ## would corrupt the text.
  s.actions.setLen(0)
  s.version = 0
  for r in recs:
    if r.k >= low(ActionKind).ord and r.k <= high(ActionKind).ord and r.version > s.version:
      s.version = r.version
    s.actions.add Action(k: ActionKind(r.k), pos: r.pos, version: r.version,
                        word: r.word, time: r.time)
  s.undoIdx = clamp(undoAt, -1, s.actions.len - 1)

proc replaceTextUndoable*(s: var SynEdit; newText: string) =
  ## Replace the whole buffer as ONE undo group: a history time-jump is just
  ## another edit -- C-z returns to the pre-restore text, C-y re-lands on the
  ## restored version, and the group carries a timestamp for the history.
  let old = s.fullText()
  let t = epochTime()
  s.setText(newText)                  # rebuilds the buffer; clears the stack
  let applied = s.fullText()           # post tab-expansion, what redo replays
  inc s.version
  # NB: dele actions store their word byte-REVERSED (rawBackspace appends the
  # removed chars last-first), so undo's backward re-insertion restores the
  # original order.
  var oldRev = newString(old.len)
  for i, c in old: oldRev[old.len - 1 - i] = c
  s.actions = @[Action(k: delFinished, pos: 0, word: oldRev, version: s.version, time: t),
                Action(k: insFinished, pos: 0, word: applied, version: s.version, time: t)]
  s.undoIdx = s.actions.len - 1
  s.changed = true

proc editStamp*(s: SynEdit): int =
  ## Monotonic per-buffer edit counter: every raw edit AND every setText/clear
  ## bumps it (clear re-seeds from a global), so callers can detect "the user
  ## did something" without inspecting the undo stack.
  s.cacheId

proc undoDepth*(s: SynEdit): int =
  ## Undoable steps from the current state (0 = nothing to undo). clear()
  ## leaves undoIdx at 0 over an empty stack, so guard that.
  if s.actions.len == 0: 0 else: s.undoIdx + 1
