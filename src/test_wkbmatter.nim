## test_wkbmatter -- Matter as SynEdit's code styler, on real R. Needs the
## optional engine, so without `-d:wkbMatter` it only reports that it skipped.
##   nim c -r -d:wkbMatter --hints:off src/test_wkbmatter.nim

when not defined(wkbMatter):
  echo "test_wkbmatter: skipped (build with -d:wkbMatter)"
else:
  import std/[monotimes, os, strutils, times]
  import uirelays
  import widgets/synedit
  import wkbmatter

  var fails = 0
  template check(name: string; cond: bool) =
    if cond: echo "ok   ", name
    else: echo "FAIL ", name; inc fails

  fontRelays.getFontMetrics = proc (f: Font): FontMetrics =
    FontMetrics(ascent: 12, descent: 4, lineHeight: 16)
  fontRelays.measureText = proc (f: Font; text: string): TextExtent =
    TextExtent(w: text.len * 8, h: 16)
  fontRelays.drawText = proc (f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
    TextExtent(w: text.len * 8, h: 16)
  drawRelays.fillRect = proc (r: Rect; color: Color) = discard
  windowRelays.saveState = proc () = discard
  windowRelays.restoreState = proc () = discard
  windowRelays.setClipRect = proc (r: Rect) = discard

  install()
  let area = rect(0, 0, 900, 700)
  const doc = "#+begin_src R\n# note\nx <- mean(y, na.rm = TRUE)\nif (x > 1) z <- \"one\n  two\"\nw <- 12\n#+end_src\n"
  var s = createSynEdit(Font(1))
  s.lang = langOrg
  s.setText(doc)
  render(s, area, false)
  template at(needle: string): TokenClass = s.getCell(doc.find(needle)).s
  check "comment", at("# note") == TokenClass.Comment
  check "keyword", at("if (x") == TokenClass.Keyword
  check "constant", at("TRUE") == TokenClass.Keyword
  check "number", at("12") == TokenClass.DecNumber
  check "function call", at("mean") == TokenClass.Command
  check "string", at("one") == TokenClass.StringLit
  check "a string carries across lines", at("two") == TokenClass.StringLit
  check "the directive stays a directive", at("#+begin_src") == TokenClass.Directive

  if paramCount() >= 1:
    proc usNow(): int64 = getMonoTime().ticks div 1000
    let text = readFile(paramStr(1))
    let at0 = text.find("#+begin_src R", text.len div 2)
    proc run(folded: bool; label: string) =
      var e = createSynEdit(Font(1))
      e.lang = langOrg
      e.foldAllPending = folded
      let t0 = usNow()
      e.setText(text)
      render(e, area, false)
      let opened = float(usNow() - t0) / 1000
      e.gotoPos(at0 + 200)
      var worst, total = 0.0
      for i in 1 .. 20:
        e.insertChar('a')
        let t1 = usNow()
        render(e, area, false)
        let ms = float(usNow() - t1) / 1000
        total += ms; worst = max(worst, ms)
      echo label, ": open ", opened.formatFloat(ffDecimal, 1), " ms, keystroke avg ",
        (total / 20).formatFloat(ffDecimal, 1), " ms, worst ", worst.formatFloat(ffDecimal, 1), " ms"
    run(false, "all blocks open")
    run(false, "open again, cache warm")
    run(true, "all blocks folded")
    codeStylerHandles = nil
    codeStyler = nil
    run(false, "no engine, open")
    run(true, "no engine, folded")

  if fails > 0:
    echo "test_wkbmatter: ", fails, " FAILED"
    quit(1)
  echo "test_wkbmatter: all assertions passed"
