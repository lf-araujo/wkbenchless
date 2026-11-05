## Included by synedit.nim: the code styler relay. wkbenchless only; kept out of
## that file so a sync with focim stays small.

proc usesCodeStyler(lang: string): bool =
  codeStyler != nil and codeStylerHandles != nil and lang.len > 0 and
    codeStylerHandles(lang.toLowerAscii)

proc styleBlockBody(s: var SynEdit; lang: string; blockStart, a, b: int) =
  ## Style the cells `a ..< b`, the body of the block opened at `blockStart`.
  ## A folded block is not on screen, so it waits until it is opened.
  if s.foldAllPending or blockStart in s.foldedBlocks or a >= b: return
  var code = newStringOfCap(b - a)
  for j in a ..< b: code.add s[j]
  var runs: seq[StyleRun]
  codeStyler(lang.toLowerAscii, code, runs)
  for j in a ..< b: s.setCellStyle(j, TokenClass.None)
  for r in runs:
    for k in r.first .. min(r.last, code.high):
      s.setCellStyle(a + k, r.tc)
