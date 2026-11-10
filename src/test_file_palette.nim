## test_file_palette -- the file palette (C-x C-f): "../" heads the listing
## while browsing but steps aside once a filter is typed, so the selection
## lands on the best match (exact < prefix < word start < substring). And the
## command palette lists `export` once: the targets' own commands are hidden,
## and a query matching a target ("pdf") offers `export`.
##   nim c -r --hints:off src/test_file_palette.nim
import std/[os, strutils]
import wkbcore

let dir = getTempDir() / "wkb_test_file_palette"
removeDir(dir)
createDir(dir / "reports")
for f in ["analysis.org", "my-report.org", "report.org", "zreport_old.txt", "notes.md"]:
  writeFile(dir / f, "")

var app = App()
app.paletteMode = pmFiles
app.paletteDir = dir

proc labels(): seq[string] =
  for e in paletteEntries(app): result.add e.label

# browsing: ../ first, then dirs, then files
doAssert labels() == @["../", "reports/", "analysis.org", "my-report.org",
                       "notes.md", "report.org", "zreport_old.txt"], $labels()

# typing a filter: no ../, best match on top
app.paletteQuery = "report"
doAssert "../" notin labels(), $labels()
doAssert labels()[0] == "report.org", $labels()
doAssert labels() == @["report.org", "reports/", "my-report.org", "zreport_old.txt"], $labels()

# backspace to empty brings ../ back
app.paletteQuery = ""
doAssert labels()[0] == "../"

# save-as keeps ../ (the query is the new name, not a filter)
app.paletteMode = pmSaveAs
app.paletteQuery = "report"
doAssert labels()[0] == "../"

removeDir(dir)
echo "file palette ok"

# -- M-x: one export entry -----------------------------------------------------
proc noop(app: var App) = discard
defcommand("export", "Export this buffer (choose target: docx, html, ...)", openExportPalette)
defcommand("latex-pdf-export", "Export: PDF document", noop)
defcommand("otd-export", "Tracked: export org -> .docx", noop)
defcommand("save", "Save", noop)
registerExport("pdf", "PDF document (LaTeX article)", "latex-pdf-export")
registerExport("docx", "Word document (.docx, tracked changes)", "otd-export")
app.paletteMode = pmCommands
proc ids(): seq[string] =
  for e in paletteEntries(app): result.add e.id
app.paletteQuery = ""
doAssert "export" in ids() and "latex-pdf-export" notin ids() and
         "otd-export" notin ids(), $ids()
app.paletteQuery = "export"
doAssert ids() == @["export"], $ids()
app.paletteQuery = "pdf"
doAssert ids() == @["export"], $ids()
app.paletteQuery = "word"
doAssert ids() == @["export"], $ids()
app.paletteQuery = "sav"
doAssert ids() == @["save"], $ids()
app.paletteMode = pmExport
app.paletteQuery = ""
doAssert ids() == @["pdf", "docx"], $ids()
echo "export entry ok"
