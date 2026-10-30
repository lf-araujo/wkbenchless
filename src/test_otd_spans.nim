## test_otd_spans -- the otd-export CriticMarkup fixes: emphasis shared by
## both sides of a substitution is hoisted out of the token (so pandoc can
## pair it past the stashed sentinel), and edge whitespace survives inside
## the w:ins/w:del spans (pandoc drops bare edge spaces in span content).
##   nim c -r --hints:off src/test_otd_spans.nim
import std/[strutils, os, osproc]
import zippy/ziparchives
import ../extensions/org_tracked

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

# -- hoistCriticEmphasis: shared emphasis leaves the token --------------------
block hoist:
  check "shared leading italic is hoisted before the token",
    hoistCriticEmphasis("quote {~~/First, X~>/In sensitivity Y~~}/ tail") ==
      "quote /{~~First, X~>In sensitivity Y~~}/ tail"
  check "shared leading bold is hoisted before the token",
    hoistCriticEmphasis("{~~*a~>*b~~}") == "*{~~a~>b~~}"
  check "shared trailing emphasis is hoisted after the token",
    hoistCriticEmphasis("{~~a*~>b*~~}") == "{~~a~>b~~}*"
  check "author tags stay inside, the delimiter still hoists",
    hoistCriticEmphasis("{~~[Carol]/a~>[Carol]/b~~}") == "/{~~[Carol]a~>[Carol]b~~}"
  check "a delimiter on only one side is left alone",
    hoistCriticEmphasis("{~~/a~>b~~}") == "{~~/a~>b~~}"
  check "prose without emphasis is untouched",
    hoistCriticEmphasis("plain {~~old~>new~~} text") == "plain {~~old~>new~~} text"

# -- criticToSpans: edge whitespace is escaped so pandoc keeps it -------------
block edges:
  var doneIds: seq[int]
  check "a trailing space stays inside the insertion span",
    criticToSpans("{++… participants ++}in", doneIds).contains(
      "[… participants&#32;]{.insertion") and
    criticToSpans("{++… participants ++}in", doneIds).endsWith("}in")
  check "a leading space stays inside the insertion span",
    criticToSpans("x{++ word++}", doneIds).contains("[&#32;word]{.insertion")
  check "a deletion's edge space is escaped too",
    criticToSpans("x{--gone --}y", doneIds).contains("[gone&#32;]{.deletion")
  check "a substitution's new side keeps its edge space",
    criticToSpans("{~~old~>new ~~}", doneIds).contains("[new&#32;]{.insertion")
  check "text without edge spaces is emitted plain",
    criticToSpans("{++clean++}", doneIds).contains("[clean]{.insertion") and
      not criticToSpans("{++clean++}", doneIds).contains("&#32;")

# -- criticToSpans: a span right after `]' is not read as a reference link ----
block afterBracket:
  var doneIds: seq[int]
  let c = criticToSpans("[@fig:a]{==x==}{>>note<<}", doneIds)
  check "a comment after a cross-ref gets a raw-span separator",
    c.startsWith("[@fig:a]<span></span>[note]{.comment-start")
  check "the separator is not an empty bracket span (`[ref][]')",
    not c.contains("[]{}")
  check "an insertion after a citation is separated too",
    criticToSpans("[@key]{++new++}", doneIds).startsWith("[@key]<span></span>[new]{.insertion")
  check "no separator when the token does not follow `]'",
    criticToSpans("see {++new++}", doneIds).startsWith("see [new]{.insertion")

# -- fillEmptyTableRow: spacer rows survive the markdown round trip -----------
block spacerRows:
  check "an all-empty row gets a no-break space in its first cell",
    fillEmptyTableRow("| | | |") == "|   | | |"
  check "indentation is kept",
    fillEmptyTableRow("  |  |  |") == "  |   |  |"
  check "a rule line is untouched",
    fillEmptyTableRow("|---+---|") == "|---+---|"
  check "a row with content is untouched",
    fillEmptyTableRow("| 9–14 | | |") == "| 9–14 | | |"
  check "prose is untouched",
    fillEmptyTableRow("text | more |") == "text | more |"

# -- prepTables: interior rules become marked rows ----------------------------
block interiorRules:
  let t = @["|---+---|", "| H | I |", "|---+---|", "| a | 1 |", "|---+---|",
            "| *b* | 2 |", "| | |", "|---+---|", "after"]
  let p = prepTables(t)
  check "top rule and header separator are kept",
    p[0] == "|---+---|" and p[2] == "|---+---|"
  check "an interior rule is dropped and marks the next row",
    p[3] == "| a | 1 |" and p[4] == "| " & ruleMark & " *b* | 2 |"
  check "a spacer row is still filled",
    p[5] == "|   | |"
  check "the bottom rule is kept and prose follows",
    p[6] == "|---+---|" and p[7] == "after" and p.len == 8
  check "tables inside blocks are untouched",
    prepTables(@["#+begin_example", "| a |", "|---|", "| b |", "|---|", "| c |",
                 "#+end_example"])[3 .. 5] == @["| b |", "|---|", "| c |"]

# -- drawRuleRows: end to end through pandoc ----------------------------------
block drawRules:
  if findExe("pandoc").len == 0:
    echo "skip drawRuleRows end-to-end: pandoc not on PATH"; break drawRules
  let dir = getTempDir() / "test_otd_rules"
  createDir(dir)
  writeFile(dir / "t.org", prepTables(@["| Model | AIC |", "|---+---|",
    "| *Alcohol* | |", "| bACE | 1.0 |", "|---+---|", "| *E-cigarette* | |",
    "| bCE | 2.0 |"]).join("\n") & "\n")
  let (_, code) = execCmdEx("pandoc " & quoteShell(dir / "t.org") & " -o " &
                            quoteShell(dir / "t.docx"))
  check "pandoc builds the test docx", code == 0
  check "drawRuleRows rewrites it", drawRuleRows(dir / "t.docx")
  let xml = openZipArchive(dir / "t.docx").extractFile("word/document.xml")
  check "the sentinel is gone", ruleMark notin xml
  check "exactly the marked row's two cells get a top border",
    xml.count("<w:tcBorders><w:top ") == 2
  let rowStart = xml.rfind("<w:tr>", 0, xml.find("E-cigarette"))
  check "the border is on the E-cigarette row",
    xml.find("<w:tcBorders>", rowStart) < xml.find("E-cigarette")
  check "the cell text is intact (no stray space run before it)",
    "<w:r><w:t xml:space=\"preserve\"> </w:t></w:r><w:r><w:rPr><w:b" notin xml

# -- wordDiffMarkup / markAcceptedEdits: fresh marks for accepted edits --------
block accepted_edits:
  check "a reworded run becomes a substitution",
    wordDiffMarkup("The result was clear.", "The finding was clear.") ==
      "The {~~result~>finding~~} was clear."
  check "a pure addition is marked as an insertion",
    wordDiffMarkup("We fit the model.", "We fit the final model.") ==
      "We fit the {++final ++}model."
  check "a pure removal is marked as a deletion",
    wordDiffMarkup("This was quite good.", "This was good.") ==
      "This was {--quite --}good."
  check "a whitespace-only change passes unmarked",
    wordDiffMarkup("a  b", "a b") == "a b"
  check "identical text passes through plain",
    wordDiffMarkup("same text", "same text") == "same text"
  check "an accepted rewording is marked against the canonical",
    markAcceptedEdits("The result was clear.", "The finding was clear.") ==
      "The {~~result~>finding~~} was clear."
  check "a comment-only change keeps the replacement untouched",
    markAcceptedEdits("Text.", "Text. {>>[Carol] note<<}") ==
      "Text. {>>[Carol] note<<}"
  check "accepting the canonical's own old mark resolves it silently",
    markAcceptedEdits("We {++add this++} now.", "We add this now.") ==
      "We add this now."

if fails > 0:
  echo "test_otd_spans: ", fails, " FAILED"
  quit 1
echo "test_otd_spans: all assertions passed"
