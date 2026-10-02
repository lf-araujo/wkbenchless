## Beamer PDF export -- org-beamer slides straight to PDF, without Emacs.
##
##   M-x beamer-pdf-export   (or Export -> "beamer")   writes <file>.tex + <file>.pdf
##
## Pipeline: the buffer is pre-processed here, pandoc (org -> beamer) writes
## <file>.tex, and the #+LATEX_COMPILER (default lualatex; xelatex, pdflatex)
## runs on it directly, twice, in batchmode -- so a recoverable LaTeX error
## (a missing image) still yields a PDF, reported in the status line.
##
## pandoc already reads #+LATEX_HEADER, #+LaTeX_CLASS_OPTIONS, #+beamer: /
## #+latex: lines, :noexport: and title/subtitle/author/date. What it doesn't,
## the org-beamer way, is translated:
##   :BEAMER_col: 0.4             -> a pandoc column (width 40%) in a columns frame
##   :BEAMER_opt: standout        -> frame options (standout, fragile, plain, ...)
##   :BEAMER_env: alertblock      -> .alert / .example blocks
##   #+ATTR_LATEX: :width/:height -> image size
##   #+BEAMER_THEME / _FONT_THEME / _COLOR_THEME / _INNER_THEME / _OUTER_THEME
##   #+OPTIONS: H:n toc:...       -> --slide-level (org-beamer default 1) / --toc
##   #+CITE_EXPORT: csl <file>, #+BIBLIOGRAPHY -> --citeproc
## and #+PANDOC_OPTIONS / #+PANDOC_VARIABLES pass through. Nothing is evaluated:
## the stored #+RESULTS are exported, with each block's :exports applied (the
## html export's rules). Code goes to listings (so a \lstset in the header styles
## it) unless the file's `org-latex-src-block-backend` local variable, or
## gBeamerSrcBackend, names another backend -- then pandoc highlights it.

import std/[os, osproc, strutils, streams, times, re, math]
import wkbcore
import ./notebook_html   # applyExports / keywordValue / optionValue

var
  gBeamerSrcBackend* = "listings"  ## code: "listings", or anything else for pandoc's
                                   ## own highlighting (a file-local variable wins)
  gBeamerLatexRuns* = 2            ## LaTeX passes (2 = TOC / nav resolved)
  gBeamerKeepAux* = false          ## keep .aux/.log/.nav/... after a clean build
  gBeamerLatexTimeout* = 300       ## seconds per LaTeX pass before it is killed
  gBeamerBabel* = false            ## load babel for #+LANGUAGE (org-beamer doesn't;
                                   ## needs the language's babel package installed)

const frameOpts = ["standout", "fragile", "plain", "allowframebreaks", "shrink",
                   "squeeze", "noframenumbering", "t", "c", "b"]

proc run(exe: string; args: seq[string]; dir: string): tuple[code: int; outp: string] =
  let p = startProcess(exe, workingDir = dir, args = args,
                       options = {poStdErrToStdOut, poUsePath})
  let outp = p.outputStream.readAll()
  result = (p.waitForExit(), outp)
  p.close()

proc runLatex(engine, tex, dir: string): bool =
  ## One LaTeX pass in batchmode (no terminal output, so nothing to drain);
  ## false if it ran past gBeamerLatexTimeout and was killed (a runaway page loop).
  let p = startProcess(engine, workingDir = dir, options = {poUsePath},
                       args = @["-shell-escape", "-interaction=batchmode", tex])
  let t0 = epochTime()
  result = true
  while p.peekExitCode() == -1:
    if epochTime() - t0 > gBeamerLatexTimeout.float:
      p.kill(); discard p.waitForExit(); result = false; break
    os.sleep(100)
  p.close()

proc firstLatexErrors(log: string; n = 3): string =
  ## The first `! ...` error lines of a LaTeX log, joined for the status line.
  var errs: seq[string]
  for ln in log.splitLines:
    if ln.startsWith("! "):
      errs.add ln[2 .. ^1].strip
      if errs.len >= n: break
  errs.join(" | ")

proc headingLevel(line: string): int =
  var n = 0
  while n < line.len and line[n] == '*': inc n
  if n > 0 and n < line.len and line[n] == ' ': n else: 0

proc percent(f: float): string = $int(round(f * 100)) & "%"

proc latexSize(v: string): string =
  ## An ATTR_LATEX length as pandoc reads it: 2.6in / 5cm / 300px stay,
  ## 0.5\linewidth / .8\textwidth become 50% / 80%; anything else is dropped.
  let s = v.strip
  var m: array[1, string]
  if s.match(re"^([0-9]*\.?[0-9]+)\s*\\(?:linewidth|textwidth|columnwidth)$", m):
    return percent(parseFloat(m[0]))
  if s.match(re"^[0-9]*\.?[0-9]+(?:in|cm|mm|px|pt|%)$"): return s
  ""

proc isBlockEdge(low: string; edge: string): bool =
  low.startsWith("#+" & edge & "_src") or low.startsWith("#+" & edge & "_example")

proc toPandocOrg(lines: seq[string]): seq[string] =
  ## Translate org-beamer heading properties and ATTR_LATEX into what pandoc's
  ## org reader understands (see the module doc).
  type Head = object
    line, level: int
    classes: seq[string]
    width: string
    hasDrawer: bool
  var heads: seq[Head]
  var inDrawerOf = newSeq[int](lines.len)   # owning heading of each drawer line, else -1
  var cur = -1
  var inDrawer, inBlock = false
  var m: array[1, string]
  for i, ln in lines:
    inDrawerOf[i] = -1
    let t = ln.strip
    let low = t.toLowerAscii
    if low.isBlockEdge("begin"): inBlock = true
    elif low.isBlockEdge("end"): inBlock = false
    if inBlock: continue
    let lv = headingLevel(ln)
    if lv > 0:
      heads.add Head(line: i, level: lv); cur = heads.high; inDrawer = false
      continue
    if not inDrawer and cur >= 0 and low == ":properties:" and i - heads[cur].line <= 2:
      inDrawer = true                         # right under the heading (or its planning line)
      heads[cur].hasDrawer = true
    if not inDrawer: continue
    inDrawerOf[i] = cur
    if low == ":end:": inDrawer = false
    elif t.match(re"(?i)^:BEAMER_col:\s*(\S+)", m):
      let w = try: parseFloat(m[0]) except ValueError: 0.0
      if w > 0: heads[cur].width = percent(w)
    elif t.match(re"(?i)^:BEAMER_opt:\s*(.*)$", m):
      for o in m[0].split(','):
        if o.strip.toLowerAscii in frameOpts: heads[cur].classes.add o.strip.toLowerAscii
    elif t.match(re"(?i)^:BEAMER_env:\s*(\S+)", m):
      case m[0].toLowerAscii
      of "alertblock": heads[cur].classes.add "alert"
      of "exampleblock": heads[cur].classes.add "example"
      else: discard
    elif t.match(re"(?i)^:class:\s*(.*)$", m):
      heads[cur].classes.add m[0].splitWhitespace
    elif t.match(re"(?i)^:width:\s*(\S+)", m):
      heads[cur].width = m[0]
  # a column's parent heading holds the columns
  for h in 0 .. heads.high:
    if heads[h].width.len == 0: continue
    if "column" notin heads[h].classes: heads[h].classes.add "column"
    for p in countdown(h - 1, 0):
      if heads[p].level < heads[h].level:
        if "columns" notin heads[p].classes: heads[p].classes.add "columns"
        break
  # rebuild: keep other drawer entries, write classes / width pandoc's way
  var headAt = newSeq[int](lines.len)
  for i in 0 ..< lines.len: headAt[i] = -1
  for h, hd in heads: headAt[hd.line] = h
  proc writeDrawer(res: var seq[string]; hd: Head; extra: seq[string]) =
    if hd.classes.len == 0 and hd.width.len == 0 and extra.len == 0: return
    res.add ":PROPERTIES:"
    if hd.classes.len > 0: res.add ":class: " & hd.classes.join(" ")
    if hd.width.len > 0: res.add ":width: " & hd.width
    res.add extra
    res.add ":END:"
  var extra: seq[string]
  inBlock = false
  for i, ln in lines:
    let low = ln.strip.toLowerAscii
    if inDrawerOf[i] >= 0:
      if low == ":end:":
        writeDrawer(result, heads[inDrawerOf[i]], extra); extra = @[]
      elif low != ":properties:" and
           not ln.strip.match(re"(?i)^:(BEAMER_\w+|class|width):"):
        extra.add ln
      continue
    if low.isBlockEdge("begin"): inBlock = true
    elif low.isBlockEdge("end"): inBlock = false
    if not inBlock and low.startsWith("#+attr_latex:"):
      var attrs: seq[string]
      for kv in ln.findAll(re"(?i):(?:width|height)\s+\S+"):
        let parts = kv.splitWhitespace
        let v = latexSize(parts[1])
        if v.len > 0: attrs.add parts[0].toLowerAscii & " " & v
      if attrs.len > 0: result.add "#+ATTR_HTML: " & attrs.join(" ")
      continue
    if not inBlock and low.startsWith("#+options:"):
      # H: is the frame level here (--slide-level); to pandoc it would turn
      # deeper headings (columns, blocks) into list items
      var toks: seq[string]
      for o in keywordValue(ln, "#+options:").splitWhitespace:
        if not o.startsWith("H:"): toks.add o
      if toks.len > 0: result.add "#+OPTIONS: " & toks.join(" ")
      continue
    result.add ln
    if not inBlock and headAt[i] >= 0 and not heads[headAt[i]].hasDrawer:
      writeDrawer(result, heads[headAt[i]], @[])   # e.g. a columns frame: right under it

proc beamerPdfExport*(app: var App) =
  if app.filePath.len == 0 or not app.filePath.toLowerAscii.endsWith(".org"):
    app.msg = "beamer: save the buffer as an .org file first"; return
  if findExe("pandoc").len == 0:
    app.msg = "beamer: pandoc not on PATH"; return
  var lines: seq[string]
  for i in 0 ..< app.ed.getLineCount(): lines.add app.ed.getLineText(i)
  # -- document settings ---------------------------------------------------------
  var options, popts, pvars, bibs: seq[string]
  var engine, csl, backend = ""
  var themes: seq[(string, string)]
  var m: array[1, string]
  for ln in lines:
    let t = ln.strip
    let low = t.toLowerAscii
    if low.startsWith("#+options:"): options.add keywordValue(ln, "#+options:").splitWhitespace
    elif low.startsWith("#+latex_compiler:"): engine = keywordValue(ln, "#+latex_compiler:")
    elif low.startsWith("#+bibliography:"): bibs.add keywordValue(ln, "#+bibliography:")
    elif low.startsWith("#+cite_export:"):
      let v = keywordValue(ln, "#+cite_export:").splitWhitespace
      if v.len > 1 and v[0].toLowerAscii == "csl": csl = v[1]
    elif low.startsWith("#+pandoc_options:"):
      popts.add keywordValue(ln, "#+pandoc_options:").splitWhitespace
    elif low.startsWith("#+pandoc_variables:"):
      pvars.add keywordValue(ln, "#+pandoc_variables:")
    elif low.match(re"^#\+beamer_(font_|color_|inner_|outer_)?theme:", m):
      themes.add ((if m[0].len > 0: m[0][0 .. ^2] else: ""), t[t.find(':') + 1 .. ^1].strip)
    elif low.match(re"^#\s+org-latex-src-block-backend:\s*(\S+)", m): backend = m[0]
  for o in popts:                                   # ox-pandoc style pdf-engine:lualatex
    if o.toLowerAscii.startsWith("pdf-engine:") and engine.len == 0: engine = o[11 .. ^1]
  if engine.len == 0: engine = "lualatex"
  if findExe(engine).len == 0: (app.msg = "beamer: " & engine & " not on PATH"; return)
  if backend.len == 0: backend = gBeamerSrcBackend
  let src = absolutePath(app.filePath)
  let dir = src.parentDir
  proc resolve(p: string): string =
    let p = p.strip(chars = {'"', ' '})
    if p.isAbsolute: p else: dir / p
  # -- pandoc args -----------------------------------------------------------------
  let h = optionValue(options, "H")
  var args = @["-f", "org", "-t", "beamer", "--standalone",
               "--slide-level=" & (if h.len > 0: h else: "1")]
  let toc = optionValue(options, "toc")
  if toc != "nil":
    args.add "--toc"
    if toc.len > 0 and toc[0] in Digits: args.add "--toc-depth=" & toc
  for (kind, v) in themes:                          # "[opts]name" -> theme + options
    var name = v
    var opts = ""
    if v.startsWith("[") and v.find(']') > 0:
      opts = v[1 ..< v.find(']')]; name = v[v.find(']') + 1 .. ^1].strip
    if name.len > 0: args.add @["-V", kind & "theme=" & name]
    if opts.len > 0: args.add @["-V", kind & "themeoptions=" & opts]
  if backend == "listings": args.add "--syntax-highlighting=idiomatic"
  if not gBeamerBabel: args.add @["-M", "lang="]   # like ox-beamer: no babel by default
  var haveBib = false
  for b in bibs:
    if fileExists(resolve(b)): (args.add "--bibliography=" & resolve(b); haveBib = true)
  if haveBib:
    args.add "--citeproc"
    if csl.len > 0: args.add "--csl=" & resolve(csl)
    # Like ox-beamer, only print a reference list where #+print_bibliography:
    # asks for one; otherwise pandoc appends it to the last frame (a single
    # frame cannot hold it, and LaTeX may run away).
    var printBib = false
    for ln in lines:
      if ln.strip.toLowerAscii.startsWith("#+print_bibliography:"): printBib = true
    if not printBib: args.add @["-M", "suppress-bibliography=true"]
  for o in popts:                                   # #+PANDOC_OPTIONS key:value
    let c = o.find(':')
    let (k, v) = if c < 0: (o, "t") else: (o[0 ..< c], o[c + 1 .. ^1].strip(chars = {'"'}))
    if k in ["pdf-engine", "standalone", "to", "from", "output"] or v == "nil": continue
    args.add (if v == "t": "--" & k else: "--" & k & "=" & v)
  for v in pvars:                                   # #+PANDOC_VARIABLES key:value
    let c = v.find(':')
    if c > 0: args.add @["-V", v[0 ..< c].strip & "=" & v[c + 1 .. ^1].strip.strip(chars = {'"'})]
  # -- buffer -> pandoc org -> .tex ------------------------------------------------
  var running = 0
  let body = toPandocOrg(applyExports(app, lines, running))
  let orgTmp = dir / (".wkb-export-" & src.splitFile.name & ".org")   # same dir: relative paths hold
  writeFile(orgTmp, body.join("\n") & "\n")
  defer: removeFile(orgTmp)
  let tex = src.changeFileExt("tex")
  args.add @[orgTmp, "-o", tex]
  let (pcode, pout) = run("pandoc", args, dir)
  if pcode != 0:
    let ls = pout.strip.splitLines
    app.msg = "beamer: pandoc failed: " & ls[0 .. min(2, ls.high)].join(" | ")
    return
  # pandoc hands a block's header args to lstlisting as options (org-language=R,
  # eval=no, session=...), which listings rejects: keep only language=
  let texIn = readFile(tex)
  var texOut = newStringOfCap(texIn.len)
  var pos = 0
  while true:
    let (a, b) = texIn.findBounds(re"\\begin\{lstlisting\}\[[^\]\n]*\]", pos)
    if a < 0: break
    let lang = texIn[a .. b].findAll(re"\blanguage=[^,\]]*")
    texOut.add texIn[pos ..< a]
    texOut.add "\\begin{lstlisting}" & (if lang.len > 0: "[" & lang[0] & "]" else: "")
    pos = b + 1
  texOut.add texIn[pos .. ^1]
  # pandoc 3.10's beamer template follows the --toc frame with a stray, unbalanced
  # `\setcounter{tocdepth}{N} \tableofcontents }` outside any frame
  texOut = texOut.replacef(re"(\\end\{frame\}\n)\\setcounter\{tocdepth\}\{\d+\}\n\\tableofcontents\n\}\n", "$1")
  # an empty frame (e.g. from an :exports none setup block above the first heading)
  texOut = texOut.replace(re"\n\\begin\{frame\}\n\\end\{frame\}\n", "\n")
  # absolute image paths come out as file:// URIs, which LaTeX can't open
  texOut = texOut.replacef(re"(\\includegraphics(?:\[[^\]]*\])?\{)file://", "$1")
  writeFile(tex, texOut)
  # -- .tex -> .pdf ----------------------------------------------------------------
  let job = tex.splitFile.name
  for i in 1 .. max(1, gBeamerLatexRuns):
    if not runLatex(engine, tex.extractFilename, dir):
      app.msg = "beamer: " & engine & " killed after " & $gBeamerLatexTimeout &
                " s (runaway?) -- see " & job & ".log"
      return
  let pdf = tex.changeFileExt("pdf")
  let log = tex.changeFileExt("log")
  let errs = firstLatexErrors(if fileExists(log): readFile(log) else: "")
  let stale = if running > 0: "; WARNING: " & $running & " block(s) still running" else: ""
  if not fileExists(pdf) or getLastModificationTime(pdf) < getLastModificationTime(tex):
    app.msg = "beamer: " & engine & " failed" & (if errs.len > 0: ": " & errs else: "") &
              " (see " & log.extractFilename & ")"
    return
  if errs.len > 0:   # nonstopmode still wrote a PDF (e.g. a missing image): keep the log
    app.msg = "beamer: wrote " & pdf.extractFilename & " WITH LaTeX errors: " & errs &
              " (see " & log.extractFilename & ")" & stale
    return
  if not gBeamerKeepAux:
    for kind, f in walkDir(dir):   # .aux .log .nav .out .snm .toc and per-frame .vrb
      let n = f.extractFilename
      if kind == pcFile and n.startsWith(job & ".") and
         n.splitFile.ext in [".aux", ".log", ".nav", ".out", ".snm", ".toc", ".vrb"]:
        removeFile(f)
  app.msg = "beamer: wrote " & pdf.extractFilename & " (pandoc + " & engine & ", " &
            $(getFileSize(pdf) div 1024) & " KB)" & stale

proc extend*(app: var App) =
  defcommand("beamer-pdf-export", "Export: Beamer slides -> PDF (pandoc + lualatex/xelatex)",
             beamerPdfExport)
  registerExport("beamer", "Beamer slides (PDF, pandoc + lualatex/xelatex)", "beamer-pdf-export")
