## wkbref -- reference context, keyed on a citation.
##
## Given a citekey, surface everything *you* have associated with that reference:
##   - your **prose**    -- paragraphs across your manuscript corpus that cite it
##   - your **notes**    -- Zotero notes on the item (added later)
##   - the **paper**     -- Mktero `source.md` full text (added later)
##
## Shared by the control-socket verbs (wkbctrl: cite-prose / cite-context / …)
## and the editor's `M-x cite-context` command (an extension). Pure Nim + the
## filesystem for prose; Zotero sources read its SQLite offline (added later).
##
## The corpus is a set of roots (config `gCorpusRoots`, or `$WKB_CORPUS`, or --
## with neither -- the open file's own directory). Indexing is cheap (a few MB),
## so the index is built lazily and rebuilt when any root's newest file changes.

import std/[os, strutils, tables, times, sets, hashes, algorithm, osproc]

var
  gCorpusRoots*: seq[string]   ## dirs to index for prose (config; `~` ok). Empty
                               ## -> `$WKB_CORPUS` (`:`/`;`-separated), else the
                               ## open file's directory.
  gZoteroDir*: string          ## Zotero data dir (holds zotero.sqlite + the
                               ## Better BibTeX db). Empty -> `$ZOTERO_DIR`, else
                               ## `~/Zotero`.

type
  Occurrence* = object
    file*: string       ## absolute path
    line*: int          ## 1-based line where the paragraph starts
    para*: string       ## the paragraph text (single spaced-joined string)
    mtime*: Time        ## the file's mtime (newest wins on dedup)
  ProseIndex* = Table[string, seq[Occurrence]]

const
  keyChars = {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '+', '-'}
  # `:` deliberately excluded -- a key containing ':' is a pandoc-crossref label
  # (@fig:/@tbl:/@sec:/@eqn:), never a Zotero citekey (verified: 0 keys with ':').

# ---- citekey extraction ----------------------------------------------------

proc addKey(dst: var seq[string]; raw: string; requireYear: bool) =
  ## Validate and add a candidate key (already stripped of a leading '@').
  if raw.len == 0 or ':' in raw: return          # crossref label -> skip
  for c in raw:
    if c notin keyChars: return
  if requireYear:                                 # bare @key must look like a
    var hasYear = false                           # BBT key (…Year) to avoid
    var i = 0                                      # @article / @book / emails
    while i + 3 < raw.len:
      if raw[i] in {'0'..'9'} and raw[i+1] in {'0'..'9'} and
         raw[i+2] in {'0'..'9'} and raw[i+3] in {'0'..'9'}: hasYear = true; break
      inc i
    if not hasYear: return
  dst.add raw

proc keyAtPoint*(line: string; col: int): string =
  ## The citekey under, or nearest to, column COL on LINE (for `M-x cite-context`
  ## on the citation at point), or "" if the line has no bibliography key.
  ## Crossref labels (`@fig:`) are ignored.
  var best = ""
  var bestDist = int.high
  var i = 0
  while i < line.len:
    if line[i] == '@' and (i == 0 or line[i-1] notin keyChars):
      var k = i + 1
      while k < line.len and line[k] in keyChars: inc k
      let key = line[i+1 ..< k]
      if key.len > 0 and ':' notin key:
        let d = if col >= i and col <= k: 0
                elif col < i: i - col else: col - k
        if d < bestDist: bestDist = d; best = key
      i = k
    else: inc i
  best   # nearest valid key on the line (the user invoked on this citation)

proc extractKeys*(text: string): seq[string] =
  ## Citekeys cited in TEXT. Handles org-cite `[cite:@a;@b]` / `[cite/t:@a]` and
  ## pandoc `[@a; @b]` (keys taken leniently inside brackets), plus bare `@key…Year`
  ## (taken strictly). Crossref labels (`@fig:x`) are excluded.
  var i = 0
  while i < text.len:
    if text[i] == '[':
      # Is this a citation bracket? [cite...:  or  [@
      let close = text.find(']', i + 1)
      if close < 0: inc i; continue
      let inner = text[i+1 ..< close]
      let low = inner.toLowerAscii
      let isCite = low.startsWith("cite") or inner.startsWith("@") or
                   (inner.len > 1 and inner[0] == '-' and inner[1] == '@')
      if isCite:
        var j = 0
        while j < inner.len:                       # every @token inside the bracket
          if inner[j] == '@':
            var k = j + 1
            while k < inner.len and inner[k] in keyChars: inc k
            addKey(result, inner[j+1 ..< k], requireYear = false)
            j = k
          else: inc j
        i = close + 1
        continue
      i = close + 1
      continue
    if text[i] == '@' and (i == 0 or text[i-1] notin keyChars and text[i-1] != '['):
      var k = i + 1
      while k < text.len and text[k] in keyChars: inc k
      addKey(result, text[i+1 ..< k], requireYear = true)
      i = k
      continue
    inc i

# ---- CriticMarkup: accept-all to the clean prose you wrote -----------------

proc acceptCritic*(s: string): string =
  ## Resolve CriticMarkup to the accepted text: keep {++ins++}, drop {--del--},
  ## take the new side of {~~old~>new~~}, keep {==highlight==}, drop {>>comment<<}.
  ## So the indexed/displayed paragraph is the clean prose, not review scaffolding.
  var i = 0
  while i < s.len:
    if i + 2 < s.len and s[i] == '{' and s[i+1] in {'+', '-', '~', '>', '='} and
       s[i+2] == s[i+1]:
      let mk = s[i+1]
      let closeSeq = (case mk
        of '+': "++}"
        of '-': "--}"
        of '~': "~~}"
        of '>': "<<}"
        else: "==}")
      let e = s.find(closeSeq, i + 3)
      if e < 0: result.add s[i]; inc i; continue
      let inner = s[i+3 ..< e]
      # Recurse on KEPT content: CriticMarkup nests (a {>>comment<<} inside an
      # {++insertion++}), so the inner must be resolved too, not copied verbatim.
      case mk
      of '+', '=': result.add acceptCritic(inner)   # insertion / highlight: keep
      of '-', '>': discard                          # deletion / comment: drop
      of '~':                                        # substitution: take new side
        let arrow = inner.find("~>")
        result.add acceptCritic(if arrow >= 0: inner[arrow+2 .. ^1] else: inner)
      else: discard
      i = e + closeSeq.len
    else:
      result.add s[i]; inc i

# ---- paragraph splitting (light org/markdown) ------------------------------

proc isStructural(line: string): bool =
  ## Lines that are never body prose: headings, keywords, drawers, list/table
  ## scaffolding, comments.
  let s = line.strip
  if s.len == 0: return true
  if s[0] in {'*', '#'} : return true            # org heading / md heading / #+kw
  if s.startsWith(":") and s.endsWith(":"): return true   # :PROPERTIES: / :END:
  if s.startsWith("#+"): return true
  if s.startsWith("|"): return true              # table row
  false

proc criticDelta(line: string): int =
  ## Net CriticMarkup nesting change on LINE: openers ({++ {-- {~~ {>> {==)
  ## minus closers (++} --} ~~} <<} ==}). Lets a multi-line comment/edit hold a
  ## paragraph open across blank lines so it is never split mid-construct.
  for tok in ["{++", "{--", "{~~", "{>>", "{=="]: result += line.count(tok)
  for tok in ["++}", "--}", "~~}", "<<}", "==}"]: result -= line.count(tok)

proc splitParagraphs(text: string): seq[tuple[line: int; para: string]] =
  ## Blank-line-separated body paragraphs, skipping headings/keywords/drawers and
  ## the bodies of `#+begin_…`/```` ``` ```` fenced blocks (code isn't prose). A
  ## paragraph is not broken while a CriticMarkup construct is still open, so
  ## multi-line coauthor comments/edits stay whole (and strip cleanly).
  var cur: seq[string]
  var startLine = 0
  var inFence = false
  var fenceKind = ""     # "src" (org) or "```"/"~~~" (md)
  var criticDepth = 0    # >0 while inside an unclosed CriticMarkup construct
  proc flush(res: var seq[tuple[line: int; para: string]]) =
    if cur.len > 0: res.add (startLine, cur.join(" ")); cur = @[]
  var ln = 0
  for raw in text.split('\n'):
    inc ln
    let s = raw.strip
    let low = s.toLowerAscii
    if inFence:
      if (fenceKind == "src" and low.startsWith("#+end")) or
         (fenceKind != "src" and (s == "```" or s == "~~~" or s.startsWith("```") and fenceKind == "```")):
        inFence = false
      continue
    if criticDepth > 0:                       # inside a spanning comment/edit:
      if cur.len == 0: startLine = ln          # take the line whole, don't flush
      cur.add s
      criticDepth += criticDelta(raw)
      if criticDepth < 0: criticDepth = 0
      continue
    if low.startsWith("#+begin"): (flush(result); inFence = true; fenceKind = "src"; continue)
    if s.startsWith("```") or s.startsWith("~~~"):
      flush(result); inFence = true
      fenceKind = (if s.startsWith("```"): "```" else: "~~~"); continue
    if isStructural(raw):
      flush(result)
    else:
      if cur.len == 0: startLine = ln
      cur.add s
      criticDepth += criticDelta(raw)
      if criticDepth < 0: criticDepth = 0

# ---- dedup across drafts ---------------------------------------------------

proc wordSet(s: string): HashSet[string] =
  var w = ""
  for ch in s:
    if ch.isAlphaNumeric: w.add ch.toLowerAscii
    else:
      if w.len >= 4: result.incl w
      w = ""
  if w.len >= 4: result.incl w

proc jaccard(a, b: HashSet[string]): float =
  if a.len == 0 or b.len == 0: return 0.0
  (a * b).len.float / (a + b).len.float

# ---- index build + lookup --------------------------------------------------

proc corpusRoots*(currentFile: string): seq[string] =
  for r in gCorpusRoots:
    let e = expandTilde(r.strip)
    if e.len > 0 and e notin result: result.add e
  let env = getEnv("WKB_CORPUS")
  if env.len > 0:
    for r in env.split({':', ';'}):
      let e = expandTilde(r.strip)
      if e.len > 0 and e notin result: result.add e
  if result.len == 0 and currentFile.len > 0:
    result.add parentDir(absolutePath(currentFile))

proc corpusFiles(roots: seq[string]): seq[string] =
  ## Your manuscripts: `.org` and `.Rmd` under each root. Generated `.md`
  ## (knitr reports, backups) is deliberately excluded -- it isn't your prose,
  ## and the paper's own Markdown (Mktero `source.md`) comes via Zotero, not here.
  for root in roots:
    if not dirExists(root):
      if fileExists(root): result.add root
      continue
    for path in walkDirRec(root):
      let ext = splitFile(path).ext.toLowerAscii
      if ext == ".org" or ext == ".rmd": result.add path

proc buildProseIndex*(roots: seq[string]): ProseIndex =
  ## Walk ROOTS, split each file into body paragraphs, and index every paragraph
  ## by the citekeys it contains. Near-identical paragraphs (across draft
  ## versions) collapse to the newest. wordSets are computed once per paragraph
  ## (the dedup compares cached sets, not re-tokenised strings).
  var wsBy: Table[string, seq[HashSet[string]]]   # parallel to result[key]
  for f in corpusFiles(roots):
    var content: string
    try: content = readFile(f)
    except CatchableError: continue
    let mt = try: getLastModificationTime(f) except CatchableError: getTime()
    let fabs = absolutePath(f)
    for (line, rawPara) in splitParagraphs(content):
      var para = acceptCritic(rawPara)            # clean prose: dedup + display
      for tok in ["{++", "{--", "{~~", "{>>", "{==",  # blank any orphan delimiters
                  "++}", "--}", "~~}", "<<}", "==}"]:   # left by malformed markup
        if tok in para: para = para.replace(tok, "")
      let keys = extractKeys(para)
      if keys.len == 0: continue
      let occ = Occurrence(file: fabs, line: line, para: para.strip, mtime: mt)
      let ws = wordSet(para)
      for key in keys.toHashSet:                  # a key cited twice in one para -> once
        if key notin result: result[key] = @[]; wsBy[key] = @[]
        var dup = -1
        for idx in 0 ..< result[key].len:         # dedup vs cached wordSets
          if jaccard(ws, wsBy[key][idx]) >= 0.85: dup = idx; break
        if dup >= 0:
          if occ.mtime > result[key][dup].mtime: result[key][dup] = occ; wsBy[key][dup] = ws
        else:
          result[key].add occ; wsBy[key].add ws

# lazy cache: rebuild when the roots set or the newest mtime changes
var
  gIdx: ProseIndex
  gIdxSig: string

proc rootsSignature(roots: seq[string]): string =
  var newest: Time
  for f in corpusFiles(roots):
    let mt = try: getLastModificationTime(f) except CatchableError: continue
    if mt > newest: newest = mt
  $hash(roots.join("|")) & ":" & $newest.toUnix

proc citeProse*(currentFile, key: string): seq[Occurrence] =
  ## Paragraphs across the corpus that cite KEY, newest first. Builds/reuses the
  ## lazy index.
  let roots = corpusRoots(currentFile)
  let sig = rootsSignature(roots)
  if sig != gIdxSig:
    gIdx = buildProseIndex(roots); gIdxSig = sig
  if key in gIdx:
    result = gIdx[key]
    result.sort(proc (a, b: Occurrence): int = cmp(b.mtime, a.mtime))

proc reindexProse*(currentFile: string): int =
  ## Force a rebuild; return the number of distinct citekeys indexed.
  let roots = corpusRoots(currentFile)
  gIdx = buildProseIndex(roots); gIdxSig = rootsSignature(roots)
  gIdx.len

# ---- Zotero: notes on the cited item (offline SQLite read) ------------------
# Read a citekey's Zotero notes by joining Better BibTeX's citekey table to
# Zotero's itemNotes. The two SQLite files are opened `immutable=1` -- no copy,
# no lock fight, works whether Zotero is running or not.

proc zoteroDir*(): string =
  if gZoteroDir.len > 0: return expandTilde(gZoteroDir)
  let env = getEnv("ZOTERO_DIR")
  if env.len > 0: return expandTilde(env)
  getHomeDir() / "Zotero"

proc zoteroDbs(): tuple[zt, bbt: string] =
  ## (zotero.sqlite, better-bibtex db) paths, or "" for a missing one.
  let dir = zoteroDir()
  let zt = dir / "zotero.sqlite"
  result.zt = if fileExists(zt): zt else: ""
  for name in ["better-bibtex-search.sqlite", "better-bibtex.sqlite"]:
    if fileExists(dir / name): result.bbt = dir / name; break

proc safeKey(key: string): bool =
  ## A citekey is safe to interpolate into SQL iff it is all key chars (no
  ## quotes/spaces) -- our keys are validated to this set, so this just guards.
  if key.len == 0: return false
  for c in key:
    if c notin keyChars: return false
  true

proc htmlToText*(html: string): string =
  ## Zotero notes are HTML; render to plain text: block tags -> newlines, list
  ## items -> "- ", other tags dropped, common entities decoded.
  var s = html
  s = s.multiReplace(("</p>", "\n"), ("<br>", "\n"), ("<br/>", "\n"),
                     ("<br />", "\n"), ("</div>", "\n"), ("</h1>", "\n"),
                     ("</h2>", "\n"), ("</h3>", "\n"), ("</li>", "\n"),
                     ("<li>", "\n- "))
  var noTags = newStringOfCap(s.len)            # drop remaining < … > tags
  var inTag = false
  for c in s:
    if c == '<': inTag = true
    elif c == '>': inTag = false
    elif not inTag: noTags.add c
  result = noTags.multiReplace(("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                               ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                               ("&apos;", "'"))
  # collapse 3+ newlines to a blank line, trim
  while "\n\n\n" in result: result = result.replace("\n\n\n", "\n\n")
  result = result.strip

proc citeNotes*(key: string): seq[string] =
  ## Your Zotero notes on the item with citekey KEY (plain text), or @[].
  if not safeKey(key): return
  let sqlite = findExe("sqlite3")
  if sqlite.len == 0: return
  let (zt, bbt) = zoteroDbs()
  if zt.len == 0 or bbt.len == 0: return
  # A printable sentinel between notes: the sqlite3 CLI renders control chars
  # (e.g. char(30)) in caret notation, so a control-char separator would not
  # survive. DISTINCT collapses Zotero's duplicate itemNotes rows (sync can leave
  # several identical note rows on one item).
  const sep = "@@WKB_NOTE_SEP@@"
  let sql = "ATTACH 'file:" & bbt & "?immutable=1' AS bbt;" &
    "SELECT DISTINCT n.note || '" & sep & "' FROM bbt.citekeys b " &
    "JOIN itemNotes n ON n.parentItemID = b.itemID WHERE b.citekey = '" & key & "';"
  let (outp, code) = execCmdEx(quoteShell(sqlite) & " " &
    quoteShell("file:" & zt & "?immutable=1") & " " & quoteShell(sql))
  if code != 0: return
  for chunk in outp.split(sep):
    let t = htmlToText(chunk)
    if t.len > 0: result.add t

# ---- formatting ------------------------------------------------------------

proc shorten(s: string; n: int): string =
  if s.len <= n: s else: s[0 ..< n-1] & "…"

proc formatProse*(key: string; occs: seq[Occurrence]; homeDir = ""): string =
  ## Human/agent-readable rendering of prose occurrences for a key.
  if occs.len == 0: return "(no paragraphs cite @" & key & " in your corpus)"
  result = "@" & key & " — " & $occs.len &
           " paragraph" & (if occs.len == 1: "" else: "s") & " you've written:\n"
  for o in occs:
    var f = o.file
    if homeDir.len > 0 and f.startsWith(homeDir): f = "~" & f[homeDir.len .. ^1]
    result.add "\n" & f & ":" & $o.line & "\n  " & shorten(o.para, 500) & "\n"

proc formatNotes*(key: string; notes: seq[string]): string =
  ## Rendering of Zotero notes for a key.
  if notes.len == 0: return "(no Zotero notes on @" & key & ")"
  result = "@" & key & " — " & $notes.len &
           " Zotero note" & (if notes.len == 1: "" else: "s") & ":\n"
  for n in notes:
    result.add "\n  " & n.replace("\n", "\n  ") & "\n"

proc formatContext*(key: string; occs: seq[Occurrence]; notes: seq[string];
                    homeDir = ""): string =
  ## The dossier: your notes, then your prose. (Paper text joins later.)
  result = "═══ @" & key & " ═══\n\n"
  result.add "── Notes (Zotero) ──\n"
  result.add (if notes.len == 0: "(none)\n"
              else: formatNotes(key, notes).split('\n', 1)[1] & "\n")
  result.add "\n── You've written about this ──\n"
  result.add (if occs.len == 0: "(none in your corpus)\n"
              else: formatProse(key, occs, homeDir).split('\n', 1)[1])
