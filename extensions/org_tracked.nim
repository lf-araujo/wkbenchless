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
import std/[osproc, os, strutils, times, tables, sequtils, sets, base64, algorithm]
import zippy/ziparchives   # vendored pure-Nim zip: embed the .org into the docx

proc isWsC(c: char): bool = c in {' ', '\t', '\n', '\r'}

proc nbspToSpace(s: string): string = s.replace("\u00A0", " ")

proc startsWithAt(s: string; i: int; lit: string): bool =
  i + lit.len <= s.len and s[i ..< i + lit.len] == lit

proc eqIgnoreCaseAt(s: string; i: int; lit: string): bool =
  i + lit.len <= s.len and s[i ..< i + lit.len].toLowerAscii == lit

var
  gPandoc* = "pandoc"
  gAuthor* = ""       ## blank -> git user.name, else "wkbenchless"
  gBib* = ""          ## bibliography path; else #+bibliography: header, else sibling .bib
  gCsl* = ""          ## CSL citation-style file (optional)
  gRefDoc* = ""       ## Word reference-doc / template (optional)
  gMediaDir* = ""     ## extra dir (relative to the org, e.g. "graphs") to search
                      ## for figure images, on top of the org's own directory
  gEmbedSource* = true ## embed the canonical .org inside the exported docx (round-trip)

proc trackAuthor(): string =
  if gAuthor.len > 0: return gAuthor
  let (o, c) = execCmdEx("git config user.name")
  result = (if c == 0: o.strip() else: "")
  if result.len == 0: result = "wkbenchless"

proc nowDate(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc pandoc*(args: seq[string]): tuple[code: int; output: string] =
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

proc peelAuthor(inner, default: string): tuple[auth, text: string] =
  ## An optional leading `[Author]` prefix on a tracked change -> (author, rest),
  ## so `{++[Carol Franz]new++}` / `{--[Carol Franz]old--}` /
  ## `{~~[Carol Franz]old~>new~~}` export as `<w:ins/w:del w:author="Carol Franz">`.
  ## Conservative: an author only when the bracket is non-empty, has text after
  ## it, and holds no `@` -- so a citation insertion like `{++[@key]++}` stays a
  ## citation rather than being mistaken for an author tag.
  if inner.startsWith("["):
    let rb = inner.find(']')
    if rb > 1 and rb < inner.high and '@' notin inner[1 ..< rb]:
      return (inner[1 ..< rb], inner[rb+1 .. ^1])
  (default, inner)

proc criticToSpans(md: string; doneIds: var seq[int]): string =
  ## CriticMarkup tokens -> pandoc markdown spans (for md -> docx). Uses the same
  ## split scanner style as wkbcore.applyCriticMarkup.
  let a = trackAuthor()
  let d = nowDate()
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
          of '+':
            let (au, tx) = peelAuthor(inner, a)
            result.add "[" & orgCiteToPandoc(tx) & "]{.insertion author=\"" & au & "\" date=\"" & d & "\"}"
          of '-':
            let (au, tx) = peelAuthor(inner, a)
            result.add "[" & orgCiteToPandoc(tx) & "]{.deletion author=\"" & au & "\" date=\"" & d & "\"}"
          of '=': result.add orgCiteToPandoc(inner)                        # highlight: keep the text
          of '~':
            let (au, body) = peelAuthor(inner, a)
            let arrow = body.find("~>")
            if arrow >= 0:
              result.add "[" & orgCiteToPandoc(body[0 ..< arrow]) & "]{.deletion author=\"" & au & "\" date=\"" & d & "\"}"
              result.add "[" & orgCiteToPandoc(body[arrow+2 .. ^1]) & "]{.insertion author=\"" & au & "\" date=\"" & d & "\"}"
            else:
              result.add "[" & orgCiteToPandoc(body) & "]{.insertion author=\"" & au & "\" date=\"" & d & "\"}"
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

proc spanAuthor(attrs: string): string =
  ## The `author="..."` value from a pandoc span's attribute string, or "".
  let ai = attrs.find("author=\"")
  if ai < 0: return ""
  let s = ai + 8
  let en = attrs.find('"', s)
  if en > s: attrs[s ..< en] else: ""

proc attrOf(attrs, name: string): string =
  ## Value of `name="..."' in a pandoc span attribute string, or "".
  let i = attrs.find(name & "=\"")
  if i < 0: return ""
  let b = i + name.len + 2
  let e = attrs.find('"', b)
  if e > b: attrs[b ..< e] else: ""

proc downgradeHeadings(s: string): string =
  ## pandoc's docx reader misclassifies a heading-styled lead paragraph as
  ## `# <300-char prose>' (e.g. the Abstract opener), which would become a
  ## section heading on md->org and eat the body. A genuine heading is short:
  ## strip the span syntax and if > 80 chars of prose remain, drop the `# '.
  var lines: seq[string]
  for ln0 in s.splitLines():
    var ln = ln0
    if ln.startsWith("# "):
      var t = ln[2 ..^ 1]
      var outp = ""
      var i = 0
      while i < t.len:                      # rough span removal: `]{.attr...}'
        if startsWithAt(t, i, "]{."):
          let b = t.find('}', i)
          if b > 0: i = b + 1; continue
        outp.add t[i]; inc i
      if outp.replace("[", "").strip.len > 80: ln = ln[2 ..^ 1]
    lines.add ln
  lines.join("\n")

proc rewriteCommentPairs(s: string): string =
  ## `[CTEXT]{.comment-start id="N" author="A" ...}BODY[]{.comment-end id="N"}'
  ## -> `{==CTEXT==}{>>[A] BODY<<}'. CTEXT may itself contain `]' (a comment
  ## quoting a citation), so find the fixed closing tag first, then scan
  ## backward by bracket depth for its true matching `[` -- a `[^]]*' forward
  ## search stops at CTEXT's own first `]' and silently drops the comment.
  var s = s
  while true:
    let cs = s.find("]{.comment-start")
    if cs < 0: break
    let braceEnd = s.find('}', cs)
    if braceEnd < 0: break
    let attrs = s[cs + 1 ..< braceEnd]
    let cid = attrOf(attrs, "id")
    let author = attrOf(attrs, "author")
    var depth = 1
    var p = cs - 1
    var open = -1
    while p >= 0 and depth > 0:
      if s[p] == ']': inc depth
      elif s[p] == '[':
        dec depth
        if depth == 0: open = p
      dec p
    let ctext = if open >= 0: s[open + 1 ..< cs] else: ""
    let endTok = "[]{.comment-end id=\"" & cid & "\"}"
    let endPos = s.find(endTok, braceEnd + 1)
    if endPos < 0:
      # orphan start marker: unwrap the anchor, keep the text, drop the span
      if open >= 0:
        s = s[0 ..< open] & ctext & s[braceEnd + 1 ..^ 1]
      else:
        s = s[0 ..< cs] & s[braceEnd + 1 ..^ 1]
      continue
    let body = s[braceEnd + 1 ..< endPos]
    let repl =
      (if ctext.len > 0: "{==" & ctext & "==}" else: "") &
      "{>>" & (if author.len > 0: "[" & author & "] " else: "") & body & "<<}"
    s = s[0 ..< open] & repl & s[endPos + endTok.len ..^ 1]
  s

proc mergeSubstitutions(s: string): string =
  ## Adjacent `{--old--}{++new++}' (no nested braces inside) -> `{~~old~>new~~}'.
  result = ""
  var i = 0
  while i < s.len:
    if startsWithAt(s, i, "{--"):
      let e = s.find("--}", i)
      if e > i + 3:
        let old = s[i + 3 ..< e]
        if '{' notin old and '}' notin old:
          var k = e + 3
          while k < s.len and s[k] in {' ', '\t', '\n'}: inc k
          if startsWithAt(s, k, "{++"):
            let e2 = s.find("++}", k)
            if e2 > k + 3:
              let new = s[k + 3 ..< e2]
              if '{' notin new and '}' notin new:
                result.add "{~~" & old & "~>" & new & "~~}"
                i = e2 + 3
                continue
    result.add s[i]; inc i

proc stripAnchorSpans(s: string): string =
  ## `[]{#id .anchor}' -> `[]{#id}': pandoc's org writer drops a Span with a
  ## class but keeps one with just an id (as `<<NAME>>'), which round-trips
  ## back to a Word bookmark so in-text `[[#citeproc_bib_item_N][N]]'
  ## hyperlinks still resolve.
  result = ""
  var i = 0
  while i < s.len:
    if startsWithAt(s, i, "[]{#"):
      let b = s.find('}', i)
      if b > 0:
        let inner = s[i + 4 ..< b]
        if inner.endsWith(" .anchor"):
          result.add "[]{#" & inner[0 ..< inner.len - 8] & "}"
          i = b + 1
          continue
    result.add s[i]; inc i

proc rewriteChangeSpans(md: string): string =
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
          of "insertion":
            let au = spanAuthor(attrs)   # keep per-coauthor authorship for re-export
            wrapped = (if au.len > 0: "{++[" & au & "]" & inner & "++}" else: "{++" & inner & "++}")
          of "deletion":
            let au = spanAuthor(attrs)
            wrapped = (if au.len > 0: "{--[" & au & "]" & inner & "--}" else: "{--" & inner & "--}")
          of "mark": wrapped = "{==" & inner & "==}"
          else: wrapped = ""    # unknown class: drop the span, keep the text
          # replace result[p+1..] : rebuild -- we appended md up to p already?
          # (handled below by rewriting; see note)
          if wrapped.len > 0 or cls notin ["insertion", "deletion", "mark"]:
            # trim what we already emitted back to the open bracket, then wrap
            result.setLen(result.len - (i - (p + 1)) - 1)   # drop inner + '['
            if wrapped.len > 0: result.add wrapped
            else: result.add inner
            i = braceEnd + 1
            continue
    result.add md[i]; inc i

proc spansToCritic*(md: string): string =
  ## pandoc markdown track-change/comment spans -> CriticMarkup (docx -> md),
  ## the same passes as org-tracked-docx.el's otd--rewrite-spans: downgrade
  ## misclassified ATX headings, pair comment-start/end into `{==..==}{>>..<<}',
  ## wrap insertion/deletion/mark spans, merge adjacent del+ins into a
  ## substitution, strip `.anchor' classes.
  var s = downgradeHeadings(md)
  s = rewriteCommentPairs(s)
  s = rewriteChangeSpans(s)
  s = mergeSubstitutions(s)
  stripAnchorSpans(s)

proc stash*(s: string; tokens: var seq[string]): string =
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

proc unstash*(s: string; tokens: seq[string]): string =
  result = s
  for idx, tok in tokens:
    result = result.replace("zZoTdZz" & $idx & "zZ", tok)

proc isBlockSyntax(t: string): bool =
  ## Text that org would read as a block on its own (headline, list item, table
  ## row, keyword, fixed-width line, drawer) -- not an inline fragment.
  if t.len == 0: return false
  if t.startsWith("* ") or t.startsWith("- ") or t.startsWith("+ ") or
     t.startsWith("|") or t.startsWith("#+") or t.startsWith(": ") or
     (t.startsWith(":") and t.endsWith(":")) or t.startsWith("-----"):
    return true
  var i = 0
  while i < t.len and t[i] in Digits: inc i
  i > 0 and i + 1 < t.len and t[i] in {'.', ')'} and t[i + 1] == ' '

proc convertCriticTokens(tokens: var seq[string]; options: seq[string]) =
  ## The text INSIDE CriticMarkup skips the main org->md pass (it is stashed so
  ## pandoc can't mangle the markup), so org syntax in it -- inline LaTeX \(..\),
  ## sub/superscripts x_{1}, *bold*, /italic/, =code=, links -- would reach the
  ## markdown->docx reader raw. Convert every insertion / deletion / substitution
  ## side / highlight to markdown here, all in ONE pandoc call (fragments joined
  ## by sentinel paragraphs). Comments are left alone (their "[Author]" prefix
  ## must survive; Word comments are plain). Leading/trailing spaces are kept;
  ## multi-paragraph or block-like fragments stay raw, as before.
  type Frag = tuple[tok, part: int; lead, trail, text: string]
  var frags: seq[Frag]
  var parts = newSeq[seq[string]](tokens.len)
  for ti, tok in tokens:
    if tok.len < 6: continue
    let kind = tok[0 .. 2]
    let inner = tok[3 ..< tok.len - 3]
    case kind
    of "{++", "{--", "{==": parts[ti] = @[inner]
    of "{~~":
      let arrow = inner.find("~>")
      parts[ti] = if arrow >= 0: @[inner[0 ..< arrow], inner[arrow + 2 .. ^1]] else: @[inner]
    else: continue                                   # {>> comments <<}: untouched
    for pi, p in parts[ti]:
      let t = p.strip()
      if t.len == 0 or "\n\n" in p or isBlockSyntax(t): continue
      let lead = p[0 ..< p.len - p.strip(leading = true, trailing = false).len]
      let trail = p[p.strip(leading = false, trailing = true).len .. ^1]
      frags.add (ti, pi, lead, trail, t)
  if frags.len == 0: return
  let src = getTempDir() / "otd-fragments.org"
  let dst = getTempDir() / "otd-fragments.md"
  proc convert(lo, hi: int) =
    ## Convert frags[lo ..< hi] in one pandoc call. pandoc's org reader can
    ## reject a whole document over one odd fragment (e.g. a stray `\*`), so on
    ## failure split the batch and retry the halves: a bad fragment only costs
    ## itself (it stays raw, as before), at a few extra calls.
    if hi <= lo: return
    var doc = options.join("\n") & "\n\n"
    for k in lo ..< hi: doc.add "WKBFRAG" & $k & "X\n\n" & frags[k].text & "\n\n"
    doc.add "WKBFRAG" & $hi & "X\n"
    writeFile(src, doc)
    let (code, _) = pandoc(@["-f", "org", "-t", "markdown", "--wrap=none", src, "-o", dst])
    if code != 0:
      if hi - lo > 1:
        let mid = (lo + hi) div 2
        convert(lo, mid)
        convert(mid, hi)
      return
    let md = readFile(dst)
    for k in lo ..< hi:
      let a = md.find("WKBFRAG" & $k & "X")
      let b = md.find("WKBFRAG" & $(k + 1) & "X")
      if a < 0 or b < 0 or b < a: continue
      let conv = md[a + ("WKBFRAG" & $k & "X").len ..< b].strip()
      if conv.len == 0 or "\n\n" in conv: continue  # not a single inline paragraph
      parts[frags[k].tok][frags[k].part] = frags[k].lead & conv & frags[k].trail
  convert(0, frags.len)
  for ti, ps in parts:
    if ps.len == 0: continue
    let kind = tokens[ti][0 .. 2]
    let close = tokens[ti][^3 .. ^1]
    tokens[ti] = kind & (if ps.len == 2: ps[0] & "~>" & ps[1] else: ps[0]) & close

# ---- embedded canonical org source (round-trip recovery) -------------------
# Port of org-tracked-docx's customXml embed/extract: the .org that generated
# the docx is stored inside it, so re-import can recover cite keys, cross-refs,
# and #+header syntax that citeproc / pandoc-crossref render away.

const
  cxItemName  = "item-otd-source.xml"
  cxItemProps = "itemProps-otd-source.xml"
  cxNamespace = "urn:org-tracked-docx:source"
  cxPropName  = "OrgTrackedSource"   ## docProps/custom.xml property (survives Word/WPS/OneDrive saves)
  cxPropFmtId = "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}"

proc cdataUnescape(s: string): string =
  s.replace("]]]]><![CDATA[>", "]]>")

proc cdataEscape(s: string): string =
  "<![CDATA[" & s.replace("]]>", "]]]]><![CDATA[>") & "]]>"

proc nextRelId(rel: string): int =
  ## One past the highest rIdN in a relationships part.
  var i = 0
  while true:
    let p = rel.find("Id=\"rId", i)
    if p < 0: break
    var j = p + 7
    var num = ""
    while j < rel.len and rel[j] in {'0'..'9'}: num.add rel[j]; inc j
    if num.len > 0: result = max(result, parseInt(num))
    i = j + 1
  inc result

proc stripOrgProperty(cx: string): string =
  ## Drop a stale <property ... name="OrgTrackedSource" ...>...</property> so a
  ## re-embed does not leave two copies of the source.
  result = cx
  while true:
    let n = result.find("name=\"" & cxPropName & "\"")
    if n < 0: break
    let ps = result.rfind("<property", 0, n)
    let pe = result.find("</property>", n)
    if ps < 0 or pe < 0: break
    result = result[0 ..< ps] & result[pe + "</property>".len .. ^1]

proc nextPid(cx: string): int =
  ## One past the highest pid="N" (ECMA-376 custom properties start at pid 2).
  result = 1
  var i = 0
  while true:
    let p = cx.find("pid=\"", i)
    if p < 0: break
    var j = p + 5
    var num = ""
    while j < cx.len and cx[j] in {'0'..'9'}: num.add cx[j]; inc j
    if num.len > 0: result = max(result, parseInt(num))
    i = j + 1
  inc result

proc embedOrgSource*(docx, orgContent: string): bool =
  ## Embed ORGCONTENT inside DOCX as a customXml part (registered in
  ## [Content_Types].xml and word/_rels/document.xml.rels) so Word / LibreOffice
  ## preserve it across saves and tracked edits, and re-import can recover cite
  ## keys / cross-refs / #+headers. Rewrites the package with vendored zippy
  ## (pure Nim): [Content_Types].xml first, NO directory entries -- a conformant
  ## OPC docx Word accepts (unlike a shell `zip -r`, which reorders parts and
  ## injects directory entries, making Word flag the file read-only). Returns
  ## true on success.
  let docxAbs = absolutePath(docx)
  if not fileExists(docxAbs): return false
  try:
    var entries: OrderedTable[string, string]
    block:
      let reader = openZipArchive(docxAbs)
      defer: reader.close()
      for path in reader.walkFiles: entries[path] = reader.extractFile(path)
    if "[Content_Types].xml" notin entries or
       "word/_rels/document.xml.rels" notin entries: return false

    entries["customXml/" & cxItemName] =
      "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
      "<orgTrackedSource xmlns=\"" & cxNamespace & "\">" &
      cdataEscape(orgContent) & "</orgTrackedSource>\n"
    entries["customXml/" & cxItemProps] =
      "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
      "<ds:datastoreItem ds:itemID=\"{ORG-TRACKED-DOCX-SOURCE}\"" &
      " xmlns:ds=\"http://schemas.openxmlformats.org/officeDocument/2006/customXml\">" &
      "<ds:schemaRefs><ds:schemaRef ds:uri=\"" & cxNamespace & "\"/></ds:schemaRefs>" &
      "</ds:datastoreItem>\n"
    entries["customXml/_rels/" & cxItemName & ".rels"] =
      "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
      "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" &
      "<Relationship Id=\"rId1\"" &
      " Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXmlProps\"" &
      " Target=\"" & cxItemProps & "\"/></Relationships>\n"

    var rel = entries["word/_rels/document.xml.rels"]
    if ("customXml/" & cxItemName) notin rel:
      rel = rel.replace("</Relationships>",
        "<Relationship Id=\"rId" & $nextRelId(rel) & "\"" &
        " Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml\"" &
        " Target=\"../customXml/" & cxItemName & "\"/></Relationships>")
      entries["word/_rels/document.xml.rels"] = rel

    # Second, embed the same org as a docProps/custom.xml <OrgTrackedSource>
    # custom property (base64). Word / OneDrive silently STRIP the customXml/
    # part when a coauthor re-saves the file, so the returned review docx would
    # otherwise carry no embedded source and import would fall back to a lossy
    # body-only reconstruction (this is exactly why Chandra's returned cr.docx
    # imported without its frontmatter). Document custom properties survive those
    # saves, so this is the fallback that lets a coauthor round-trip recover the
    # full org. Port of otd--embed-custom-property.
    block:
      let b64 = base64.encode(orgContent)
      var cx = entries.getOrDefault("docProps/custom.xml", "")
      if cx.len == 0:
        cx = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
             "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties\"" &
             " xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"></Properties>\n"
        if "_rels/.rels" in entries:
          var rr = entries["_rels/.rels"]
          if "docProps/custom.xml" notin rr:
            rr = rr.replace("</Relationships>",
              "<Relationship Id=\"rId" & $nextRelId(rr) & "\"" &
              " Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties\"" &
              " Target=\"docProps/custom.xml\"/></Relationships>")
            entries["_rels/.rels"] = rr
        var ct0 = entries["[Content_Types].xml"]
        if "/docProps/custom.xml" notin ct0:
          ct0 = ct0.replace("</Types>",
            "<Override PartName=\"/docProps/custom.xml\"" &
            " ContentType=\"application/vnd.openxmlformats-officedocument.custom-properties+xml\"/></Types>")
          entries["[Content_Types].xml"] = ct0
      # pandoc emits an empty, self-closing <Properties .../> (no close tag);
      # open it up so the property can be inserted before </Properties>.
      if "</Properties>" notin cx:
        let pe = cx.rfind("/>")
        if pe >= 0: cx = cx[0 ..< pe] & "></Properties>" & cx[pe+2 .. ^1]
      cx = stripOrgProperty(cx)
      cx = cx.replace("</Properties>",
        "<property fmtid=\"" & cxPropFmtId & "\" pid=\"" & $nextPid(cx) & "\" name=\"" &
        cxPropName & "\"><vt:lpwstr>" & b64 & "</vt:lpwstr></property></Properties>")
      entries["docProps/custom.xml"] = cx

    # [Content_Types].xml must be the FIRST archive entry; zippy emits entries in
    # reverse insertion order, so patch it and re-insert it LAST.
    var ct = entries["[Content_Types].xml"]
    if ("customXml/" & cxItemName) notin ct:
      ct = ct.replace("</Types>",
        "<Override PartName=\"/customXml/" & cxItemName &
        "\" ContentType=\"application/xml\"/>" &
        "<Override PartName=\"/customXml/" & cxItemProps &
        "\" ContentType=\"application/vnd.openxmlformats-officedocument.customXmlProperties+xml\"/></Types>")
    entries.del("[Content_Types].xml")
    entries["[Content_Types].xml"] = ct

    writeFile(docxAbs, createZipArchive(entries))
    result = true
  except CatchableError:
    result = false

proc propagateSectionChrome*(docx: string): bool =
  ## pandoc's --reference-doc attaches the header/footer references (running
  ## heads, the PAGE-field page numbers) only to the document's final <w:sectPr>,
  ## the one it derives from the reference doc. Any *inline* <w:sectPr> the source
  ## injected as raw OOXML (e.g. a landscape break around a figure, or a portrait
  ## reset) is self-contained, so it silently drops those references and page
  ## numbering vanishes from every section but the last. Copy the final section's
  ## <w:headerReference>/<w:footerReference> tags into each earlier sectPr that
  ## lacks them, reusing the relationships pandoc already created (they are
  ## document-scoped, so sharing one footer part across sections is valid).
  ## Returns true if the document was changed.
  let docxAbs = absolutePath(docx)
  if not fileExists(docxAbs): return false
  try:
    var entries: OrderedTable[string, string]
    block:
      let reader = openZipArchive(docxAbs)
      defer: reader.close()
      for path in reader.walkFiles: entries[path] = reader.extractFile(path)
    if "word/document.xml" notin entries: return false
    var doc = entries["word/document.xml"]

    var sects: seq[Slice[int]]
    var i = 0
    while true:
      let a = doc.find("<w:sectPr", i)
      if a < 0: break
      let b = doc.find("</w:sectPr>", a)
      if b < 0: break
      sects.add a .. (b + "</w:sectPr>".len - 1)
      i = b + 1
    if sects.len < 2: return false        # only the body section: nothing to fix

    proc refTags(sect: string): string =
      ## the self-closing <w:headerReference/>/<w:footerReference/> tags, headers
      ## first (schema order within EG_HdrFtrReferences).
      for tag in ["w:headerReference", "w:footerReference"]:
        var j = 0
        while true:
          let p = sect.find("<" & tag, j)
          if p < 0: break
          let e = sect.find("/>", p)
          if e < 0: break
          result.add sect[p .. e + 1]
          j = e + 2

    let chrome = refTags(doc[sects[^1]])
    if chrome.len == 0: return false      # reference doc carried no header/footer

    var changed = false
    for k in countdown(sects.len - 2, 0):  # last-first: keep earlier offsets valid
      let s = doc[sects[k]]
      if "w:headerReference" in s or "w:footerReference" in s: continue
      let openEnd = doc.find(">", sects[k].a)   # end of the "<w:sectPr ...>" tag
      if openEnd < 0 or openEnd >= sects[k].b: continue
      doc = doc[0 .. openEnd] & chrome & doc[openEnd + 1 .. ^1]
      changed = true
    if not changed: return false

    entries["word/document.xml"] = doc
    # [Content_Types].xml must stay the first archive entry (see embedOrgSource).
    if "[Content_Types].xml" in entries:
      let ct = entries["[Content_Types].xml"]
      entries.del("[Content_Types].xml")
      entries["[Content_Types].xml"] = ct
    writeFile(docxAbs, createZipArchive(entries))
    result = true
  except CatchableError:
    result = false

proc extractOrgSourceProperty(docx: string): string =
  ## Recover the embedded org from the docProps/custom.xml <OrgTrackedSource>
  ## property -- the fallback used when Word/OneDrive stripped the customXml/
  ## part on save. Port of otd--extract-org-source-property; CRLF/CR -> LF.
  let unzipExe = findExe("unzip")
  if unzipExe.len == 0 or not fileExists(docx): return ""
  let (content, cc) = execCmdEx(quoteShell(unzipExe) & " -p " &
                                quoteShell(docx) & " docProps/custom.xml")
  if cc != 0: return ""
  let ni = content.find("name=\"" & cxPropName & "\"")
  if ni < 0: return ""
  let vs = content.find("<vt:lpwstr>", ni)
  if vs < 0: return ""
  let payStart = vs + "<vt:lpwstr>".len
  let ve = content.find("</vt:lpwstr>", payStart)
  if ve < 0: return ""
  let b64 = content[payStart ..< ve].strip()
  if b64.len == 0: return ""
  try:
    result = base64.decode(b64).replace("\r\n", "\n").replace("\r", "\n")
  except CatchableError:
    result = ""

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
  extractOrgSourceProperty(docx)   # customXml stripped by Word? try docProps.

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

proc parseUnits*(text: string): seq[Unit] =
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
    elif t.startsWith("|"):
      # Tables are structural: a contiguous run of `|` lines passes through
      # from the canonical verbatim -- tracked table rows (mangled by the
      # docx->org conversion) never replace or halve a canonical table.
      flush(result); result.add (ukStruct, line)
    elif t.len == 0 or t.startsWith("#+") or isHeading(t):
      flush(result); result.add (ukStruct, line)
    else:
      cur.add line
  flush(result)

proc bodyParas*(units: seq[Unit]): seq[string] =
  for u in units:
    if u.kind == ukBody: result.add u.text

# ---- hardened merge (port of org-tracked-docx.el's merge core) --------------

const XrefWords = ["figure", "fig.", "section", "sec.", "equation", "eq.",
                   "table", "tbl.", "listing", "lst."]

proc collapseCites*(s: string): string =
  ## Every citation / cross-ref rendering -> the fixed token [CITE]: citeproc
  ## anchors `[[#citeproc_bib_item_N][N]]', org-cite `[[cite...]]', `[cite:...]',
  ## `[@key]', numeric superscripts `^{N}', and cross-refs -- anchored
  ## (`sec. [[#sec:foo][2]]') or rendered (`Figure 3'), each with an optional
  ## fig./Section/... prefix word. Hand-rolled: std/re is impure (PCRE) and
  ## this binary deliberately carries no external C deps.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '[':
      if startsWithAt(s, i, "[[#citeproc_bib_item_"):
        let e = s.find("]]", i)
        if e > 0: result.add "[CITE]"; i = e + 2; continue
      elif startsWithAt(s, i, "[[cite"):
        let e = s.find("]]", i)
        if e > 0: result.add "[CITE]"; i = e + 2; continue
      elif startsWithAt(s, i, "[cite:"):
        let e = s.find(']', i)
        if e > 0: result.add "[CITE]"; i = e + 1; continue
      elif startsWithAt(s, i, "[@"):
        let e = s.find(']', i)
        if e > i + 2 and
           s[i + 2 ..< e].allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', ';', ',', '@', '-', ' '}):
          result.add "[CITE]"; i = e + 1; continue
    elif s[i] == '^' and i + 1 < s.len and s[i + 1] == '{':
      var k = i + 2
      while k < s.len and s[k] in {'0'..'9', ',', '-', ' '}: inc k
      if k < s.len and s[k] == '}' and k > i + 2 and s[i + 2].isDigit:
        result.add "[CITE]"; i = k + 1; continue
    else:
      var plen = 0
      for w in XrefWords:
        if eqIgnoreCaseAt(s, i, w) and (i == 0 or not s[i - 1].isAlphaNumeric):
          plen = w.len; break
      if plen > 0:
        var k = i + plen
        while k < s.len and isWsC(s[k]): inc k
        if startsWithAt(s, k, "[[#"):
          let e = s.find("]]", k)
          if e > 0: result.add "[CITE]"; i = e + 2; continue
        var d = k
        while d < s.len and s[d].isDigit: inc d
        if d > k and (d >= s.len or not s[d].isAlphaNumeric):
          result.add "[CITE]"; i = d; continue
    result.add s[i]
    inc i

proc normalizeForMatch*(text: string): string =
  ## Fingerprint for paragraph alignment: CriticMarkup accepted away, every
  ## citation AND cross-ref rendering (citeproc anchor, org-cite, `[@key]',
  ## numeric superscript, `Figure N') collapsed to a fixed [CITE] token,
  ## whitespace collapsed -- so the tracked docx's rendered forms match the
  ## canonical's `[cite:@key]' paragraphs exactly.
  var s = nbspToSpace(applyCriticMarkup(text, accept = true))
  s = collapseCites(s)
  result = ""
  var prevWs = false
  for c in s:
    if isWsC(c):
      if not prevWs: result.add ' '
      prevWs = true
    else:
      result.add c; prevWs = false
  result = result.strip()

proc restoreCiteForms*(s: string): string =
  ## `[[cite/t:@key]]' / `[[cite:@key]]' -> `[cite:@key]'; `[@key]' ->
  ## `[cite:@key]' -- the pandoc-org reconstruction forms.
  result = ""
  var i = 0
  while i < s.len:
    if startsWithAt(s, i, "[[cite"):
      let e = s.find("]]", i)
      if e > 0:
        let inner = s[i + 6 ..< e]           # `cite/t:@key' / `cite:@key'
        let c = inner.find(':')
        if c > 0:
          result.add "[cite:" & inner[c + 1 ..^ 1] & "]"
          i = e + 2
          continue
    elif startsWithAt(s, i, "[@"):
      let e = s.find(']', i)
      if e > i + 2:
        result.add "[cite:" & s[i ..< e] & "]"
        i = e + 1
        continue
    result.add s[i]
    inc i

proc buildCiteMap*(orgContent: string): seq[tuple[key: string; n: int]] =
  ## `[cite:@a;@b]' entries (multi-key aware) in first-occurrence order ->
  ## (key, N), mirroring citeproc's numbering: a key cited again keeps its
  ## first number (citeproc does not renumber duplicates).
  var n = 0
  var i = 0
  while true:
    let s = orgContent.find("[cite:", i)
    if s < 0: break
    let e = orgContent.find(']', s)
    if e < 0: break
    for part in orgContent[s + 6 ..< e].split(';'):
      let k = part.strip
      if k.len == 0: continue
      let key = if k.startsWith("@"): k[1 ..^ 1] else: k
      var known = false
      for (k0, _) in result:
        if k0 == key: known = true; break
      if known: continue
      inc n
      result.add (key, n)
    i = e + 1

proc bibTitleOf(entry: string): string =
  ## The `title = {...}' field of a BibTeX entry (case-insensitive), or "".
  let low = entry.toLowerAscii
  var i = 0
  while true:
    i = low.find("title", i)
    if i < 0: return ""
    var j = i + 5
    while j < entry.len and entry[j] in {' ', '\t', '\n'}: inc j
    if j < entry.len and entry[j] == '=':
      inc j
      while j < entry.len and entry[j] in {' ', '\t', '\n'}: inc j
      if j < entry.len and entry[j] == '{':
        var depth = 1
        var k = j + 1
        var buf = ""
        while k < entry.len and depth > 0:
          if entry[k] == '{': inc depth
          elif entry[k] == '}':
            dec depth
            if depth == 0: break
          buf.add entry[k]; inc k
        return buf
    i += 5

proc parseBibEntries*(text: string): seq[tuple[key, title: string]] =
  ## `@type{key, ...}' BibTeX entries -> (key, title).
  var i = text.find('@')
  while i >= 0:
    let nxt = text.find('@', i + 1)
    let entryEnd = if nxt < 0: text.len else: nxt
    let lb = text.find('{', i)
    let comma = if lb >= 0: text.find(',', lb) else: -1
    if lb >= 0 and comma > lb and comma < entryEnd:
      let key = text[lb + 1 ..< comma].strip
      if key.len > 0:
        result.add (key, bibTitleOf(text[i ..< entryEnd]))
    i = nxt

proc parseDocxBib(tracked: string): Table[int, string] =
  ## The docx's rendered References list from the tracked text: number ->
  ## reference text. Starts after a `* ... References' heading; entries are
  ## `N text...' (or `N. text') lines.
  var inRefs = false
  for ln in tracked.splitLines():
    let t = ln.strip
    if isHeading(t):
      if inRefs: break
      if t.toLowerAscii.contains("references"): inRefs = true
      continue
    if not inRefs or t.len == 0: continue
    var i = 0
    while i < t.len and t[i].isDigit: inc i
    if i == 0 or i >= t.len: continue
    var j = i
    if t[j] == '.': inc j
    if j < t.len and t[j] == ' ' and i <= 3:
      try: result[parseInt(t[0 ..< i])] = t[j + 1 ..^ 1]
      except ValueError: discard

proc matchRefToKey(refText: string;
                   bibs: seq[tuple[key, title: string]]): string =
  ## The .bib key whose TITLE best matches the rendered reference text
  ## (distinctive >=5-letter title words present in the ref), or "" when
  ## nothing clears the bar -- an unmatched number stays visible as `^{N}'.
  let low = refText.toLowerAscii
  var best = ""
  var bestScore = 0.0
  for (key, title) in bibs:
    if title.len == 0: continue
    var words: seq[string]
    var w = ""
    for ch in title:
      if ch.isAlphaNumeric: w.add ch.toLowerAscii
      else:
        if w.len >= 5: words.add w
        w = ""
    if w.len >= 5: words.add w
    if words.len == 0: continue
    var hit = 0
    for w in words:
      if low.contains(w): inc hit
    let score = hit.float / words.len.float
    if score > bestScore: bestScore = score; best = key
  if bestScore >= 0.6: best else: ""

proc buildDocxNumMap*(tracked: string; bibPaths: seq[string]): Table[string, string] =
  ## The docx's OWN bibliography numbers -> .bib keys, by matching each
  ## rendered reference against the .bib titles. This is the ground truth for
  ## numeric back-substitution: the numbers in the tracked text refer to the
  ## docx's bibliography, which can differ from the canonical's current
  ## `[cite:]' order when the canonical drifted since the export -- mapping
  ## through the canonical would silently hand back wrong keys.
  let refs = parseDocxBib(tracked)
  if refs.len == 0: return
  var bibs: seq[tuple[key, title: string]]
  for p in bibPaths:
    if not fileExists(p): continue
    try: bibs.add parseBibEntries(readFile(p))
    except CatchableError: discard
  if bibs.len == 0: return
  for n, refText in refs.pairs:
    let key = matchRefToKey(refText, bibs)
    if key.len > 0: result[$n] = key

proc parseCiteNums(inner: string; n2key: Table[string, string]): seq[string] =
  ## `9,10' / `5--7' / `1,2,5--7' -> @["@key9", ...] via the reverse map;
  ## @[] when anything doesn't resolve (the caller leaves such text alone).
  for part in inner.split(','):
    let p = part.strip
    let dd = p.find("--")
    if dd > 0:
      try:
        let a = parseInt(p[0 ..< dd])
        let b = parseInt(p[dd + 2 ..^ 1])
        if b < a or b - a > 50: return @[]
        for x in a .. b:
          if n2key.hasKey($x): result.add "@" & n2key[$x]
          else: return @[]
      except ValueError: return @[]
    elif p.len > 0 and p.allCharsInSet(Digits):
      if n2key.hasKey(p): result.add "@" & n2key[p]
      else: return @[]
    else: return @[]

proc substituteCiteKeys*(text: string; num2key: Table[string, string]): string =
  ## Rewrite every lossy citation form in TEXT back to canonical `[cite:@key]':
  ## citeproc anchors, pandoc-org reconstruction, bare `[@key]', and the
  ## Vancouver-style numeric superscripts citeproc renders for numbered styles
  ## (`^{N}', `^{N,M}', `^{N--M}', mixed) -- without which every cite collapses
  ## to a bare number and the next export ships `1.', `2.' with no keys. All
  ## numeric forms resolve through NUM2KEY (the docx's own bibliography numbers
  ## matched to .bib keys); a number that doesn't resolve stays visible as-is.
  var s = text
  for n, k in num2key:                    # citeproc anchors: [[#citeproc_bib_item_N][N]]
    s = s.replace("[[#citeproc_bib_item_" & n & "][" & n & "]]",
                  "[cite:@" & k & "]")
  s = restoreCiteForms(s)
  let n2key = num2key
  # numeric superscripts -> [cite:@k1;@k2...] (ranges expanded). Two forms:
  # org `^{9,10}' (pandoc converted it) and markdown `^9,10^' -- CriticMarkup
  # tokens are stashed as sentinels through the md->org pass, so text inside
  # {++/--/~~} keeps the markdown form.
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '^' and i + 1 < s.len:
      var keys: seq[string]
      var after = -1
      if s[i + 1] == '{':                       # org form: ^{9,10}
        let e = s.find('}', i)
        if e > i + 2:
          keys = parseCiteNums(s[i + 2 ..< e], n2key)
          after = e + 1
      else:                                     # markdown form: ^9,10^
        var e = i + 1
        while e < s.len and s[e] in {'0'..'9', ',', '-', ' '}: inc e
        if e > i + 1 and e < s.len and s[e] == '^':
          keys = parseCiteNums(s[i + 1 ..< e], n2key)
          after = e + 1
      if keys.len > 0:
        result.add "[cite:" & keys.join(";") & "]"
        i = after
        continue
    result.add s[i]
    inc i

type XrefMap* = Table[string, seq[tuple[label: string; n: int]]]

proc buildXrefMap*(canonical: string): XrefMap =
  ## pandoc-crossref targets in document order: `#+NAME: fig:LABEL' / tbl: /
  ## lst:, `:CUSTOM_ID: sec:LABEL', `{#eq:LABEL}' -> per-type (label, N), the
  ## number pandoc-crossref assigns at export. Used to rewrite `Figure 1' /
  ## `Table 2' in tracked text back to `[cite:@fig:LABEL]' during merge.
  var counts = initCountTable[string]()
  for ln in canonical.splitLines():
    let t = nbspToSpace(ln).strip
    let low = t.toLowerAscii
    if low.startsWith("#+name:"):
      let rest = t[7 ..^ 1].strip
      let c = rest.find(':')
      if c > 0:
        let typ = rest[0 ..< c].toLowerAscii
        if (typ == "fig" or typ == "tbl" or typ == "lst") and rest[c + 1 ..^ 1].len > 0:
          counts.inc(typ)
          result.mgetOrPut(typ, @[]).add (rest[c + 1 ..^ 1], counts[typ])
    elif low.startsWith(":custom_id:"):
      let rest = t[11 ..^ 1].strip
      if rest.toLowerAscii.startsWith("sec:") and rest[4 ..^ 1].len > 0:
        counts.inc("sec")
        result.mgetOrPut("sec", @[]).add (rest[4 ..^ 1], counts["sec"])
    else:
      var i = 0                        # `{#eq:label}' anywhere in the line
      while true:
        let s = t.find("{#eq:", i)
        if s < 0: break
        let e = t.find('}', s)
        if e < 0: break
        counts.inc("eq")
        result.mgetOrPut("eq", @[]).add (t[s + 5 ..< e], counts["eq"])
        i = e + 1

proc replaceRenderedXref(s, word: string; n: int; repl: string): string =
  ## Case-insensitive `word [spaces] N' with word boundaries on both sides
  ## -> `repl'. (`Figure 3', `fig. 3', `Section 2', `tbl. 1', ...)
  let num = $n
  result = ""
  var i = 0
  while i < s.len:
    if eqIgnoreCaseAt(s, i, word) and (i == 0 or not s[i - 1].isAlphaNumeric):
      var k = i + word.len
      while k < s.len and s[k] == ' ': inc k
      if startsWithAt(s, k, num) and
         (k + num.len >= s.len or not s[k + num.len].isAlphaNumeric):
        result.add repl
        i = k + num.len
        continue
    result.add s[i]
    inc i

proc substituteXrefs*(text: string; xrefMap: XrefMap): string =
  ## Rewrite rendered cross-refs in TEXT back to canonical `[cite:@TYPE:LABEL]'.
  ## Anchored form first (`sec. [[#sec:foo][2]]' carries the label itself), then
  ## rendered `Figure N' / `fig. N' / `Section N' / ... via the map, with either
  ## a space or an NBSP before the number (pandoc-crossref's default template).
  var s = nbspToSpace(text)
  block anchored:                      # `[[#fig:foo][2]]' -> `[cite:@fig:foo]'
    var outp = ""
    var i = 0
    while i < s.len:
      if startsWithAt(s, i, "[[#"):
        let e = s.find("]]", i)
        if e > 0:
          let inner = s[i + 3 ..< e]     # `fig:foo][2'
          let br = inner.find("][")
          if br > 0:
            outp.add "[cite:@" & inner[0 ..< br] & "]"
            i = e + 2
            continue
      outp.add s[i]; inc i
    s = outp
  const words = {"fig": ["figure", "fig."], "sec": ["section", "sec."],
                 "eq": ["equation", "eq."], "tbl": ["table", "tbl."],
                 "lst": ["listing", "lst."]}.toTable
  for typ, entries in xrefMap.pairs:
    if not words.hasKey(typ): continue
    for (label, n) in entries:
      for w in words[typ]:
        s = replaceRenderedXref(s, w, n, "[cite:@" & typ & ":" & label & "]")
  s

proc fpEq(a, b: string): bool =
  ## Prefix-equality on normalized fingerprints: the first min(40, len) chars
  ## agree (>= 8). 40 chars is enough prose to be unique across a manuscript's
  ## body paragraphs yet tolerates small accepted edits -- a coauthor who
  ## ACCEPTED changes in Word strips the w:ins/w:del runs, so the imported
  ## paragraph has the new wording but no CriticMarkup; strict equality would
  ## miss it and the abstract body would land wherever the author block sat.
  const pref = 40
  let mn = min(pref, min(a.len, b.len))
  mn >= 8 and a[0 ..< mn] == b[0 ..< mn]

proc wordContainment*(a, b: string): float =
  ## Overlap coefficient of >=4-char words of two fingerprints: |A*B| /
  ## min(|A|,|B|). The tier-2 correspondence test when a heavy edit (an
  ## abstract rewrite, an expanded paragraph) defeats the 40-char prefix --
  ## unlike Jaccard it stays high when one side adds a lot of new material.
  var wa, wb: HashSet[string]
  var w = ""
  proc feed(set: var HashSet[string]; c: char) =
    if c.isAlphaNumeric: w.add c.toLowerAscii
    else:
      if w.len >= 4: set.incl w
      w.setLen 0
  for c in a: feed(wa, c)
  if w.len >= 4: wa.incl w
  w.setLen 0
  for c in b: feed(wb, c)
  if w.len >= 4: wb.incl w
  let mn = min(wa.len, wb.len)
  if mn < 8: return 0.0          # too few distinctive words to trust
  (wa * wb).len.float / mn.float

var gAlignDebug* = false      ## echo alignParagraphs' pointer walk when set

proc alignParagraphs*(canon, tracked: seq[string]): seq[string] =
  ## Two-pointer alignment (positional + fingerprint, lookahead 12): result[i]
  ## is the tracked paragraph aligned to canonical body paragraph i, or "".
  ## Positional keeps canonical and tracked in step when a coauthor accepted
  ## edits (fingerprint-only would fall back to canonical and lose them);
  ## lookahead absorbs pandoc unwrapping the frontmatter author block into a
  ## dozen separate paragraphs the canonical keeps in one export block (this
  ## manuscript: 10 affiliations + corresponding + name = 12), and the trailing
  ## bibliography the canonical doesn't contain.
  const la = 24
  let cfp = canon.mapIt(normalizeForMatch(it))
  let tfp = tracked.mapIt(normalizeForMatch(it))
  result = newSeq[string](canon.len)
  var i = 0
  var j = 0
  while i < canon.len and j < tracked.len:
    if gAlignDebug: echo "i=", i, " j=", j, " C=", cfp[i][0 ..< min(30, cfp[i].len)], " T=", tfp[j][0 ..< min(30, tfp[j].len)]
    if fpEq(cfp[i], tfp[j]):
      if gAlignDebug: echo "  -> prefix pair"
      result[i] = tracked[j]; inc i; inc j
    else:
      var found = -1
      for k in j + 1 ..< min(tracked.len, j + la):   # extra tracked paras
        if fpEq(cfp[i], tfp[k]): found = k; break
      if found >= 0: j = found; continue
      found = -1
      for k in i + 1 ..< min(canon.len, i + la):     # extra canonical paras
        if fpEq(cfp[k], tfp[j]): found = k; break
      if found >= 0: i = found; continue
      # Tier 2: the tracked paragraph AT j may be a light edit that shifts
      # text inside the first 40 chars (an inserted "(MZ)") -- a 24-char
      # prefix agreement, positionally at j with symmetric size, is the
      # same-paragraph signal.
      let pn = min(24, min(cfp[i].len, tfp[j].len))
      if pn >= 16 and cfp[i][0 ..< pn] == tfp[j][0 ..< pn] and
         tfp[j].len <= 2 * cfp[i].len and cfp[i].len <= 2 * tfp[j].len:
        if gAlignDebug: echo "  tier2 positional prefix"
        result[i] = tracked[j]; inc i; inc j
        continue
      # No prefix match in window on either side. Tier 2: a heavy edit (an
      # abstract rewrite, an expanded paragraph) defeats the 40-char prefix
      # but not word containment. Shortest match wins: try the tracked
      # paragraph at j, then growing joins of it -- the docx may SPLIT one
      # canonical paragraph into several (sentence-level breaks), and a 1:1
      # candidate covering only a fraction of a long canonical paragraph is
      # passed over so the join tier can swallow the whole split.
      var rawJoin = ""
      var joined = false
      for k in j ..< min(tracked.len, j + 8):
        rawJoin.add (if k > j: "\n\n" else: "") & tracked[k]
        let fpJoin = normalizeForMatch(rawJoin)
        # size symmetry: the candidate must cover the canonical paragraph but
        # not dwarf it -- a short SUMMARY paragraph is vocabulary-contained in
        # the detailed paragraphs it summarises, and without this guard the
        # join tier would replace it with them (losing the summary and any
        # comment anchored on it).
        if wordContainment(cfp[i], fpJoin) >= 0.6 and
           cfp[i].len <= 2 * fpJoin.len and fpJoin.len <= 2 * cfp[i].len:
          if gAlignDebug: echo "  tier2/3 join through k=", k
          result[i] = rawJoin; inc i; j = k + 1
          joined = true
          break
      if joined: continue
      # Nothing corresponds: keep the canonical paragraph, and skip a
      # tracked paragraph that matches no canonical paragraph in the window
      # (structural junk -- the unwrapped author block, extracted figure
      # captions) so the pointers don't wedge.
      var junk = true
      for k in i ..< min(canon.len, i + la):
        if fpEq(cfp[k], tfp[j]) or wordContainment(cfp[k], tfp[j]) >= 0.7:
          junk = false; break
      if gAlignDebug: echo "  keep canonical; junk=", junk
      if junk: inc j
      inc i

proc scanAnnotations*(text: string): seq[tuple[range, cmt: string]] =
  ## Balance-aware scan of `{==RANGE==}{>>CMT<<}' pairs: a bracket stack over
  ## `{==' / `==}' so overlapping/nested annotations yield correct inner and
  ## outer pairs (a lazy regex splits them wrong).
  var stack: seq[int]
  var pos = 0
  while pos < text.len:
    let op = text.find("{==", pos)
    let cl = text.find("==}", pos)
    if op >= 0 and (cl < 0 or op < cl):
      stack.add op + 3
      pos = op + 3
    elif cl >= 0:
      let start = if stack.len > 0: stack.pop() else: -1
      if start >= 0 and cl + 6 <= text.len and startsWithAt(text, cl + 3, "{>>"):
        let cmtEnd = text.find("<<}", cl + 6)
        if cmtEnd >= 0:
          result.add (text[start ..< cl], text[cl + 6 ..< cmtEnd])
          pos = cmtEnd + 3
        else: pos = cl + 3
      else: pos = cl + 3
    else: break

proc insideAnnotation(s: string; pos: int): bool =
  ## Is `pos' within a `{==...==}' span of `s' (a rough check: an even number
  ## of delimiters before it means we are inside one)?
  var depth = 0
  var i = 0
  while i < pos:
    if startsWithAt(s, i, "{=="): inc depth; i += 3
    elif startsWithAt(s, i, "==}"): dec depth; i += 3
    else: inc i
  depth mod 2 == 1

proc allPositions(needle, hay: string): seq[int] =
  var i = 0
  while true:
    let p = hay.find(needle, i)
    if p < 0: break
    result.add p
    i = p + needle.len

proc reanchorComments(merged: var string; tracked: string;
                      num2key: Table[string, string]; xrefMap: XrefMap;
                      nGrafted: var int; unplaced: var seq[tuple[range, cmt: string]]) =
  ## Splice reviewer comments from TRACKED into MERGED that paragraph
  ## alignment missed. Tiered anchoring per annotation (longest range first,
  ## so an outer comment is placed before a shorter inner overlap can break
  ## it): exact-once -> back-substituted variant (the tracked range carries
  ## rendered `^{N}' where merged has `[cite:@key]') -> case-insensitive-once
  ## -> truncated-prefix ladder -> ordinal (Kth tracked occurrence to Kth
  ## merged occurrence, <=5 occurrences). A candidate only splices when it
  ## appears exactly once and is not already inside an existing annotation.
  let anns = scanAnnotations(tracked)
  # document-order ordinal of each annotation, per stripped range
  var ordinals: Table[tuple[range, cmt: string], int]
  var seen: CountTable[string]
  for a in anns:
    ordinals[a] = seen[a.range]
    seen.inc(a.range)
  # longest range first
  let sorted = anns.sortedByIt(-it.range.len)
  for a in sorted:
    let cmt = a.cmt
    let raw = a.range.strip
    let range = applyCriticMarkup(raw, accept = true).strip
    if range.len == 0: continue
    if merged.contains("{==" & raw & "==}{>>" & cmt & "<<}"): continue  # carried
    let backsub = substituteXrefs(substituteCiteKeys(range, num2key), xrefMap)
    var placed = false
    for cand in [range, backsub]:
      if placed: break
      if cand.len >= 4:
        # tier 1: exact, exactly once, not inside an existing annotation
        let ps = allPositions(cand, merged)
        if ps.len == 1 and not insideAnnotation(merged, ps[0]):
          merged = merged[0 ..< ps[0]] & "{==" & cand & "==}{>>" & cmt & "<<}" &
                   merged[ps[0] + cand.len ..^ 1]
          inc nGrafted; placed = true
        # tier 2: case-insensitive, exactly once
        if not placed:
          let low = merged.toLowerAscii
          let ps2 = allPositions(cand.toLowerAscii, low)
          if ps2.len == 1 and not insideAnnotation(merged, ps2[0]):
            merged = merged[0 ..< ps2[0]] & "{==" & cand & "==}{>>" & cmt & "<<}" &
                     merged[ps2[0] + cand.len ..^ 1]
            inc nGrafted; placed = true
        # tier 3: truncated-prefix ladder
        if not placed:
          for frac in [0.75, 0.5, 0.3, 0.2]:
            let tlen = max(16, (cand.len.float * frac).int)
            if tlen >= cand.len: continue
            let trunc = cand[0 ..< tlen]
            let ps3 = allPositions(trunc, merged)
            if ps3.len == 1 and not insideAnnotation(merged, ps3[0]):
              merged = merged[0 ..< ps3[0]] & "{==" & trunc & "==}{>>" & cmt & "<<}" &
                       merged[ps3[0] + tlen ..^ 1]
              inc nGrafted; placed = true; break
        # tier 4: ordinal -- Kth tracked occurrence to Kth merged occurrence
        if not placed:
          let ps4 = allPositions(cand, merged)
          let k = ordinals.getOrDefault(a, 0)
          if ps4.len in 2..5 and k < ps4.len and not insideAnnotation(merged, ps4[k]):
            merged = merged[0 ..< ps4[k]] & "{==" & cand & "==}{>>" & cmt & "<<}" &
                     merged[ps4[k] + cand.len ..^ 1]
            inc nGrafted; placed = true
    if not placed:
      unplaced.add (raw, cmt)

proc bibPathsOf(canonical, baseDir: string): seq[string] =
  ## The `#+bibliography:' paths of the canonical, relative ones resolved
  ## against baseDir (the org file's directory).
  for ln in canonical.splitLines():
    let t = ln.strip
    if t.toLowerAscii.startsWith("#+bibliography:"):
      let p = expandTilde(t[t.find(':') + 1 ..^ 1].strip)
      if p.len == 0: continue
      let q = if isAbsolute(p): p else: baseDir / p
      if q notin result: result.add q

proc criticComments(text: string): seq[string] =
  ## Every `{>>...<<}' comment token in TEXT (bare or annotation-paired).
  var i = 0
  while true:
    let s = text.find("{>>", i)
    if s < 0: break
    let e = text.find("<<}", s)
    if e < 0: break
    result.add text[s ..< e + 3]
    i = e + 3

proc mergeContent*(canonical, tracked, baseDir: string; report: var string): string =
  ## Walk CANONICAL preserving its full structure (headers, property drawers,
  ## export/src blocks, tables -- all verbatim); replace a body paragraph with
  ## its aligned TRACKED paragraph when the reviewer changed it (CriticMarkup
  ## present, or accepted edits that alter the normalized text), with
  ## citations and cross-refs back-substituted to `[cite:@key]' so the
  ## canonical's keys survive the round-trip. Untouched paragraphs keep the
  ## canonical form. Tracked paragraphs that align to nothing (the citeproc
  ## bibliography, the unwrapped author block) are dropped. Afterwards,
  ## comments whose anchor paragraph alignment missed are re-anchored by
  ## substring; any that still can't be placed go to a
  ## `* Reviewer comments not auto-placed' section -- nothing is ever lost.
  let num2key = buildDocxNumMap(tracked, bibPathsOf(canonical, baseDir))
  let xrefMap = buildXrefMap(canonical)
  let units = parseUnits(canonical)
  let cParas = bodyParas(units)
  let tParas = bodyParas(parseUnits(tracked))
  let align = alignParagraphs(cParas, tParas)
  var outLines: seq[string]
  var bi = 0
  var nMerged = 0
  for u in units:
    if u.kind == ukStruct:
      outLines.add u.text
    else:
      let ti = align[bi]; inc bi
      if ti.len > 0 and (hasCriticMarkup(ti) or normalizeForMatch(ti) != normalizeForMatch(u.text)):
        var repl = substituteXrefs(substituteCiteKeys(ti, num2key), xrefMap)
        # the canonical paragraph's own comments must survive the replacement
        for c in criticComments(u.text):
          if not repl.contains(c): repl.add " " & c
        outLines.add repl
        inc nMerged
      else:
        outLines.add u.text
  var merged = outLines.join("\n")
  var nGrafted = 0
  var unplaced: seq[tuple[range, cmt: string]]
  reanchorComments(merged, tracked, num2key, xrefMap, nGrafted, unplaced)
  # The canonical's OWN comments must survive a paragraph replacement too:
  # graft any that the replaced tracked text no longer carries.
  reanchorComments(merged, canonical, num2key, xrefMap, nGrafted, unplaced)
  if unplaced.len > 0:
    merged.add "\n\n* Reviewer comments not auto-placed\n:PROPERTIES:\n:UNNUMBERED: t\n:END:\n"
    for (r, c) in unplaced:
      merged.add "\n- re: " & r & " :: " & "{>>" & c & "<<}" & "\n"
  report = $nMerged & " paragraph" & (if nMerged == 1: "" else: "s") & " merged, " &
            $nGrafted & " comment" & (if nGrafted == 1: "" else: "s") & " re-anchored" &
            (if unplaced.len > 0: ", " & $unplaced.len & " unplaced (listed at the end)" else: "")
  merged

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

proc findBibs(app: App): seq[string] =
  ## Every bibliography to pass to pandoc: gBib override, else *all*
  ## #+bibliography: headers (ox-pandoc permits several -- e.g. a project-local
  ## .bib plus a Zotero-managed master), else the first sibling *.bib. Each path
  ## is resolved relative to the org file and de-duplicated. Returning the full
  ## set (not just the first) is what lets citeproc see keys that live only in a
  ## secondary bib.
  if gBib.len > 0: return @[resolveRel(app, gBib)]
  for h in orgHeaders(app, "bibliography"):
    let r = resolveRel(app, h)
    if r notin result: result.add r
  if result.len == 0 and app.filePath.len > 0:
    for f in walkFiles(parentDir(app.filePath) / "*.bib"):
      result.add f; break

proc pandocOpts(app: App): seq[(string, string)] =
  ## Parse `#+PANDOC_OPTIONS: key:value` headers (ox-pandoc style). The value
  ## may itself contain ':' (e.g. an absolute path or a metadata pair), so split
  ## on the first ':' only. Keys used below: reference-doc, csl, filter, metadata
  ## (citeproc is always on; #+bibliography: is handled via findBibs).
  for v in orgHeaders(app, "PANDOC_OPTIONS"):
    let c = v.find(':')
    if c < 0: continue
    result.add (strutils.strip(v[0 ..< c]).toLowerAscii, strutils.strip(v[c+1 .. ^1]))

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
  # Merge base: the org embedded in the docx when it survived the round-trip
  # (customXml, or the docProps fallback Word/OneDrive leave intact), else the
  # open buffer -- the canonical the user is working from.
  var canonical = extractOrgSource(docx)
  var base = "embedded org source"
  if canonical.len == 0 and app.filePath.len > 0 and app.filePath.endsWith(".org"):
    canonical = app.ed.fullText()
    base = "the open buffer"
  if canonical.len > 0:
    var report: string
    app.ed.setText(mergeContent(canonical, tracked,
                                app.filePath.parentDir, report).strip())
    app.ed.markChanged()
    app.msg = "otd: imported " & extractFilename(docx) & " onto " & base &
              " -- " & report
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
  var options: seq[string]                          # sub/superscript etc. settings apply
  for ln in lines:                                  # to the fragments as to the body
    if strutils.strip(ln).toLowerAscii.startsWith("#+options:"): options.add ln
  convertCriticTokens(toks, options)                # org -> md inside CriticMarkup too
  writeFile(md, unescapeRefs(criticToSpans(unstash(readFile(md), toks), doneIds)))
  # md -> docx: standalone (title), citeproc + bibliography (references),
  # pandoc-crossref (fig:/tbl: cross-refs), optional CSL + reference-doc.
  var dargs = @["-f", "markdown", "-t", "docx", "-s"]
  # Resolve relative image paths (e.g. [[file:media/fig.png]]) against the org's
  # directory -- pandoc runs on a copy in /tmp, so without this it can't fetch
  # them and drops the figures ("replacing image with description").
  let srcDir = if app.filePath.len > 0: parentDir(absolutePath(app.filePath))
               else: getCurrentDir()
  var rpaths = @[srcDir]
  if gMediaDir.len > 0:                        # e.g. gMediaDir = "graphs"
    rpaths.add (if isAbsolute(gMediaDir): gMediaDir else: srcDir / gMediaDir)
  dargs.add "--resource-path=" & rpaths.join($PathSep)   # PathSep: ':' / ';'
  # Buffer #+PANDOC_OPTIONS: (ox-pandoc style) supplement the config globals;
  # a set global (gCsl / gRefDoc) still wins, mirroring findBibs' gBib-first rule.
  let popts = pandocOpts(app)
  proc optVal(k: string): string =
    for (kk, vv) in popts:
      if kk == k: return vv
    ""
  let haveCrossref = findExe("pandoc-crossref").len > 0
  if haveCrossref: (dargs.add "--filter"; dargs.add "pandoc-crossref")
  dargs.add "--citeproc"
  # Extra filters and metadata declared in #+PANDOC_OPTIONS (pandoc-crossref is
  # already handled above, so skip it to avoid running the filter twice).
  for (kk, vv) in popts:
    if kk == "filter" and vv.len > 0 and not (vv == "pandoc-crossref" and haveCrossref):
      if findExe(vv).len > 0: (dargs.add "--filter"; dargs.add vv)
    elif kk == "metadata" and vv.len > 0:
      (dargs.add "--metadata"; dargs.add vv)
  let bibs = findBibs(app)
  for bib in bibs:
    if bib.len > 0 and fileExists(bib): dargs.add "--bibliography=" & bib
  let csl = if gCsl.len > 0: gCsl else: optVal("csl")
  if csl.len > 0: dargs.add "--csl=" & resolveRel(app, csl)
  let refdoc = if gRefDoc.len > 0: gRefDoc else: optVal("reference-doc")
  if refdoc.len > 0: dargs.add "--reference-doc=" & resolveRel(app, refdoc)
  dargs.add md; dargs.add "-o"; dargs.add docx
  (code, outp) = pandoc(dargs)
  if code != 0: (app.msg = "pandoc md->docx failed: " & outp.strip(); return)
  # Give inline section breaks (raw-OOXML <w:sectPr> for a landscape figure etc.)
  # the reference doc's running head / page numbers, which pandoc otherwise leaves
  # only on the final section.
  if refdoc.len > 0: discard propagateSectionChrome(docx)
  # Embed the canonical org so re-import can recover cite keys / cross-refs / headers.
  let embedded = gEmbedSource and embedOrgSource(docx, app.ed.fullText())
  if doneIds.len > 0: discard resolveDoneComments(docx, doneIds)
  app.msg = "otd: exported -> " & extractFilename(docx) &
            (if embedded: "  [+org]" else: "") &
            (if bibs.len > 0: "  [refs: " & extractFilename(bibs[0]) &
               (if bibs.len > 1: " +" & $(bibs.len - 1) else: "") & "]" else: "")

proc extend*(app: var App) =
  defcommand("otd-import", "Tracked: import .docx -> org (CriticMarkup)", otdImport)
  defcommand("otd-export", "Tracked: export org (CriticMarkup) -> .docx", otdExport)
  registerExport("docx", "Word document (.docx, tracked changes)", "otd-export")
