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

proc spanKeepEdges(t: string): string =
  ## pandoc's markdown reader drops leading/trailing spaces inside a span
  ## (`[x ]{.insertion}' -> `x'), which glues an insertion ending in a space to
  ## the word after the token in Word (`{++… participants ++}in' ->
  ## "participantsin"). A `&#32;' character reference survives as a real space
  ## (`\ ' would come back as U+00A0), keeping the whitespace inside the
  ## w:ins/w:del run.
  var a = 0
  while a < t.len and t[a] == ' ': inc a
  var b = t.len
  while b > a and t[b - 1] == ' ': dec b
  if a == 0 and b == t.len: return t
  result = ""
  for _ in 1 .. a: result.add "&#32;"
  result.add t[a ..< b]
  for _ in 1 .. t.len - b: result.add "&#32;"

proc criticToSpans*(md: string; doneIds: var seq[int]): string =
  ## CriticMarkup tokens -> pandoc markdown spans (for md -> docx). Uses the same
  ## split scanner style as wkbcore.applyCriticMarkup.
  let a = trackAuthor()
  let d = nowDate()
  result = newStringOfCap(md.len)
  var i = 0
  var cid = 0
  proc sep(r: var string) =
    ## A span written right after `]' -- e.g. a comment straight after a
    ## citation/cross-ref, `[@tbl:x][note]{.comment-start}' -- reads in pandoc
    ## markdown as a `[text][label]' reference link: the comment-start is
    ## swallowed and Word gets an orphan commentRangeEnd/commentReference with
    ## no comment (desktop Word repairs it; Word Online refuses to open the
    ## file). An empty span `[]{}' separates them and renders as nothing.
    if r.len > 0 and r[^1] == ']': r.add "[]{}"
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
            sep(result); result.add "[" & orgCiteToPandoc(note) & "]{.comment-start id=\"" & $cid &
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
            sep(result); result.add "[" & spanKeepEdges(orgCiteToPandoc(tx)) &
              "]{.insertion author=\"" & au & "\" date=\"" & d & "\"}"
          of '-':
            let (au, tx) = peelAuthor(inner, a)
            sep(result); result.add "[" & spanKeepEdges(orgCiteToPandoc(tx)) &
              "]{.deletion author=\"" & au & "\" date=\"" & d & "\"}"
          of '=': result.add orgCiteToPandoc(inner)                        # highlight: keep the text
          of '~':
            let (au, body) = peelAuthor(inner, a)
            let arrow = body.find("~>")
            if arrow >= 0:
              sep(result); result.add "[" & spanKeepEdges(orgCiteToPandoc(body[0 ..< arrow])) &
                "]{.deletion author=\"" & au & "\" date=\"" & d & "\"}"
              let (au2, newText) = peelAuthor(body[arrow+2 .. ^1], au)   # `~>[Author]new'
              sep(result); result.add "[" & spanKeepEdges(orgCiteToPandoc(newText)) &
                "]{.insertion author=\"" & au2 & "\" date=\"" & d & "\"}"
            else:
              sep(result); result.add "[" & spanKeepEdges(orgCiteToPandoc(body)) &
                "]{.insertion author=\"" & au & "\" date=\"" & d & "\"}"
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
          sep(result); result.add "[" & orgCiteToPandoc(note) & "]{.comment-start id=\"" & $cid & "\" author=\"" &
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
  ## `[NOTE]{.comment-start id="N" author="A" ...}ANCHOR[]{.comment-end id="N"}'
  ## -> `{==ANCHOR==}{>>[A] NOTE<<}'. pandoc puts the reviewer's comment NOTE in
  ## the comment-start span and the commented (anchored) document text between
  ## the start and end markers, so the anchor is the CriticMarkup highlight (it
  ## stays in the prose) and the note is the `{>>..<<}' comment (it does not) --
  ## emitting them the other way round leaks the note into the text and exiles
  ## the real sentence to a margin comment. NOTE may itself contain `]' (a
  ## comment quoting a citation), so find the fixed closing tag first, then scan
  ## backward by bracket depth for its true matching `[` -- a `[^]]*' forward
  ## search stops at NOTE's own first `]' and silently drops the comment.
  var s = s
  # pandoc can nest one comment's end marker inside another's when both ranges
  # end at the same point -- `[[]{.comment-end id="13"}]{.comment-end id="12"}'
  # -- so the outer end is not the empty `[]{..}' looked for below: comment 12
  # turns orphan and 13's anchor swallows the `[' of an enclosing insertion.
  # Unwrap: `[X]{.comment-end id="N"}' -> `X[]{.comment-end id="N"}'.
  block:
    var k = 0
    while true:
      let ce = s.find("]{.comment-end", k)
      if ce < 0: break
      if ce > 0 and s[ce - 1] != '[':
        var depth = 1
        var q = ce - 1
        while q >= 0:
          if s[q] == ']': inc depth
          elif s[q] == '[':
            dec depth
            if depth == 0: break
          dec q
        if q >= 0 and depth == 0 and "{.comment-end" in s[q + 1 ..< ce]:
          s = s[0 ..< q] & s[q + 1 ..< ce] & "[" & s[ce .. ^1]
          k = 0; continue
      k = ce + 1
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
    let note = if open >= 0: s[open + 1 ..< cs] else: ""   # reviewer's comment text
    let endTok = "[]{.comment-end id=\"" & cid & "\"}"
    let endPos = s.find(endTok, braceEnd + 1)
    let cmt = "{>>" & (if author.len > 0: "[" & author & "] " else: "") & note & "<<}"
    if endPos < 0:
      # orphan start marker (no matching comment-end): drop the wrapper and keep
      # the note as a standalone comment rather than leaking it into the prose.
      let cut = if open >= 0: open else: cs
      s = s[0 ..< cut] & cmt & s[braceEnd + 1 ..^ 1]
      continue
    var anchor = s[braceEnd + 1 ..< endPos]   # the commented document text
    # A Word comment range may start outside a tracked change and end inside it
    # (or the reverse), so the anchor holds half a span: an unmatched `[' of an
    # insertion that opens inside it, or the `]{.insertion ..}' of one that
    # closes inside it. Keep those halves out of the highlight, or the span
    # loses its bracket and its text turns plain.
    var head, tail = ""
    block:
      var opens: seq[int]
      var lastClose = -1                      # end of the last unmatched `]{..}'
      var k = 0
      while k < anchor.len:
        if anchor[k] == '\\': k += 2; continue
        if anchor[k] == '[': opens.add k
        elif anchor[k] == ']':
          if opens.len > 0: discard opens.pop()
          else:
            var e = k
            if k + 1 < anchor.len and anchor[k + 1] == '{':
              let b = anchor.find('}', k)
              if b > 0: e = b
            lastClose = e
        inc k
      if opens.len > 0:
        tail = anchor[opens[0] .. ^1]; anchor = anchor[0 ..< opens[0]]
      if lastClose >= 0 and lastClose < anchor.len:
        head = anchor[0 .. lastClose]; anchor = anchor[lastClose + 1 .. ^1]
    let repl = head & (if anchor.strip.len > 0: "{==" & anchor & "==}" else: anchor) & cmt & tail
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
              proc tagOf(x: string): string =
                if x.startsWith("["):
                  let rb = x.find(']')
                  if rb > 0: return x[0 .. rb]
                ""
              # one author's replacement only: a deletion by one coauthor next
              # to another's insertion are two separate edits
              if '{' notin new and '}' notin new and tagOf(old) == tagOf(new):
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
  ## The matching `[` is located by a balanced, escape-aware scan over the text
  ## ALREADY EMITTED (`result`), never by md-index arithmetic. That matters for
  ## NESTED spans -- a reviewer's deletion inside another author's insertion,
  ## `[... [-]{.deletion author="b"} ...]{.insertion author="a"}` -- which
  ## pandoc emits when one author edits inside another's tracked insertion. Each
  ## `]{.class}` is processed innermost-first, so by the time the outer span is
  ## wrapped its inner spans are already CriticMarkup of a different length;
  ## trimming `result` by the ORIGINAL md span length (the old approach) then
  ## over- or under-counts and shreds surrounding text into unbalanced tokens.
  ## Scanning `result` is length-correct because inner CriticMarkup (`{--[b]x--}`,
  ## author tags `[b]`, `[cite:@k]`, display math `\[..\]`) is bracket-balanced,
  ## so it is skipped and the true outer `[` is found and nested cleanly.
  result = newStringOfCap(md.len)
  var i = 0
  while i < md.len:
    # a closing `]{.class ...}` -> find the matching `[` in `result`, wrap it
    if md[i] == ']' and i + 2 < md.len and md[i+1] == '{' and md[i+2] == '.':
      let braceEnd = md.find('}', i)
      if braceEnd > 0:
        let attrs = md[i+3 ..< braceEnd]      # skip `]{.`
        let cls = attrs.split({' ', '\t'})[0]
        # find the matching open bracket in the already-emitted result
        var depth = 1; var p = result.len - 1
        while p >= 0:
          let esc = p > 0 and result[p-1] == '\\'   # ignore escaped \[ \]
          if result[p] == ']' and not esc: inc depth
          elif result[p] == '[' and not esc:
            dec depth
            if depth == 0: break
          dec p
        # Where in `result` the span begins: the matching `[` when found, else
        # -- for a block-spanning insertion/deletion whose inline `[` pandoc
        # could not emit (markdown spans can't hold a paragraph break) or that a
        # reviewer's own edit consumed -- the start of the current block. That
        # wraps a fully-inserted paragraph as one token (pandoc emits one
        # `\]{.insertion}` closer per inserted block) instead of leaving a bare
        # orphan closer in the org.
        var cutPos = -1        # where result is truncated (span replaced from here)
        var contentStart = -1  # where the span's inner text begins in result
        if p >= 0 and depth == 0:
          cutPos = p; contentStart = p + 1              # drop inner and its `[`
        elif cls in ["insertion", "deletion", "mark"]:
          if result.len > 0 and result[^1] == '\\':     # the escaped \] of this closer
            result.setLen(result.len - 1)
          let bs = result.rfind("\n\n")
          cutPos = (if bs >= 0: bs + 2 else: 0)          # start of the current block
          contentStart = cutPos
        if cutPos >= 0:
          let inner = result[contentStart ..< result.len]   # already-rewritten inner text
          var wrapped = ""
          case cls
          of "insertion":
            let au = spanAuthor(attrs)   # keep per-coauthor authorship for re-export
            if inner.strip.len > 0:      # drop empty insertions (pandoc split artifacts)
              wrapped = (if au.len > 0: "{++[" & au & "]" & inner & "++}" else: "{++" & inner & "++}")
          of "deletion":
            let au = spanAuthor(attrs)
            if inner.strip.len > 0:
              wrapped = (if au.len > 0: "{--[" & au & "]" & inner & "--}" else: "{--" & inner & "--}")
          of "mark": wrapped = "{==" & inner & "==}"
          else: wrapped = ""    # unknown class: drop the span, keep the text
          result.setLen(cutPos)                         # drop the span text and its `[`
          if wrapped.len > 0: result.add wrapped
          elif cls notin ["insertion", "deletion", "mark"]: result.add inner
          i = braceEnd + 1
          continue
    result.add md[i]; inc i

proc flattenCritic*(s: string): string =
  ## Word lets revisions and comment ranges overlap freely; CriticMarkup can't
  ## nest (the stash, the org export and every reader assume flat tokens). So
  ## after the span rewrite, resolve every overlap into adjacent flat tokens:
  ##   - a highlight `{==..==}' whose range holds other markup loses its
  ##     highlight -- its comment stays right after the anchored text (a point
  ##     comment at the range end), the inner markup is kept;
  ##   - a comment inside an insertion/deletion moves to just after it;
  ##   - an insertion/deletion inside another (a coauthor deleting text another
  ##     inserted) splits the outer one around it, each piece keeping its author.
  ## `{~~a~>b~~}' is a leaf (mergeSubstitutions only builds brace-free ones).
  type
    Kind = enum kText, kIns, kDel, kHl, kCmt, kSub
    Node = ref object
      kind: Kind
      text: string          # kText / kCmt / kSub: raw token text
      author: string        # kIns / kDel: the `[author]' prefix (with brackets)
      kids: seq[Node]
      runStart: int         # kIns / kDel: where its current run's text began in outp
      split: bool           # kIns / kDel: a nested change split this run
  let opens = ["{++", "{--", "{=="]
  let closes = ["++}", "--}", "==}"]
  var i = 0
  proc parse(closers: seq[string]): seq[Node] =
    ## closers[^1] closes this level; an ancestor's closer met first means the
    ## ranges interleave (a comment starting inside an insertion and ending
    ## after it): end this level there without consuming it.
    var buf = ""
    proc flush(r: var seq[Node]) =
      if buf.len > 0: r.add Node(kind: kText, text: buf); buf.setLen 0
    while i < s.len:
      if closers.len > 0 and startsWithAt(s, i, closers[^1]):
        flush(result); i += 3; return
      if closers.anyIt(startsWithAt(s, i, it)):
        flush(result); return
      if closers.len == 0 and closes.anyIt(startsWithAt(s, i, it)):
        i += 3; continue                       # stray closer of an interleaved range
      let oi = (if i + 2 < s.len: opens.find(s[i ..< i + 3]) else: -1)
      if oi >= 0 and s.find(closes[oi], i + 3) >= 0:
        flush(result)
        i += 3
        var au = ""
        if oi < 2 and i < s.len and s[i] == '[':
          let rb = s.find(']', i)
          if rb > i and rb - i < 80 and '\n' notin s[i .. rb] and ' ' notin s[i+1 ..< rb].strip:
            au = s[i .. rb]; i = rb + 1
        let kids = parse(closers & closes[oi])
        result.add Node(kind: [kIns, kDel, kHl][oi], author: au, kids: kids)
        continue
      var leaf = false
      for (o, c, k) in [("{>>", "<<}", kCmt), ("{~~", "~~}", kSub)]:
        if startsWithAt(s, i, o):
          let e = s.find(c, i + 3)
          if e >= 0:
            flush(result)
            result.add Node(kind: k, text: s[i ..< e + 3])
            i = e + 3; leaf = true
          break
      if leaf: continue
      buf.add s[i]; inc i
    flush(result)
  let tree = parse(@[])
  proc plain(ns: seq[Node]): bool = ns.allIt(it.kind == kText)
  var outp = newStringOfCap(s.len)
  proc openEmph(t: string): string =
    ## markdown emphasis left open at the end of T (`*' / `**' toggles)
    var one, two = false
    var k = 0
    while k < t.len:
      if t[k] == '\\': k += 2; continue
      if t[k] == '*':
        if k + 1 < t.len and t[k + 1] == '*': two = not two; k += 2; continue
        one = not one
      inc k
    (if two: "**" else: "") & (if one: "*" else: "")
  proc closeRun(ctx: Node): string =
    ## close CTX's run for a split; returns the emphasis to reopen with
    ctx.split = true
    result = openEmph(outp[ctx.runStart .. ^1])
    var closer = result
    closer.reverse
    # the closer hugs the last word (`*a b*  ', not `*a b *'): move the run's
    # trailing whitespace after it
    var ws = ""
    while outp.len > ctx.runStart and outp[^1] in {' ', '\t'}:
      ws.insert($outp[^1], 0); outp.setLen(outp.len - 1)
    outp.add closer & ws & (if ctx.kind == kIns: "++}" else: "--}")
  proc reopenRun(ctx: Node; emph: string) =
    outp.add (if ctx.kind == kIns: "{++" else: "{--") & ctx.author
    ctx.runStart = outp.len
    outp.add emph
  proc emit(ns: seq[Node]; ctx: Node; deferred: var seq[string]) =
    ## ctx: the enclosing insertion/deletion whose run is open, or nil.
    ## Splitting a run around a nested change keeps markdown emphasis
    ## balanced in each piece (`*a {--b--} c*' -> `*a*' `{--b--}' `*c*').
    for n in ns:
      case n.kind
      of kText: outp.add n.text
      of kSub:
        if ctx == nil: outp.add n.text
        else:                                  # close the run around it
          let emph = closeRun(ctx)
          outp.add n.text
          reopenRun(ctx, emph)
      of kCmt:
        if ctx == nil: outp.add n.text else: deferred.add n.text
      of kHl:
        if ctx == nil and plain(n.kids):
          var t = ""
          for k in n.kids: t.add k.text
          if t.strip.len > 0: outp.add "{==" & t & "==}"
        else:                                  # overlap: keep the text, drop the highlight
          emit(n.kids, ctx, deferred)
      of kIns, kDel:
        let (o, c) = if n.kind == kIns: ("{++", "++}") else: ("{--", "--}")
        var emph = ""
        if ctx != nil:                         # close the enclosing run, emit, reopen
          emph = closeRun(ctx)
        outp.add o & n.author
        n.runStart = outp.len
        var inner: seq[string]
        emit(n.kids, n, inner)
        if n.split:                            # its own last piece balanced too
          var cl = openEmph(outp[n.runStart .. ^1])
          cl.reverse
          outp.add cl
        outp.add c
        if ctx != nil:
          deferred.add inner
          reopenRun(ctx, emph)
        else:
          for d in inner: outp.add d
  var top: seq[string]
  emit(tree, nil, top)
  for d in top: outp.add d
  # splitting can leave empty runs `{++[a]++}' / `{--++}' -- drop them
  result = outp
  for (o, c) in [("{++", "++}"), ("{--", "--}")]:
    var k = 0
    while true:
      let p = result.find(o, k)
      if p < 0: break
      var q = p + 3
      if q < result.len and result[q] == '[':
        let rb = result.find(']', q)
        if rb > 0 and rb - q < 80 and result[q ..< rb].anyIt(it.isAlphaAscii): q = rb + 1
      if startsWithAt(result, q, c):
        result = result[0 ..< p] & result[q + 3 .. ^1]
        k = p
      elif q < result.len and result.find(c, q) >= 0 and
           result[q ..< result.find(c, q)].strip(chars = Whitespace + {'*'}).len == 0 and
           '{' notin result[q ..< result.find(c, q)]:
        let e = result.find(c, q)        # keep its whitespace, drop stray `*'s
        result = result[0 ..< p] & result[q ..< e].replace("*", "") & result[e + 3 .. ^1]
        k = p
      else: k = p + 3

proc spansToCritic*(md: string): string =
  ## pandoc markdown track-change/comment spans -> CriticMarkup (docx -> md),
  ## the same passes as org-tracked-docx.el's otd--rewrite-spans: downgrade
  ## misclassified ATX headings, pair comment-start/end into `{==..==}{>>..<<}',
  ## wrap insertion/deletion/mark spans, flatten overlaps (CriticMarkup can't
  ## nest), merge adjacent del+ins into a substitution, strip `.anchor' classes.
  var s = downgradeHeadings(md)
  s = rewriteCommentPairs(s)
  s = rewriteChangeSpans(s)
  s = flattenCritic(s)
  s = mergeSubstitutions(s)
  stripAnchorSpans(s)

proc sharedEdge(side: string; c: char; leading: bool): tuple[ok: bool; side: string] =
  ## Whether SIDE's prose (after any `[Author]' prefix) starts (or ends) with
  ## emphasis delimiter `c', and the side with that one delimiter stripped.
  var p = side
  var pre = ""
  let (au, rest) = peelAuthor(p, "")
  if au.len > 0: (pre = p[0 ..< p.len - rest.len]; p = rest)
  if leading:
    if p.len == 0 or p[0] != c: return (false, side)
    return (true, pre & p[1 .. ^1])
  if p.len == 0 or p[^1] != c: return (false, side)
  (true, pre & p[0 ..< p.len - 1])

proc hoistCriticEmphasis*(s: string): string =
  ## Org emphasis opened INSIDE a tracked change cannot reach past the token:
  ## export stashes the token to a sentinel for the org->md pass, so a `/' (or
  ## `*') leading both sides of a substitution -- an italic quote the coauthor
  ## edited, `{~~/First, …~>/In sensitivity …~~}/' -- pairs with nothing and
  ## exports as a literal `/' with no italics. When both sides share a
  ## leading/trailing emphasis delimiter, move one copy outside the token:
  ## pandoc then sees `/<sentinel>/…' and italicises the whole change.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if i + 5 < s.len and s[i] == '{' and s[i+1] == '~' and s[i+2] == '~':
      let e = s.find("~~}", i + 3)
      if e > 0:
        let inner = s[i + 3 ..< e]
        let arrow = inner.find("~>")
        if arrow >= 0:
          var o = inner[0 ..< arrow]
          var n = inner[arrow + 2 .. ^1]
          var pre = ""
          var post = ""
          for c in {'/', '*'}:
            let (oOk, o2) = sharedEdge(o, c, leading = true)
            let (nOk, n2) = sharedEdge(n, c, leading = true)
            if oOk and nOk: (pre = $c; o = o2; n = n2)
            let (oTk, o3) = sharedEdge(o, c, leading = false)
            let (nTk, n3) = sharedEdge(n, c, leading = false)
            if oTk and nTk: (post = $c; o = o3; n = n3)
          result.add pre & "{~~" & o & "~>" & n & "~~}" & post
          i = e + 3
          continue
    result.add s[i]; inc i

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
  # `3. item', and a bare `217.' -- an inserted fragment ending a number that
  # pandoc would otherwise read as an empty list item and renumber `1.'
  i > 0 and i < t.len and t[i] in {'.', ')'} and (i + 1 == t.len or t[i + 1] == ' ')

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
  var authorTags = newSeq[seq[string]](tokens.len)
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
    for pi, p0 in parts[ti]:
      # a coauthor's `[Author]' tag is not text: keep it out of pandoc (which
      # would escape it to `\[Author\]', so peelAuthor misses it, the change
      # exports under the default author and the tag prints in Word)
      var p = p0
      var tag = ""
      if p.startsWith("["):
        let (au, rest) = peelAuthor(p, "")
        if au.len > 0: tag = "[" & au & "]"; p = rest
      authorTags[ti].setLen(max(authorTags[ti].len, pi + 1))
      authorTags[ti][pi] = tag
      parts[ti][pi] = p
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
    proc tagged(k: int): string =
      (if k < authorTags[ti].len: authorTags[ti][k] else: "") & ps[k]
    tokens[ti] = kind & (if ps.len == 2: tagged(0) & "~>" & tagged(1) else: tagged(0)) & close

proc criticTokensToOrg*(tokens: var seq[string]) =
  ## Import-side mirror of convertCriticTokens. On docx -> org the CriticMarkup
  ## tokens are stashed through the md -> org pass, so their text came back in
  ## pandoc MARKDOWN syntax: `**bold**', `10^-3^', `Study^®^', `\[', `\<', `\''.
  ## In an org file those print literally on the next export. Convert every
  ## inline fragment (insertion, deletion, both substitution sides, highlight,
  ## and a comment's note after its `[Author] ' prefix) to org in ONE pandoc
  ## call, with the same batch-split fallback; a fragment pandoc can't convert
  ## as a single inline paragraph stays as it was.
  type Frag = tuple[tok, part: int; lead, trail, text: string]
  var frags: seq[Frag]
  var parts = newSeq[seq[string]](tokens.len)
  var prefix = newSeq[string](tokens.len)       # a comment's "[Author] "
  for ti, tok in tokens:
    if tok.len < 6: continue
    let kind = tok[0 .. 2]
    var inner = tok[3 ..< tok.len - 3]
    case kind
    of "{++", "{--", "{==": parts[ti] = @[inner]
    of "{~~":
      let arrow = inner.find("~>")
      parts[ti] = if arrow >= 0: @[inner[0 ..< arrow], inner[arrow + 2 .. ^1]] else: @[inner]
    of "{>>":
      if inner.startsWith("["):
        let rb = inner.find(']')
        if rb > 0:
          var p = rb + 1
          while p < inner.len and inner[p] == ' ': inc p
          prefix[ti] = inner[0 ..< p]; inner = inner[p .. ^1]
      parts[ti] = @[inner]
    else: continue
    for pi, p in parts[ti]:
      let t = p.strip()
      if t.len == 0 or "\n\n" in p: continue
      if not (('*' in t) or ('^' in t) or ('\\' in t) or ('~' in t) or ('`' in t) or ('_' in t)):
        continue                                     # nothing markdown-specific to convert
      let lead = p[0 ..< p.len - p.strip(leading = true, trailing = false).len]
      let trail = p[p.strip(leading = false, trailing = true).len .. ^1]
      frags.add (ti, pi, lead, trail, t)
  if frags.len == 0: return
  let src = getTempDir() / "otd-fragments-in.md"
  let dst = getTempDir() / "otd-fragments-in.org"
  proc convert(lo, hi: int) =
    if hi <= lo: return
    var doc = ""
    for k in lo ..< hi: doc.add "WKBFRAG" & $k & "X\n\n" & frags[k].text & "\n\n"
    doc.add "WKBFRAG" & $hi & "X\n"
    writeFile(src, doc)
    let (code, _) = pandoc(@["-f", "markdown", "-t", "org", "--wrap=none", src, "-o", dst])
    if code != 0:
      if hi - lo > 1:
        let mid = (lo + hi) div 2
        convert(lo, mid); convert(mid, hi)
      return
    let org = readFile(dst)
    for k in lo ..< hi:
      let a = org.find("WKBFRAG" & $k & "X")
      let b = org.find("WKBFRAG" & $(k + 1) & "X")
      if a < 0 or b < 0 or b < a: continue
      let conv = org[a + ("WKBFRAG" & $k & "X").len ..< b].strip()
      if conv.len == 0 or "\n\n" in conv or isBlockSyntax(conv): continue
      parts[frags[k].tok][frags[k].part] = frags[k].lead & conv & frags[k].trail
  convert(0, frags.len)
  for ti, ps in parts:
    if ps.len == 0: continue
    let kind = tokens[ti][0 .. 2]
    let close = tokens[ti][^3 .. ^1]
    tokens[ti] = kind & prefix[ti] & (if ps.len == 2: ps[0] & "~>" & ps[1] else: ps[0]) & close

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
  cxPropChunk = 32000                ## < Word's 32767-char cap on a text property

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
  ## Drop stale <property ... name="OrgTrackedSource*" ...>...</property> (the
  ## chunks and the length) so a re-embed does not leave two copies of the source.
  result = cx
  while true:
    let n = result.find("name=\"" & cxPropName)
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
      "<ds:datastoreItem ds:itemID=\"{6F1C1E2A-0B5D-4C9E-9A7E-3D2B8C4F1A01}\"" &
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
      # Word truncates a text property to 32767 chars on save (a 150 KB org is
      # ~200 KB of base64), so split it into numbered chunks -- OrgTrackedSource,
      # OrgTrackedSource2, ... -- plus OrgTrackedSourceLen, the total base64
      # length, so import can tell a complete source from a cut one.
      var props = ""
      var pid = nextPid(cx)
      let nChunks = max(1, (b64.len + cxPropChunk - 1) div cxPropChunk)
      for k in 0 ..< nChunks:
        let name = if k == 0: cxPropName else: cxPropName & $(k + 1)
        props.add "<property fmtid=\"" & cxPropFmtId & "\" pid=\"" & $pid & "\" name=\"" &
          name & "\"><vt:lpwstr>" &
          b64[k * cxPropChunk ..< min(b64.len, (k + 1) * cxPropChunk)] & "</vt:lpwstr></property>"
        inc pid
      props.add "<property fmtid=\"" & cxPropFmtId & "\" pid=\"" & $pid & "\" name=\"" &
        cxPropName & "Len\"><vt:lpwstr>" & $b64.len & "</vt:lpwstr></property>"
      cx = cx.replace("</Properties>", props & "</Properties>")
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

var gEmbeddedTruncated* = false  ## set by extractOrgSource: the docx's source was cut

proc extractOrgSourceProperty(docx: string): string =
  ## Recover the embedded org from the docProps/custom.xml <OrgTrackedSource>
  ## property -- the fallback used when Word/OneDrive stripped the customXml/
  ## part on save. Port of otd--extract-org-source-property; CRLF/CR -> LF.
  ## The source may be split over OrgTrackedSource, OrgTrackedSource2, ... with
  ## OrgTrackedSourceLen giving the full base64 length. A source that does not
  ## add up -- Word cut a property at its 32767-char cap, as it does to the
  ## single unchunked property older exports wrote -- is rejected (""), so
  ## import merges onto the open buffer instead of a canonical that silently
  ## ends mid-document and drops everything after the cut.
  gEmbeddedTruncated = false
  let unzipExe = findExe("unzip")
  if unzipExe.len == 0 or not fileExists(docx): return ""
  let (content, cc) = execCmdEx(quoteShell(unzipExe) & " -p " &
                                quoteShell(docx) & " docProps/custom.xml")
  if cc != 0: return ""
  proc prop(name: string): tuple[found: bool; value: string] =
    let ni = content.find("name=\"" & name & "\"")
    if ni < 0: return
    let vs = content.find("<vt:lpwstr>", ni)
    if vs < 0: return
    let payStart = vs + "<vt:lpwstr>".len
    let ve = content.find("</vt:lpwstr>", payStart)
    if ve < 0: return
    (true, content[payStart ..< ve].strip())
  var (found, b64) = prop(cxPropName)
  if not found or b64.len == 0: return ""
  var k = 2
  while true:
    let (more, chunk) = prop(cxPropName & $k)
    if not more: break
    b64.add chunk; inc k
  let (hasLen, lenStr) = prop(cxPropName & "Len")
  let complete =
    if hasLen: (try: parseInt(lenStr) == b64.len except ValueError: false)
    else: b64.len mod 4 == 0 and b64.len < 32767
  if not complete:
    gEmbeddedTruncated = true
    return ""
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
  ## The package is read and rewritten in memory with zippy, like
  ## embedOrgSource: [Content_Types].xml first and NO directory entries. (This
  ## used to shell out to `zip -r', which put [Content_Types].xml last and added
  ## folder entries -- Word Online then refused to open the exported file.)
  let docxAbs = absolutePath(docx)
  if not fileExists(docxAbs): return false
  var pkg: OrderedTable[string, string]
  try:
    let reader = openZipArchive(docxAbs)
    defer: reader.close()
    for path in reader.walkFiles: pkg[path] = reader.extractFile(path)
  except CatchableError: return false
  if "word/comments.xml" notin pkg: return false      # no comments -> nothing to do
  var comments = pkg["word/comments.xml"]
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
  pkg["word/comments.xml"] = res
  pkg["word/commentsExtended.xml"] = (
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n" &
    "<w15:commentsEx xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\">" &
    entries & "</w15:commentsEx>")
  var ct = pkg.getOrDefault("[Content_Types].xml", "")
  if ct.len > 0:
    let c = ct
    if "commentsExtended" notin c:
      ct = (c.replace("</Types>",
        "<Override PartName=\"/word/commentsExtended.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml\"/></Types>"))
  if "word/_rels/document.xml.rels" in pkg:
    let r = pkg["word/_rels/document.xml.rels"]
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
      pkg["word/_rels/document.xml.rels"] = (r.replace("</Relationships>",
        "<Relationship Id=\"rId" & $(maxId+1) & "\" Type=\"http://schemas.microsoft.com/office/2011/relationships/commentsExtended\" Target=\"commentsExtended.xml\"/></Relationships>"))
  # zippy writes entries in reverse insertion order: insert [Content_Types].xml
  # LAST so it is the FIRST entry in the archive.
  pkg.del("[Content_Types].xml")
  pkg["[Content_Types].xml"] = ct
  try:
    writeFile(docxAbs, createZipArchive(pkg))
    true
  except CatchableError: false

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
  # bracketed numbers `[21]', `[36, 52]', `[32–34]' -- the form a citation
  # takes once a coauthor's Word drops its superscript/hyperlink. Converted
  # only when EVERY number resolves through the docx bibliography, and never
  # an org link `[[..][N]]' or a `[cite:..]'.
  block:
    var o = ""
    var i = 0
    while i < s.len:
      if s[i] == '[' and (i == 0 or s[i - 1] notin {'[', ']'}):
        var e = i + 1
        while e < s.len and s[e] in {'0'..'9', ',', ' ', '-'}: inc e
        var inner = s[i + 1 ..< e]
        var e2 = e
        while startsWithAt(s, e2, "–"):          # en-dash range, multi-byte
          inner.add "--"; e2 += "–".len
          while e2 < s.len and s[e2] in {'0'..'9', ',', ' '}: inner.add s[e2]; inc e2
        if e2 < s.len and s[e2] == ']' and inner.len > 0 and inner[0].isDigit and
           (e2 + 1 >= s.len or s[e2 + 1] notin {'[', ']'}):
          let keys = parseCiteNums(inner, n2key)
          if keys.len > 0:
            o.add "[cite:" & keys.join(";") & "]"
            i = e2 + 1
            continue
      o.add s[i]; inc i
    s = o
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

type Alignment* = object
  aligned*: seq[string]  ## per canonical paragraph: its tracked paragraph(s), or ""
  owner*: seq[int]       ## per tracked paragraph: the canonical paragraph it
                         ## belongs to or follows (-1: none)
  used*: seq[bool]       ## per tracked paragraph: consumed by `aligned'

proc alignParagraphsEx*(canon, tracked: seq[string]): Alignment =
  ## Two-pointer alignment (positional + fingerprint, lookahead 12): aligned[i]
  ## is the tracked paragraph aligned to canonical body paragraph i, or "".
  ## Tracked paragraphs the walk steps over (a paragraph a coauthor split off
  ## or wrote new, a commented heading's neighbour) are not lost: `owner'
  ## records the canonical paragraph each one sits after, so the merge can
  ## insert new text there and put comments that can't re-anchor next to it.
  ## Positional keeps canonical and tracked in step when a coauthor accepted
  ## edits (fingerprint-only would fall back to canonical and lose them);
  ## lookahead absorbs pandoc unwrapping the frontmatter author block into a
  ## dozen separate paragraphs the canonical keeps in one export block (this
  ## manuscript: 10 affiliations + corresponding + name = 12), and the trailing
  ## bibliography the canonical doesn't contain.
  const la = 24
  let cfp = canon.mapIt(normalizeForMatch(it))
  let tfp = tracked.mapIt(normalizeForMatch(it))
  result.aligned = newSeq[string](canon.len)
  result.owner = newSeqWith(tracked.len, -1)
  result.used = newSeq[bool](tracked.len)
  var i = 0
  var j = 0
  proc take(r: var Alignment; i, j: int; text: string) =
    r.aligned[i] = text; r.owner[j] = i; r.used[j] = true
  while i < canon.len and j < tracked.len:
    if gAlignDebug: echo "i=", i, " j=", j, " C=", cfp[i][0 ..< min(30, cfp[i].len)], " T=", tfp[j][0 ..< min(30, tfp[j].len)]
    if fpEq(cfp[i], tfp[j]):
      if gAlignDebug: echo "  -> prefix pair"
      result.take(i, j, tracked[j]); inc i; inc j
    else:
      var found = -1
      for k in j + 1 ..< min(tracked.len, j + la):   # extra tracked paras
        if fpEq(cfp[i], tfp[k]): found = k; break
      if found >= 0:
        for k in j ..< found: result.owner[k] = max(0, i - 1)   # stepped over: follows i-1
        j = found; continue
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
        result.take(i, j, tracked[j]); inc i; inc j
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
          result.take(i, j, rawJoin)
          for q in j + 1 .. k: result.owner[q] = i; result.used[q] = true
          inc i; j = k + 1
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
      if junk: result.owner[j] = i; inc j
      inc i
  for k in j ..< tracked.len:                      # trailing (the bibliography)
    if result.owner[k] < 0: result.owner[k] = max(0, canon.len - 1)

proc alignParagraphs*(canon, tracked: seq[string]): seq[string] =
  ## alignParagraphsEx's per-canonical-paragraph alignment only.
  alignParagraphsEx(canon, tracked).aligned


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

proc cslOf(canonical, baseDir: string): string =
  ## The `csl:' value of the canonical's `#+PANDOC_OPTIONS:' headers, resolved
  ## like the bibliography paths; "" when none (pandoc then uses its default).
  for ln in canonical.splitLines():
    let t = ln.strip
    if t.toLowerAscii.startsWith("#+pandoc_options:"):
      let v = t[t.find(':') + 1 ..^ 1].strip
      if v.toLowerAscii.startsWith("csl:"):
        let p = expandTilde(v[4 ..^ 1].strip)
        return if isAbsolute(p): p else: baseDir / p
  ""

proc isCrossRef(body: string): bool =
  ## A `[cite:...]' whose keys are all pandoc-crossref labels (@tbl:, @fig:, ...).
  for part in body.split(';'):
    let k = part.strip
    if k.len > 0 and not (k.startsWith("@tbl:") or k.startsWith("@fig:") or
                          k.startsWith("@sec:") or k.startsWith("@eq:")):
      return false
  true

proc buildAuthorYearMap*(canonical, baseDir: string): seq[tuple[rendered, cite: string]] =
  ## Rendered citation text -> the canonical's own `[cite:...]', for
  ## author-date styles (APA, Chicago author-date, ...), where citeproc writes
  ## "(Nash et al., 2005; Verhulst et al., 2015)" into the docx and the
  ## numeric back-substitution (buildDocxNumMap) has nothing to key on.
  ## Every bibliographic citation of the canonical is rendered with the
  ## document's own CSL and bibliographies in ONE pandoc run, in document
  ## order, so citeproc's whole-document disambiguation ("H. H. Maes" vs
  ## "H. Maes", "Neale, Aggen, et al.") matches what went into the docx.
  ## Returns @[] (no substitution) when rendering fails or the paragraph count
  ## does not line up -- a wrong key is worse than plain text.
  var cites: seq[string]                       # the original `[cite...]' text
  var i = 0
  while true:
    let s = canonical.find("[cite", i)
    if s < 0: break
    let colon = canonical.find(':', s)
    let e = canonical.find(']', s)
    if e < 0 or colon < 0 or colon > e: break
    let tok = canonical[s .. e]
    if not isCrossRef(canonical[colon + 1 ..< e]) and tok notin cites: cites.add tok
    i = e + 1
  if cites.len == 0: return
  let bibs = bibPathsOf(canonical, baseDir)
  var args = @["-f", "markdown", "-t", "plain", "--wrap=none", "--citeproc",
               "-M", "suppress-bibliography=true"]
  var anyBib = false
  for b in bibs:
    if fileExists(b): args.add "--bibliography=" & b; anyBib = true
  if not anyBib: return
  let csl = cslOf(canonical, baseDir)
  if csl.len > 0 and fileExists(csl): args.add "--csl=" & csl
  var md = ""
  for c in cites: md.add orgCiteToPandoc(c) & "\n\n"
  let src = getTempDir() / "otd-cites.md"
  let dst = getTempDir() / "otd-cites.txt"
  writeFile(src, md)
  let (code, _) = pandoc(args & @[src, "-o", dst])
  if code != 0 or not fileExists(dst): return
  var paras: seq[string]
  for p in readFile(dst).split("\n\n"):
    let q = nbspToSpace(p).strip
    if q.len > 0: paras.add q
  if paras.len != cites.len: return
  proc keySet(c: string): seq[string] =        # same keys in another order = same cite
    for k in c[c.find(':') + 1 ..^ 2].split(';'): result.add k.strip
    result.sort()
  var seen: Table[string, string]
  for k in 0 ..< cites.len:
    let r = paras[k]
    if "???" in r or r.len < 6: continue        # unresolved key: leave the text alone
    if seen.hasKey(r):
      if seen[r].len > 0 and keySet(seen[r]) != keySet(cites[k]): seen[r] = ""  # truly ambiguous
    else: seen[r] = cites[k]
  for r, c in seen:
    if c.len > 0: result.add (r, c)
  result.sort(proc (a, b: tuple[rendered, cite: string]): int = cmp(b.rendered.len, a.rendered.len))

proc substituteAuthorYear*(text: string; ay: seq[tuple[rendered, cite: string]]): string =
  ## Replace each rendered author-date citation in TEXT by its `[cite:...]'
  ## (longest first, so a two-key group wins over its one-key prefix).
  result = nbspToSpace(text)
  for (r, c) in ay:
    result = result.replace(r, c)

type RbTok = object
  key: string      ## comparison key; "" = glue (whitespace, emphasis markers)
  text: string

proc rbTokens(s: string; xrefMap: XrefMap): seq[RbTok] =
  ## Tokenize a paragraph for rebaseOnCanonical: CriticMarkup tokens, citations,
  ## cross-refs, links, sub/superscripts and words are atoms; whitespace and
  ## emphasis markers are glue. Keys normalise what the docx round-trip changes
  ## without meaning to: citation forms, `Table N' vs `[cite:@tbl:x]', bare vs
  ## bracketed URLs, curly vs straight quotes, `--' vs an en dash.
  var nOf: Table[string, string]                 # "tbl:one" -> "tbl1"
  for typ, entries in xrefMap.pairs:
    for (label, n) in entries: nOf[typ & ":" & label] = typ & $n
  const xwords = {"table": "tbl", "tbl.": "tbl", "figure": "fig", "fig.": "fig",
                  "section": "sec", "sec.": "sec", "equation": "eq", "eq.": "eq"}
  proc normInner(t: string): string =
    ## markup content key: drop `[author]' tags and emphasis, collapse spaces
    var x = t
    for sep in ["~>"]:
      x = x.replace(sep, " \x03 ")
    var o = ""
    var k = 0
    var atStart = true
    while k < x.len:
      if atStart and x[k] == '[':
        let rb = x.find(']', k)
        if rb > k and rb - k < 60 and '@' notin x[k .. rb] and ':' notin x[k .. rb]:
          k = rb + 1; atStart = false; continue
      if x[k] == '\x03': atStart = true; o.add " > "; inc k; continue
      if x[k] notin {'*', '/', '_', '=', '~', '\t', '\n'}: o.add x[k]
      if x[k] != ' ': atStart = false
      inc k
    o.splitWhitespace.join(" ").toLowerAscii
  proc add(r: var seq[RbTok]; key, text: string) = r.add RbTok(key: key, text: text)
  var i = 0
  while i < s.len:
    let c = s[i]
    # CriticMarkup atom
    if c == '{' and i + 2 < s.len:
      let op = s[i ..< i + 3]
      let cl = case op
               of "{++": "++}"
               of "{--": "--}"
               of "{~~": "~~}"
               of "{==": "==}"
               of "{>>": "<<}"
               else: ""
      if cl.len > 0:
        let e = s.find(cl, i + 3)
        if e >= 0:
          result.add("M" & op & normInner(s[i + 3 ..< e]), s[i ..< e + 3])
          i = e + 3; continue
    # [cite:...] -- a citation, or a cross-ref keyed by its rendered number
    if startsWithAt(s, i, "[cite:"):
      let e = s.find(']', i)
      if e > 0:
        let body = s[i + 6 ..< e].strip
        let lab = if body.startsWith("@"): body[1 .. ^1] else: body
        result.add((if nOf.hasKey(lab): "X" & nOf[lab] else: "CITE"), s[i .. e])
        i = e + 1; continue
    # org links [[url]] / [[url][desc]] -- citeproc anchors are citations
    if startsWithAt(s, i, "[["):
      let e = s.find("]]", i)
      if e > 0:
        let inner = s[i + 2 ..< e]
        let br = inner.find("][")
        let url = (if br >= 0: inner[0 ..< br] else: inner)
        if url.startsWith("#citeproc_bib_item"): result.add("CITE", s[i .. e + 1])
        elif url.startsWith("#"):
          let lab = url[1 .. ^1]
          result.add((if nOf.hasKey(lab): "X" & nOf[lab] else: "L" & url), s[i .. e + 1])
        else: result.add("L" & url.strip(chars = {'<', '>'}).toLowerAscii, s[i .. e + 1])
        i = e + 2; continue
    # numeric citation forms: ^{21}, [21], [36, 52], [32–34]
    if c == '^' and i + 2 < s.len and s[i + 1] == '{':
      let e = s.find('}', i)
      if e > 0:
        let body = s[i + 2 ..< e]
        result.add((if body.len > 0 and body.allCharsInSet({'0'..'9', ',', ' ', '-'}): "CITE"
                    else: "^" & body), s[i .. e])
        i = e + 1; continue
    if c == '_' and i + 1 < s.len and s[i + 1] == '{':
      let e = s.find('}', i)
      if e > 0: result.add("_" & s[i + 2 ..< e], s[i .. e]); i = e + 1; continue
    if c == '[' and i + 1 < s.len and s[i + 1].isDigit:
      var e = i + 1
      while e < s.len and (s[e] in {'0'..'9', ',', ' ', '-'} or startsWithAt(s, e, "–")):
        e += (if startsWithAt(s, e, "–"): "–".len else: 1)
      if e < s.len and s[e] == ']':
        result.add("CITE", s[i .. e]); i = e + 1; continue
    # bare URL
    if startsWithAt(s, i, "http://") or startsWithAt(s, i, "https://"):
      var e = i
      while e < s.len and s[e] notin {' ', '\t', '\n', ')', ']', '>'}: inc e
      var url = s[i ..< e]
      while url.len > 0 and url[^1] in {'.', ',', ';'}: url.setLen(url.len - 1)
      result.add("L" & url.toLowerAscii, url)
      i += url.len; continue
    # multi-byte glue / punctuation
    if startsWithAt(s, i, "​"): result.add("", "​"); i += 3; continue
    if startsWithAt(s, i, " "): result.add("", " "); i += 2; continue
    block uni:
      for (u, k) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""),
                     ("–", "-"), ("—", "--"), ("−", "-"), ("…", "...")]:
        if startsWithAt(s, i, u):
          result.add(k, u); i += u.len; break uni
      # ASCII
      if c in {' ', '\t', '\n', '\r'}:
        var e = i
        while e < s.len and s[e] in {' ', '\t', '\n', '\r'}: inc e
        result.add("", s[i ..< e]); i = e
      elif c in {'*', '/', '_'}:
        result.add("", $c); inc i
      elif startsWithAt(s, i, "---"): result.add("--", "---"); i += 3
      elif startsWithAt(s, i, "--"): result.add("-", "--"); i += 2
      elif c == '\\' and startsWithAt(s, i, "\\\\"): result.add("", "\\\\"); i += 2
      elif c.isAlphaNumeric or ord(c) >= 0x80:
        var e = i
        while e < s.len and (s[e].isAlphaNumeric or (ord(s[e]) >= 0x80 and
              not startsWithAt(s, e, "’") and not startsWithAt(s, e, "–") and
              not startsWithAt(s, e, "—") and not startsWithAt(s, e, "​") and
              not startsWithAt(s, e, " ") and not startsWithAt(s, e, "“") and
              not startsWithAt(s, e, "”") and not startsWithAt(s, e, "‘"))): inc e
        if e == i: e = i + 1
        let w = s[i ..< e]
        # `Table 2' / `Figure 1' as one cross-ref atom
        let lw = w.toLowerAscii
        var done = false
        for (xw, typ) in xwords:
          if lw == xw.strip(chars = {'.'}) :
            var k = e
            if k < s.len and s[k] == '.': inc k
            var sp = k
            while sp < s.len and s[sp] == ' ': inc sp
            if startsWithAt(s, sp, " "): sp += 2
            var ne = sp
            while ne < s.len and s[ne].isDigit: inc ne
            if ne > sp and sp > k - 0 and (sp > k or startsWithAt(s, k, " ")):
              result.add("X" & typ & s[sp ..< ne], s[i ..< ne]); i = ne; done = true
            break
        if not done:
          result.add(lw, w); i = e
      else:
        result.add($c, $c); inc i

proc commentsOutOfWords*(s: string): string =
  ## Word anchors comments inside words (`status f{>>..<<}or', or with the
  ## formatting-run split `f/{>>..<<}/or'): move each such run of comments to
  ## the end of the word it splits, the word rejoined.
  result = s
  var k = 0
  while true:
    let p = result.find("{>>", k)
    if p < 0: break
    var e = p                                   # end of the run of comments
    while startsWithAt(result, e, "{>>"):
      let c = result.find("<<}", e)
      if c < 0: break
      e = c + 3
    if e == p: break
    var a = p                                   # emphasis markers before / after
    while a > 0 and result[a - 1] in {'*', '/', '_'}: dec a
    var b = e
    while b < result.len and result[b] in {'*', '/', '_'}: inc b
    if a > 0 and result[a - 1].isAlphaNumeric and b < result.len and
       result[b].isAlphaNumeric and result[a ..< p] == result[e ..< b]:
      var w = b
      while w < result.len and result[w].isAlphaNumeric: inc w
      # `f/` + `/or' are a closing and reopening italic: drop both
      result = result[0 ..< a] & result[b ..< w] & result[p ..< e] & result[w .. ^1]
      k = a + (w - b) + (e - p)
    else: k = e

proc rebaseOnCanonical*(canon, tracked: string; xrefMap: XrefMap): string =
  ## Carry a coauthor's paragraph onto the canonical one instead of replacing
  ## it: a token LCS keeps the canonical's own text -- emphasis, `[cite:]'
  ## keys, cross-refs, links, list numbers, dashes -- wherever the words agree,
  ## and takes from TRACKED only what differs: the coauthors' CriticMarkup and
  ## any untracked rewording. The docx round-trip otherwise turns italic quotes
  ## into bold fragments, bare URLs into `[[url][<url>]]', `2.' into `1.'.
  ## The canonical's own comments always survive. Returns "" when the two
  ## paragraphs agree on too little to trust the alignment.
  # Highlights are only comment anchors, and Word's comment ranges cut across
  # words and citations (`intac{==t[32--34==}{==].==}'). Align on the bare
  # text, then re-wrap each anchor that still sits intact right before its
  # comment; the rest stay point comments at the same spot.
  var anchors: seq[tuple[x, tok: string]]
  var bare = newStringOfCap(tracked.len)
  block:
    var pending = ""
    var i = 0
    while i < tracked.len:
      if startsWithAt(tracked, i, "{=="):
        let e = tracked.find("==}", i + 3)
        if e >= 0 and not hasCriticMarkup(tracked[i + 3 ..< e]):
          pending = tracked[i + 3 ..< e]
          bare.add pending; i = e + 3; continue
      if startsWithAt(tracked, i, "{>>"):
        let e = tracked.find("<<}", i + 3)
        if e >= 0:
          let tok = tracked[i .. e + 2]
          if pending.len > 0: anchors.add (pending, tok)
          pending = ""
          bare.add tok; i = e + 3; continue
      pending = ""
      bare.add tracked[i]; inc i
  # pandoc splits a word where Word's formatting runs break inside it
  # (`f//or', `e**ntering'): a doubled emphasis marker between two word
  # characters is never real org, so drop it before tokenizing.
  block:
    var o = newStringOfCap(bare.len)
    var i = 0
    while i < bare.len:
      if i > 0 and bare[i] in {'*', '/', '_', '=', '~', '+'} and bare[i - 1].isAlphaNumeric:
        var e = i
        while e < bare.len and bare[e] == bare[i]: inc e
        if e - i >= 2 and e < bare.len and bare[e].isAlphaNumeric:
          i = e; continue
      o.add bare[i]; inc i
    bare = o
  # Word keeps an edit typed inside a sub/superscript run in that run, so
  # pandoc nests it in the braces -- `γ_{1{++)++}}': markup inside `_{..}' is
  # neither valid org nor matchable, so hoist it out after the script.
  block:
    var o = newStringOfCap(bare.len)
    var i = 0
    while i < bare.len:
      if i + 1 < bare.len and bare[i] in {'_', '^'} and bare[i + 1] == '{':
        let cb = bare.find('}', i + 2)
        let ob = bare.find('{', i + 2)
        if ob >= 0 and cb > ob and ob + 2 < bare.len and bare[ob + 1] in {'+', '-', '~', '>', '='}:
          var hoisted = ""
          var k = ob
          var ok = true
          while k < bare.len and bare[k] == '{':
            let cl = case bare[k + 1]
                     of '+': "++}"
                     of '-': "--}"
                     of '~': "~~}"
                     of '>': "<<}"
                     else: "==}"
            let e = bare.find(cl, k + 3)
            if e < 0: ok = false; break
            hoisted.add bare[k ..< e + 3]; k = e + 3
          if ok and k < bare.len and bare[k] == '}':
            o.add bare[i ..< ob] & "}" & hoisted
            i = k + 1; continue
      o.add bare[i]; inc i
    bare = o
  bare = commentsOutOfWords(bare)
  let ct = rbTokens(canon, xrefMap)
  let tt = rbTokens(bare, xrefMap)
  var ci, ti: seq[int]                            # significant token indexes
  for k, t in ct: (if t.key.len > 0: ci.add k)
  for k, t in tt: (if t.key.len > 0: ti.add k)
  let n = ci.len
  let m = ti.len
  if n == 0 or m == 0: return ""
  # LCS table (suffix form), uint16 cells -- paragraphs are a few hundred tokens
  var dp = newSeq[uint16]((n + 1) * (m + 1))
  template D(a, b: int): untyped = dp[(a) * (m + 1) + (b)]
  for a in countdown(n - 1, 0):
    for b in countdown(m - 1, 0):
      D(a, b) = if ct[ci[a]].key == tt[ti[b]].key: D(a + 1, b + 1) + 1
                else: max(D(a + 1, b), D(a, b + 1))
  if D(0, 0).int * 2 < n: return ""              # too little in common
  proc glueBefore(toks: seq[RbTok]; idx: seq[int]; p: int): string =
    let lo = if p == 0: 0 else: idx[p - 1] + 1
    let hi = if p < idx.len: idx[p] else: toks.len
    for k in lo ..< hi: result.add toks[k].text
  proc fmtOnly(g: string): string =
    for ch in g:
      if ch in {'*', '/', '_'}: result.add ch
  proc wsOnly(g: string): string =
    if g.len == 0: "" else:
      (if g.anyIt(it in {' ', '\t', '\n'}) or " " in g: " " else: "")
  result = ""
  var a = 0
  var b = 0
  while a < n or b < m:
    if a < n and b < m and ct[ci[a]].key == tt[ti[b]].key:
      result.add glueBefore(ct, ci, a) & ct[ci[a]].text
      inc a; inc b
    elif b < m and (a == n or D(a, b + 1) >= D(a + 1, b)):
      result.add wsOnly(glueBefore(tt, ti, b)) & tt[ti[b]].text
      inc b
    else:
      let tok = ct[ci[a]]
      if tok.key.startsWith("M{>>"):                  # canonical comments always survive
        result.add glueBefore(ct, ci, a) & tok.text
      else:
        result.add fmtOnly(glueBefore(ct, ci, a))     # keep emphasis balanced
      inc a
  result.add glueBefore(ct, ci, n)
  for (x, tok) in anchors:
    let p = result.find(tok)
    if p > x.len and x.strip.len >= 3 and x.anyIt(it.isAlphaNumeric) and
       result[0 ..< p].endsWith(x) and not insideAnnotation(result, p - x.len):
      result = result[0 ..< p - x.len] & "{==" & x & "==}" & result[p .. ^1]

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
  let ay = buildAuthorYearMap(canonical, baseDir)
  let xrefMap = buildXrefMap(canonical)
  proc backsub(t: string): string =
    substituteXrefs(substituteAuthorYear(substituteCiteKeys(t, num2key), ay), xrefMap)
  proc backsubFor(t, canon: string): string =
    ## Back-substitution for a tracked paragraph replacing canonical CANON:
    ## rendered `Table N' / `Figure N' become cross-refs only where CANON used
    ## them (a response letter's plain "Table 1" stays plain); and when the
    ## paragraph carries as many citations as CANON, CANON's own `[cite:]'s
    ## are put back in order -- exact keys and order, instead of trusting the
    ## title match of the docx bibliography (similar titles can mis-resolve)
    ## or leaving a number that did not resolve.
    result = substituteAuthorYear(substituteCiteKeys(t, num2key), ay)
    if "[cite:@fig:" in canon or "[cite:@tbl:" in canon or "[cite:@sec:" in canon or
       "[cite:@eq:" in canon:
      result = substituteXrefs(result, xrefMap)
    proc isXref(c: string): bool =
      for x in ["[cite:@fig:", "[cite:@tbl:", "[cite:@sec:", "[cite:@eq:", "[cite:@lst:"]:
        if c.startsWith(x): return true
    proc citeSpans(x: string; numeric: bool): seq[Slice[int]] =
      var k = 0
      while k < x.len:
        if startsWithAt(x, k, "[cite:"):
          let e = x.find(']', k)
          if e < 0: break
          if not isXref(x[k .. e]): result.add k .. e
          k = e + 1; continue
        if numeric and x[k] == '[' and (k == 0 or x[k - 1] notin {'[', ']'}):
          var e = k + 1
          while e < x.len and (x[e] in {'0'..'9', ',', ' ', '-'} or startsWithAt(x, e, "–")):
            e += (if startsWithAt(x, e, "–"): "–".len else: 1)
          if e < x.len and x[e] == ']' and e > k + 1 and x[k + 1].isDigit and
             (e + 1 >= x.len or x[e + 1] notin {'[', ']'}):
            result.add k .. e; k = e + 1; continue
        if numeric and x[k] == '^' and k + 2 < x.len and x[k + 1] == '{' and x[k + 2].isDigit:
          let e = x.find('}', k)
          if e > 0 and x[k + 2 ..< e].allCharsInSet({'0'..'9', ',', ' ', '-'}):
            result.add k .. e; k = e + 1; continue
        inc k
    let cc = citeSpans(canon, false)
    let tc = citeSpans(result, true)
    if cc.len > 0 and cc.len == tc.len:
      for k in countdown(tc.len - 1, 0):
        result = result[0 ..< tc[k].a] & canon[cc[k]] & result[tc[k].b + 1 .. ^1]
  proc listMarker(t: string): int =
    ## length of a leading `N. ' list marker, or 0
    var k = 0
    while k < t.len and t[k].isDigit: inc k
    if k > 0 and k + 1 < t.len and t[k] in {'.', ')'} and t[k + 1] == ' ': k + 2 else: 0
  let units = parseUnits(canonical)
  let cParas = bodyParas(units)
  let tUnits = parseUnits(tracked)
  let tParas = bodyParas(tUnits)
  let al = alignParagraphsEx(cParas, tParas)
  # Paragraph-end sentinels: where a comment that can't re-anchor goes (the
  # end of the canonical paragraph its tracked paragraph aligned to or follows).
  proc mark(k: int): string = "\x01P" & $k & "\x02"
  proc hasEdits(t: string): bool = "{++" in t or "{--" in t or "{~~" in t
  var outLines: seq[string]
  var bi = 0
  var nMerged = 0
  var nNew = 0
  for u in units:
    if u.kind == ukStruct:
      outLines.add u.text
    else:
      let ti = al.aligned[bi]
      if ti.len > 0 and (hasCriticMarkup(ti) or normalizeForMatch(ti) != normalizeForMatch(u.text)):
        var ti2 = ti
        # keep the canonical's list number: Word numbers each list item of a
        # docx apart, so pandoc hands every one back as `1.'
        let cm = listMarker(u.text)
        let tm = listMarker(ti2)
        if cm > 0 and tm > 0: ti2 = u.text[0 ..< cm] & ti2[tm .. ^1]
        var repl = rebaseOnCanonical(u.text,
                     substituteAuthorYear(substituteCiteKeys(ti2, num2key), ay), xrefMap)
        if repl.len == 0: repl = backsubFor(ti2, u.text)
        # the canonical paragraph's own comments must survive the replacement
        for c in criticComments(u.text):
          if not repl.contains(c): repl.add " " & c
        outLines.add repl & mark(bi)
        inc nMerged
      else:
        outLines.add u.text & mark(bi)
      # tracked paragraphs the alignment stepped over that carry edits -- a
      # paragraph a coauthor split off or wrote new -- go in right after
      # tracked paragraphs the alignment stepped over go in right after it when
      # they carry edits (a paragraph a coauthor wrote new) or hold text of
      # this canonical paragraph that its replacement lacks (a coauthor split
      # it in two: the replacement is only the first half)
      let replText = normalizeForMatch(outLines[^1])
      for j, t in tParas:
        if al.used[j] or al.owner[j] != bi: continue
        let tn = normalizeForMatch(t)
        let splitOff = wordContainment(tn, normalizeForMatch(u.text)) >= 0.8 and
                       wordContainment(tn, replText) < 0.8
        if hasEdits(t) or splitOff:
          outLines.add ""
          outLines.add substituteAuthorYear(substituteCiteKeys(t, num2key), ay)
          inc nNew
      inc bi
  var merged = outLines.join("\n")
  var nGrafted = 0
  var unplaced: seq[tuple[range, cmt: string]]
  reanchorComments(merged, tracked, num2key, xrefMap, nGrafted, unplaced)
  # The canonical's OWN comments must survive a paragraph replacement too:
  # graft any that the replaced tracked text no longer carries.
  reanchorComments(merged, canonical, num2key, xrefMap, nGrafted, unplaced)
  # Every tracked comment still missing (a short or repeated anchor, a comment
  # on a heading, a figure caption or a table) becomes a point comment at the
  # end of the paragraph it belongs to, quoting its anchor -- never nested
  # into a heading, caption, table or cite.
  var anchorOf: Table[string, string]
  for a in scanAnnotations(tracked): anchorOf["{>>" & a.cmt & "<<}"] = a.range
  var nPoint = 0
  var placedToks: HashSet[string]
  var still: seq[tuple[range, cmt: string]]
  var tb = -1                                  # tracked body-paragraph index
  var pendingHeading: seq[string]              # comments on struct lines
  proc place(tok: string; owner: int) =
    if merged.contains(tok) or merged.contains(backsub(tok)): return
    let rng = applyCriticMarkup(anchorOf.getOrDefault(tok, ""), accept = true).strip
    let inner = tok[3 ..< tok.len - 3]
    var note = inner
    if rng.len > 0:
      let q = "(re: \"" & (if rng.len > 60: rng[0 ..< 57] & "..." else: rng) & "\") "
      let rb = inner.find("] ")
      note = if inner.startsWith("[") and rb > 0: inner[0 .. rb + 1] & q & inner[rb + 2 .. ^1]
             else: q & inner
    let m = mark(max(owner, 0))
    if owner >= 0 and merged.contains(m):
      merged = merged.replace(m, " {>>" & note & "<<}" & m)
      placedToks.incl tok
      inc nPoint
    else:
      still.add (rng, inner)
  proc commentsIn(t: string): seq[string] =
    var k = 0
    while true:
      let p = t.find("{>>", k)
      if p < 0: break
      let e = t.find("<<}", p)
      if e < 0: break
      result.add t[p .. e + 2]; k = e + 3
  for u in tUnits:
    if u.kind == ukBody:
      inc tb
      let owner = if tb < al.owner.len: al.owner[tb] else: -1
      for tok in pendingHeading: place(tok, owner)
      pendingHeading.setLen 0
      for tok in commentsIn(u.text): place(tok, owner)
    else:
      pendingHeading.add commentsIn(u.text)
  for tok in pendingHeading: place(tok, cParas.len - 1)
  for k in 0 ..< cParas.len: merged = merged.replace(mark(k), "")
  merged = commentsOutOfWords(merged)
  for r in unplaced:
    let tok = "{>>" & r.cmt & "<<}"
    if tok notin placedToks and not merged.contains(tok) and
       not merged.contains(backsub(tok)) and r notin still: still.add r
  unplaced = still
  if unplaced.len > 0:
    merged.add "\n\n* Reviewer comments not auto-placed\n:PROPERTIES:\n:UNNUMBERED: t\n:END:\n"
    # The anchor text and the note are printed as plain text here, so neutralise
    # any stray CriticMarkup delimiters they carry (a mis-paired or overlapping
    # source annotation can leave one) -- otherwise the dumped `{>>note<<}' wrapper
    # would nest and leave the document with an unbalanced CriticMarkup token.
    proc flatCritic(s: string): string =
      s.multiReplace(("{==", ""), ("==}", ""), ("{>>", ""), ("<<}", ""),
                     ("{++", ""), ("++}", ""), ("{--", ""), ("--}", ""),
                     ("{~~", ""), ("~~}", ""), ("~>", " -> ")).strip
    for (r, c) in unplaced:
      merged.add "\n- re: " & flatCritic(r) & " :: " & "{>>" & flatCritic(c) & "<<}" & "\n"
  report = $nMerged & " paragraph" & (if nMerged == 1: "" else: "s") & " merged, " &
            (if nNew > 0: $nNew & " new, " else: "") &
            $nGrafted & " comment" & (if nGrafted == 1: "" else: "s") & " re-anchored" &
            (if nPoint > 0: ", " & $nPoint & " placed at their paragraph" else: "") &
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
  ## numbers (1, 2, ... in #+AFFIL declaration order) matching the numbered
  ## affiliation list below the byline (Nature-style numeric affiliations).
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
  var label: Table[string, string]
  for idx, a in affils: label[a[0]] = $(idx + 1)   # numeric superscripts, matching the list
  var authorStrs: seq[string]
  for au in authors:
    var sups: seq[string]
    for k in au.keys:
      if label.hasKey(k): sups.add label[k]
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
  criticTokensToOrg(toks)          # their text skipped md->org: convert it too
  let tracked = unstash(readFile(orgOut), toks)
  # Merge base: the org embedded in the docx when it survived the round-trip
  # (customXml, or the docProps fallback Word/OneDrive leave intact), else the
  # open buffer -- the canonical the user is working from.
  var canonical = extractOrgSource(docx)
  var base = "embedded org source"
  if canonical.len == 0 and app.filePath.len > 0 and app.filePath.endsWith(".org"):
    canonical = app.ed.fullText()
    base = "the open buffer" &
           (if gEmbeddedTruncated: " (the docx's embedded source was truncated by Word)" else: "")
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
  let orgStashed = stash(hoistCriticEmphasis(lines.join("\n")), toks)
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
