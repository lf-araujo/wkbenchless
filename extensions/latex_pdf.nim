## PDF export -- an org document straight to a LaTeX article PDF, without Emacs.
##
##   M-x latex-pdf-export   (or Export -> "pdf")   writes <file>.tex + <file>.pdf
##
## The article counterpart of beamer_pdf (and it shares that pipeline): the
## buffer is pre-processed here, pandoc (org -> latex) writes <file>.tex, and the
## #+LATEX_COMPILER (default lualatex; xelatex, pdflatex) runs on it twice in
## batchmode, so a recoverable LaTeX error still yields a PDF, reported in the
## status line.
##
## pandoc already reads #+LATEX_CLASS, #+LATEX_CLASS_OPTIONS, #+LATEX_HEADER,
## #+LATEX: lines, #+BEGIN_EXPORT latex, :noexport: and the title keywords.
## What it reads differently from ox-latex is aligned here:
##   #+OPTIONS: title:nil         -> no title block (#+TITLE/#+SUBTITLE dropped)
##   #+OPTIONS: num:nil / toc:nil -> pandoc's --number-sections / --toc follow
##                                   org's defaults (both on unless turned off)
##   \hypersetup{...} in a header -> deferred to \AtBeginDocument (pandoc loads
##                                   hyperref after the header-includes)
##   #+ATTR_LATEX: :width/:height -> image size (beamer_pdf's translation)
##   straight quotes              -> typographic quotes (org+smart), as LaTeX
##                                   renders them under ox-latex
##   #+CITE_EXPORT: csl <file>, #+BIBLIOGRAPHY -> --citeproc; a reference list
##                                   only where #+print_bibliography: asks
## and #+PANDOC_OPTIONS / #+PANDOC_VARIABLES pass through. Nothing is evaluated:
## the stored #+RESULTS are exported, with each block's :exports applied.

import std/[os, strutils, times, re]
import wkbcore
import ./notebook_html   # applyExports / keywordValue / optionValue
import ./beamer_pdf      # run / runLatex / firstLatexErrors / toPandocOrg

var
  gPdfLatexRuns* = 2     ## LaTeX passes (2 = page refs / "x of y" resolved)
  gPdfKeepAux* = false   ## keep .aux/.log/.out/.toc after a clean build

proc latexPdfExport*(app: var App) =
  if app.filePath.len == 0 or not app.filePath.toLowerAscii.endsWith(".org"):
    app.msg = "pdf: save the buffer as an .org file first"; return
  if findExe("pandoc").len == 0:
    app.msg = "pdf: pandoc not on PATH"; return
  var lines: seq[string]
  for i in 0 ..< app.ed.getLineCount(): lines.add app.ed.getLineText(i)
  # -- document settings ---------------------------------------------------------
  var options, popts, pvars, bibs: seq[string]
  var engine, csl = ""
  var printBib = false
  for ln in lines:
    let low = ln.strip.toLowerAscii
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
    elif low.startsWith("#+print_bibliography:"): printBib = true
  for o in popts:                                   # ox-pandoc style pdf-engine:lualatex
    if o.toLowerAscii.startsWith("pdf-engine:") and engine.len == 0: engine = o[11 .. ^1]
  if engine.len == 0: engine = "lualatex"
  if findExe(engine).len == 0: (app.msg = "pdf: " & engine & " not on PATH"; return)
  let src = absolutePath(app.filePath)
  let dir = src.parentDir
  proc resolve(p: string): string =
    let p = expandTilde(p.strip(chars = {'"', ' '}))
    if p.isAbsolute: p else: dir / p
  # -- pandoc args -----------------------------------------------------------------
  var args = @["-f", "org+smart", "-t", "latex", "--standalone"]
  let num = optionValue(options, "num")
  if num != "nil" and num != "0": args.add "--number-sections"
  let toc = optionValue(options, "toc")
  if toc != "nil":
    args.add "--toc"
    if toc.len > 0 and toc[0] in Digits: args.add "--toc-depth=" & toc
  var haveBib = false
  for b in bibs:
    if fileExists(resolve(b)): (args.add "--bibliography=" & resolve(b); haveBib = true)
  if haveBib:
    args.add "--citeproc"
    if csl.len > 0: args.add "--csl=" & resolve(csl)
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
  var body: seq[string]
  let noTitle = optionValue(options, "title") == "nil"
  for ln in toPandocOrg(applyExports(app, lines, running)):
    let low = ln.strip.toLowerAscii
    if noTitle and (low.startsWith("#+title:") or low.startsWith("#+subtitle:")): continue
    if low.startsWith("#+latex_header:") and "\\hypersetup" in ln:
      let v = ln[ln.find(':') + 1 .. ^1].strip
      body.add "#+LATEX_HEADER: \\AtBeginDocument{" & v & "}"
      continue
    body.add ln
  let orgTmp = dir / (".wkb-export-" & src.splitFile.name & ".org")   # same dir: relative paths hold
  writeFile(orgTmp, body.join("\n") & "\n")
  defer: removeFile(orgTmp)
  let tex = src.changeFileExt("tex")
  args.add @[orgTmp, "-o", tex]
  let (pcode, pout) = run("pandoc", args, dir)
  if pcode != 0:
    let ls = pout.strip.splitLines
    app.msg = "pdf: pandoc failed: " & ls[0 .. min(2, ls.high)].join(" | ")
    return
  # absolute image paths come out as file:// URIs, which LaTeX can't open
  writeFile(tex, readFile(tex).replacef(re"(\\includegraphics(?:\[[^\]]*\])?\{)file://", "$1"))
  # -- .tex -> .pdf ----------------------------------------------------------------
  let job = tex.splitFile.name
  for i in 1 .. max(1, gPdfLatexRuns):
    if not runLatex(engine, tex.extractFilename, dir):
      app.msg = "pdf: " & engine & " killed after " & $gBeamerLatexTimeout &
                " s (runaway?) -- see " & job & ".log"
      return
  let pdf = tex.changeFileExt("pdf")
  let log = tex.changeFileExt("log")
  let errs = firstLatexErrors(if fileExists(log): readFile(log) else: "")
  let stale = if running > 0: "; WARNING: " & $running & " block(s) still running" else: ""
  if not fileExists(pdf) or getLastModificationTime(pdf) < getLastModificationTime(tex):
    app.msg = "pdf: " & engine & " failed" & (if errs.len > 0: ": " & errs else: "") &
              " (see " & log.extractFilename & ")"
    return
  if errs.len > 0:   # batchmode still wrote a PDF (e.g. a missing image): keep the log
    app.msg = "pdf: wrote " & pdf.extractFilename & " WITH LaTeX errors: " & errs &
              " (see " & log.extractFilename & ")" & stale
    return
  if not gPdfKeepAux:
    for kind, f in walkDir(dir):
      let n = f.extractFilename
      if kind == pcFile and n.startsWith(job & ".") and
         n.splitFile.ext in [".aux", ".log", ".out", ".toc"]:
        removeFile(f)
  app.msg = "pdf: wrote " & pdf.extractFilename & " (pandoc + " & engine & ", " &
            $(getFileSize(pdf) div 1024) & " KB)" & stale

proc extend*(app: var App) =
  defcommand("latex-pdf-export", "Export: PDF document (LaTeX article, pandoc + lualatex)",
             latexPdfExport)
  registerExport("pdf", "PDF document (LaTeX article, pandoc + lualatex/xelatex)",
                 "latex-pdf-export")
