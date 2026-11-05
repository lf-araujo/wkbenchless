## Included by synedit.nim: the code styler relay, fence names and
## Markdown inline emphasis. wkbenchless only; kept out of
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

proc fenceToken(rest: string): string =
  ## Rmd uses ```{r} fences (with braces + optional chunk options); the language
  ## is the token before any space/comma/brace.
  result = rest
  if result.startsWith("{"):
    result = result[1 .. ^1]
  let sp = result.find({' ', ',', '}'})
  if sp >= 0: result = result[0 ..< sp]

proc emph(s: var SynEdit; ch: char; flag: CellFlag; first, last: int) =
  var p = first
  while p < last:
    if s[p] == ch and
       (p == first or s[p - 1] in {' ', '\t', '\L', '(', '{', '\''}) and
       p + 1 <= last and s[p + 1] notin {' ', '\t', '\L'}:
      var q = p + 1
      while q <= last and s[q] != '\L':
        if s[q] == ch and s[q - 1] notin {' ', '\t'}: break
        inc q
      if q <= last and s[q] == ch and q > p + 1:
        s.addCellFlags(p, {cfHidden}); s.addCellFlags(q, {cfHidden})
        for k in p + 1 .. q - 1: s.addCellFlags(k, {flag})
        p = q + 1
        continue
    inc p
# Markdown bold is **text** (double star); italic is *text* (single star).
# Handle **bold** first (double star), then *italic* (single star).
proc emphBold(s: var SynEdit; first, last: int) =
  var p = first
  while p + 1 < last:
    if s[p] == '*' and s[p + 1] == '*' and
       (p == first or s[p - 1] in {' ', '\t', '\L', '(', '{', '\''}) and
       p + 2 <= last and s[p + 2] notin {' ', '\t', '\L'}:
      var q = p + 2
      while q + 1 <= last and s[q] != '\L':
        if s[q] == '*' and s[q + 1] == '*' and s[q - 1] notin {' ', '\t'}:
          break
        inc q
      if q + 1 <= last and s[q] == '*' and s[q + 1] == '*' and q > p + 1:
        s.addCellFlags(p, {cfHidden}); s.addCellFlags(p + 1, {cfHidden})
        s.addCellFlags(q, {cfHidden}); s.addCellFlags(q + 1, {cfHidden})
        for k in p + 2 .. q - 1: s.addCellFlags(k, {cfBold})
        p = q + 2
        continue
    inc p
# `code` spans: colour the content in the code face, hide the backticks.
proc emphCode(s: var SynEdit; ch: char; tc: TokenClass; first, last: int) =
  var p = first
  while p < last:
    if s[p] == ch and
       (p == first or s[p - 1] in {' ', '\t', '\L', '(', '{', '\''}) and
       p + 1 <= last and s[p + 1] notin {' ', '\t', '\L'}:
      var q = p + 1
      while q <= last and s[q] != '\L':
        if s[q] == ch and s[q - 1] notin {' ', '\t'}: break
        inc q
      if q <= last and s[q] == ch and q > p + 1:
        s.addCellFlags(p, {cfHidden}); s.addCellFlags(q, {cfHidden})
        for k in p + 1 .. q - 1: s.setCellStyle(k, tc)
        p = q + 1
        continue
    inc p

proc styleMarkdownEmphasis(s: var SynEdit; first, last: int) =
  ## Inline emphasis: **bold**, *italic*, and `code` (Markdown syntax).
  s.emphBold(first, last)
  s.emph('*', cfItalic, first, last)
  s.emphCode('`', TokenClass.StringLit, first, last)
