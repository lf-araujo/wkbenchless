## org-tracked -- Word .docx <-> org round-trip with tracked changes as
## CriticMarkup, via pandoc. A wkbenchless port of org-tracked-docx.
##
## Needs `pandoc` on PATH. Link a buffer to its Word doc with a header line:
##   #+OTD_DOCX: /path/to/manuscript.docx
## Then:
##   M-x otd-import  -- docx -> this buffer, tracked changes/comments as CriticMarkup
##   M-x otd-export  -- this buffer's CriticMarkup -> tracked changes in the docx
##
## CriticMarkup handled: {++ins++} {--del--} {~~old~>new~~} {>>[Author] note<<}
## {==highlight==}. Insertions/deletions/substitutions round-trip as real Word
## revisions; comments are emitted best-effort as Word comments.

import wkbcore
import std/[osproc, os, strutils, times, tables, sequtils, sets]

var
  gPandoc* = "pandoc"
  gAuthor* = ""       ## blank -> git user.name, else "wkbenchless"
  gBib* = ""          ## bibliography path; else #+bibliography: header, else sibling .bib
  gCsl* = ""          ## CSL citation-style file (optional)
  gRefDoc* = ""       ## Word reference-doc / template (optional)
  gEmbedSource* = true ## embed the canonical .org inside the exported docx (round-trip)

proc trackAuthor(): string =
  if gAuthor.len > 0: return gAuthor
  let (o, c) = execCmdEx("git config user.name")
  result = (if c == 0: o.strip() else: "")
  if result.len == 0: result = "wkbenchless"

proc nowDate(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc pandoc(args: seq[string]): tuple[code: int; output: string] =
  let exe = findExe(gPandoc)
  if exe.len == 0: return (127, "pandoc not on PATH")
  var cmd = quoteShell(exe)
  for a in args: cmd.add " " & quoteShell(a)
  let r = execCmdEx(cmd)
  (r.exitCode, r.output)

# ---- CriticMarkup <-> pandoc span conversion -------------------------------

proc orgCiteToPandoc(s: string): string =
  ## Convert Org citation syntax to pandoc markdown citations, so a citation
  ## inside a CriticMarkup span (which bypasses the org->md stage via `stash`)
  ## still resolves.  Its `[cite:@key]` would otherwise reach `md -> docx` in
  ## Org syntax, which pandoc's *markdown* reader does not recognise -- it ships
  ## as literal text that citeproc never resolves.  `[cite:@key]` / `[cite:@a;@b]`
  ## -> `[@key]` / `[@a;@b]` (parenthetical); `[cite/t:@key]` -> `@key`
  ## (narrative single key).  Mirrors org-tracked-docx's `otd--orgcite->pandoc`.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '[' and i + 5 < s.len and s[i+1] == 'c' and s[i+2] == 'i' and
       s[i+3] == 't' and s[i+4] == 'e' and (s[i+5] == ':' or s[i+5] == '/'):
      let closeB = s.find(']', i+5)
      let colon  = s.find(':', i+5)
      if closeB > i and colon > i and colon < closeB:
        let style = s[i+5 ..< colon]                 # "" or "/t" or "/text" ...
        let body  = s[colon+1 ..< closeB].strip()
        if (style == "/t" or style == "/text") and body.startsWith("@") and
           ';' notin body and ' ' notin body:
          result.add body                            # narrative: @key
        else:
          result.add "[" & body & "]"                # parenthetical: [@key] / [@a;@b]
        i = closeB + 1
        continue
    result.add s[i]; inc i

proc criticToSpans(md: string; doneIds: var seq[int]): string =
  ## CriticMarkup tokens -> pandoc markdown spans (for md -> docx). Uses the same
  ## split scanner style as wkbcore.applyCriticMarkup.
  let a = trackAuthor()
  let d = nowDate()
  let ins = " author=\"" & a & "\" date=\"" & d & "\""
  result = newStringOfCap(md.len)
  var i = 0
  var cid = 0
  proc closeOf(o, c: char): int =
    var q = i + 3
    while q + 2 < md.len:
      if md[q] == c and md[q+1] == c and md[q+2] == '}': return q + 2
      inc q
    -1
  while i < md.len:
    # {==range==} optionally followed by {>>comment<<}: anchor the comment to
    # the highlighted range (a real commented span in Word), else keep the text.
    if i + 4 < md.len and md[i] == '{' and md[i+1] == '=' and md[i+2] == '=':
      let he = closeOf('=', '=')                 # index of the highlight's '}'
      if he >= 0:
        let rng = orgCiteToPandoc(md[i+3 ..< he-2])
        if he + 3 < md.len and md[he+1] == '{' and md[he+2] == '>' and md[he+3] == '>':
          var q = he + 4
          var ce = -1
          while q + 2 < md.len:
            if md[q] == '<' and md[q+1] == '<' and md[q+2] == '}': ce = q + 2; break
            inc q
          if ce >= 0:
            var note = md[he+4 ..< ce-2].strip()
            var cauth = a
            if note.startsWith("[") and ']' in note:
              let rb = note.find(']')
              cauth = note[1 ..< rb]
              note = note[rb+1 .. ^1].strip()
            if "[DONE]" in note:
              doneIds.add cid
              note = note.replace("[DONE] ", "").replace("[DONE]", "").strip()
            result.add "[" & orgCiteToPandoc(note) & "]{.comment-start id=\"" & $cid &
                       "\" author=\"" & cauth & "\" date=\"" & d & "\"}" & rng &
                       "[]{.comment-end id=\"" & $cid & "\"}"
            inc cid
            i = ce + 1; continue
        result.add rng                           # orphan highlight: keep the text
        i = he + 1; continue
    if i + 4 < md.len and md[i] == '{':
      let x = md[i+1]; let y = md[i+2]
      if x == y and x in {'+', '-', '=', '~'}:
        let e = closeOf(x, x)
        if e >= 0:
          let inner = md[i+3 ..< e-2]
          case x
          of '+': result.add "[" & orgCiteToPandoc(inner) & "]{.insertion" & ins & "}"
          of '-': result.add "[" & orgCiteToPandoc(inner) & "]{.deletion" & ins & "}"
          of '=': result.add orgCiteToPandoc(inner)                        # highlight: keep the text
          of '~':
            let arrow = inner.find("~>")
            if arrow >= 0:
              result.add "[" & orgCiteToPandoc(inner[0 ..< arrow]) & "]{.deletion" & ins & "}"
              result.add "[" & orgCiteToPandoc(inner[arrow+2 .. ^1]) & "]{.insertion" & ins & "}"
            else:
              result.add "[" & orgCiteToPandoc(inner) & "]{.insertion" & ins & "}"
          else: discard
          i = e + 1; continue
      elif x == '>' and y == '>':                         # {>>[A] note<<}
        var q = i + 3
        var e = -1
        while q + 2 < md.len:
          if md[q] == '<' and md[q+1] == '<' and md[q+2] == '}': e = q + 2; break
          inc q
        if e >= 0:
          var note = md[i+3 ..< e-2].strip()
          var cauth = a
          if note.startsWith("[") and ']' in note:        # [Author] prefix
            let rb = note.find(']')
            cauth = note[1 ..< rb]
            note = note[rb+1 .. ^1].strip()
          if "[DONE]" in note:
            doneIds.add cid
            note = note.replace("[DONE] ", "").replace("[DONE]", "").strip()
          result.add "[" & orgCiteToPandoc(note) & "]{.comment-start id=\"" & $cid & "\" author=\"" &
                     cauth & "\" date=\"" & d & "\"}[]{.comment-end id=\"" & $cid & "\"}"
          inc cid
          i = e + 1; continue
    result.add md[i]; inc i

proc spansToCritic(md: string): string =
  ## pandoc markdown track-change spans -> CriticMarkup (for docx -> md).
  ## Balanced-bracket scan so inserted/deleted text may itself contain `]`.
  result = newStringOfCap(md.len)
  var i = 0
  while i < md.len:
    # a closing `]{.class ...}` -> find the matching `[`, wrap in CriticMarkup
    if md[i] == ']' and i + 2 < md.len and md[i+1] == '{' and md[i+2] == '.':
      let braceEnd = md.find('}', i)
      if braceEnd > 0:
        let attrs = md[i+3 ..< braceEnd]      # skip `]{.`
        let cls = attrs.split({' ', '\t'})[0]
        # find matching open bracket
        var depth = 1; var p = i - 1
        while p >= 0 and depth > 0:
          if md[p] == ']': inc depth
          elif md[p] == '[': dec depth
          if depth == 0: break
          dec p
        if p >= 0 and depth == 0:
          let inner = md[p+1 ..< i]
          var wrapped = ""
          case cls
          of "insertion": wrapped = "{++" & inner & "++}"
          of "deletion": wrapped = "{--" & inner & "--}"
          of "mark": wrapped = "{==" & inner & "==}"
          of "comment-start":
            var auth = ""
            let ai = attrs.find("author=\"")
            if ai >= 0:
              let s = ai + 8; let en = attrs.find('"', s)
              if en > s: auth = attrs[s ..< en]
            wrapped = "{>>[" & auth & "] " & inner & "<<}"
          else: wrapped = ""    # unknown class: drop the span, keep the text
          # replace result[p+1..] : rebuild -- we appended md up to p already?
          # (handled below by rewriting; see note)
          if wrapped.len > 0 or cls notin ["insertion","deletion","mark","comment-start"]:
            # trim what we already emitted back to the open bracket, then wrap
            result.setLen(result.len - (i - (p + 1)) - 1)   # drop inner + '['
            if wrapped.len > 0: result.add wrapped
            else: result.add inner
            i = braceEnd + 1
            continue
    result.add md[i]; inc i

proc stash(s: string; tokens: var seq[string]): string =
  ## Replace CriticMarkup tokens with opaque sentinels so a pandoc org<->md pass
  ## can't mangle them (=verbatim=, ~~, etc.). Restored with `unstash`.
  result = newStringOfCap(s.len)
  var i = 0
  proc take(closeSeq: string): int =
    let e = s.find(closeSeq, i + 3)
    if e < 0: -1 else: e + closeSeq.len
  while i < s.len:
    var e = -1
    if i + 4 < s.len and s[i] == '{':
      case s[i+1]
      of '+': (if s[i+2] == '+': e = take("++}"))
      of '-': (if s[i+2] == '-': e = take("--}"))
      of '=': (if s[i+2] == '=': e = take("==}"))
      of '~': (if s[i+2] == '~': e = take("~~}"))
      of '>': (if s[i+2] == '>': e = take("<<}"))
      else: discard
    if e > 0:
      tokens.add s[i ..< e]
      result.add "zZoTdZz" & $(tokens.len - 1) & "zZ"
      i = e
    else:
      result.add s[i]; inc i

proc unstash(s: string; tokens: seq[string]): string =
  result = s
  for idx, tok in tokens:
    result = result.replace("zZoTdZz" & $idx & "zZ", tok)

# ---- embedded canonical org source (round-trip recovery) -------------------
# Port of org-tracked-docx's customXml embed/extract: the .org that generated
# the docx is stored inside it, so re-import can recover cite keys, cross-refs,
# and #+header syntax that citeproc / pandoc-crossref render away.

const
  cxItemName  = "item-otd-source.xml"
  cxItemProps = "itemProps-otd-source.xml"
  cxNamespace = "urn:org-tracked-docx:source"

proc cdataEscape(s: string): string =
  "<![CDATA[" & s.replace("]]>", "]]]]><![CDATA[>") & "]]>"

proc cdataUnescape(s: string): string =
  s.replace("]]]]><![CDATA[>", "]]>")

proc embedOrgSource*(docx, orgContent: string): bool =
  ## Embed ORGCONTENT inside DOCX as a customXml part, registered in
  ## [Content_Types].xml and word/_rels/document.xml.rels so Word and
  ## LibreOffice preserve it across saves and tracked edits. Port of
  ## otd--embed-org-source. Returns true on success.
  let unzipExe = findExe("unzip")
  let zipExe   = findExe("zip")
  if unzipExe.len == 0 or zipExe.len == 0: return false
  let docxAbs = absolutePath(docx)
  if not fileExists(docxAbs): return false
  let tmp = getTempDir() / ("otd-embed-" & $getCurrentProcessId() & "-" & $int(epochTime()))
  removeDir(tmp); createDir(tmp)
  defer: removeDir(tmp)
  if execCmdEx(quoteShell(unzipExe) & " -q " & quoteShell(docxAbs) &
               " -d " & quoteShell(tmp)).exitCode != 0: return false
  let cxDir = tmp / "customXml"
  createDir(cxDir); createDir(cxDir / "_rels")
  writeFile(cxDir / cxItemName,
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
    "<orgTrackedSource xmlns=\"" & cxNamespace & "\">" &
    cdataEscape(orgContent) & "</orgTrackedSource>\n")
  writeFile(cxDir / cxItemProps,
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
    "<ds:datastoreItem ds:itemID=\"{ORG-TRACKED-DOCX-SOURCE}\"" &
    " xmlns:ds=\"http://schemas.openxmlformats.org/officeDocument/2006/customXml\">" &
    "<ds:schemaRefs><ds:schemaRef ds:uri=\"" & cxNamespace & "\"/></ds:schemaRefs>" &
    "</ds:datastoreItem>\n")
  writeFile(cxDir / "_rels" / (cxItemName & ".rels"),
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
    "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" &
    "<Relationship Id=\"rId1\"" &
    " Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXmlProps\"" &
    " Target=\"" & cxItemProps & "\"/></Relationships>\n")
  let ct = tmp / "[Content_Types].xml"
  if fileExists(ct):
    let ins = "<Override PartName=\"/customXml/" & cxItemName &
              "\" ContentType=\"application/xml\"/>" &
              "<Override PartName=\"/customXml/" & cxItemProps &
              "\" ContentType=\"application/vnd.openxmlformats-officedocument.customXmlProperties+xml\"/>"
    writeFile(ct, readFile(ct).replace("</Types>", ins & "</Types>"))
  let rels = tmp / "word" / "_rels" / "document.xml.rels"
  if fileExists(rels):
    let r = readFile(rels)
    var maxId = 0
    var i = 0
    while true:
      let p = r.find("Id=\"rId", i)
      if p < 0: break
      var j = p + 7
      var num = ""
      while j < r.len and r[j] in {'0'..'9'}: num.add r[j]; inc j
      if num.len > 0: maxId = max(maxId, parseInt(num))
      i = j + 1
    let ins = "<Relationship Id=\"rId" & $(maxId + 1) & "\"" &
              " Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml\"" &
              " Target=\"../customXml/" & cxItemName & "\"/>"
    writeFile(rels, r.replace("</Relationships>", ins & "</Relationships>"))
  removeFile(docxAbs)
  execCmdEx(quoteShell(zipExe) & " -q -r " & quoteShell(docxAbs) & " .",
            workingDir = tmp).exitCode == 0

proc extractOrgSource*(docx: string): string =
  ## Recover the embedded canonical org from DOCX, or "" if absent. Identifies
  ## the part by its <orgTrackedSource> element (LibreOffice renames the item on
  ## save). Port of otd--extract-org-source-customxml; normalizes CRLF/CR to LF.
  let unzipExe = findExe("unzip")
  if unzipExe.len == 0 or not fileExists(docx): return ""
  let (listing, lc) = execCmdEx(quoteShell(unzipExe) & " -Z1 " & quoteShell(docx))
  if lc != 0: return ""
  for raw in listing.splitLines():
    let entry = raw.strip()
    if entry.startsWith("customXml/") and entry.endsWith(".xml") and entry.count('/') == 1:
      let (content, cc) = execCmdEx(quoteShell(unzipExe) & " -p " &
                                    quoteShell(docx) & " " & quoteShell(entry))
      if cc != 0: continue
      let mi = content.find("<orgTrackedSource")
      if mi < 0: continue
      let cdStart = content.find("<![CDATA[", mi)
      if cdStart < 0: continue
      let payStart = cdStart + "<![CDATA[".len
      let closeTag = content.find("</orgTrackedSource>", payStart)
      if closeTag < 0: continue
      var e = closeTag
      while e > payStart and content[e-1] in {' ', '\t', '\n', '\r'}: dec e
      if e >= payStart + 3 and content[e-3 ..< e] == "]]>":
        return cdataUnescape(content[payStart ..< e-3]).replace("\r\n", "\n").replace("\r", "\n")
  ""

proc resolveDoneComments(docx: string; doneIds: seq[int]): bool =
  ## Mark the given comment ids "Resolved" in Word's reviewing pane: inject a
  ## w14:paraId on each comment's first <w:p> and write word/commentsExtended.xml
  ## with w15:done="1" for those ids, registered in [Content_Types].xml and the
  ## document rels. Port of org-tracked-docx's otd-resolve-comments.py.
  if doneIds.len == 0: return false
  let unzipExe = findExe("unzip")
  let zipExe   = findExe("zip")
  if unzipExe.len == 0 or zipExe.len == 0: return false
  let docxAbs = absolutePath(docx)
  let tmp = getTempDir() / ("otd-done-" & $getCurrentProcessId() & "-" & $int(epochTime()))
  removeDir(tmp); createDir(tmp)
  defer: removeDir(tmp)
  if execCmdEx(quoteShell(unzipExe) & " -q " & quoteShell(docxAbs) &
               " -d " & quoteShell(tmp)).exitCode != 0: return false
  let cPath = tmp / "word" / "comments.xml"
  if not fileExists(cPath): return false            # no comments -> nothing to do
  var comments = readFile(cPath)
  let headEnd = comments.find('>')
  if headEnd > 0 and "xmlns:w14=" notin comments[0 .. headEnd]:
    comments = comments.replace("<w:comments ",
      "<w:comments xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\" ")
  var paraIds = initTable[int, string]()
  var counter = 0x10000001
  var res = ""
  var i = 0
  while true:
    let cs = comments.find("<w:comment ", i)
    if cs < 0: res.add comments[i .. ^1]; break
    res.add comments[i ..< cs]
    let ce = comments.find("</w:comment>", cs)
    if ce < 0: res.add comments[cs .. ^1]; break
    let ceEnd = ce + "</w:comment>".len
    var blk = comments[cs ..< ceEnd]
    let tagEnd = blk.find('>')
    var cid = -1
    let idp = blk.find("w:id=\"")
    if idp >= 0 and idp < tagEnd:
      var k = idp + 6
      var num = ""
      while k < blk.len and blk[k] in {'0'..'9'}: num.add blk[k]; inc k
      if num.len > 0: cid = parseInt(num)
    var pp = -1                                        # first <w:p> (not <w:pPr>)
    var sp = tagEnd
    while true:
      let cand = blk.find("<w:p", sp)
      if cand < 0: break
      if cand + 4 < blk.len and blk[cand+4] in {' ', '>', '/'}: pp = cand; break
      sp = cand + 4
    if pp >= 0:
      let pe = blk.find('>', pp)
      if pe >= 0 and "w14:paraId" notin blk[pp .. pe]:
        let pid = toHex(counter, 8); inc counter
        if blk[pe-1] == '/': blk = blk[0 ..< pe-1] & " w14:paraId=\"" & pid & "\"/>" & blk[pe+1 .. ^1]
        else:                blk = blk[0 ..< pe] & " w14:paraId=\"" & pid & "\">" & blk[pe+1 .. ^1]
        if cid >= 0: paraIds[cid] = pid
    res.add blk
    i = ceEnd
  var entries = ""
  for cid in doneIds:
    if paraIds.hasKey(cid):
      entries.add "<w15:commentEx w15:paraId=\"" & paraIds[cid] & "\" w15:done=\"1\"/>"
  writeFile(cPath, res)
  writeFile(tmp / "word" / "commentsExtended.xml",
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n" &
    "<w15:commentsEx xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\">" &
    entries & "</w15:commentsEx>")
  let ct = tmp / "[Content_Types].xml"
  if fileExists(ct):
    let c = readFile(ct)
    if "commentsExtended" notin c:
      writeFile(ct, c.replace("</Types>",
        "<Override PartName=\"/word/commentsExtended.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml\"/></Types>"))
  let rels = tmp / "word" / "_rels" / "document.xml.rels"
  if fileExists(rels):
    let r = readFile(rels)
    if "commentsExtended.xml" notin r:
      var maxId = 0
      var k = 0
      while true:
        let p = r.find("Id=\"rId", k)
        if p < 0: break
        var j = p + 7
        var num = ""
        while j < r.len and r[j] in {'0'..'9'}: num.add r[j]; inc j
        if num.len > 0: maxId = max(maxId, parseInt(num))
        k = j + 1
      writeFile(rels, r.replace("</Relationships>",
        "<Relationship Id=\"rId" & $(maxId+1) & "\" Type=\"http://schemas.microsoft.com/office/2011/relationships/commentsExtended\" Target=\"commentsExtended.xml\"/></Relationships>"))
  removeFile(docxAbs)
  execCmdEx(quoteShell(zipExe) & " -q -r " & quoteShell(docxAbs) & " .", workingDir = tmp).exitCode == 0

# ---- import merge: embedded canonical + reviewer's tracked changes ---------
# Recover cite keys / cross-refs / #+headers / structure from the embedded
# canonical org; overlay only the paragraphs the reviewer actually edited.
# Port (paragraph-level) of org-tracked-docx's otd--merge-content.

type
  UnitKind = enum ukStruct, ukBody
  Unit = tuple[kind: UnitKind; text: string]

proc isHeading(t: string): bool =
  var k = 0
  while k < t.len and t[k] == '*': inc k
  k > 0 and k < t.len and t[k] == ' '

proc hasCriticMarkup(s: string): bool =
  "{++" in s or "{--" in s or "{~~" in s or "{>>" in s or "{==" in s

proc parseUnits(text: string): seq[Unit] =
  ## Split TEXT into structural units (headers, headings, property drawers,
  ## export/src blocks, blank lines -- kept verbatim) and body paragraphs.
  var cur: seq[string]
  var inDrawer, inExport, inSrc = false
  proc flush(res: var seq[Unit]) =
    if cur.len > 0: res.add (ukBody, cur.join("\n")); cur = @[]
  for line in text.split("\n"):
    let t = line.strip()
    let low = t.toLowerAscii
    if inDrawer:
      result.add (ukStruct, line)
      if t == ":END:": inDrawer = false
    elif inExport:
      result.add (ukStruct, line)
      if low.startsWith("#+end_export"): inExport = false
    elif inSrc:
      result.add (ukStruct, line)
      if low.startsWith("#+end_src"): inSrc = false
    elif t == ":PROPERTIES:":
      flush(result); inDrawer = true; result.add (ukStruct, line)
    elif low.startsWith("#+begin_export"):
      flush(result); inExport = true; result.add (ukStruct, line)
    elif low.startsWith("#+begin_src"):
      flush(result); inSrc = true; result.add (ukStruct, line)
    elif t.len == 0 or t.startsWith("#+") or isHeading(t):
      flush(result); result.add (ukStruct, line)
    else:
      cur.add line
  flush(result)

proc bodyParas(units: seq[Unit]): seq[string] =
  for u in units:
    if u.kind == ukBody: result.add u.text

proc wordSet(s: string): HashSet[string] =
  ## Long (>=4 char) lowercased alphanumeric words of the accepted text -- a
  ## citation-tolerant fingerprint (a few rendered-vs-key token differences do
  ## not tank the overlap of the surrounding prose).
  let accepted = applyCriticMarkup(s, accept = true)
  var w = ""
  for ch in accepted:
    if ch.isAlphaNumeric: w.add ch.toLowerAscii
    else:
      if w.len >= 4: result.incl w
      w = ""
  if w.len >= 4: result.incl w

proc similarity(a, b: HashSet[string]): float =
  if a.len == 0 or b.len == 0: return 0.0
  (a * b).len.float / (a + b).len.float

proc alignParas(canon, tracked: seq[string]): seq[int] =
  ## For each canonical body paragraph, the greedily best-matching tracked
  ## paragraph index (each used once) above a similarity threshold, else -1.
  let cs = canon.mapIt(wordSet(it))
  let ts = tracked.mapIt(wordSet(it))
  var used = newSeq[bool](tracked.len)
  result = newSeq[int](canon.len)
  for ci in 0 ..< canon.len:
    var best = -1
    var bestSim = 0.45
    for ti in 0 ..< tracked.len:
      if used[ti]: continue
      let sim = similarity(cs[ci], ts[ti])
      if sim > bestSim: bestSim = sim; best = ti
    result[ci] = best
    if best >= 0: used[best] = true

proc mergeContent*(canonical, tracked: string): string =
  ## Walk CANONICAL preserving its structure; replace a body paragraph with the
  ## aligned TRACKED paragraph only when the reviewer edited it (CriticMarkup
  ## present) -- untouched paragraphs keep the canonical form, so their cite
  ## keys / cross-refs survive. Unaligned tracked paragraphs (e.g. the rendered
  ## author block or bibliography) are dropped.
  let units = parseUnits(canonical)
  let cParas = bodyParas(units)
  let tParas = bodyParas(parseUnits(tracked))
  let align = alignParas(cParas, tParas)
  var outLines: seq[string]
  var bi = 0
  for u in units:
    if u.kind == ukStruct:
      outLines.add u.text
    else:
      let ti = align[bi]; inc bi
      if ti >= 0 and hasCriticMarkup(tParas[ti]): outLines.add tParas[ti]
      else: outLines.add u.text
  outLines.join("\n")

# ---- commands --------------------------------------------------------------

proc docxOf(app: App): string =
  ## The docx path from a #+OTD_DOCX: header, or a sibling <file>.docx of the
  ## open .org, or "" if neither is available.
  for i in 0 ..< app.ed.getLineCount():
    let ln = strutils.strip(app.ed.getLineText(i))
    if ln.toLowerAscii.startsWith("#+otd_docx:"):
      return expandTilde(strutils.strip(ln[ln.find(':') + 1 .. ^1]))
  if app.filePath.len > 0: return app.filePath.changeFileExt("docx")
  ""

proc orgHeaders(app: App; key: string): seq[string] =
  ## Values of every `#+<key>: value` line (case-insensitive).
  let k = "#+" & key.toLowerAscii & ":"
  for i in 0 ..< app.ed.getLineCount():
    let ln = strutils.strip(app.ed.getLineText(i))
    if ln.toLowerAscii.startsWith(k):
      result.add strutils.strip(ln[ln.find(':') + 1 .. ^1])

proc resolveRel(app: App; p: string): string =
  let e = expandTilde(p)
  if isAbsolute(e) or app.filePath.len == 0: e else: parentDir(app.filePath) / e

proc findBib(app: App): string =
  ## gBib, else a #+bibliography: header, else the first sibling *.bib.
  if gBib.len > 0: return resolveRel(app, gBib)
  let h = orgHeaders(app, "bibliography")
  if h.len > 0: return resolveRel(app, h[0])
  if app.filePath.len > 0:
    for f in walkFiles(parentDir(app.filePath) / "*.bib"): return f
  ""

proc unescapeRefs(md: string): string =
  ## pandoc's org reader escapes cross-ref keys `@fig:x` as `\@fig:x`; unescape
  ## so pandoc-crossref (and citeproc for `[@cite]`) can see them.
  md.replace("\\@", "@")

proc authorBlock(app: App): string =
  ## Port of org-tracked-docx's otd--generate-author-block: turn
  ##   #+AFFIL: key :: institution
  ##   #+AUTHOR_LIST: Name :: key1, key2 :: corresponding
  ##   #+AUTHOR_GROUP: for the ... Group
  ## into a #+begin_export markdown block with pandoc superscript affiliation
  ## letters (a, b, ... in #+AFFIL declaration order) and a numbered affil list.
  var affils: seq[(string, string)]                 # (key, description), in order
  var authors: seq[tuple[name: string; keys: seq[string]; corr: bool]]
  var group = ""
  for i in 0 ..< app.ed.getLineCount():
    let ln = strutils.strip(app.ed.getLineText(i))
    let low = ln.toLowerAscii
    if low.startsWith("#+affil:"):
      let rest = strutils.strip(ln[ln.find(':') + 1 .. ^1])
      let sep = rest.find("::")
      if sep >= 0:
        affils.add (strutils.strip(rest[0 ..< sep]), strutils.strip(rest[sep + 2 .. ^1]))
    elif low.startsWith("#+author_list:"):
      let parts = strutils.strip(ln[ln.find(':') + 1 .. ^1]).split("::")
      if parts.len >= 2:
        var keys: seq[string]
        for k in parts[1].split(','):
          let kk = strutils.strip(k)
          if kk.len > 0: keys.add kk
        authors.add (strutils.strip(parts[0]), keys,
                     parts.len >= 3 and "corresponding" in parts[2].toLowerAscii)
    elif low.startsWith("#+author_group:"):
      group = strutils.strip(ln[ln.find(':') + 1 .. ^1])
  if authors.len == 0: return ""
  var letter: Table[string, string]
  for idx, a in affils: letter[a[0]] = $chr(ord('a') + (idx mod 26))
  var authorStrs: seq[string]
  for au in authors:
    var sups: seq[string]
    for k in au.keys:
      if letter.hasKey(k): sups.add letter[k]
    if au.corr: sups.add "*"
    authorStrs.add (if sups.len > 0: au.name & "^" & sups.join(",") & "^" else: au.name)
  var authorLine = authorStrs.join(", ")
  if group.len > 0: authorLine.add ", " & group
  var affilLines: seq[string]
  for idx, a in affils: affilLines.add $(idx + 1) & ". " & a[1]
  result = "#+begin_export markdown\n" & authorLine & "\n\n" &
           affilLines.join("\n\n") & "\n\n" &
           (if authors.anyIt(it.corr): "*Corresponding author.\n" else: "") &
           "#+end_export"

proc otdImport(app: var App) =
  let docx = docxOf(app)
  if docx.len == 0: (app.msg = "add a  #+OTD_DOCX: /path.docx  line first"; return)
  if not fileExists(docx): (app.msg = "not found: " & docx; return)
  let md = getTempDir() / "otd-import.md"
  var (code, outp) = pandoc(@["-f", "docx", "-t", "markdown", "--wrap=none",
                              "--track-changes=all", docx, "-o", md])
  if code != 0: (app.msg = "pandoc docx->md failed: " & outp.strip(); return)
  var toks: seq[string]
  let stashed = stash(spansToCritic(readFile(md)), toks)
  writeFile(md, stashed)
  let orgOut = getTempDir() / "otd-import.org"
  (code, outp) = pandoc(@["-f", "markdown", "-t", "org", "--wrap=none", md, "-o", orgOut])
  if code != 0: (app.msg = "pandoc md->org failed: " & outp.strip(); return)
  let tracked = unstash(readFile(orgOut), toks)
  let canonical = extractOrgSource(docx)          # embedded .org, if this docx has one
  if canonical.len > 0:
    app.ed.setText(mergeContent(canonical, tracked).strip())
    app.ed.markChanged()
    app.msg = "otd: imported " & extractFilename(docx) &
              " (merged reviewer edits onto embedded org source)"
  else:
    app.ed.setText("#+OTD_DOCX: " & docx & "\n\n" & tracked.strip())
    app.ed.markChanged()
    app.msg = "otd: imported " & extractFilename(docx) & " (tracked changes as CriticMarkup)"

proc otdExport(app: var App) =
  let docx = docxOf(app)
  if docx.len == 0:
    app.msg = "otd: save the .org first, or add a  #+OTD_DOCX: /path.docx  line"; return
  if findExe(gPandoc).len == 0: (app.msg = "otd: pandoc not on PATH"; return)
  # Feed pandoc the org with the OTD header dropped and the #+AFFIL/#+AUTHOR_LIST/
  # #+AUTHOR_GROUP headers replaced (once, in place) by a generated author block.
  let authors = authorBlock(app)
  var lines: seq[string]
  var authorsDone = false
  for i in 0 ..< app.ed.getLineCount():
    let ln = app.ed.getLineText(i)
    let low = strutils.strip(ln).toLowerAscii
    if low.startsWith("#+otd_docx:"): continue
    if low.startsWith("#+affil:") or low.startsWith("#+author_list:") or
       low.startsWith("#+author_group:"):
      if not authorsDone and authors.len > 0: lines.add authors
      authorsDone = true
      continue
    lines.add ln
  var toks: seq[string]
  let orgStashed = stash(lines.join("\n"), toks)
  let orgTmp = getTempDir() / "otd-export.org"
  writeFile(orgTmp, orgStashed)
  let md = getTempDir() / "otd-export.md"
  # -s carries #+TITLE etc. as YAML metadata into the markdown.
  var (code, outp) = pandoc(@["-f", "org", "-t", "markdown", "--wrap=none", "-s", orgTmp, "-o", md])
  if code != 0: (app.msg = "pandoc org->md failed: " & outp.strip(); return)
  var doneIds: seq[int]
  writeFile(md, unescapeRefs(criticToSpans(unstash(readFile(md), toks), doneIds)))
  # md -> docx: standalone (title), citeproc + bibliography (references),
  # pandoc-crossref (fig:/tbl: cross-refs), optional CSL + reference-doc.
  var dargs = @["-f", "markdown", "-t", "docx", "-s"]
  if findExe("pandoc-crossref").len > 0: (dargs.add "--filter"; dargs.add "pandoc-crossref")
  dargs.add "--citeproc"
  let bib = findBib(app)
  if bib.len > 0 and fileExists(bib): dargs.add "--bibliography=" & bib
  if gCsl.len > 0: dargs.add "--csl=" & resolveRel(app, gCsl)
  if gRefDoc.len > 0: dargs.add "--reference-doc=" & resolveRel(app, gRefDoc)
  dargs.add md; dargs.add "-o"; dargs.add docx
  (code, outp) = pandoc(dargs)
  if code != 0: (app.msg = "pandoc md->docx failed: " & outp.strip(); return)
  # Embed the canonical org so re-import can recover cite keys / cross-refs / headers.
  let embedded = gEmbedSource and embedOrgSource(docx, app.ed.fullText())
  if doneIds.len > 0: discard resolveDoneComments(docx, doneIds)
  app.msg = "otd: exported -> " & extractFilename(docx) &
            (if embedded: "  [+org]" else: "") &
            (if bib.len > 0: "  [refs: " & extractFilename(bib) & "]" else: "")

proc extend*(app: var App) =
  defcommand("otd-import", "Tracked: import .docx -> org (CriticMarkup)", otdImport)
  defcommand("otd-export", "Tracked: export org (CriticMarkup) -> .docx", otdExport)
