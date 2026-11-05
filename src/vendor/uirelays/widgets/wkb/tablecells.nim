## Included by synedit.nim: pipe table rows. wkbenchless only; kept out of
## that file so a sync with focim stays small.

proc isTableLine(s: SynEdit; i: int): bool =
  ## org table rows (start with '|' after leading whitespace) don't wrap; they
  ## extend past the edge and pan with hScroll.
  if s.lang != langOrg: return false
  var j = i
  while j < s.len and s[j] in {' ', '\t'}: inc j
  j < s.len and s[j] == '|'

proc fontForFlags(s: SynEdit; f: CellFlags; base: Font): Font =
  if cfBold in f and cfItalic in f: (if s.boldItalicFont.int != 0: s.boldItalicFont else: base)
  elif cfBold in f: (if s.boldFont.int != 0: s.boldFont else: base)
  elif cfItalic in f: (if s.italicFont.int != 0: s.italicFont else: base)
  else: base

proc tableGlyph(c: char; sep, atFirst, atLast: bool): string =
  ## Display-only box-drawing substitution for org/rmd table cells. `sep` marks a
  ## rule row (|---+---|); the buffer keeps the ASCII so tables stay editable.
  case c
  of '|':
    if not sep: "│"                       # │
    elif atFirst: "├"                     # ├
    elif atLast: "┤"                      # ┤
    else: "┼"                             # ┼
  of '+': (if sep: "┼" else: $c)          # ┼ (only in rule rows)
  of '-': (if sep: "─" else: $c)          # ─ (only in rule rows)
  else: $c
