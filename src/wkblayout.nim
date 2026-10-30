## wkblayout -- backend-neutral page-layout directives for wkbenchless exports.
##
## A shared textual pre-pandoc pass that every export backend runs, so one
## semantic keyword expands to the right raw block per target instead of the
## author hand-writing raw OOXML / LaTeX:
##
##   #+PAGEBREAK:              a page / frame break at that point
##   #+LANDSCAPE: begin|end    wrap a region to render landscape
##   #+RUNNING_TITLE: <text>   declare a short running title (emits nothing itself)
##   #+TITLEBLOCK: short       running title + author names + group (no affiliations)
##   #+SUPPLEMENT: begin|end   number fig:/tbl: items in the region separately
##   #+SUPP_FIGURE_LABEL: <t>  label template, %n = number (default "Figure S%n")
##   #+SUPP_TABLE_LABEL: <t>   likewise for tables (default "Table S%n")
##
## Per target: docx -> raw OOXML <w:sectPr> / page break; latex -> landscape
## environment / \newpage; beamer & html -> silent no-op for the paged
## directives (slides/screens are not paged that way). #+TITLEBLOCK emits plain
## *bold* markup, identical across every backend.
##
## Supplement labels (eTable 1, Figure S1, Supplementary Fig. 1, ...): for docx
## and html the supplement's `#+name: tbl:x` items leave pandoc-crossref's
## sequence -- renamed `supp-tbl-x`, caption prefixed "eTable 1: ", and every
## `[cite:@tbl:x]` (anywhere in the document) becomes the internal link
## `[[#supp-tbl-x][eTable 1]]`, which pandoc keeps as a docx bookmark +
## hyperlink. crossref cannot do this itself: its figure/table title word is
## document-wide. latex -> \figurename / \thefigure (and table) redefinitions
## at `begin`; beamer -> no-op.
##
## Every exporter calls `expandLayout` at the top of its buffer preprocessing
## (where org_tracked already rewrites #+AFFIL). It is a pure line->line pass,
## preceded by the two-pass supplement relabelling (refs may precede targets).

import std/[strutils, tables, sequtils]

type LayoutTarget* = enum ltDocx, ltLatex, ltBeamer, ltHtml

const
  # docx: a <w:sectPr> inside a paragraph CLOSES the section up to that point, so
  # "begin" emits a portrait break that closes the preceding (portrait) content,
  # and "end" emits the landscape break that closes the wrapped region. Page size
  # is US Letter (12240x15840 twips) with 1-inch (1440) margins -- the values the
  # manuscript used by hand. propagateSectionChrome (org_tracked) later copies the
  # reference doc's running head / page numbers onto these inline sections.
  oxPortrait = """#+begin_export markdown
```{=openxml}
<w:p><w:pPr><w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/><w:type w:val="nextPage"/></w:sectPr></w:pPr></w:p>
```
#+end_export"""
  oxLandscape = """#+begin_export markdown
```{=openxml}
<w:p><w:pPr><w:sectPr><w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/><w:type w:val="nextPage"/></w:sectPr></w:pPr></w:p>
```
#+end_export"""
  oxPageBreak = """#+begin_export markdown
```{=openxml}
<w:p><w:r><w:br w:type="page"/></w:r></w:p>
```
#+end_export"""
  texLandscapeBegin = "#+begin_export latex\n\\begin{landscape}\n#+end_export"
  texLandscapeEnd   = "#+begin_export latex\n\\end{landscape}\n#+end_export"
  texPageBreak      = "#+begin_export latex\n\\newpage\n#+end_export"
  htmlPageBreak = """#+begin_export html
<div style="page-break-after:always"></div>
#+end_export"""

proc keyVal(s: string): string =
  ## Value after a "#+KEY:" keyword line (already stripped).
  let c = s.find(':')
  if c < 0: "" else: s[c + 1 .. ^1].strip

proc titleBlockShort(lines: seq[string]): seq[string] =
  ## Running title (falls back to #+TITLE) + author names + group, as plain
  ## *bold*-title + comma-joined names. No superscripts, affiliations, or
  ## corresponding marker. Reuses the #+AUTHOR_LIST/#+AUTHOR_GROUP metadata.
  var running, fullTitle, group: string
  var names: seq[string]
  for ln in lines:
    let s = ln.strip
    let low = s.toLowerAscii
    if low.startsWith("#+running_title:"): running = keyVal(s)
    elif low.startsWith("#+title:") and fullTitle.len == 0: fullTitle = keyVal(s)
    elif low.startsWith("#+author_list:"):
      let nm = keyVal(s).split("::")[0].strip
      if nm.len > 0: names.add nm
    elif low.startsWith("#+author_group:"): group = keyVal(s)
  let title = if running.len > 0: running else: fullTitle
  var authorLine = names.join(", ")
  if group.len > 0: authorLine.add (if authorLine.len > 0: ", " else: "") & group
  if title.len > 0: result.add "*" & title & "*"
  if title.len > 0 and authorLine.len > 0: result.add ""
  if authorLine.len > 0: result.add authorLine

const
  suppFigDefault = "Figure S%n"
  suppTblDefault = "Table S%n"

proc suppLabel(tmpl: string; n: int): string = tmpl.replace("%n", $n)

proc suppTexNames(tmpl: string): (string, string) =
  ## Split a label template into the LaTeX float name and number prefix:
  ## "eTable %n" -> ("eTable", ""), "Figure S%n" -> ("Figure", "S"),
  ## "Supplementary Fig. %n" -> ("Supplementary Fig.", "").
  let before = tmpl.split("%n")[0]
  let sp = before.rfind(' ')
  if sp < 0: (before.strip, "") else: (before[0 ..< sp].strip, before[sp + 1 .. ^1])

proc suppTargetId(lines: seq[string]; i: int): string =
  ## "fig:x" / "tbl:x" when line I is a `#+name:` of a figure or table (not of
  ## a src block, whose results carry their own name), else "".
  let s = lines[i].strip
  if not s.toLowerAscii.startsWith("#+name:"): return ""
  let id = keyVal(s)
  if not (id.startsWith("fig:") or id.startsWith("tbl:")): return ""
  var k = i + 1
  while k < lines.len and lines[k].strip.startsWith("#+") and
        not lines[k].strip.toLowerAscii.startsWith("#+begin_src"):
    inc k
  if k < lines.len and lines[k].strip.toLowerAscii.startsWith("#+begin_src"): ""
  else: id

proc suppId(id: string): string =
  ## "tbl:x" -> "supp-tbl-x": an id pandoc-crossref leaves alone.
  "supp-" & id.replace(":", "-")

proc suppGroupLabel(tmpl: string; ns: seq[int]): string =
  ## Label for several items of one kind: "Supplementary Figs. 3–5",
  ## "eTables 1 and 2", "Figures S3–S5". A run of three or more is a range.
  let (name, pre) = suppTexNames(tmpl)
  let plural = if name.endsWith("."): name[0 ..< ^1] & "s." else: name & "s"
  var parts: seq[string]
  var k = 0
  while k < ns.len:
    var j = k
    while j + 1 < ns.len and ns[j + 1] == ns[j] + 1: inc j
    if j - k >= 2: parts.add pre & $ns[k] & "–" & pre & $ns[j]
    else:
      for m in k .. j: parts.add pre & $ns[m]
    k = j + 1
  let list = if parts.len == 1: parts[0]
             else: parts[0 ..< ^1].join(", ") & " and " & parts[^1]
  plural & " " & list

proc suppRefs(ln: string; labels: Table[string, string]; nums: Table[string, int];
              figT, tblT: string): string =
  ## Rewrite each `[cite:@a;@b]` naming a supplement item: supplement keys
  ## become internal links (several of one kind share one plural label, linked
  ## to the first), the remaining keys stay a citation.
  result = ""
  var i = 0
  while i < ln.len:
    if ln.continuesWith("[cite:", i):
      let e = ln.find(']', i)
      if e > 0:
        var figs, tbls, rest: seq[string]
        for k in ln[i + 6 ..< e].split(';'):
          let key = k.strip
          let id = if key.startsWith("@"): key[1 .. ^1] else: ""
          if not labels.hasKey(id): rest.add key
          elif id.startsWith("fig:"): figs.add id
          else: tbls.add id
        if figs.len + tbls.len > 0:
          var parts: seq[string]
          for (ids, tmpl) in [(figs, figT), (tbls, tblT)]:
            if ids.len == 1:
              parts.add "[[#" & suppId(ids[0]) & "][" & labels[ids[0]] & "]]"
            elif ids.len > 1:
              parts.add "[[#" & suppId(ids[0]) & "][" &
                suppGroupLabel(tmpl, ids.mapIt(nums[it])) & "]]"
          if rest.len > 0: parts.add "[cite:" & rest.join(";") & "]"
          result.add parts.join(", ")
          i = e + 1
          continue
    result.add ln[i]
    inc i

proc expandSupplement*(lines: seq[string]; target: LayoutTarget): seq[string] =
  ## Relabel the fig:/tbl: items inside `#+SUPPLEMENT: begin` ... `end` (or to
  ## the end of the document) per the #+SUPP_*_LABEL templates; see the module
  ## doc for what each target gets. Drops the directive lines themselves.
  var figT = suppFigDefault
  var tblT = suppTblDefault
  for ln in lines:
    let low = ln.strip.toLowerAscii
    if low.startsWith("#+supp_figure_label:"): figT = keyVal(ln.strip)
    elif low.startsWith("#+supp_table_label:"): tblT = keyVal(ln.strip)
  # Pass 1: number the supplement's figures and tables, and find each one's
  # #+caption: among its block of affiliated keywords (before or after #+name:).
  var labels: Table[string, string]          # "tbl:x" -> "eTable 1"
  var nums: Table[string, int]               # "tbl:x" -> 1
  var captionOf: Table[int, string]          # caption line -> its item's label
  var uncaptioned: Table[int, string]        # #+name: line -> label (no caption)
  var inSupp, inSrc = false
  var nFig, nTbl = 0
  for i, ln in lines:
    let low = ln.strip.toLowerAscii
    if low.startsWith("#+begin_src"): inSrc = true
    elif low.startsWith("#+end_src"): inSrc = false
    elif inSrc: discard
    elif low.startsWith("#+supplement:"): inSupp = keyVal(low) == "begin"
    elif inSupp:
      let id = suppTargetId(lines, i)
      if id.len == 0: continue
      if id.startsWith("fig:"): inc nFig; nums[id] = nFig; labels[id] = suppLabel(figT, nFig)
      else: inc nTbl; nums[id] = nTbl; labels[id] = suppLabel(tblT, nTbl)
      var a = i
      while a > 0 and lines[a - 1].strip.startsWith("#+"): dec a
      var b = i
      while b + 1 < lines.len and lines[b + 1].strip.startsWith("#+"): inc b
      var found = false
      for c in a .. b:
        if lines[c].strip.toLowerAscii.startsWith("#+caption:"):
          captionOf[c] = labels[id]; found = true
      if not found: uncaptioned[i] = labels[id]
  # Pass 2: rewrite names, captions and references.
  let relabel = target in {ltDocx, ltHtml}
  inSrc = false
  for i, ln in lines:
    let s = ln.strip
    let low = s.toLowerAscii
    if low.startsWith("#+begin_src"): inSrc = true
    elif low.startsWith("#+end_src"): inSrc = false
    if inSrc or low.startsWith("#+end_src"):
      result.add ln; continue
    if low.startsWith("#+supp_figure_label:") or low.startsWith("#+supp_table_label:"):
      continue
    if low.startsWith("#+supplement:"):
      if target == ltLatex and keyVal(low) == "begin":
        let (fn, fp) = suppTexNames(figT)
        let (tn, tp) = suppTexNames(tblT)
        result.add "#+begin_export latex\n\\setcounter{figure}{0}\\setcounter{table}{0}\n" &
          "\\renewcommand{\\figurename}{" & fn & "}\\renewcommand{\\thefigure}{" & fp &
          "\\arabic{figure}}\n\\renewcommand{\\tablename}{" & tn &
          "}\\renewcommand{\\thetable}{" & tp & "\\arabic{table}}\n#+end_export"
      continue
    if not relabel:
      result.add ln; continue
    let id = suppTargetId(lines, i)
    if labels.hasKey(id):
      result.add "#+name: " & suppId(id)
      if uncaptioned.hasKey(i): result.add "#+caption: " & uncaptioned[i]
    elif captionOf.hasKey(i):
      result.add "#+caption: " & captionOf[i] & ": " & suppRefs(keyVal(s), labels, nums, figT, tblT)
    else:
      result.add (if "[cite:" in ln: suppRefs(ln, labels, nums, figT, tblT) else: ln)

proc expandLayout*(lines: seq[string]; target: LayoutTarget;
                   usedLandscape: var bool): seq[string] =
  ## Expand the layout directives in LINES for TARGET. Sets USEDLANDSCAPE when a
  ## landscape region was emitted for LaTeX (so the caller can add pdflscape).
  usedLandscape = false
  for ln in expandSupplement(lines, target):
    let s = ln.strip
    let low = s.toLowerAscii
    if low.startsWith("#+pagebreak:"):
      case target
      of ltDocx:  result.add oxPageBreak
      of ltLatex: result.add texPageBreak
      of ltHtml:  result.add htmlPageBreak
      of ltBeamer: discard                        # silent no-op (slides)
    elif low.startsWith("#+landscape:"):
      let v = keyVal(s).toLowerAscii
      case target
      of ltDocx:
        if v == "begin": result.add oxPortrait
        elif v == "end": result.add oxLandscape
      of ltLatex:
        usedLandscape = true
        if v == "begin": result.add texLandscapeBegin
        elif v == "end": result.add texLandscapeEnd
      of ltBeamer, ltHtml: discard                # silent no-op
    elif low.startsWith("#+titleblock:"):
      for t in titleBlockShort(lines): result.add t   # "short" (the only mode)
    elif low.startsWith("#+running_title:"):
      discard                                       # metadata only (used above)
    else:
      result.add ln
