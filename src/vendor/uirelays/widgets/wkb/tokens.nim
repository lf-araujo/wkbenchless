## Included by synedit.nim: R and Org tokenizers. wkbenchless only; kept out of
## that file so a sync with focim stays small.

# --- wkbenchless additions: R and org-mode -------------------------------------
const rKeywords = ["if", "else", "for", "while", "repeat", "function",
  "return", "break", "next", "in", "TRUE", "FALSE", "NULL", "NA", "Inf",
  "NaN", "T", "F", "NA_integer_", "NA_real_", "NA_character_"]

proc rNextToken(g: var GeneralTokenizer) =
  ## Like pythonNextToken (# comments, ' and " strings, numbers), but with R
  ## keywords and `.` allowed inside identifiers (data.frame, is.na).
  const
    hexChars = {'0'..'9', 'A'..'F', 'a'..'f'}
    symChars = {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '\x80'..'\xFF'}
  var pos = g.pos
  g.start = g.pos
  if g.state == TokenClass.StringLit:
    g.kind = TokenClass.StringLit
    while true:
      case g.buf[pos]
      of '\\': g.kind = TokenClass.EscapeSequence; inc(pos); inc(pos); break
      of '\L': g.state = TokenClass.None; break
      of '"', '\'': inc(pos); g.state = TokenClass.None; break
      else: inc(pos)
  else:
    case g.buf[pos]
    of ' ', '\x09'..'\x0D':
      g.kind = TokenClass.Whitespace
      while pos < g.buf.len and g.buf[pos] in {' ', '\x09'..'\x0D'}: inc(pos)
    of '#':
      g.kind = TokenClass.Comment
      while g.buf[pos] != '\L': inc(pos)
    of 'a'..'z', 'A'..'Z', '.', '_', '\x80'..'\xFF':
      var id = ""
      while g.buf[pos] in symChars: add(id, g.buf[pos]); inc(pos)
      g.kind = TokenClass.Identifier
      for kw in rKeywords:
        if kw == id: g.kind = TokenClass.Keyword; break
      if g.kind == TokenClass.Identifier and g.buf[pos] == '(':
        g.kind = TokenClass.Command                # function name / call
    of '0'..'9':
      g.kind = TokenClass.DecNumber
      inc(pos)
      if g.buf[pos] in {'x', 'X'}:
        inc(pos); (while g.buf[pos] in hexChars: inc(pos))
      else:
        while g.buf[pos] in {'0'..'9', '.', 'e', 'E', 'L'}: inc(pos)
    of '"', '\'':
      inc(pos); g.kind = TokenClass.StringLit
      while pos < g.buf.len:
        case g.buf[pos]
        of '"', '\'': inc(pos); break
        of '\\': g.state = g.kind; break
        else: inc(pos)
    of '(', ')', '[', ']', '{', '}', ',', ';':
      inc(pos); g.kind = TokenClass.Punctuation
    else:
      if g.buf[pos] in OpChars:
        g.kind = TokenClass.Operator
        while g.buf[pos] in OpChars: inc(pos)
      else:
        if pos < g.buf.len: inc(pos)
        g.kind = TokenClass.None
  g.length = pos - g.pos
  g.pos = pos

proc orgNextToken(g: var GeneralTokenizer) =
  ## Line-oriented: #+directives, * headings, # and : lines get their own
  ## color; everything else is prose. Each line classifies itself, so it needs
  ## no cross-line state.
  var pos = g.pos
  g.start = g.pos
  if g.buf[pos] == '\L':
    g.kind = TokenClass.Whitespace; inc(pos)
  else:
    let atLineStart = pos == 0 or g.buf[pos - 1] == '\L'
    if atLineStart:
      var p = pos
      while p < g.buf.len and g.buf[p] in {' ', '\x09'}: inc(p)
      let c = if p < g.buf.len: g.buf[p] else: '\L'
      if c == '#':
        g.kind = if p + 1 < g.buf.len and g.buf[p + 1] == '+':
                   TokenClass.Directive else: TokenClass.Comment
      elif c == '*': g.kind = TokenClass.Keyword     # heading
      elif c == ':': g.kind = TokenClass.Comment     # results / drawer
      else: g.kind = TokenClass.Text
    else:
      g.kind = TokenClass.Text
    while pos < g.buf.len and g.buf[pos] != '\L': inc(pos)
  g.length = pos - g.pos
  g.pos = pos
