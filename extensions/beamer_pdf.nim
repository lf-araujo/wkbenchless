## Beamer PDF export -- org-beamer slides straight to PDF.
##
##   M-x beamer-pdf-export   (or Export -> "beamer")   writes <file>.tex + <file>.pdf
##
## Pipeline: Emacs's own ox-beamer (`emacs -Q --batch`) turns the buffer into
## <file>.tex -- so the file's #+LATEX_* / #+BEAMER_* / metropolis config,
## BEAMER_col columns, #+beamer: lines and file-local variables (e.g.
## `org-latex-src-block-backend`) are honored exactly as in Emacs -- then the
## #+LATEX_COMPILER (default lualatex) runs twice with -shell-escape (minted,
## TOC / navigation). Nothing is evaluated: the stored #+RESULTS are exported,
## with each block's :exports applied. Packages (citeproc for CSL cites, a newer
## org) come from ~/.emacs.d/elpa; add your own setup through gBeamerElisp, e.g.
##   gBeamerElisp = "(load \"~/.emacs.d/init.el\")"

import std/[os, osproc, strutils, streams, times]
import wkbcore

var
  gBeamerEmacs* = "emacs"          ## Emacs used for the org -> LaTeX step
  gBeamerSrcBackend* = "listings"  ## default org-latex-src-block-backend (a
                                   ## file-local variable in the .org still wins)
  gBeamerElisp* = ""               ## extra elisp evaluated before the export
  gBeamerLatexRuns* = 2            ## LaTeX passes (2 = TOC / nav resolved)
  gBeamerKeepAux* = false          ## keep .aux/.log/.nav/... after a clean build

proc elispStr(s: string): string =
  "\"" & s.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & "\""

proc latexCompiler(lines: seq[string]): string =
  for ln in lines:
    let t = ln.strip
    if t.toLowerAscii.startsWith("#+latex_compiler:"):
      let v = t["#+latex_compiler:".len .. ^1].strip
      if v.len > 0: return v
  "lualatex"

proc firstLatexErrors(log: string; n = 3): string =
  ## The first `! ...` error lines of a LaTeX log, joined for the status line.
  var errs: seq[string]
  for ln in log.splitLines:
    if ln.startsWith("! "):
      errs.add ln[2 .. ^1].strip
      if errs.len >= n: break
  errs.join(" | ")

proc run(exe: string; args: seq[string]; dir: string): tuple[code: int; outp: string] =
  let p = startProcess(exe, workingDir = dir, args = args,
                       options = {poStdErrToStdOut, poUsePath})
  let outp = p.outputStream.readAll()
  result = (p.waitForExit(), outp)
  p.close()

proc beamerPdfExport*(app: var App) =
  if app.filePath.len == 0 or not app.filePath.toLowerAscii.endsWith(".org"):
    app.msg = "beamer: save the buffer as an .org file first"; return
  if findExe(gBeamerEmacs).len == 0:
    app.msg = "beamer: " & gBeamerEmacs & " not on PATH (ox-beamer does the org -> LaTeX step)"; return
  var lines: seq[string]
  for i in 0 ..< app.ed.getLineCount(): lines.add app.ed.getLineText(i)
  let compiler = latexCompiler(lines)
  if findExe(compiler).len == 0:
    app.msg = "beamer: " & compiler & " not on PATH"; return
  let src = absolutePath(app.filePath)
  let dir = src.parentDir
  let name = src.splitFile.name
  # Export the live buffer (unsaved edits included) under the real file name, so
  # the .tex/.pdf land beside it and relative paths resolve as in Emacs.
  let orgTmp = getTempDir() / ("wkb-beamer-" & name & ".org")
  writeFile(orgTmp, lines.join("\n") & "\n")
  defer: removeFile(orgTmp)
  let elisp = "(progn (package-initialize)" &
    " (require 'ox-beamer) (require 'oc-csl nil t)" &
    " (setq enable-local-variables :all org-confirm-babel-evaluate nil" &
    " org-latex-src-block-backend '" & gBeamerSrcBackend & ")" &
    " " & gBeamerElisp &
    " (advice-add 'org-babel-execute-src-block :override #'ignore)" &   # never evaluate
    " (with-temp-buffer (insert-file-contents " & elispStr(orgTmp) & ")" &
    " (setq buffer-file-name " & elispStr(src) & " default-directory " & elispStr(dir & "/") & ")" &
    " (org-mode) (hack-local-variables)" &
    " (princ (format \"WKB-TEX:%s\\n\" (expand-file-name (org-beamer-export-to-latex))))" &
    " (set-buffer-modified-p nil)))"
  let (ecode, eout) = run(gBeamerEmacs, @["-Q", "--batch", "--eval", elisp], dir)
  var tex = ""
  for ln in eout.splitLines:
    if ln.startsWith("WKB-TEX:"): tex = ln["WKB-TEX:".len .. ^1].strip
  if ecode != 0 or tex.len == 0 or not fileExists(tex):
    var why = ""
    for ln in eout.splitLines:
      if ln.startsWith("Error") or ln.contains("error:"): (why = ln.strip; break)
    app.msg = "beamer: org -> LaTeX failed" & (if why.len > 0: ": " & why else: " (emacs exit " & $ecode & ")")
    return
  let job = tex.splitFile.name
  for i in 1 .. max(1, gBeamerLatexRuns):
    discard run(compiler, @["-shell-escape", "-interaction=nonstopmode",
                            tex.extractFilename], tex.parentDir)
  let pdf = tex.changeFileExt("pdf")
  let log = tex.changeFileExt("log")
  let logText = if fileExists(log): readFile(log) else: ""
  let errs = firstLatexErrors(logText)
  if not fileExists(pdf) or getLastModificationTime(pdf) < getLastModificationTime(tex):
    app.msg = "beamer: " & compiler & " failed" &
              (if errs.len > 0: ": " & errs else: "") & " (see " & log.extractFilename & ")"
    return
  if errs.len > 0:   # nonstopmode still wrote a PDF (e.g. a missing image): keep the log
    app.msg = "beamer: wrote " & pdf.extractFilename & " WITH LaTeX errors: " & errs &
              " (see " & log.extractFilename & ")"
    return
  if not gBeamerKeepAux:
    for ext in ["aux", "log", "nav", "out", "snm", "toc", "vrb"]:
      removeFile(tex.parentDir / (job & "." & ext))
    for kind, f in walkDir(tex.parentDir):   # beamer's per-frame verbatim files
      if kind == pcFile and f.extractFilename.startsWith(job & ".") and f.endsWith(".vrb"):
        removeFile(f)
  app.msg = "beamer: wrote " & pdf.extractFilename & " (" & compiler & ", " &
            $(getFileSize(pdf) div 1024) & " KB)"

proc extend*(app: var App) =
  defcommand("beamer-pdf-export", "Export: Beamer slides -> PDF (ox-beamer + lualatex)",
             beamerPdfExport)
  registerExport("beamer", "Beamer slides (PDF, ox-beamer + lualatex)", "beamer-pdf-export")
