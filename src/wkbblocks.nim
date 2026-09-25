## Org src blocks as a dependency graph -- pure functions over buffer lines, so
## the editor (wkbcore) and tests share one parser.
##
## A block names itself with `#+name:` (org's affiliated keyword) and lists what
## it needs with `:depends a b ...` (our header arg; Emacs ignores unknown ones)
## or org's own `:var x=otherblock`. Each block gets a content hash over its
## language, session, header args, body AND the hashes of its dependencies, so
## editing a block makes everything downstream stale -- make-style. The hash is
## stored org-style in `#+RESULTS[<hash>]:`.

import std/[strutils, tables, md5, osproc, os, tempfiles, sets, algorithm, sequtils]

type
  BlockInfo* = object
    idx*: int                  ## ordinal among the buffer's src blocks
    header*: int               ## 0-based line of `#+begin_src`
    endLine*: int              ## 0-based line of `#+end_src`
    nameLine*: int             ## 0-based line of `#+name:`, -1 if unnamed
    lang*, name*, session*: string
    args*: seq[string]         ## header tokens: `#+header:` lines, then the begin_src line
    depends*: seq[string]      ## `:depends` names + `:var` block references
    cache*: bool               ## `:cache yes`
    body*: string
    resultsLine*: int          ## 0-based `#+RESULTS` line, -1 if none
    storedHash*: string        ## the hash in `#+RESULTS[<hash>]:`, "" if none
    hash*: string              ## current content hash (see computeHashes)

const affiliated = ["#+name:", "#+caption:", "#+header:", "#+attr_", "#+label:"]

proc isAffiliated(low: string): bool =
  for a in affiliated:
    if low.startsWith(a): return true

proc argValues*(toks: seq[string]; key: string): seq[string] =
  ## Every value token following each occurrence of `key` (up to the next `:arg`).
  var k = 0
  while k < toks.len:
    if toks[k] == key:
      var j = k + 1
      while j < toks.len and not toks[j].startsWith(":"):
        result.add toks[j]
        inc j
      k = j
    else: inc k

proc varRefs(vals: seq[string]): seq[string] =
  ## `:var x=block`, `x=block()`, `x=block[2:3]` -> "block"; literals are skipped.
  for v in vals:
    for part in v.split(','):
      let eq = part.find('=')
      if eq < 0: continue
      var rhs = part[eq + 1 .. ^1].strip()
      for stop in ['(', '[']:
        let p = rhs.find(stop)
        if p >= 0: rhs = rhs[0 ..< p]
      if rhs.len == 0 or rhs[0] in {'"', '\'', '0'..'9', '-'}: continue
      result.add rhs

proc parseResultsHash(line: string): string =
  ## "#+RESULTS[abc123]:" -> "abc123" ("" for a plain "#+RESULTS:").
  let s = line.strip()
  let a = s.find('[')
  let b = s.find(']')
  if s.toLowerAscii.startsWith("#+results[") and a >= 0 and b > a: s[a + 1 ..< b] else: ""

proc parseBlocks*(lines: seq[string]; defaults = initTable[string, seq[string]]()): seq[BlockInfo] =
  ## Every `#+begin_src` block, with names, args (document defaults for the
  ## block's language appended last, so the block's own args win), dependencies,
  ## body and stored results hash.
  var i = 0
  while i < lines.len:
    let low = lines[i].strip().toLowerAscii
    if not low.startsWith("#+begin_src"):
      inc i; continue
    var b = BlockInfo(idx: result.len, header: i, nameLine: -1, resultsLine: -1)
    let hdr = lines[i].strip().splitWhitespace()
    b.lang = if hdr.len >= 2: hdr[1].toLowerAscii else: ""
    var headerLineArgs: seq[string]
    var h = i - 1
    while h >= 0:
      let hl = lines[h].strip()
      let hlow = hl.toLowerAscii
      if not isAffiliated(hlow): break
      if hlow.startsWith("#+name:"):
        b.nameLine = h
        b.name = hl[hl.find(':') + 1 .. ^1].strip()
      elif hlow.startsWith("#+header:"):
        headerLineArgs.add hl.splitWhitespace()[1 .. ^1]
      dec h
    b.args = headerLineArgs & (if hdr.len > 2: hdr[2 .. ^1] else: @[])
    if defaults.hasKey(b.lang): b.args.add defaults[b.lang]
    let sess = argValues(b.args, ":session")
    b.session = if sess.len > 0: sess[0] else: "default"
    let cache = argValues(b.args, ":cache")
    b.cache = cache.len > 0 and cache[0].toLowerAscii == "yes"
    for d in argValues(b.args, ":depends"): b.depends.add d
    for d in varRefs(argValues(b.args, ":var")):
      if d notin b.depends: b.depends.add d
    var e = i + 1
    while e < lines.len and not lines[e].strip().toLowerAscii.startsWith("#+end_src"): inc e
    b.endLine = e
    var body: seq[string]
    for k in i + 1 ..< min(e, lines.len): body.add lines[k]
    b.body = body.join("\n")
    var p = e + 1
    while p < lines.len and lines[p].strip().len == 0: inc p
    if p < lines.len and lines[p].strip().toLowerAscii.startsWith("#+results"):
      b.resultsLine = p
      b.storedHash = parseResultsHash(lines[p])
    result.add b
    i = e + 1

proc refName*(name: string): string =
  ## How `:depends` refers to a block: header args are whitespace-separated, so a
  ## `#+name:` with spaces ("mx_ functions") is referenced with them as '_'.
  name.strip().splitWhitespace().join("_")

proc nameIndex*(blocks: seq[BlockInfo]): Table[string, int] =
  for b in blocks:
    if b.name.len > 0:
      if not result.hasKey(b.name): result[b.name] = b.idx
      let r = refName(b.name)
      if not result.hasKey(r): result[r] = b.idx

proc hashArgs(args: seq[string]): string =
  ## Header args that define the run (not `:cache`, which only says whether to
  ## skip it, nor `:depends`, which enters through the dependency hashes).
  var k = 0
  var keep: seq[string]
  while k < args.len:
    if args[k] in [":cache", ":depends"]:
      inc k
      while k < args.len and not args[k].startsWith(":"): inc k
    else:
      keep.add args[k]; inc k
  keep.join(" ")

proc hashVisit(blocks: var seq[BlockInfo]; names: Table[string, int];
               state: var seq[int]; i: int; problems: var seq[string]) =
  if state[i] == 2: return
  state[i] = 1
  var depHashes: seq[string]
  for d in blocks[i].depends:
    if not names.hasKey(d):
      problems.add "block " & $(i + 1) & ": unknown dependency '" & d & "'"
      continue
    let j = names[d]
    if state[j] == 1:
      problems.add "dependency cycle through '" & d & "'"
      continue
    hashVisit(blocks, names, state, j, problems)
    depHashes.add d & "=" & blocks[j].hash
  let b = blocks[i]
  blocks[i].hash = ($toMD5(b.lang & "\0" & b.session & "\0" & hashArgs(b.args) &
                           "\0" & b.body & "\0" & depHashes.join(",")))[0 ..< 12]
  state[i] = 2

proc computeHashes*(blocks: var seq[BlockInfo]): seq[string] =
  ## Fill `hash` for every block (dependencies first) and return problems:
  ## unknown dependency names and cycles. A block in a cycle hashes without the
  ## cyclic edge, so it still gets a stable hash.
  let names = nameIndex(blocks)
  var state = newSeq[int](blocks.len)   # 0 new, 1 visiting, 2 done
  for i in 0 ..< blocks.len: hashVisit(blocks, names, state, i, result)

proc orderVisit(blocks: seq[BlockInfo]; names: Table[string, int]; state: var seq[int];
                i: int; order, problems: var seq[string]; idxs: var seq[int]) =
  if state[i] == 2: return
  if state[i] == 1:
    problems.add "dependency cycle at block " & $(i + 1)
    return
  state[i] = 1
  for d in blocks[i].depends:
    if names.hasKey(d): orderVisit(blocks, names, state, names[d], order, problems, idxs)
    else: problems.add "block " & $(i + 1) & ": unknown dependency '" & d & "'"
  state[i] = 2
  idxs.add i

proc dependencyOrder*(blocks: seq[BlockInfo]; target: int; problems: var seq[string]): seq[int] =
  ## The transitive dependencies of `target`, dependencies first, target last.
  let names = nameIndex(blocks)
  var state = newSeq[int](blocks.len)
  var order: seq[string]
  orderVisit(blocks, names, state, target, order, problems, result)

# -- dependency inference (R) ---------------------------------------------------
# Static, from R's own parser: which top-level names a block assigns (not inside
# function bodies) and which free names it reads (codetools::findGlobals, both
# variables and functions). A block depends on the LATEST earlier block in the
# same session that assigns a name it reads. NSE column names (dplyr) can
# create false edges when they coincide with an assigned name; `assign()` with a
# computed name or `get()` are invisible -- the header stays editable.

const rAssignedFn* = """
lhs_name <- function(l) { while (is.call(l)) l <- l[[2]]; if (is.name(l)) as.character(l) else if (is.character(l)) l else NULL }
assigned <- function(ex) {
  out <- character()
  walk <- function(e) {
    if (!is.call(e)) return(invisible())
    fn <- if (is.name(e[[1]])) as.character(e[[1]]) else ""
    if (fn == "function") return(invisible())
    if (fn %in% c("<-", "=", "<<-") && length(e) >= 2) out <<- c(out, lhs_name(e[[2]]))
    if (fn == "assign" && length(e) >= 2 && is.character(e[[2]])) out <<- c(out, e[[2]])
    if (length(e) >= 2) for (i in 2:length(e)) tryCatch(walk(e[[i]]), error = function(err) NULL)
  }
  for (e in ex) walk(e)
  unique(out)
}
"""

const inferScript = rAssignedFn & """
used <- function(ex) {
  f <- function() NULL
  body(f) <- as.call(c(as.name("{"), as.list(ex)))
  g <- codetools::findGlobals(f, merge = FALSE)
  unique(c(g$variables, g$functions))
}
for (p in commandArgs(trailingOnly = TRUE)) {
  ex <- tryCatch(parse(p, keep.source = FALSE), error = function(e) NULL)
  if (is.null(ex)) { cat(basename(p), "\tPARSE-ERROR\t\n", sep = ""); next }
  cat(basename(p), "\t", paste(assigned(ex), collapse = ","), "\t",
      paste(used(ex), collapse = ","), "\n", sep = "")
}
"""

type SymInfo* = tuple[assigned, used: seq[string]; ok: bool]

proc rSymbols*(bodies: seq[string]; err: var string): seq[SymInfo] =
  ## Assigned/used names of each R body, via one Rscript call.
  result = newSeq[SymInfo](bodies.len)
  let dir = createTempDir("wkbdeps-", "")
  defer: removeDir(dir)
  var files: seq[string]
  for i, b in bodies:
    let f = dir / ("b" & $i & ".R")
    writeFile(f, b)
    files.add quoteShell(f)
  writeFile(dir / "infer.R", inferScript)
  let (outp, code) = execCmdEx("Rscript --vanilla " & quoteShell(dir / "infer.R") & " " &
                               files.join(" "))
  if code != 0:
    err = "Rscript failed: " & outp.strip()
    return
  for ln in outp.splitLines():
    let f = ln.split('\t')
    if f.len < 3 or not f[0].startsWith("b"): continue
    let i = try: parseInt(f[0][1 .. ^3]) except ValueError: -1   # "b12.R"
    if i < 0 or i >= bodies.len: continue
    if f[1] == "PARSE-ERROR": continue
    result[i] = (f[1].split(',').filterIt(it.len > 0), f[2].split(',').filterIt(it.len > 0), true)

proc inferDepends*(blocks: seq[BlockInfo]; syms: seq[SymInfo]; langs: openArray[string]): seq[seq[int]] =
  ## For each block, the indices of the earlier blocks (same language + session)
  ## that last assigned a name it reads. `syms` is indexed like `blocks`.
  result = newSeq[seq[int]](blocks.len)
  var lastDef: Table[string, int]            # session-key & "\0" & name -> block
  for i, b in blocks:
    if b.lang notin langs or not syms[i].ok: continue
    let sk = b.lang & "/" & b.session & "\0"
    var deps: seq[int]
    for s in syms[i].used:
      if lastDef.hasKey(sk & s):
        let j = lastDef[sk & s]
        if j != i and j notin deps: deps.add j
    deps.sort()
    result[i] = deps
    for s in syms[i].assigned: lastDef[sk & s] = i

proc suggestName*(b: BlockInfo; sym: SymInfo; taken: HashSet[string]): string =
  ## A readable, unique `#+name:` for an unnamed block: its first assigned
  ## symbol, else "block-<n>".
  var base = ""
  for s in sym.assigned:
    var c = ""
    for ch in s:
      c.add(if ch.isAlphaNumeric or ch in {'_', '-'}: ch else: '-')
    if c.len > 0 and c[0] != '.': base = c; break
  if base.len == 0: base = "block-" & $(b.idx + 1)
  result = base
  var n = 2
  while result in taken:
    result = base & "-" & $n
    inc n
