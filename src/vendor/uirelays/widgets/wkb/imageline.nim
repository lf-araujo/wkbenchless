## Included by synedit.nim: inline images and LaTeX previews, sized like Org.
## Replaces focim's Markdown-only version, kept out of that file so a sync with
## focim stays small.

proc renderMarkdownImageLine(
    s: var SynEdit; lineStart: int; dim: var Rect;
    endX, endY, lineH: int; showCursor: bool;
    nextIndex, consumedRows: var int): bool =
  ## Render a whole-line image link inline, sized like Emacs org-mode: the
  ## image's native dimensions by default, overridable per-image with a
  ## preceding `#+ATTR_ORG: :width N [:height M]` (or the editor's
  ## `imageDefaultWidth`); aspect ratio is always preserved.
  var j = lineStart
  while j < s.len and s[j] != '\L': inc j

  var line = newStringOfCap(max(0, j - lineStart))
  for p in lineStart ..< j:
    line.add s[p]

  var imgPath = ""
  var handled = false
  if rfInlineImages in s.flags and parseImageLinkPath(line, imgPath):
    handled = true                                  # image link (relative ok)
  var blockEnd = -1                                 # byte past a multi-line math block
  if not handled and rfLatexPreview in s.flags:     # cached LaTeX math preview
    var inner = ""
    if latexDisplayMathAt(s, lineStart, inner, blockEnd):
      let cp = ltxCachePath(inner)
      if fileExists(cp): imgPath = cp; handled = true   # else: show source
  if not handled:
    return

  # Keep source visible while actively editing this line.
  if showCursor and lineStart <= s.cursor.int and s.cursor.int <= j:
    return

  let maxW = endX - dim.x - 4
  let maxH = endY - dim.y - 2
  if maxW <= 16 or maxH < lineH:
    return

  let img = s.getCachedImage(imgPath)
  let (iw, ih) = imageSize(img)                     # native px, (0,0) if unloaded

  # Requested size: per-image #+ATTR_* :width/:height, else the editor default.
  var wantW, wantH = 0
  scanImageAttrs(s, lineStart, wantW, wantH)
  if wantW == 0 and wantH == 0 and s.imageDefaultWidth > 0:
    wantW = s.imageDefaultWidth

  # For a multi-line block the image replaces all its source lines, so size it
  # to fill the block's vertical space (capped by the pane) rather than the
  # native/tight height, which would leave a gap or overlap the next line.
  var blockRows = 1
  if blockEnd > j:
    blockRows = 0
    var k = lineStart
    while k < blockEnd:
      if s[k] == '\L': inc blockRows
      inc k
    if blockRows < 1: blockRows = 1

  var tw, th: int
  if img != Image(0) and iw > 0 and ih > 0:
    # Derive from the native aspect ratio -- never stretch.
    if wantW > 0 and wantH > 0: (tw, th) = (wantW, wantH)
    elif wantW > 0: tw = wantW; th = max(1, wantW * ih div iw)
    elif wantH > 0: th = wantH; tw = max(1, wantH * iw div ih)
    else: (tw, th) = (iw, ih)                        # default: native size
    if tw > maxW: th = max(1, th * maxW div tw); tw = maxW   # fit width, keep aspect
    if th > maxH: tw = max(1, tw * maxH div th); th = maxH   # fit height, keep aspect
    if blockRows > 1 and th > blockRows * lineH:
      tw = max(1, tw * (blockRows * lineH) div th); th = blockRows * lineH
  else:
    # Placeholder box (backend without image relays, or a format that could not
    # be loaded/converted): no native aspect to honour.
    tw = if wantW > 0: min(wantW, maxW) else: min(maxW, max(240, maxW div 2))
    th = min(maxH, if wantH > 0: wantH else: lineH * 6)

  let dst = rect(dim.x, dim.y + 1, tw, th)
  if img != Image(0):
    # The source rectangle is in the picture's own pixels, so "all of it" is
    # its own size -- not the size of the hole it is going into, which is a
    # different rectangle that happens to also be a rectangle. A driver that
    # cannot say how big a picture is gets asked the old way and answers by
    # cropping, which is at least a picture.
    let srcRect = if iw > 0 and ih > 0: rect(0, 0, iw, ih)
                  else: rect(0, 0, dst.w, dst.h)
    drawImage(img, srcRect, dst)
  else:
    fillRect(dst, color(52, 56, 64))
    drawLine(dst.x, dst.y, dst.x + dst.w - 1, dst.y + dst.h - 1, color(140, 146, 172))
    drawLine(dst.x + dst.w - 1, dst.y, dst.x, dst.y + dst.h - 1, color(140, 146, 172))
    discard drawText(s.font, dst.x + 6, dst.y + 4, imgPath, color(220, 220, 220), color(52, 56, 64))

  dim.y += th + 2
  if blockEnd > j:
    # multi-line block: skip all its source lines and advance the line/span
    # counters by the number of buffer lines it occupies.
    nextIndex = blockEnd
    consumedRows = 0
    var k = lineStart
    while k < blockEnd:
      if s[k] == '\L': inc consumedRows
      inc k
    if consumedRows < 1: consumedRows = 1
    result = true
  else:
    nextIndex = j + 1
    consumedRows = 1
    result = true
