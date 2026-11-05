## Included by synedit.nim: big Org headings and captions. wkbenchless only; kept out of
## that file so a sync with focim stays small.

proc isBigOrgLine(s: SynEdit; i: int): bool =
  ## org #+title / #+author / top-level headings, and Markdown/Rmd # headings,
  ## render in bigFont.
  if s.lang notin {langOrg, langMarkdown}: return false
  var t = ""
  var j = i
  while j < s.len and s[j] != '\L' and t.len < 12:
    t.add s[j]; inc j
  let ls = t.strip(leading = true, trailing = false).toLowerAscii
  if s.lang == langMarkdown:
    # Markdown/Rmd ATX headings (# / ## / ###). Exclude '#' inside a code chunk
    # (```{r}), where R comments also start with '#'.
    return ls.len > 0 and ls[0] == '#' and not s.inSrcBlock(i)
  result = ls.startsWith("#+title") or ls.startsWith("#+author") or
           isOrgHeadlineText(t)                 # `*+ ` headline, not `*bold*`

proc isCaptionLine(s: SynEdit; i: int): bool =
  ## org #+caption: lines render a touch larger (captionFont).
  if s.lang != langOrg: return false
  var t = ""
  var j = i
  while j < s.len and s[j] != '\L' and t.len < 12:
    t.add s[j]; inc j
  t.strip(leading = true, trailing = false).toLowerAscii.startsWith("#+caption")

proc rowFont(s: SynEdit; i: int): Font =
  if isBigOrgLine(s, i): s.bigFont   # taller row, bigger glyphs
  elif isCaptionLine(s, i) and s.captionFont.int != 0: s.captionFont
  else: s.font

proc applyReadingMargin(s: SynEdit; i: int; dim: var Rect; baseX, fullEndX: int) =
  ## Prose sits in a centered column; code blocks and tables span the full width
  ## (baseX..fullEndX) so wide content isn't cramped.
  let wide = s.readingMargin <= 0 or s.inSrcBlock(i) or
             isTableLine(s, i) or isImageLine(s, i)
  let lm = if wide: 0 else: s.readingMargin
  dim.x = baseX + lm
  dim.w = fullEndX - lm

proc skipFoldedBody(s: SynEdit; fold: Slice[int]; endX, lineY: int; i: var int;
                    renderLine: var Natural) =
  ## Mark the collapsed block and hop the buffer/line cursors past its body.
  discard drawText(s.font, endX - 60, lineY, "\u25b8 \u22ef",
                   s.theme.lineNumColor, s.srcBlockBg)
  var skipped = 0
  var j = i
  while j <= fold.b:
    if s[j] == '\L': inc skipped
    inc j
  i = fold.b + 1
  renderLine = (renderLine.int + skipped).Natural

proc drawGhostText(s: SynEdit; endX: int) =
  ## Copilot inline completion: greyed text after the cursor.
  if s.ghostText.len > 0 and s.cursorDim.h > 0:
    let gx = s.cursorDim.x
    let gy = s.cursorDim.y
    if gx + textWidth(s.font, s.ghostText) <= endX:
      discard drawText(s.font, gx, gy, s.ghostText, s.theme.lineNumColor, s.theme.bg)
