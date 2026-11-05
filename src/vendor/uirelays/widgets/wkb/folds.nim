## Included by synedit.nim: block folding and the Org highlighter. wkbenchless only; kept out of
## that file so a sync with focim stays small.

proc inSrcBlock(s: SynEdit; offset: int): bool =
  for r in s.srcBlockRanges:
    if offset in r: return true
  false

proc blockRangeAt*(s: SynEdit; offset: int): Slice[int] =
  ## The src-block range whose #+begin_src line starts at `offset`, or (-1..-1).
  for r in s.srcBlockRanges:
    if r.a == offset: return r
  -1 .. -1

proc isFolded*(s: SynEdit; blockStart: int): bool = blockStart in s.foldedBlocks

proc toggleFold*(s: var SynEdit; blockStart: int) =
  let idx = s.foldedBlocks.find(blockStart)
  if idx >= 0:
    s.foldedBlocks.delete(idx)
    s.highlighter.version = s.version - 1   # the styler skipped it while folded
  else:
    s.foldedBlocks.add blockStart

proc foldAllBlocks*(s: var SynEdit) =
  ## Collapse every src block (used to start documents with code hidden).
  s.foldedBlocks.setLen 0
  for r in s.srcBlockRanges: s.foldedBlocks.add r.a

proc unfoldAll*(s: var SynEdit) =
  s.foldedBlocks.setLen 0
  s.highlighter.version = s.version - 1     # the styler skipped them while folded

proc lineStartOf(s: SynEdit; offset: int): int =
  ## Buffer offset of the start of the line containing `offset`.
  var i = clamp(offset, 0, s.len)
  while i > 0 and s[i-1] != '\L': dec i
  i

proc foldedRangeContaining(s: SynEdit; offset: int): Slice[int] =
  ## The *folded* src-block range whose collapsed body contains `offset`,
  ## or (-1 .. -1). Folds are display-only -- the text stays in the buffer --
  ## so cursor motion and selection must hop over the hidden rows; this is how
  ## up/down notice they have wandered inside a collapsed block. `r.a` is the
  ## line-start of the #+begin_src line, which is the one row still drawn.
  for r in s.srcBlockRanges:
    if r.a in s.foldedBlocks and offset in r: return r
  -1 .. -1

proc offsetAtColumn(s: SynEdit; lineStart, col: int): int =
  ## Offset `col` graphemes into the line beginning at `lineStart`, stopping
  ## at end of line (mirrors the column walk in up/down).
  var i = clamp(lineStart, 0, s.len)
  var c = col
  while i < s.len and c > 0 and s[i] != '\L':
    i += s.graphemeLen(i)
    dec c
  i

proc isOrgHeadlineText*(line: string): bool =
  ## True iff LINE is an org headline: column 0, a run of 1+ `*`, then a space
  ## (`^\*+ `). A line like `*Response.*` or `*eTable 1.*` is bold emphasis, not a
  ## headline -- so it must NOT get heading colour / big-font styling.
  if line.len == 0 or line[0] != '*': return false
  var k = 0
  while k < line.len and line[k] == '*': inc k
  k < line.len and line[k] == ' '

proc highlightOrg(s: var SynEdit; first, last: int) =
  ## Org-mode, fontified natively: #+directives / * headings / # and : lines
  ## get their own colour, and the body of a #+begin_src <lang> ... #+end_src
  ## block is tokenized in <lang> (like Markdown fenced code). Line-based, so it
  ## carries the in-block state that a per-token tokenizer cannot.
  var insideBlock = false
  var blockLang = langNone
  var blockName = ""
  var blockStyled = false
  var blockBody = first
  var blockStart = first
  s.srcBlockRanges.setLen(0)             # org calls this full-buffer, so rebuild
  for j in first .. last: s.setCellFlags(j, {})   # rebuilt below each pass
  var pos = first
  while pos > 0 and s[pos-1] != '\L': dec pos
  while pos <= last:
    let lineStart = pos
    var lineEnd = pos
    while lineEnd <= last and s[lineEnd] != '\L': inc lineEnd
    var lineText = ""
    for j in lineStart ..< lineEnd: lineText.add s[j]
    let stripped = lineText.strip(leading = true, trailing = false)
    let ls = stripped.toLowerAscii
    if ls.startsWith("#+begin_src"):
      for j in lineStart ..< min(lineEnd, last + 1): s.setCellStyle(j, TokenClass.Directive)
      let parts = stripped.splitWhitespace()
      blockLang = if parts.len >= 2: strToLanguage(parts[1]) else: langNone
      blockName = if parts.len >= 2: parts[1] else: ""
      blockStyled = usesCodeStyler(blockName)
      insideBlock = true
      blockStart = lineStart
      blockBody = lineEnd + 1
    elif ls.startsWith("#+end_src"):
      for j in lineStart ..< min(lineEnd, last + 1): s.setCellStyle(j, TokenClass.Directive)
      if insideBlock:
        s.srcBlockRanges.add(blockStart .. lineEnd)
        if blockStyled: s.styleBlockBody(blockName, blockStart, blockBody, lineStart)
      insideBlock = false; blockLang = langNone; blockStyled = false
    elif insideBlock and blockStyled:
      discard                            # styled as a whole at #+end_src
    elif insideBlock and blockLang != langNone:
      var g: GeneralTokenizer
      g.buf = addr s
      g.kind = low(TokenClass)
      g.start = lineStart
      g.length = 0
      g.state = TokenClass.None
      g.pos = lineStart
      while g.pos < lineEnd and g.pos <= last:
        getNextToken(g, blockLang)
        if g.length == 0: break
        for k in 0 ..< g.length:
          if g.start + k <= last: s.setCellStyle(g.start + k, g.kind)
      if lineEnd <= last: s.setCellStyle(lineEnd, TokenClass.None)
    elif stripped.len > 0 and stripped[0] == '|':
      # org table row: colour the | borders (and +---+ rules) like a frame so
      # the table reads as a grid; cells keep the default text colour.
      for j in lineStart ..< min(lineEnd, last + 1):
        s.setCellStyle(j, if s[j] in {'|', '+', '-'}: TokenClass.Operator
                          else: TokenClass.Text)
      if lineEnd <= last: s.setCellStyle(lineEnd, TokenClass.Whitespace)
    else:
      var tc = TokenClass.Text
      if stripped.len > 0:
        case stripped[0]
        of '#': tc = if stripped.len > 1 and stripped[1] == '+': TokenClass.Directive
                     else: TokenClass.Comment
        of '*': tc = if isOrgHeadlineText(lineText): TokenClass.Keyword  # `*+ ` only
                     else: TokenClass.Text                              # `*bold*` is body
        of ':': tc = TokenClass.Comment
        else: discard
      for j in lineStart ..< min(lineEnd, last + 1): s.setCellStyle(j, tc)
      if lineEnd <= last: s.setCellStyle(lineEnd, TokenClass.Whitespace)
    pos = lineEnd + 1
  if insideBlock: s.srcBlockRanges.add(blockStart .. last)   # unterminated block
  # [[target][label]] / [[target]] org links: colour the label, hide the
  # brackets and the target so only the human-readable text shows.
  var lp = first
  while lp < last:
    if s[lp] == '[' and s[lp + 1] == '[' and not s.inSrcBlock(lp):
      var q = lp + 2
      while q < last and not (s[q] == ']' and s[q + 1] == ']'): inc q
      if q < last:
        # inner = between [[ and ]] ; split on "][" into target / label
        var sep = -1
        var t = lp + 2
        while t < q - 1:
          if s[t] == ']' and s[t + 1] == '[': sep = t; break
          inc t
        for k in lp .. q + 1: s.setCellStyle(k, TokenClass.Link)
        s.addCellFlags(lp, {cfHidden}); s.addCellFlags(lp + 1, {cfHidden})   # [[
        s.addCellFlags(q, {cfHidden}); s.addCellFlags(q + 1, {cfHidden})     # ]]
        if sep >= 0:
          for k in lp + 2 .. sep + 1: s.addCellFlags(k, {cfHidden})  # target + ][
        lp = q + 2
        continue
    inc lp
  # [cite:...] citations (org-cite): colour the whole construct as a link and
  # pick out each @key in the reference face so the keys read at a glance.
  var cp = first
  while cp + 5 <= last:
    if s[cp] == '[' and s[cp + 1] == 'c' and s[cp + 2] == 'i' and
       s[cp + 3] == 't' and s[cp + 4] == 'e' and not s.inSrcBlock(cp):
      # optional /style after "cite", then ':'
      var k = cp + 5
      if k < last and s[k] == '/':
        inc k
        while k < last and s[k] notin {':', ']', '\L'}: inc k
      if k < last and s[k] == ':':
        var q = k + 1
        while q <= last and s[q] notin {']', '\L'}: inc q
        if q <= last and s[q] == ']':
          for j in cp .. q: s.setCellStyle(j, TokenClass.Link)
          # Hide the "[cite:" / "[cite/style:" prefix and the closing "]" so the
          # citation reads as bare @key(s); the delimiters stay in the buffer.
          for j in cp .. k: s.addCellFlags(j, {cfHidden})
          s.addCellFlags(q, {cfHidden})
          # @key runs in the reference face
          var t = k + 1
          while t < q:
            if s[t] == '@':
              var u = t
              while u < q and s[u] notin {' ', ';', ']', '\L'}: inc u
              for j in t ..< u: s.setCellStyle(j, TokenClass.Reference)
              t = u
            else: inc t
          cp = q + 1
          continue
    inc cp
  # inline emphasis: *bold* /italic/ _underline_ =verbatim= ~code~. Org requires
  # the markers to hug non-space text, so a lone '*' or a spaced '/' is left be.
  proc emph(s: var SynEdit; ch: char; flag: CellFlag; first, last: int) =
    var p = first
    while p < last:
      if s[p] == ch and not s.inSrcBlock(p) and
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
  s.emph('*', cfBold, first, last)
  s.emph('/', cfItalic, first, last)
  # =verbatim= and ~code~: colour the content in the code face, hide the markers.
  proc emphCode(s: var SynEdit; ch: char; tc: TokenClass; first, last: int) =
    var p = first
    while p < last:
      if s[p] == ch and not s.inSrcBlock(p) and
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
  s.emphCode('=', TokenClass.StringLit, first, last)
  s.emphCode('~', TokenClass.StringLit, first, last)
  # CriticMarkup (tracked changes, cf. org-tracked-docx): {++ins++} green,
  # {--del--} red, {~~old~>new~~} red->green, {>>comment<<} grey, {==hi==} yellow.
  # No per-cell strike/underline here, so colour carries the meaning; markers dim.
  proc critic(s: var SynEdit; o1, o2, c1, c2: char; body: TokenClass; first, last: int) =
    var p = first
    while p + 3 <= last:
      if s[p] == '{' and s[p+1] == o1 and s[p+2] == o2 and not s.inSrcBlock(p):
        var q = p + 3
        while q + 2 <= last and not (s[q] == c1 and s[q+1] == c2 and s[q+2] == '}'): inc q
        if q + 2 <= last and s[q] == c1 and s[q+1] == c2 and s[q+2] == '}':
          for k in p + 3 .. q - 1: s.setCellStyle(k, body)
          for k in p .. p + 2: s.setCellStyle(k, TokenClass.Punctuation)   # {oo
          for k in q .. q + 2: s.setCellStyle(k, TokenClass.Punctuation)   # cc}
          p = q + 3
          continue
      inc p
  s.critic('+', '+', '+', '+', TokenClass.Green, first, last)    # insertion
  s.critic('-', '-', '-', '-', TokenClass.Red, first, last)      # deletion
  s.critic('=', '=', '=', '=', TokenClass.Yellow, first, last)   # highlight
  s.critic('>', '>', '<', '<', TokenClass.Comment, first, last)  # comment
  block:                                   # {~~old~>new~~}: old red, new green
    var p = first
    while p + 3 <= last:
      if s[p] == '{' and s[p+1] == '~' and s[p+2] == '~' and not s.inSrcBlock(p):
        var q = p + 3
        while q + 2 <= last and not (s[q] == '~' and s[q+1] == '~' and s[q+2] == '}'): inc q
        if q + 2 <= last and s[q] == '~' and s[q+1] == '~' and s[q+2] == '}':
          var arrow = -1
          var t = p + 3
          while t < q - 1:
            if s[t] == '~' and s[t+1] == '>': arrow = t; break
            inc t
          for k in p .. p + 2: s.setCellStyle(k, TokenClass.Punctuation)
          for k in q .. q + 2: s.setCellStyle(k, TokenClass.Punctuation)
          if arrow >= 0:
            for k in p + 3 .. arrow - 1: s.setCellStyle(k, TokenClass.Red)
            s.setCellStyle(arrow, TokenClass.Punctuation); s.setCellStyle(arrow+1, TokenClass.Punctuation)
            for k in arrow + 2 .. q - 1: s.setCellStyle(k, TokenClass.Green)
          else:
            for k in p + 3 .. q - 1: s.setCellStyle(k, TokenClass.Green)
          p = q + 3
          continue
      inc p
  # Drop folds that no longer sit on a block start (edits shifted the buffer).
  var kept: seq[int]
  for f in s.foldedBlocks:
    for r in s.srcBlockRanges:
      if r.a == f: kept.add f; break
  s.foldedBlocks = kept
