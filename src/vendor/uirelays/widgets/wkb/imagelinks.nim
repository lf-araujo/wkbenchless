## Included by synedit.nim: image links and LaTeX display math. wkbenchless only; kept out of
## that file so a sync with focim stays small.

proc isImagePath(path: string): bool =
  ## Path with a recognised raster/vector image extension. BMP loads directly;
  ## other formats are converted on load (see toLoadableBmp). If conversion is
  ## unavailable the line still reserves space and shows a labelled placeholder.
  const exts = [".bmp", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg",
                ".tif", ".tiff", ".ppm"]
  let low = path.toLowerAscii
  for e in exts:
    if low.endsWith(e): return true

proc parseImageLinkPath(line: string; path: var string): bool =
  ## A whole line that is just an image link, in either syntax:
  ##   Markdown  ![alt](path)
  ##   Org       [[path]]  /  [[file:path]]  /  [[file:path][desc]]
  ## Returns the (extension-checked) path with any `file:` prefix stripped.
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i

  if i < line.len and line[i] == '!':                 # ---- Markdown ![alt](p)
    if i + 1 >= line.len or line[i + 1] != '[': return
    var closeBracket = -1
    var k = i + 2
    while k < line.len:
      if line[k] == ']': closeBracket = k; break
      inc k
    if closeBracket < 0 or closeBracket + 1 >= line.len or
       line[closeBracket + 1] != '(': return
    var closeParen = -1
    k = closeBracket + 2
    while k < line.len:
      if line[k] == ')': closeParen = k; break
      inc k
    if closeParen < 0: return
    var tail = closeParen + 1
    while tail < line.len and line[tail] in {' ', '\t'}: inc tail
    if tail != line.len: return
    path = line[(closeBracket + 2) ..< closeParen]
    return path.len > 0

  if i + 1 < line.len and line[i] == '[' and line[i + 1] == '[':  # ---- Org [[..]]
    let close = line.find("]]", i + 2)
    if close < 0: return
    var tail = close + 2
    while tail < line.len and line[tail] in {' ', '\t'}: inc tail
    if tail != line.len: return                       # must be the whole line
    var inner = line[(i + 2) ..< close]
    let desc = inner.find("][")                       # [[PATH][DESC]] -> PATH
    if desc >= 0: inner = inner[0 ..< desc]
    if inner.startsWith("file:"): inner = inner[5 .. ^1]
    path = inner
    return path.len > 0 and isImagePath(path)

proc isImageLine(s: SynEdit; i: int): bool =
  ## True if the line at byte offset `i` is a figure link (![](p) / [[file:p]]),
  ## so figures render full-width rather than inside the reading margin.
  var line = ""
  var j = i
  while j < s.len and s[j] != '\L':
    line.add s[j]; inc j
  var p = ""
  parseImageLinkPath(line, p)

proc latexDisplayMathAt*(s: SynEdit; lineStart: int; body: var string;
                         blockEnd: var int): bool =
  ## If the line beginning at buffer offset `lineStart` is a display-math
  ## fragment, set `body` to the clean math (delimiters and any trailing
  ## `{#label}` stripped) and `blockEnd` to the buffer offset just past the
  ## closing line, returning true.
  ##
  ## Handles single-line `$$..$$` / `\[..\]` and multi-line blocks opened by a
  ## bare `$$` / `\[` line and closed by a matching `$$` / `\]` line (the
  ## close may carry an org label, e.g. `\]#{eq:req}` or `$${#eq:org}`).
  var j = lineStart
  while j < s.len and s[j] != '\L': inc j
  var t = newStringOfCap(max(0, j - lineStart))
  for p in lineStart ..< j:
    t.add s[p]
  let ts = t.strip
  if ts.len < 2: return

  proc peelLabel(x: string): string =
    ## Drop a trailing `{#label}` suffix so a labelled close still matches.
    if x.len > 0 and x[^1] == '}':
      let k = x.rfind("{#")
      if k >= 0 and k + 1 < x.len and
         (k == 0 or x[k - 1] in {' ', '\t', ']'}):
        return x[0 ..< (if k > 0 and x[k - 1] in {' ', '\t'}: k - 1 else: k)]
    x

  template single(a, b: string): string =
    (if ts.startsWith(a) and ts.endsWith(b) and ts.len >= a.len + b.len:
       ts[a.len ..< ts.len - b.len].strip else: "")
  var m = single("$$", "$$")
  var openerDollar = false
  var openerBracket = false
  if m.len == 0:
    let tlb = peelLabel(ts)
    if tlb.startsWith("\\[") and tlb.endsWith("\\]"):
      m = tlb[2 ..< tlb.len - 2].strip
  if m.len == 0 and ts == "$$": openerDollar = true
  if m.len == 0 and ts == "\\[": openerBracket = true
  if m.len > 0:
    body = m
    blockEnd = j
    return true                       # self-contained single-line fragment
  if not openerDollar and not openerBracket: return

  # multi-line block: accumulate lines until the closing delimiter
  var outBuf = newStringOfCap(256)
  var start = j + 1                   # first byte of the line after the opener
  var closed = false
  var e = start
  while start <= s.len:
    e = start
    while e < s.len and s[e] != '\L': inc e
    var ltxt = newStringOfCap(max(0, e - start))
    for p in start ..< e:
      ltxt.add s[p]
    let ls = peelLabel(ltxt.strip)
    let closeTok = if openerDollar: "$$" else: "\\]"
    if ls.len >= closeTok.len and ls.startsWith(closeTok):
      closed = true
      break
    if outBuf.len > 0: outBuf.add "\n"
    outBuf.add ltxt
    start = e + 1
  if not closed: return
  blockEnd = e + (if e < s.len: 1 else: 0)   # just past the closing line
  body = outBuf
  result = true

proc ltxCachePath*(body: string): string =
  ## Deterministic PNG cache path for a math fragment's rendered image -- the
  ## body hash is the render loop's lookup key, so generation (in `M-x
  ## latex-preview`) and lookup stay in sync without shared state.
  getCacheDir() / "wkbenchless" / "ltximg" /
    (toHex(hash(body).uint64) & ".png")

proc attrDim(line, key: string): int =
  ## Leading integer after `:key` in an org attribute line (units ignored), or 0.
  ## e.g. `:width 300` -> 300, `:width 0.8\textwidth` -> 0 (no leading int px).
  let k = line.find(key)
  if k < 0: return
  var p = k + key.len
  while p < line.len and line[p] in {' ', '\t'}: inc p
  var n = 0
  var any = false
  while p < line.len and line[p] in {'0'..'9'}:
    n = n * 10 + (ord(line[p]) - ord('0')); inc p; any = true
  if any: n else: 0

proc scanImageAttrs(s: SynEdit; lineStart: int; w, h: var int) =
  ## Walk the affiliated-keyword lines directly above the image link, reading
  ## the nearest `#+ATTR_ORG:` / `#+ATTR_HTML:` / `#+ATTR_LATEX:` `:width` /
  ## `:height` (Emacs org-mode style). Nearest line wins; stops at a blank or
  ## non-`#+` line. ATTR_ORG is preferred over the others when both are present.
  if lineStart <= 0: return
  var lineEnd = lineStart - 1            # the '\L' ending the previous line
  var orgW, orgH = 0
  while lineEnd > 0:
    var ls = lineEnd - 1
    while ls >= 0 and s[ls] != '\L': dec ls
    let prevStart = ls + 1
    var t = ""
    for p in prevStart ..< lineEnd: t.add s[p]
    let ts = t.strip
    if not ts.startsWith("#+"): break
    let low = ts.toLowerAscii
    if low.startsWith("#+attr_"):
      let isOrg = low.startsWith("#+attr_org")
      let aw = attrDim(low, ":width")
      let ah = attrDim(low, ":height")
      if isOrg:
        if orgW == 0 and aw > 0: orgW = aw
        if orgH == 0 and ah > 0: orgH = ah
      else:
        if w == 0 and aw > 0: w = aw
        if h == 0 and ah > 0: h = ah
    if prevStart == 0: break
    lineEnd = prevStart - 1
  if orgW > 0: w = orgW                  # ATTR_ORG overrides other backends
  if orgH > 0: h = orgH
