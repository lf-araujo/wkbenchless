## agent_tools -- wkbctl verbs for coding agents (3code / Claude Code in the
## terminal panel): the useful parts of nimlangserver's MCP tool set -- which is
## nimsuggest underneath -- plus session-panel runners, so an agent can locate
## symbols, check and build without reading whole files or spawning invisible
## shells.
##
## Symbol intelligence (a persistent `nimsuggest --v3 --autobind` per project):
##   wkbctl symbols [file]                      outline: "line: kind name"
##   wkbctl find-symbol <query>                 project-wide: "path:line: kind name"
##   wkbctl references <file> <line> [word|col] usages + definition: "path:line:col"
##   wkbctl def <file> <line> [word|col]         definition site(s)
##   wkbctl type-def <file> <line> [word|col]    type definition site(s)
## A position is "line + word" (or a 1-based column); the word may be omitted
## when the line has a single identifier. First use on a project spawns
## nimsuggest and its analysis warms in the background -- queries answer
## "still warming up" until then (outline answers right away).
##
## Run / check / build -- queued in the bash session, so they show in the
## panel and the editor returns to the terminal tab when the job finishes:
##   wkbctl check [file]                        nim check + "check: ok|FAILED"
##   wkbctl check-project [main.nim]             nim check on the project's main file
##   wkbctl build [nim c args...]               project build + "build: ok|FAILED"
##   wkbctl sh [session] < code                  bash in the session panel
##   wkbctl nim-run < code                       scratch.nim -> nim r (project paths apply)

import wkbcore
import std/[os, osproc, strutils, net, nativesockets, sequtils, times, streams, tables,
            algorithm]

const IdentChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}

# -- nimsuggest driver ------------------------------------------------------
#
# One `nimsuggest --v3 --autobind <project>` per project, kept alive between
# verbs (its analysis warms in the background). Commands go over a fresh TCP
# connection each -- nimsuggest closes the socket after answering -- and the
# reply is the v3 tab format:
#   section  symkind  qualifiedPath  signature  file  line(1-based)  col(0-based)
#   doc  quality  [endLine endCol]

type
  NsRow = object
    section, kind, name, typ, path, doc: string
    line, col: int

  NsState = ref object
    p: Process
    port: int
    project: string          ## the project file nimsuggest was started with

var
  gNs: NsState               ## the live instance (one project at a time)
  gNsErr = ""                ## why the last spawn failed ("" = fine)
  gWarmUntil = 0.0           ## epoch: until then, a query timed out recently

proc nimbleRoot(start: string): string =
  ## The closest ancestor dir holding a .nimble file ("" if none).
  var dir = start.absolutePath
  if not dir.dirExists: dir = dir.parentDir
  for i in 0 ..< 12:
    for f in walkFiles(dir / "*.nimble"): return dir
    let p = dir.parentDir
    if p == dir: break
    dir = p
  ""

proc nimbleField(txt, name: string): string =
  ## Value of `name = @["x"]` / `name = "x"` in .nimble text ("" if absent).
  for ln in txt.splitLines():
    var s = ln.strip()
    if not s.startsWith(name): continue
    s = s[name.len .. ^1].strip
    if not s.startsWith("="): continue
    let a = s.find('"')
    let b = if a >= 0: s.find('"', a + 1) else: -1
    if a >= 0 and b > a: return s[a + 1 ..< b]
  ""

proc nimbleMain(root: string): string =
  ## The first `bin` target's source file in the .nimble at `root` ("" if none).
  for f in walkFiles(root / "*.nimble"):
    let txt = try: readFile(f) except CatchableError: ""
    let bin = nimbleField(txt, "bin")
    if bin.len == 0: continue
    let d = nimbleField(txt, "srcDir")
    let srcDir = if d.len > 0: d else: "src"
    for cand in [root / srcDir / (bin & ".nim"), root / (bin & ".nim")]:
      if fileExists(cand): return cand
  ""

proc nsProjectFor(path: string): string =
  ## The project file nimsuggest should load to analyze `path`: the nimble
  ## bin target when there is one, else the file itself.
  let root = nimbleRoot(path)
  result = if root.len > 0: nimbleMain(root) else: ""
  if result.len == 0: result = path.absolutePath

proc ensureNs(project: string): NsState =
  ## A live nimsuggest for `project` (restarted when the project changes).
  if gNs != nil and gNs.project == project and gNs.p != nil and gNs.p.running:
    return gNs
  if gNs != nil and gNs.p != nil:
    try: gNs.p.kill() except CatchableError: discard
  gNs = nil
  gNsErr = ""
  var p: Process
  try:
    p = startProcess("nimsuggest",
                     args = ["--v3", "--autobind",
                             "--clientProcessId:" & $getCurrentProcessId(),
                             project],
                     options = {poUsePath})
  except CatchableError:
    gNsErr = "nimsuggest not found (" & getCurrentExceptionMsg() & ")"
    return nil
  let portLine = try: p.outputStream.readLine() except CatchableError: ""
  let port = try: parseInt(portLine.strip) except ValueError: 0
  if port == 0:
    gNsErr = "nimsuggest did not report a port (Nim >= 1.6 needed)"
    try: p.kill() except CatchableError: discard
    return nil
  gWarmUntil = 0.0
  gNs = NsState(p: p, port: port, project: project)
  gNs

proc nsCall(ns: NsState; cmd, file: string; line, col: int;
            dirty = ""): tuple[rows: seq[NsRow], timedOut: bool] =
  ## One command over a fresh connection; nimsuggest closes after answering.
  var s = newSocket()
  var buf = ""
  try:
    s.connect("127.0.0.1", Port(ns.port))
    let d = if dirty.len > 0: ";\"" & dirty & "\"" else: ""
    s.send(cmd & " \"" & file & "\"" & d & ":" & $line & ":" & $col & "\n")
    while true:
      let chunk = s.recv(4096, 15000)   # ms; warm answers in <1s, cold times out
      if chunk.len == 0: break           # server closed: answer complete
      buf.add chunk
  except TimeoutError:
    result.timedOut = true
  finally:
    try: s.close() except CatchableError: discard
  for ln in buf.splitLines():
    if ln.len == 0: continue
    let f = ln.split('\t')
    if f.len < 8: continue
    try:
      result.rows.add NsRow(section: f[0], kind: f[1], name: f[2], typ: f[3],
                            path: f[4], line: parseInt(f[5]), col: parseInt(f[6]),
                            doc: f[7])
    except ValueError: discard

proc warmingMsg(ns: NsState): string =
  gWarmUntil = epochTime() + 30   # don't hammer a busy server from the main loop
  "(nimsuggest is still analyzing " & ns.project & " in the background -- try again in a bit)"

proc kindShort(k: string): string =
  if k.startsWith("sk") and k.len > 2: k[2 .. ^1].toLowerAscii else: k

proc lastName(qualified: string): string =
  let i = qualified.rfind('.')
  if i >= 0: qualified[i + 1 .. ^1] else: qualified

proc relPath(p: string): string =
  try: relativePath(p, getCurrentDir()) except CatchableError: p

# -- position + target resolution -------------------------------------------

proc lineTextOf(app: App; path: string): string =
  ## The file's current text: the live buffer when it is the open file.
  if app.filePath.len > 0 and path.absolutePath == app.filePath.absolutePath:
    app.ed.fullText()
  else:
    try: readFile(path) except CatchableError: ""

proc resolvePos(app: App; path, lineArg, colArg: string): tuple[line, col: int, err: string] =
  ## "line + (word | 1-based column | first identifier)" -> a nimsuggest
  ## position (1-based line, 0-based col). The col points INSIDE the word: its
  ## first char can ambiguously match an enclosing symbol (e.g. a proc's
  ## implicit `result`), which nimsuggest resolves instead of the word.
  let ln = try: parseInt(lineArg) except ValueError: 0
  if ln <= 0: return (0, 0, "give a 1-based line number")
  let txt = lineTextOf(app, path).splitLines()
  if ln > txt.len: return (0, 0, path & " has " & $txt.len & " lines")
  let text = txt[ln - 1]
  var col = -1
  if colArg.len > 0:
    if colArg.allCharsInSet(Digits):          # an explicit 1-based column
      col = (try: parseInt(colArg) except ValueError: 0) - 1
    else:                                     # or a word to locate on the line
      let i = text.find(colArg)
      if i < 0: return (0, 0, "'" & colArg & "' is not on line " & lineArg)
      col = i
  else:                                       # else: the first identifier
    var s = 0
    while s < text.len and text[s] notin IdentChars: inc s
    if s >= text.len: return (0, 0, "no identifier on line " & lineArg)
    col = s
  if col < 0 or col >= text.len: return (0, 0, "column past end of line")
  if col + 1 < text.len and text[col + 1] in IdentChars: inc col
  (ln, col, "")

proc targetFile(app: App; fileArg: string): string =
  ## The .nim file a verb operates on: the argument, else the open buffer.
  if fileArg.len > 0:
    let q = expandTilde(fileArg)
    result = if isAbsolute(q): q else: getCurrentDir() / q
    if not fileExists(result): return ""
  else:
    result = app.filePath
  if result.len == 0 or not result.endsWith(".nim"): result = ""

proc dirtyFor(app: App; path: string): string =
  ## When `path` is the open (possibly unsaved) buffer, hand nimsuggest its
  ## live text via a scratch copy (the v3 "dirty file" mechanism).
  if app.filePath.len == 0 or path.absolutePath != app.filePath.absolutePath:
    return ""
  try:
    let dir = getTempDir() / "wkbenchless-ns"
    createDir(dir)
    let f = dir / extractFilename(path)
    writeFile(f, app.ed.fullText())
    f
  except CatchableError: ""

# -- nimsuggest-backed verbs --------------------------------------------------

proc vSymbols(app: var App; args: seq[string]; body: string): string =
  let path = targetFile(app, if args.len > 0: args[0] else: "")
  if path.len == 0: return "(symbols: give a .nim file, or open one)"
  let ns = ensureNs(nsProjectFor(path))
  if ns == nil: return "(symbols: " & gNsErr & ")"
  let (rows, to) = nsCall(ns, "outline", path, 0, 0, dirtyFor(app, path))
  if to and rows.len == 0: return warmingMsg(ns)
  if rows.len == 0: return "(no symbols in " & path & ")"
  for r in rows:
    result.add $r.line & ": " & kindShort(r.kind) & " " & lastName(r.name) & "\n"

proc vFindSymbol(app: var App; args: seq[string]; body: string): string =
  let query = if args.len > 0: args.join(" ") else: ""
  if query.len == 0: return "(find-symbol: give a name to search for)"
  let start = if app.filePath.endsWith(".nim"): app.filePath else: getCurrentDir()
  let root = nimbleRoot(start)
  if root.len == 0: return "(find-symbol: no .nimble project around here)"
  let main = nimbleMain(root)
  if main.len == 0: return "(find-symbol: no bin target in the .nimble)"
  let ns = ensureNs(main)
  if ns == nil: return "(find-symbol: " & gNsErr & ")"
  let (rows, to) = nsCall(ns, "globalSymbols", query, 0, 0)
  if to and rows.len == 0: return warmingMsg(ns)
  if rows.len == 0: return "(no symbol matches '" & query & "')"
  # project rows first (nimsuggest also matches the stdlib), order kept
  var mine, others: seq[NsRow]
  for r in rows:
    if r.path.startsWith(root): mine.add r else: others.add r
  for r in mine:
    result.add relPath(r.path) & ":" & $r.line & ": " & kindShort(r.kind) & " " &
               lastName(r.name) & "\n"
  if others.len > 0:
    result.add "(stdlib/other matches:\n"
    for i, r in others:
      if i >= 10:
        result.add "  ... " & $others.len & " total)\n"; break
      result.add "  " & r.path & ":" & $r.line & ": " & lastName(r.name) & "\n"
    if others.len <= 10: result.add "  )\n"
  if result.len == 0: result = "(no symbol matches '" & query & "')"

proc locRows(app: var App; cmd, verb: string; args: seq[string]): string =
  ## Shared by references / def / type-def: <file> <line> [word|col].
  if args.len < 2: return "(usage: " & verb & " <file> <line> [word|col])"
  let path = targetFile(app, args[0])
  if path.len == 0: return "(" & verb & ": no such .nim file: " & args[0] & ")"
  let (ln, col, err) = resolvePos(app, path, args[1], if args.len > 2: args[2] else: "")
  if err.len > 0: return "(" & verb & ": " & err & ")"
  let ns = ensureNs(nsProjectFor(path))
  if ns == nil: return "(" & verb & ": " & gNsErr & ")"
  let (rows, to) = nsCall(ns, cmd, path, ln, col, dirtyFor(app, path))
  if to and rows.len == 0: return warmingMsg(ns)
  if rows.len == 0:
    return "(" & verb & ": no symbol at " & path & ":" & $ln & ":" & $(col + 1) & ")"
  if cmd == "use":
    var defs, refs: seq[string]
    for r in rows:
      let loc = relPath(r.path) & ":" & $r.line & ":" & $(r.col + 1)
      if r.section == "def": defs.add loc
      elif r.section == "use": refs.add loc
    if defs.len > 0: result.add "definition: " & defs.join(" ") & "\n"
    result.add $refs.len & " reference" & (if refs.len == 1: "" else: "s") & ":\n"
    for r in refs: result.add "  " & r & "\n"
  else:
    for r in rows:
      result.add relPath(r.path) & ":" & $r.line & ":" & $(r.col + 1) & " " &
                 lastName(r.name) & "\n"

proc vReferences(app: var App; args: seq[string]; body: string): string =
  result = locRows(app, "use", "references", args)

proc vDef(app: var App; args: seq[string]; body: string): string =
  result = locRows(app, "def", "def", args)

proc vTypeDef(app: var App; args: seq[string]; body: string): string =
  result = locRows(app, "type", "type-def", args)

# -- session-panel verbs (queued bash jobs) ----------------------------------

proc shq(s: string): string =
  ## Single-quote for the bash snippets below (paths are agent-supplied).
  "'" & s.replace("'", "'\\''") & "'"

proc queueShell(app: var App; script: string): string =
  ## Run `script` in the bash session: visible in the panel, and the editor
  ## returns to the terminal tab when the job finishes.
  let id = submitEval(app, "bash", "default", script)
  if id == 0: return "(no bash session could start)"
  result = "queued: job " & $id

proc vSh(app: var App; args: seq[string]; body: string): string =
  if strip(body).len == 0: return "(no code on stdin)"
  let sess = if args.len > 0 and args[0].len > 0: args[0] else: "default"
  let id = submitEval(app, "bash", sess, body)
  if id == 0: return "(no bash session could start)"
  result = "queued: job " & $id

proc runCheck(app: var App; path: string): string =
  ## `nim check` on `path`, from its project root (config.nims applies), with a
  ## crisp pass/fail signal line at the end. Errors in imported files surface
  ## too -- the check compiles the import graph.
  let root = nimbleRoot(path)
  let dir = if root.len > 0: root else: path.parentDir
  let script =
    "( cd " & shq(dir) & " && nim check --hints:off --colors:off " & shq(path) &
    " ) 2>&1; st=$?; " &
    "if [ \"$st\" -eq 0 ]; then echo 'check: ok'; " &
    "else echo 'check: FAILED (exit '$st')'; fi"
  queueShell(app, script)

proc vCheck(app: var App; args: seq[string]; body: string): string =
  let path = targetFile(app, if args.len > 0: args[0] else: "")
  if path.len == 0: return "(check: give a .nim file, or open one)"
  runCheck(app, path)

proc vCheckProject(app: var App; args: seq[string]; body: string): string =
  var main = if args.len > 0 and args[0].len > 0: targetFile(app, args[0]) else: ""
  if main.len == 0:
    let start = if app.filePath.endsWith(".nim"): app.filePath else: getCurrentDir()
    let root = nimbleRoot(start)
    main = if root.len > 0: nimbleMain(root) else: ""
  if main.len == 0:
    return "(check-project: no .nimble bin target found -- pass the main .nim)"
  runCheck(app, main)

proc vBuild(app: var App; args: seq[string]; body: string): string =
  let start = if app.filePath.endsWith(".nim"): app.filePath else: getCurrentDir()
  let root = nimbleRoot(start)
  if root.len == 0: return "(build: no .nimble project here)"
  var cmd = getEnv("WKB_BUILD")          # full override
  if cmd.len == 0:
    let main = nimbleMain(root)
    cmd = "nim c --hints:off --colors:off"
    if args.len > 0: cmd &= " " & args.join(" ")
    if args.len == 0 or not args.anyIt(it.endsWith(".nim")):
      if main.len == 0: return "(build: no bin target in the .nimble -- pass a .nim file)"
      cmd &= " -o:" & shq(main.extractFilename.changeFileExt("")) & " " &
             shq(main.relativePath(root))
  let script =
    "( cd " & shq(root) & " && " & cmd & " ) 2>&1; st=$?; " &
    "if [ \"$st\" -eq 0 ]; then echo 'build: ok'; " &
    "else echo 'build: FAILED (exit '$st')'; fi"
  queueShell(app, script)

proc vNimRun(app: var App; args: seq[string]; body: string): string =
  ## Nim code from stdin. With nimteractive (registered below as the `nim`
  ## session) it goes to that warm session; otherwise scratch.nim + `nim r`
  ## in the bash session, from the project root so config.nims paths apply.
  if strip(body).len == 0: return "(no code on stdin)"
  if gRepls.hasKey("nim"):
    let id = submitEval(app, "nim", "default", body)
    if id != 0: return "queued: job " & $id
  let root = nimbleRoot(getCurrentDir())
  let dir = if root.len > 0: root else: getCurrentDir()
  let scratch = dir / "scratch.nim"
  try: writeFile(scratch, body)
  except CatchableError: return "(nim-run: cannot write " & scratch & ")"
  let script =
    "( cd " & shq(dir) & " && nim r --hints:off --colors:off " & shq(scratch) &
    " ) 2>&1; st=$?; " &
    "if [ \"$st\" -eq 0 ]; then echo 'nim-run: ok'; " &
    "else echo 'nim-run: FAILED (exit '$st')'; fi"
  queueShell(app, script)

# -- nimteractive as the `nim` session ---------------------------------------
#
# A python3 carrier hosts `nimteractive` (lf-araujo/nimteractive: a warm Nim
# session -- each eval compiles the growing script as a lib against a
# persistent nimcache and dlopens it, so only the delta recompiles). It speaks
# line-delimited JSON ops; the carrier translates the session's file+nonce
# run into an eval op and relays the result's stdout. Registered only when the
# binary exists, so `wkbctl eval nim`, `nim-run` and org `#+begin_src nim`
# blocks all get the fast warm path; without it they fall back to nim r.

proc registerNimSession() =
  var bin = findExe("nimteractive")
  if bin.len == 0:                 # the standard nimble bin dir, if not on PATH
    let cand = getHomeDir() / ".nimble" / "bin" / "nimteractive"
    if fileExists(cand): bin = cand
  if bin.len == 0: return
  let root = nimbleRoot(getCurrentDir())
  let cwd = if root.len > 0: root else: getCurrentDir()
  let pyCwd = "\"" & cwd.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
  let spec = ReplSpec(
    argv: @["python3", "-q", "-u"],
    env: @[("PYTHON_BASIC_REPL", "1")],
    prime:
      "import subprocess as _sp, json as _js, sys as _sys\n" &
      "_nt = _sp.Popen([" & "'" & bin & "'" & "], cwd=" & pyCwd & ", stdin=_sp.PIPE, stdout=_sp.PIPE, text=True)\n" &
      "def _nimacs_run(path, nonce):\n" &
      "    print('__NIMACS' '_BOR__', nonce)\n" &
      "    _nt.stdin.write(_js.dumps({'op':'eval','id':nonce,'code':open(path).read()}) + '\\n')\n" &
      "    _nt.stdin.flush()\n" &
      "    for _ln in _nt.stdout:\n" &
      "        _i = _ln.find('{')\n" &
      "        if _i < 0: continue\n" &
      "        try: _r = _js.loads(_ln[_i:])\n" &
      "        except ValueError: continue\n" &
      "        if _r.get('id') != nonce: continue\n" &
      "        if _r.get('op') == 'compiling':\n" &
      "            _sys.stdout.write('[compiling...]\\n'); continue\n" &
      "        _out = _r.get('stdout')\n" &
      "        if _out:\n" &
      "            _sys.stdout.write(_out)\n" &
      "            if not _out.endswith('\\n'): _sys.stdout.write('\\n')\n" &
      "        elif _r.get('op') != 'result':\n" &
      "            print(_ln, end='')\n" &
      "        break\n" &
      "    print('__NIMACS' '_END__', nonce)\n" &
      "    _sys.stdout.flush()\n" &
      "\n",
    ready: "print('NIMACS' 'xREADY')\n",
    run: "_nimacs_run('{file}','{nonce}')\n",
    quit: "_nt.stdin.write('{\"op\":\"exit\",\"id\":\"q\"}\\n'); _nt.stdin.flush()\n")
  registerRepl("nim", spec)

proc vHelp(app: var App; args: seq[string]; body: string): string =
  ## `wkbctl help`: every extension-registered verb, one line each -- the
  ## running editor is the source of truth, so agents never rely on stale docs.
  result = "agent verbs (run `wkbctl` with no args for the built-in list):\n"
  for name in toSeq(gCtlVerbs.keys).sorted:
    result.add "  " & name &
      (if gCtlVerbHelp.hasKey(name): "  --  " & gCtlVerbHelp[name] else: "") & "\n"

proc extend*(app: var App) =
  registerNimSession()
  registerCtlVerb("help", "list these verbs", vHelp)
  registerCtlVerb("symbols",
    "[file] -- outline: 'line: kind name' (default: the open buffer)", vSymbols)
  registerCtlVerb("find-symbol",
    "<query> -- project-wide symbol search: 'path:line: kind name'", vFindSymbol)
  registerCtlVerb("references",
    "<file> <line> [word|col] -- definition + usages of the symbol", vReferences)
  registerCtlVerb("def",
    "<file> <line> [word|col] -- definition site of the symbol", vDef)
  registerCtlVerb("type-def",
    "<file> <line> [word|col] -- definition of the symbol's type", vTypeDef)
  registerCtlVerb("check",
    "[file] -- nim check + 'check: ok|FAILED' (default: the open buffer)", vCheck)
  registerCtlVerb("check-project",
    "[main.nim] -- nim check on the project's main file", vCheckProject)
  registerCtlVerb("build",
    "[nim c args...] -- project build + 'build: ok|FAILED'", vBuild)
  registerCtlVerb("sh",
    "[session] -- bash from stdin, in the session panel", vSh)
  registerCtlVerb("nim-run",
    "-- Nim from stdin: warm nimteractive session (or scratch.nim + nim r)",
    vNimRun)
