## A small VT/ANSI terminal emulator: a screen grid of colored cells with a
## cursor, driven by the byte stream from a PTY. Enough to render cursor-
## addressed TUIs (claude, htop, vim) that the earlier ANSI-stripped line-log
## could not -- CUP/cursor moves, ED/EL erase, scroll region, insert/delete,
## the alternate screen, and SGR colors (16 / 256 / truecolor).
##
## Not a conformance-complete DEC VT; unknown sequences are swallowed rather
## than printed. Pure data -- the host reads `grid`/`cursor` and draws them.

import std/strutils
import uirelays   # Color, color

type
  Cell* = object
    ch*: string        ## one UTF-8 grapheme; "" renders as a blank
    fg*, bg*: Color
    inv*: bool         ## reverse video (swap fg/bg at draw time)
    wide*: bool        ## primary cell of a double-width glyph (CJK, emoji, ...)
    cont*: bool        ## trailing (blank) half of the double-width glyph before it
  VtState = enum vsGround, vsEsc, vsCsi, vsOsc
  VTerm* = ref object
    rows*, cols*: int
    grid*: seq[seq[Cell]]      ## the visible screen, rows*cols
    saved: seq[seq[Cell]]      ## stash for the primary screen while in alt
    inAlt*: bool               ## on the alternate screen (TUIs; no scrollback)
    scrollback*: seq[seq[Cell]] ## lines pushed off the top of the primary screen
    viewOffset*: int           ## lines scrolled up into scrollback (0 == live tail)
    mouseRep*: bool            ## app enabled mouse reporting (DECSET 1000/1002/1003)
    mouseSgr*: bool            ## app enabled SGR mouse encoding (DECSET 1006)
    bracketedPaste*: bool      ## app enabled bracketed paste (DECSET 2004)
    cx*, cy*: int              ## cursor column, row (0-based)
    scx, scy: int              ## saved cursor (DECSC / ESC7)
    top, bot: int              ## scroll region rows [top, bot]
    curFg, curBg: Color
    inv, bold: bool
    defFg*, defBg*: Color      ## palette defaults (from the theme)
    st: VtState
    par: string                ## collected CSI parameter bytes
    priv: bool                 ## CSI '?' private marker
    osc: string
    pending: string             ## a UTF-8 sequence truncated at the end of the last
                                 ## `write` (pty reads land wherever the kernel split
                                 ## them, not on character boundaries); completed by
                                 ## whatever `write` brings next instead of being torn
                                 ## into a garbage lead byte plus orphaned continuation
                                 ## bytes that each printed as their own stray glyph.

const maxScrollback = 5000    ## cap history so a long-running shell stays bounded
const scrollbackTrimAt = maxScrollback * 2   ## trim only past this, so the cap is amortized O(1)

proc blankCell(t: VTerm): Cell = Cell(ch: "", fg: t.curFg, bg: t.curBg, inv: false)

proc blankRow(t: VTerm): seq[Cell] =
  result = newSeq[Cell](t.cols)
  for i in 0 ..< t.cols: result[i] = Cell(ch: "", fg: t.defFg, bg: t.defBg)

proc newVTerm*(rows, cols: int; fg, bg: Color): VTerm =
  result = VTerm(rows: max(1, rows), cols: max(1, cols),
                 defFg: fg, defBg: bg, curFg: fg, curBg: bg)
  result.top = 0; result.bot = result.rows - 1
  result.grid = newSeq[seq[Cell]](result.rows)
  for r in 0 ..< result.rows: result.grid[r] = result.blankRow()

proc clampCursor(t: VTerm) =
  t.cx = max(0, min(t.cx, t.cols - 1))
  t.cy = max(0, min(t.cy, t.rows - 1))

proc resize*(t: VTerm; rows, cols: int) =
  let rows = max(1, rows)
  let cols = max(1, cols)
  if rows == t.rows and cols == t.cols: return
  var ng = newSeq[seq[Cell]](rows)
  for r in 0 ..< rows:
    var row = newSeq[Cell](cols)
    for c in 0 ..< cols:
      row[c] = if r < t.grid.len and c < t.grid[r].len: t.grid[r][c]
               else: Cell(ch: "", fg: t.defFg, bg: t.defBg)
    ng[r] = row
  t.rows = rows; t.cols = cols
  t.grid = ng
  t.top = 0; t.bot = rows - 1
  t.viewOffset = min(t.viewOffset, t.scrollback.len)
  t.clampCursor()

proc maxViewOffset*(t: VTerm): int = t.scrollback.len

proc recolorDefaults*(t: VTerm; oldFg, oldBg, newFg, newBg: Color) =
  ## After a theme change, repaint every cell that used the old default
  ## foreground/background with the new defaults. Cells carrying an explicit
  ## SGR colour (which differs from the old default) are left alone.
  for row in t.grid.mitems:
    for c in row.mitems:
      if c.fg == oldFg: c.fg = newFg
      if c.bg == oldBg: c.bg = newBg
  for row in t.scrollback.mitems:
    for c in row.mitems:
      if c.fg == oldFg: c.fg = newFg
      if c.bg == oldBg: c.bg = newBg
  t.curFg = newFg; t.curBg = newBg

proc scrollView*(t: VTerm; delta: int) =
  ## Move the viewport by `delta` lines (positive = back into history).
  t.viewOffset = max(0, min(t.viewOffset + delta, t.scrollback.len))

proc viewRow*(t: VTerm; ry: int): seq[Cell] =
  ## Row `ry` (0-based, top of body) of the viewport, accounting for how far the
  ## user has scrolled back. When `viewOffset == 0` this is just `grid[ry]`.
  ## A scrollback row may predate a resize and be shorter than `cols`; pad it so
  ## the caller can index `0 ..< cols` safely.
  let idx = t.scrollback.len - t.viewOffset + ry
  var row: seq[Cell]
  if idx < 0: row = t.blankRow()
  elif idx < t.scrollback.len: row = t.scrollback[idx]
  else:
    let g = idx - t.scrollback.len
    if g >= 0 and g < t.grid.len: row = t.grid[g]
    else: row = t.blankRow()
  if row.len < t.cols:
    let old = row
    row = newSeq[Cell](t.cols)
    for c in 0 ..< t.cols:
      row[c] = if c < old.len: old[c] else: Cell(ch: "", fg: t.defFg, bg: t.defBg)
  row

# --- screen ops -------------------------------------------------------------

proc scrollUp(t: VTerm; n = 1) =
  ## Move lines in the scroll region up by n; blank the vacated bottom lines.
  ## On the primary screen with a full-height region, the evicted top line is
  ## preserved in `scrollback` so the user can scroll back to it.
  let history = not t.inAlt and t.top == 0 and t.bot == t.rows - 1
  for _ in 0 ..< n:
    if history:
      t.scrollback.add t.grid[0]
    for r in t.top ..< t.bot:
      t.grid[r] = t.grid[r + 1]
    t.grid[t.bot] = t.blankRow()
  if history and t.scrollback.len > scrollbackTrimAt:
    t.scrollback = t.scrollback[^maxScrollback .. ^1]
  # Keep a scrolled-up viewport looking at the same content as history grows.
  if history and t.viewOffset > 0:
    t.viewOffset = min(t.viewOffset + n, t.scrollback.len)

proc scrollDown(t: VTerm; n = 1) =
  for _ in 0 ..< n:
    for r in countdown(t.bot, t.top + 1):
      t.grid[r] = t.grid[r - 1]
    t.grid[t.top] = t.blankRow()

proc lineFeed(t: VTerm) =
  if t.cy == t.bot: t.scrollUp()
  elif t.cy < t.rows - 1: inc t.cy

# --- Unicode display width ---------------------------------------------------
# wkbenchless used to advance the cursor by exactly one column per grapheme,
# full stop. That disagrees with whatever wrote the bytes in the first place:
# once the producer and this terminal disagree on the column a redraw lands in,
# every cursor move after such a glyph on the line is off, and partial repaints
# leave old and new glyphs interleaved. Producers (wcwidth; `string-width`, as
# used by Ink TUIs) give 2 columns only to East Asian Wide/Fullwidth characters,
# so symbols such as the ● ❯ ✓ ▶ ⚠ a TUI prints are 1: treating whole symbol
# blocks as 2 scrambled every line that held one. `wideSymbols` is therefore
# the exact EAW=W list for the symbol and emoji planes, not block ranges.

proc decodeRune(s: string): int =
  ## Decode the single UTF-8 grapheme `s` (as sliced by `write`, so its length
  ## already matches the lead byte) to its code point.
  if s.len == 0: return 0
  let b0 = s[0].uint8
  case s.len
  of 1: b0.int
  of 2: ((b0.int and 0x1F) shl 6) or (s[1].uint8.int and 0x3F)
  of 3: ((b0.int and 0x0F) shl 12) or ((s[1].uint8.int and 0x3F) shl 6) or
        (s[2].uint8.int and 0x3F)
  of 4: ((b0.int and 0x07) shl 18) or ((s[1].uint8.int and 0x3F) shl 12) or
        ((s[2].uint8.int and 0x3F) shl 6) or (s[3].uint8.int and 0x3F)
  else: 0xFFFD

# Unicode 16.0.0 East_Asian_Width=W, U+2190..U+2BFF and U+1F000..U+1FAFF.
const wideSymbols = [
  (0x231A, 0x231B), (0x2329, 0x232A), (0x23E9, 0x23EC), (0x23F0, 0x23F0),
  (0x23F3, 0x23F3), (0x25FD, 0x25FE), (0x2614, 0x2615), (0x2630, 0x2637),
  (0x2648, 0x2653), (0x267F, 0x267F), (0x268A, 0x268F), (0x2693, 0x2693),
  (0x26A1, 0x26A1), (0x26AA, 0x26AB), (0x26BD, 0x26BE), (0x26C4, 0x26C5),
  (0x26CE, 0x26CE), (0x26D4, 0x26D4), (0x26EA, 0x26EA), (0x26F2, 0x26F3),
  (0x26F5, 0x26F5), (0x26FA, 0x26FA), (0x26FD, 0x26FD), (0x2705, 0x2705),
  (0x270A, 0x270B), (0x2728, 0x2728), (0x274C, 0x274C), (0x274E, 0x274E),
  (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797), (0x27B0, 0x27B0),
  (0x27BF, 0x27BF), (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55),
  (0x1F004, 0x1F004), (0x1F0CF, 0x1F0CF), (0x1F18E, 0x1F18E),
  (0x1F191, 0x1F19A), (0x1F200, 0x1F202), (0x1F210, 0x1F23B),
  (0x1F240, 0x1F248), (0x1F250, 0x1F251), (0x1F260, 0x1F265),
  (0x1F300, 0x1F320), (0x1F32D, 0x1F335), (0x1F337, 0x1F37C),
  (0x1F37E, 0x1F393), (0x1F3A0, 0x1F3CA), (0x1F3CF, 0x1F3D3),
  (0x1F3E0, 0x1F3F0), (0x1F3F4, 0x1F3F4), (0x1F3F8, 0x1F43E),
  (0x1F440, 0x1F440), (0x1F442, 0x1F4FC), (0x1F4FF, 0x1F53D),
  (0x1F54B, 0x1F54E), (0x1F550, 0x1F567), (0x1F57A, 0x1F57A),
  (0x1F595, 0x1F596), (0x1F5A4, 0x1F5A4), (0x1F5FB, 0x1F64F),
  (0x1F680, 0x1F6C5), (0x1F6CC, 0x1F6CC), (0x1F6D0, 0x1F6D2),
  (0x1F6D5, 0x1F6D7), (0x1F6DC, 0x1F6DF), (0x1F6EB, 0x1F6EC),
  (0x1F6F4, 0x1F6FC), (0x1F7E0, 0x1F7EB), (0x1F7F0, 0x1F7F0),
  (0x1F90C, 0x1F93A), (0x1F93C, 0x1F945), (0x1F947, 0x1F9FF),
  (0x1FA70, 0x1FA7C), (0x1FA80, 0x1FA89), (0x1FA8F, 0x1FAC6),
  (0x1FACE, 0x1FADC), (0x1FADF, 0x1FAE9), (0x1FAF0, 0x1FAF8)]

proc runeWidth(cp: int): int =
  ## Display columns for code point `cp`: 0 for combining marks / invisible
  ## formatting characters, 2 for East-Asian-wide/fullwidth characters (see
  ## note above), 1 otherwise.
  if (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or
     (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF) or
     (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xFE20 and cp <= 0xFE2F) or
     cp in [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]:
    return 0
  if (cp >= 0x1100 and cp <= 0x115F) or                 # Hangul Jamo
     (cp >= 0x2E80 and cp <= 0x303E) or                 # CJK radicals/symbols
     (cp >= 0x3041 and cp <= 0x33FF) or                 # Hiragana..CJK compat
     (cp >= 0x3400 and cp <= 0x4DBF) or                 # CJK ext A
     (cp >= 0x4E00 and cp <= 0x9FFF) or                 # CJK unified
     (cp >= 0xA000 and cp <= 0xA4CF) or                 # Yi
     (cp >= 0xAC00 and cp <= 0xD7A3) or                 # Hangul syllables
     (cp >= 0xF900 and cp <= 0xFAFF) or                 # CJK compat ideographs
     (cp >= 0xFE30 and cp <= 0xFE4F) or                 # CJK compat forms
     (cp >= 0xFF00 and cp <= 0xFF60) or                 # fullwidth forms
     (cp >= 0xFFE0 and cp <= 0xFFE6) or                 # fullwidth signs
     (cp >= 0x20000 and cp <= 0x3FFFD):                 # CJK ext B+
    return 2
  for (lo, hi) in wideSymbols:
    if cp >= lo and cp <= hi: return 2
  1

proc cursorCol*(t: VTerm): int =
  ## The cell the cursor is on. `cx` itself reaches `cols` after a character
  ## lands in the last column (pending wrap, so the next character wraps), which
  ## is one past the end of a row: anything indexing the grid at the cursor
  ## between writes must use this instead.
  max(0, min(t.cx, t.cols - 1))

proc clearPairAt(t: VTerm; cy, cx: int) =
  ## Writing into one half of a previously double-width glyph leaves the
  ## other half dangling (still marked wide/cont, showing stale content) --
  ## blank it out too.
  if cx < 0 or cx >= t.cols: return
  let cell = t.grid[cy][cx]
  if cell.wide and cx + 1 < t.cols and t.grid[cy][cx + 1].cont:
    t.grid[cy][cx + 1] = Cell(ch: "", fg: t.defFg, bg: t.defBg)
  elif cell.cont and cx - 1 >= 0 and t.grid[cy][cx - 1].wide:
    t.grid[cy][cx - 1] = Cell(ch: "", fg: t.defFg, bg: t.defBg)

proc putChar(t: VTerm; ch: string; width = 1) =
  if width == 0:                 # combining mark: merge into the previous cell
    if t.cx > 0: t.grid[t.cy][t.cx - 1].ch.add ch
    return
  if t.cx + width > t.cols:      # not enough room left on this line -- wrap
    t.cx = 0
    t.lineFeed()
  t.clampCursor()
  t.clearPairAt(t.cy, t.cx)
  if width == 2 and t.cx + 1 < t.cols: t.clearPairAt(t.cy, t.cx + 1)
  t.grid[t.cy][t.cx] = Cell(ch: ch, fg: t.curFg, bg: t.curBg, inv: t.inv, wide: width == 2)
  if width == 2:
    if t.cx + 1 < t.cols:
      t.grid[t.cy][t.cx + 1] = Cell(ch: "", fg: t.curFg, bg: t.curBg, inv: t.inv, cont: true)
    t.cx += 2
  else:
    inc t.cx

proc eraseInLine(t: VTerm; mode: int) =
  let blank = Cell(ch: "", fg: t.defFg, bg: t.defBg)
  case mode
  of 0: (for c in t.cx ..< t.cols: t.grid[t.cy][c] = blank)          # cursor->end
  of 1: (for c in 0 .. min(t.cx, t.cols - 1): t.grid[t.cy][c] = blank)  # start->cursor
  of 2: (for c in 0 ..< t.cols: t.grid[t.cy][c] = blank)             # whole line
  else: discard

proc eraseInDisplay(t: VTerm; mode: int) =
  let blank = Cell(ch: "", fg: t.defFg, bg: t.defBg)
  case mode
  of 0:                                    # cursor -> end of screen
    t.eraseInLine(0)
    for r in t.cy + 1 ..< t.rows: t.grid[r] = t.blankRow()
  of 1:                                    # start -> cursor
    for r in 0 ..< t.cy: t.grid[r] = t.blankRow()
    t.eraseInLine(1)
  of 2, 3:                                 # whole screen
    for r in 0 ..< t.rows: t.grid[r] = t.blankRow()
  else: discard

proc insertLines(t: VTerm; n: int) =
  if t.cy < t.top or t.cy > t.bot: return
  for _ in 0 ..< n:
    for r in countdown(t.bot, t.cy + 1): t.grid[r] = t.grid[r - 1]
    t.grid[t.cy] = t.blankRow()

proc deleteLines(t: VTerm; n: int) =
  if t.cy < t.top or t.cy > t.bot: return
  for _ in 0 ..< n:
    for r in t.cy ..< t.bot: t.grid[r] = t.grid[r + 1]
    t.grid[t.bot] = t.blankRow()

proc insertChars(t: VTerm; n: int) =
  let x = t.cursorCol
  for _ in 0 ..< n:
    for c in countdown(t.cols - 1, x + 1): t.grid[t.cy][c] = t.grid[t.cy][c - 1]
    t.grid[t.cy][x] = Cell(ch: "", fg: t.defFg, bg: t.defBg)

proc deleteChars(t: VTerm; n: int) =
  for _ in 0 ..< n:
    for c in t.cx ..< t.cols - 1: t.grid[t.cy][c] = t.grid[t.cy][c + 1]
    t.grid[t.cy][t.cols - 1] = Cell(ch: "", fg: t.defFg, bg: t.defBg)

# --- SGR colors -------------------------------------------------------------

proc xterm256(n: int; defFg, defBg: Color): Color =
  if n < 16:
    # On a light theme the stock 16-colour palette (black/white/…) clashes with
    # the pale background -- e.g. white text on off-white is unreadable. Swap in
    # a light-theme palette: the "dark" half stays dark enough, the "bright"
    # half is darkened so it reads on the light background.
    let light = defBg.r.int + defBg.g.int + defBg.b.int > 3 * 128
    const base = [0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080,
                  0x008080, 0xc0c0c0, 0x808080, 0xff0000, 0x00ff00, 0xffff00,
                  0x0000ff, 0xff00ff, 0x00ffff, 0xffffff]
    const lightBase = [0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080,
                       0x008080, 0x404040, 0x606060, 0xb00000, 0x006000, 0xb0a000,
                       0x0000b0, 0xb000b0, 0x00a0a0, 0x808080]
    let h = (if light: lightBase[n] else: base[n])
    color(uint8(h shr 16 and 0xFF), uint8(h shr 8 and 0xFF), uint8(h and 0xFF))
  elif n < 232:
    let i = n - 16
    let r = i div 36
    let g = (i div 6) mod 6
    let b = i mod 6
    proc c(v: int): uint8 = uint8(if v == 0: 0 else: 55 + v * 40)
    color(c(r), c(g), c(b))
  else:
    let v = uint8(8 + (n - 232) * 10)
    color(v, v, v)

proc applySgr(t: VTerm; params: seq[int]) =
  var i = 0
  if params.len == 0:
    t.curFg = t.defFg; t.curBg = t.defBg; t.inv = false; t.bold = false; return
  while i < params.len:
    let p = params[i]
    case p
    of 0: t.curFg = t.defFg; t.curBg = t.defBg; t.inv = false; t.bold = false
    of 1: t.bold = true
    of 7: t.inv = true
    of 22: t.bold = false
    of 27: t.inv = false
    of 39: t.curFg = t.defFg
    of 49: t.curBg = t.defBg
    of 30..37: t.curFg = xterm256(p - 30, t.defFg, t.defBg)
    of 90..97: t.curFg = xterm256(p - 90 + 8, t.defFg, t.defBg)
    of 40..47: t.curBg = xterm256(p - 40, t.defFg, t.defBg)
    of 100..107: t.curBg = xterm256(p - 100 + 8, t.defFg, t.defBg)
    of 38, 48:
      # extended color: 5;n (256) or 2;r;g;b (truecolor)
      if i + 1 < params.len and params[i+1] == 5 and i + 2 < params.len:
        let col = xterm256(params[i+2], t.defFg, t.defBg)
        if p == 38: t.curFg = col else: t.curBg = col
        i += 2
      elif i + 1 < params.len and params[i+1] == 2 and i + 4 < params.len:
        let col = color(uint8(params[i+2] and 0xFF), uint8(params[i+3] and 0xFF),
                        uint8(params[i+4] and 0xFF))
        if p == 38: t.curFg = col else: t.curBg = col
        i += 4
    else: discard
    inc i

# --- CSI dispatch -----------------------------------------------------------

proc csiParams(par: string): seq[int] =
  for p in par.split(';'):
    result.add (if p.len == 0: 0 else: (try: parseInt(p) except: 0))

proc handleCsi(t: VTerm; final: char) =
  let ps = csiParams(t.par)
  proc arg(i, def: int): int = (if i < ps.len and ps[i] != 0: ps[i] else: def)
  case final
  of 'A': t.cy = max(t.top, t.cy - arg(0, 1))
  of 'B': t.cy = min(t.bot, t.cy + arg(0, 1))
  of 'C': t.cx = min(t.cols - 1, t.cx + arg(0, 1))
  of 'D': t.cx = max(0, t.cx - arg(0, 1))
  of 'E': t.cx = 0; t.cy = min(t.bot, t.cy + arg(0, 1))
  of 'F': t.cx = 0; t.cy = max(t.top, t.cy - arg(0, 1))
  of 'G', '`': t.cx = max(0, min(t.cols - 1, arg(0, 1) - 1))
  of 'd': t.cy = max(0, min(t.rows - 1, arg(0, 1) - 1))
  of 'H', 'f':
    t.cy = max(0, min(t.rows - 1, arg(0, 1) - 1))
    t.cx = max(0, min(t.cols - 1, arg(1, 1) - 1))
  of 'J': t.eraseInDisplay(arg(0, 0))
  of 'K': t.eraseInLine(arg(0, 0))
  of 'L': t.insertLines(arg(0, 1))
  of 'M': t.deleteLines(arg(0, 1))
  of '@': t.insertChars(arg(0, 1))
  of 'P': t.deleteChars(arg(0, 1))
  of 'S': t.scrollUp(arg(0, 1))
  of 'T': t.scrollDown(arg(0, 1))
  of 'm': t.applySgr(ps)
  of 'r':
    t.top = max(0, arg(0, 1) - 1)
    t.bot = min(t.rows - 1, arg(1, t.rows) - 1)
    if t.top >= t.bot: (t.top = 0; t.bot = t.rows - 1)
    t.cx = 0; t.cy = t.top
  of 's': t.scx = t.cx; t.scy = t.cy
  of 'u': t.cx = t.scx; t.cy = t.scy
  of 'h', 'l':
    if t.priv:
      let on = final == 'h'
      for p in ps:
        case p
        of 1049, 1047, 47:               # alternate screen
          if on and not t.inAlt:
            t.saved = t.grid
            t.grid = newSeq[seq[Cell]](t.rows)
            for r in 0 ..< t.rows: t.grid[r] = t.blankRow()
            t.inAlt = true
            t.viewOffset = 0             # alt screen has no scrollback to view
            if p == 1049: (t.scx = t.cx; t.scy = t.cy)
          elif not on and t.inAlt:
            t.grid = t.saved
            t.saved = @[]
            t.inAlt = false
            if p == 1049: (t.cx = t.scx; t.cy = t.scy)
        of 1000, 1002, 1003: t.mouseRep = on   # mouse click/drag/any reporting
        of 1006: t.mouseSgr = on               # SGR mouse encoding
        of 2004: t.bracketedPaste = on         # bracketed paste mode
        else: discard                    # ?25 (cursor): ignored
  else: discard
  t.clampCursor()

# --- byte-stream driver -----------------------------------------------------

proc feedByte(t: VTerm; b: char) =
  case t.st
  of vsGround:
    case b
    of '\e': t.st = vsEsc
    of '\r': t.cx = 0
    of '\n', '\x0b', '\x0c': t.lineFeed()
    of '\b': t.cx = max(0, t.cx - 1)
    of '\t': t.cx = min(t.cols - 1, (t.cx div 8 + 1) * 8)
    of '\a': discard                       # bell
    else:
      if b >= ' ' or b.uint8 >= 0x80:       # printable / UTF-8 lead or cont
        t.putChar($b)
  of vsEsc:
    case b
    of '[': t.st = vsCsi; t.par = ""; t.priv = false
    of ']': t.st = vsOsc; t.osc = ""
    of '7': t.scx = t.cx; t.scy = t.cy; t.st = vsGround
    of '8': t.cx = t.scx; t.cy = t.scy; t.st = vsGround
    of 'M':                                # reverse index
      if t.cy == t.top: t.scrollDown() else: t.cy = max(0, t.cy - 1)
      t.st = vsGround
    of 'c': t.eraseInDisplay(2); t.cx = 0; t.cy = 0; t.st = vsGround   # RIS
    of '(', ')', '*', '+': discard         # charset select: consume next byte
    else: t.st = vsGround
  of vsCsi:
    case b
    of '?', '<', '=', '>': t.priv = true
    of '0'..'9', ';', ':': t.par.add b
    of ' '..'/': discard                   # intermediate bytes
    of '@'..'~': t.handleCsi(b); t.st = vsGround
    else: t.st = vsGround
  of vsOsc:
    # OSC ... terminated by BEL or ST (ESC \)
    if b == '\a': t.st = vsGround
    elif b == '\e': t.st = vsEsc           # ST: next char is '\'; ESC handler resets
    else: t.osc.add b

proc putCharRun(t: VTerm; s: string; a, b: int) =
  ## Write the plain-ASCII run `s[a ..< b]` to the grid in bulk, handling wrap
  ## and line-feed. Avoids the per-char string allocation of `putChar`.
  var i = a
  while i < b:
    if t.cx >= t.cols:            # wrap
      t.cx = 0
      t.lineFeed()
    t.clampCursor()
    while i < b and t.cx < t.cols:
      t.grid[t.cy][t.cx] = Cell(ch: $s[i], fg: t.curFg, bg: t.curBg, inv: t.inv)
      inc t.cx
      inc i

proc write*(t: VTerm; s: string) =
  ## Feed raw PTY bytes. UTF-8 multibyte sequences are reassembled into one
  ## cell with the correct display width. A sequence truncated at the end of
  ## this chunk (pty reads land wherever the kernel split them, not on
  ## character boundaries) is buffered in `t.pending` and completed by the
  ## start of the next call, instead of printing its lead byte(s) as one
  ## grapheme and the orphaned continuation byte(s) as more, garbage, ones.
  var s = s
  if t.pending.len > 0:
    s = t.pending & s
    t.pending = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if t.st == vsGround and c.uint8 >= 0x80:     # UTF-8 lead byte -> one grapheme
      var nbytes = 1
      if (c.uint8 and 0xE0) == 0xC0: nbytes = 2
      elif (c.uint8 and 0xF0) == 0xE0: nbytes = 3
      elif (c.uint8 and 0xF8) == 0xF0: nbytes = 4
      if i + nbytes > s.len:          # sequence crosses the chunk boundary
        t.pending = s[i ..< s.len]
        return
      let grapheme = s[i ..< i + nbytes]
      t.putChar(grapheme, runeWidth(decodeRune(grapheme)))
      i += nbytes
    elif t.st == vsGround and c >= ' ' and c < '\x7f':
      # Fast path: a run of plain printable ASCII (no escape/control bytes).
      var j = i + 1
      while j < s.len and s[j] >= ' ' and s[j] < '\x7f': inc j
      t.putCharRun(s, i, j)
      i = j
    else:
      t.feedByte(c)
      inc i

proc lineText*(t: VTerm; row: int): string =
  ## The row's text with trailing blanks trimmed (for selection / copy).
  if row < 0 or row >= t.rows: return ""
  for c in t.grid[row]:
    result.add (if c.ch.len == 0: " " else: c.ch)
  result = result.strip(leading = false, trailing = true)

# --- hot-reload snapshot: preserve the visible screen across a re-exec so a TUI
#     looks identical afterwards without waiting for it to repaint (tmux-style).

proc serialize*(t: VTerm): string =
  ## Compact binary snapshot of the visible screen (dims, alt flag, cursor, cells).
  proc u16(s: var string; v: int) = s.add chr((v shr 8) and 0xFF); s.add chr(v and 0xFF)
  result = newStringOfCap(t.rows * t.cols * 8 + 16)
  result.u16(t.rows); result.u16(t.cols)
  result.add chr(if t.inAlt: 1 else: 0)
  result.u16(t.cx); result.u16(t.cy)
  for row in t.grid:
    for c in row:
      let n = min(c.ch.len, 255)
      result.add chr(n)
      if n > 0: result.add c.ch[0 ..< n]
      result.add chr(c.fg.r.int); result.add chr(c.fg.g.int); result.add chr(c.fg.b.int)
      result.add chr(c.bg.r.int); result.add chr(c.bg.g.int); result.add chr(c.bg.b.int)
      result.add chr((if c.inv: 1 else: 0) or (if c.wide: 2 else: 0) or (if c.cont: 4 else: 0))

proc restore*(t: VTerm; blob: string) =
  ## Rebuild the screen from a `serialize` snapshot.
  if blob.len < 9: return
  var i = 0
  proc rd(): int =
    if i >= blob.len: return 0
    result = blob[i].int and 0xFF; inc i
  proc rd16(): int = (let hi = rd(); let lo = rd(); (hi shl 8) or lo)
  let rows = rd16(); let cols = rd16()
  if rows <= 0 or cols <= 0: return
  t.resize(rows, cols)
  t.inAlt = rd() == 1
  t.cx = rd16(); t.cy = rd16()
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let n = rd()
      var ch = ""
      for _ in 0 ..< n:
        if i < blob.len: (ch.add blob[i]; inc i)
      let fr = rd(); let fgc = rd(); let fb = rd()
      let br = rd(); let bgc = rd(); let bb = rd()
      let flags = rd()
      if r < t.grid.len and c < t.grid[r].len:
        t.grid[r][c] = Cell(ch: ch, fg: color(fr.uint8, fgc.uint8, fb.uint8),
                            bg: color(br.uint8, bgc.uint8, bb.uint8),
                            inv: (flags and 1) != 0, wide: (flags and 2) != 0,
                            cont: (flags and 4) != 0)
  t.clampCursor()
