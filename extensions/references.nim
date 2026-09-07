## references -- reference context at point.
##
## `M-x cite-context` (bound to C-c ?) on a `[cite:@key]` shows, in a
## `*cite-context*` buffer, every paragraph across your manuscript corpus that
## cites that reference -- your accumulated prose about it. Notes (Zotero) and
## the paper's own text (Mktero) will join the same buffer as further sections.
##
## Corpus roots come from `gCorpusRoots` (config), `$WKB_CORPUS`, or -- with
## neither -- the open file's directory. See src/wkbref.nim.

import wkbcore
import std/[strutils, os]

proc citeContextCmd(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  let key = keyAtPoint(line, app.ed.currentCol)
  if key.len == 0:
    app.msg = "cite-context: put the cursor on a [cite:@key] citation"; return
  app.msg = "cite-context: searching your corpus for @" & key & " …"
  let occs = citeProse(app.filePath, key)
  showInfoBuffer(app, "cite-context", formatProse(key, occs, getHomeDir()))
  app.msg = "cite-context @" & key & " — " & $occs.len &
            " paragraph" & (if occs.len == 1: "" else: "s") &
            "  (C-c C-o on a file:line to open it)"

proc citeReindexCmd(app: var App) =
  app.msg = "cite-context: reindexing corpus …"
  app.msg = "cite-context: indexed " & $reindexProse(app.filePath) & " citekeys"

proc extend*(app: var App) =
  defcommand("cite-context",
    "References: your prior paragraphs citing the key at point", citeContextCmd)
  defcommand("cite-reindex",
    "References: rebuild the manuscript prose index", citeReindexCmd)
  bindkey("C-c ?", "cite-context")
