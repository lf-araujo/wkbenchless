## references -- reference context at point.
##
## Editor commands (all in the M-x palette). On a `[cite:@key]` citation:
##   cite-context (C-c ?)  your notes + prose + the paper, in a *cite-context* buffer
##   cite-prose            just your manuscript paragraphs citing @key
##   cite-notes            just your Zotero notes on the item
##   cite-paper            just the paper's own Markdown (Mktero source)
##   cite-reindex          rebuild the manuscript prose index
##   zotero-search         search the whole library for the selection / word at point
##
## The same are scriptable as `wkbctl` verbs (see src/wkbctrl.nim). Corpus roots
## come from `gCorpusRoots` (config), `$WKB_CORPUS`, or the open file's directory.
## See src/wkbref.nim.

import wkbcore
import std/[strutils, os]

proc keyAt(app: App): string =
  ## The citekey under point, or "".
  keyAtPoint(app.ed.getLineText(app.ed.currentLine), app.ed.currentCol)

proc citeContextCmd(app: var App) =
  let key = keyAt(app)
  if key.len == 0:
    app.msg = "cite-context: put the cursor on a [cite:@key] citation"; return
  app.msg = "cite-context: gathering notes + prose + paper for @" & key & " …"
  let occs = citeProse(app.filePath, key)
  let notes = citeNotes(key)
  let papers = citePaper(key)
  showInfoBuffer(app, "cite-context",
                 formatContext(key, occs, notes, papers, getHomeDir()))
  app.msg = "cite-context @" & key & " — " & $notes.len & " note" &
            (if notes.len == 1: "" else: "s") & ", " & $occs.len & " paragraph" &
            (if occs.len == 1: "" else: "s") &
            (if papers.len > 0: ", paper text" else: "") &
            "  (C-c C-o on a file:line to open)"

proc citeProseCmd(app: var App) =
  let key = keyAt(app)
  if key.len == 0:
    app.msg = "cite-prose: put the cursor on a [cite:@key] citation"; return
  let occs = citeProse(app.filePath, key)
  showInfoBuffer(app, "cite-context", formatProse(key, occs, getHomeDir()))
  app.msg = "cite-prose @" & key & " — " & $occs.len & " paragraph" &
            (if occs.len == 1: "" else: "s")

proc citeNotesCmd(app: var App) =
  let key = keyAt(app)
  if key.len == 0:
    app.msg = "cite-notes: put the cursor on a [cite:@key] citation"; return
  let notes = citeNotes(key)
  showInfoBuffer(app, "cite-context", formatNotes(key, notes))
  app.msg = "cite-notes @" & key & " — " & $notes.len & " Zotero note" &
            (if notes.len == 1: "" else: "s")

proc citePaperCmd(app: var App) =
  let key = keyAt(app)
  if key.len == 0:
    app.msg = "cite-paper: put the cursor on a [cite:@key] citation"; return
  let papers = citePaper(key)
  showInfoBuffer(app, "cite-context", formatPaper(key, papers, getHomeDir()))
  app.msg = "cite-paper @" & key & " — " &
            (if papers.len > 0: "paper full text" else: "no attached Markdown")

proc zoteroSearchCmd(app: var App) =
  ## Query = the selection, else the word at point. Results in *zotero-search*.
  var q = app.ed.getSelectedText().strip
  if q.len == 0: q = wordAtCursor(app)
  if q.len == 0:
    app.msg = "zotero-search: select some text (or put the cursor on a word) to search"
    return
  app.msg = "zotero-search: searching the library for “" & q & "” …"
  var hits = zoteroSearch(q)
  markInProse(hits, app.filePath)
  showInfoBuffer(app, "zotero-search", formatSearch(q, hits))
  app.msg = "zotero-search “" & q & "” — " & $hits.len & " match" &
            (if hits.len == 1: "" else: "es")

proc citeReindexCmd(app: var App) =
  app.msg = "cite-context: reindexing corpus …"
  app.msg = "cite-context: indexed " & $reindexProse(app.filePath) & " citekeys"

proc extend*(app: var App) =
  defcommand("cite-context",
    "References: notes + prose + paper for the citation at point", citeContextCmd)
  defcommand("cite-prose",
    "References: your paragraphs citing the key at point", citeProseCmd)
  defcommand("cite-notes",
    "References: your Zotero notes on the citation at point", citeNotesCmd)
  defcommand("cite-paper",
    "References: the paper's own text (Mktero) for the citation at point", citePaperCmd)
  defcommand("zotero-search",
    "References: search the Zotero library for the selection / word at point", zoteroSearchCmd)
  defcommand("cite-reindex",
    "References: rebuild the manuscript prose index", citeReindexCmd)
  bindkey("C-c ?", "cite-context")
