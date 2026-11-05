## test_synedit_render -- SynEdit's drawing, headless: fake font and draw relays
## record every text run. Guards what the focim merges can break without any
## conflict: heading fonts, prose wrapping, no-wrap tables, folded blocks.
##   nim c -r --hints:off src/test_synedit_render.nim

import std/[sequtils, strutils]
import uirelays
import widgets/synedit

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

type Run = tuple[font, x, y: int; text: string]
var runs: seq[Run]
const Ell = "\xE2\x80\xA6"

proc charW(f: Font): int = (if f.int == 2: 12 else: 8)
proc lineH(f: Font): int = (if f.int == 2: 24 else: 16)

fontRelays.getFontMetrics = proc (f: Font): FontMetrics =
  FontMetrics(ascent: lineH(f) - 4, descent: 4, lineHeight: lineH(f))
fontRelays.measureText = proc (f: Font; text: string): TextExtent =
  TextExtent(w: text.len * charW(f), h: lineH(f))
fontRelays.drawText = proc (f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
  runs.add (f.int, x, y, text)
  TextExtent(w: text.len * charW(f), h: lineH(f))
drawRelays.fillRect = proc (r: Rect; color: Color) = discard
windowRelays.saveState = proc () = discard
windowRelays.restoreState = proc () = discard
windowRelays.setClipRect = proc (r: Rect) = discard

proc draw(lang: SourceLanguage; text: string; w = 400; prep: proc (s: var SynEdit) = nil): seq[Run] =
  var s = createSynEdit(Font(1))
  s.bigFont = Font(2)
  s.captionFont = Font(3)
  s.lang = lang
  s.setText(text)
  discard
  let area = rect(0, 0, w, 600)
  render(s, area, false)
  if prep != nil: prep(s)
  runs.setLen 0
  render(s, area, false)
  result = runs

proc rowsOf(r: seq[Run]; needle: string): seq[int] =
  for x in r:
    if needle in x.text and x.y notin result: result.add x.y

proc joined(r: seq[Run]): string =
  for x in r: result.add x.text

block heading_fonts:
  let r = draw(langOrg, "#+title: Paper name\n\n* Heading text\n\nplain body\n")
  var title, body = -1
  for x in r:
    if "Paper" in x.text: title = x.font
    if "plain" in x.text: body = x.font
  check "a title keeps the big font", title == 2
  check "a body line keeps the base font", body == 1

block bold_font:
  let r = draw(langOrg, "some *loud* word\n", prep = proc (s: var SynEdit) = s.boldFont = Font(4))
  var loud = -1
  for x in r:
    if "loud" in x.text: loud = x.font
  check "bold text keeps the bold font", loud == 4

const prose = "Words in a sentence (with a bracket, and a comma) keep going " &
  "for long enough that this one line has to wrap onto a second row of the pane.\n"

block prose_wrapping:
  let r = draw(langOrg, prose)
  var xs: seq[int]
  for x in r:
    if x.text.strip.len > 0 and x.x notin xs: xs.add x.x
  var rows: seq[int]
  for x in r:
    if x.y notin rows: rows.add x.y
  check "the sentence wraps", rows.len >= 2
  check "wrapped prose has no ellipsis marker", Ell notin r.joined
  var leftOnRow2 = high(int)
  for x in r:
    if x.y == rows[1]: leftOnRow2 = min(leftOnRow2, x.x)
  var leftOnRow1 = high(int)
  for x in r:
    if x.y == rows[0]: leftOnRow1 = min(leftOnRow1, x.x)
  check "wrapped prose returns to the left edge", leftOnRow2 == leftOnRow1

block code_wrapping:
  let r = draw(langNim, "proc f(a, b: int; " & "x".repeat(120) & ")\n")
  check "wrapped code keeps upstream's ellipsis marker", Ell in r.joined

block tables:
  let r = draw(langOrg, "| " & "cell ".repeat(40) & " | end |\n", 300)
  var rows: seq[int]
  for x in r:
    if x.y notin rows: rows.add x.y
  check "a wide table row stays on one row", rows.len == 1

const fold = "before\n\n#+begin_src R\nHIDDENBODY <- 1\n#+end_src\n\nafter\n"

block folding:
  let open = draw(langOrg, fold)
  check "an open block draws its body", "HIDDENBODY" in open.joined
  let closed = draw(langOrg, fold, prep = proc (s: var SynEdit) = s.foldAllBlocks())
  check "a folded block hides its body", "HIDDENBODY" notin closed.joined
  check "a folded block keeps its header", "begin_src" in closed.joined
  check "text after a fold still draws", "after" in closed.joined

# A fake styler: every body byte becomes a keyword, and each call is counted.
var styled: seq[string]
proc fakeHandles(lang: string): bool = lang == "r"
proc fakeStyler(lang, code: string; runs: var seq[StyleRun]) =
  styled.add code
  if code.len > 0: runs.add (0, code.high, TokenClass.Keyword)

proc styleAt(s: SynEdit; needle: string; text: string): TokenClass =
  s.getCell(text.find(needle)).s

const twoBlocks = "#+begin_src R\nrcode <- 1\n#+end_src\n\n#+begin_src python\npycode = 1\n#+end_src\n"

block code_styler_relay:
  let area = rect(0, 0, 400, 600)
  var plain = createSynEdit(Font(1))
  plain.lang = langOrg
  plain.setText(twoBlocks)
  render(plain, area, false)
  check "without a styler nothing is styled by it", styled.len == 0
  check "without a styler the tokenizer colors R",
    plain.styleAt("rcode", twoBlocks) != TokenClass.Keyword

  codeStylerHandles = fakeHandles
  codeStyler = fakeStyler
  var s = createSynEdit(Font(1))
  s.lang = langOrg
  s.setText(twoBlocks)
  render(s, area, false)
  echo "     styler calls: ", styled
  check "the styler gets a claimed block's body", styled.len > 0 and
    styled.allIt(it == "rcode <- 1\n")
  check "its runs reach the cells", s.styleAt("rcode", twoBlocks) == TokenClass.Keyword
  check "an unclaimed language keeps its tokenizer",
    s.styleAt("pycode", twoBlocks) != TokenClass.Keyword

  styled.setLen 0
  var f = createSynEdit(Font(1))
  f.lang = langOrg
  f.foldAllPending = true
  f.setText(twoBlocks)
  render(f, area, false)
  check "a folded block is not styled", styled.len == 0
  check "block ranges are still found while folded", f.blockRangeAt(0).a == 0
  check "fold-all folded both blocks", f.foldedBlocks.len == 2
  f.toggleFold(f.foldedBlocks[0])
  render(f, area, false)
  check "opening a block styles it", styled == @["rcode <- 1\n"] and
    f.styleAt("rcode", twoBlocks) == TokenClass.Keyword
  styled.setLen 0
  f.foldAllBlocks()
  f.unfoldAll()
  render(f, area, false)
  check "unfold-all styles what it reveals", styled.len >= 1

  styled.setLen 0
  var rmd = createSynEdit(Font(1))
  rmd.lang = langMarkdown
  rmd.setText("text\n\n```{r}\nchunk <- 1\n```\n")
  render(rmd, area, false)
  echo "     styler calls: ", styled
  check "an Rmd chunk reaches the styler", styled.len > 0 and
    styled.allIt(it == "chunk <- 1\n")
  codeStylerHandles = nil
  codeStyler = nil

if fails > 0:
  echo "test_synedit_render: ", fails, " FAILED"
  quit(1)
echo "test_synedit_render: all assertions passed"
