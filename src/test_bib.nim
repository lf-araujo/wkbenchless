## test_bib -- the bib --insert / --extract verbs: insert works on LOCAL
## project bibs only (the global Zotero export is machine-overwritten, so a
## key lifted from it can vanish), extract copies from both local and global.
##   nim c -r --hints:off src/test_bib.nim
import std/[os, strutils]
import uirelays/screen
import wkbcore
import wkbctrl

var fails = 0
template check(name: string; cond: bool; got = "") =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name, (if got.len > 0: "  got: " & got else: ""); inc fails

let dir = getTempDir() / "test_bib"
createDir(dir)
writeFile(dir / "local.bib", """
@article{reynolds2005,
  author = {Reynolds, Chandra},
  title = {Quantitative genetic analysis of twin data},
  year = {2005},
}
@article{local2001,
  author = {Local Author},
  title = {A local project note},
  year = {2001},
}
""")
writeFile(dir / "global.bib", """
@article{globalonly1999,
  author = {Global Author},
  title = {Only in the overwritten Zotero export},
  year = {1999},
}
""")
putEnv("WKB_BIB", dir / "global.bib")

var app: App
app.ed = createSynEdit(Font(0))
app.filePath = dir / "paper.org"
app.ed.setText("#+bibliography: " & dir / "local.bib" & "\n" &
               "We build on prior work.\n")

block insert:
  app.ed.gotoPos(app.ed.fullText().find("prior") + 2)
  let r = bibInsert(app, "reynolds quantitative")
  check "a single local match inserts at the cursor",
    r == "ok: inserted [cite:@reynolds2005]", r
  check "the citation landed in the buffer",
    app.ed.fullText().contains("on [cite:@reynolds2005] work") or
    app.ed.fullText().contains("[cite:@reynolds2005]"), app.ed.fullText()

  let r2 = bibInsert(app, "nonexistent thing")
  check "no match says so", r2.startsWith("(no local bib entry matches"), r2

  # a query only the GLOBAL bib matches must not insert: the Zotero export
  # is machine-generated and gets overwritten -- its keys are not stable
  let r3 = bibInsert(app, "globalonly")
  check "a global-only match is refused",
    r3.startsWith("(no local bib entry matches"), r3

  # ambiguous: both local entries match (years 2005 / 2001)
  let r4 = bibInsert(app, "20")
  check "several matches come back as a list to narrow",
    r4.startsWith("2 local matches -- narrow the query:") and
      "reynolds2005" in r4 and "local2001" in r4, r4
  check "an ambiguous query inserts nothing",
    not app.ed.fullText().contains("[cite:@local2001]")

block extract:
  app.ed.setText("#+bibliography: " & dir / "local.bib" & "\n" &
                 "First [cite:@reynolds2005], then [cite:@globalonly1999], " &
                 "and [cite:@nowhere999].\n")
  let res = bibExtract(app, dir / "refs.bib")
  check "extract reports both found and missing",
    res.startsWith("ok: wrote 2 of 3 cited entries"), res
  check "the missing key is named", "nowhere999" in res, res
  let refs = readFile(dir / "refs.bib")
  check "the local entry is copied", "reynolds2005" in refs and
    "Quantitative genetic analysis" in refs
  check "the global entry is copied too (extract may use both)",
    "globalonly1999" in refs
  check "citation order is kept",
    refs.find("reynolds2005") < refs.find("globalonly1999")
  check "the missing key is not invented", "nowhere999" notin refs

  app.ed.setText("#+bibliography: " & dir / "local.bib" & "\nNo cites here.\n")
  check "a buffer without citations says so",
    bibExtract(app, dir / "empty.bib") == "(no citations in this buffer)"

if fails > 0:
  echo "test_bib: ", fails, " FAILED"
  quit 1
echo "test_bib: all assertions passed"
