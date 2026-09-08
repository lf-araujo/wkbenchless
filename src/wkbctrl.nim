## Control server: a loopback-TCP socket (127.0.0.1, ephemeral port) the editor
## polls (non-blocking, from the main loop -- NO thread) so external tools --
## `wkbctl`, `wkbenchless ctl <verb>`, or Claude in the terminal -- can drive the
## editor: run code in a live session, read the buffer, show a diff, run a command.
##
## Protocol (one request per connection; client half-closes after sending):
##   "buffer"                      -> the current buffer text
##   "eval\t<lang>\t<session>\n<code>" -> run <code> in that session, return output
##   "command\t<name>"             -> run a registered command
##   "diff\t<title>\n<OLD>\x1e<NEW>" -> open the side-by-side diff view
##   "blocks"                      -> list #+begin_src blocks
##
## Cross-platform via std/net (works on Windows too, unlike the old AF_UNIX
## transport). The chosen port + a random token are written to a user-private
## file (<cache>/wkbenchless/control.port -- "port\ntoken"); a client connects to
## 127.0.0.1:<port> and sends "token\n<request>". The token keeps another local
## user from port-scanning the socket (parity with the old unix-socket perms).

import std/[strutils, tables, net, nativesockets, os, random]
when defined(posix): import std/posix
import wkbcore

type ControlServer* = object
  listener*: Socket        ## nil when not started
  client*: Socket          ## the in-flight client, or nil
  inbuf*: string
  token*: string

# --- BibTeX search (wkbctl bib <query>) ------------------------------------
# Find citation keys without loading the .bib into an agent's context. Returns
# `key — Author (year). Title` lines. Searches the buffer's own
# `#+bibliography:` paths plus an optional master set via $WKB_BIB.
proc bibValue(entry, field: string): string =
  ## Value of `field = {…}` / `field = "…"` / `field = bareword` in an entry.
  let low = entry.toLowerAscii
  var i = 0
  while true:
    i = low.find(field, i)
    if i < 0: return ""
    var j = i + field.len
    while j < entry.len and entry[j] in {' ', '\t', '\n', '\r'}: inc j
    if j < entry.len and entry[j] == '=':
      inc j
      while j < entry.len and entry[j] in {' ', '\t', '\n', '\r'}: inc j
      if j >= entry.len: return ""
      if entry[j] == '{':
        var depth = 1
        var k = j + 1
        var buf = ""
        while k < entry.len and depth > 0:
          if entry[k] == '{': inc depth
          elif entry[k] == '}':
            dec depth
            if depth == 0: break
          buf.add entry[k]; inc k
        return strip(buf).replace("\r", " ").replace("\n", " ")
      elif entry[j] == '"':
        var k = j + 1
        var buf = ""
        while k < entry.len and entry[k] != '"': buf.add entry[k]; inc k
        return strip(buf).replace("\r", " ").replace("\n", " ")
      else:
        var k = j
        while k < entry.len and entry[k] notin {',', '\n', '}'}: inc k
        return strip(entry[j ..< k])
    i = i + field.len

proc bibPathsFromBuffer(app: App): seq[string] =
  for i in 0 ..< app.ed.getLineCount():
    let ln = strip(app.ed.getLineText(i))
    if ln.toLowerAscii.startsWith("#+bibliography:"):
      let p = strip(ln[ln.find(':') + 1 .. ^1])
      if p.len > 0 and p notin result: result.add p
  let master = getEnv("WKB_BIB")
  if master.len > 0 and master notin result: result.add master

proc resolveBib(p: string): string =
  let q = expandTilde(p)
  if q.len > 0 and not isAbsolute(q):
    let alt = getCurrentDir() / q
    if fileExists(alt): return alt
  q

proc bibSearch(app: App; query: string; limit = 30): string =
  let terms = query.toLowerAscii.splitWhitespace()
  var seen: seq[string]
  var hits: seq[string]
  for raw in bibPathsFromBuffer(app):
    let path = resolveBib(raw)
    if not fileExists(path): continue
    var txt = ""
    try: txt = readFile(path)
    except CatchableError: continue
    var i = txt.find('@')
    while i >= 0:
      let nxt = txt.find('@', i + 1)
      let entry = if nxt < 0: txt[i .. ^1] else: txt[i ..< nxt]
      let lb = entry.find('{')
      let comma = entry.find(',')
      if lb >= 0 and comma > lb:
        let key = strip(entry[lb + 1 ..< comma])
        if key.len > 0 and key notin seen:
          let author = bibValue(entry, "author")
          let title  = bibValue(entry, "title")
          let year   = bibValue(entry, "year")
          let hay = (key & " " & author & " " & title & " " & year).toLowerAscii
          var ok = true
          for t in terms:
            if not hay.contains(t): ok = false; break
          if ok:
            seen.add key
            let a1 = (if author.len > 0: author.split(" and ")[0] else: "?").multiReplace(("{", ""), ("}", ""))
            let yr = if year.len > 0: year else: "n.d."
            hits.add key & " — " & a1 & " (" & yr & "). " & title.multiReplace(("{", ""), ("}", ""))
      i = nxt
  if hits.len == 0: return "(no bib entry matches: " & query & ")"
  if hits.len > limit:
    hits = hits[0 ..< limit] & @["… (" & $hits.len & " matches; showing " & $limit & ")"]
  hits.join("\n")

proc citeGoto(app: var App; key: string): string =
  ## Open the .bib that defines `@type{key,` and move the cursor to that entry.
  let needle = "{" & key.toLowerAscii & ","        # matches @article{key,
  for raw in bibPathsFromBuffer(app):
    let path = resolveBib(raw)
    if not fileExists(path): continue
    var txt = ""
    try: txt = readFile(path)
    except CatchableError: continue
    var i = 0
    for ln in txt.splitLines():
      let low = ln.toLowerAscii.replace(" ", "")
      if low.startsWith("@") and low.contains(needle):
        openFile(app, path)
        app.ed.gotoLine(i + 1, 0)
        return "ok: " & key & " at " & extractFilename(path) & ":" & $(i + 1)
      inc i
  "cite-goto: key not found: " & key

proc handle(app: var App; req: string): string =
  let nl = req.find('\n')
  let header = (if nl >= 0: req[0 ..< nl] else: req).strip()
  let body = if nl >= 0: req[nl + 1 .. ^1] else: ""
  let parts = header.split('\t')
  case parts[0]
  of "buffer":
    result = app.ed.fullText()
  of "eval":
    let lang = if parts.len > 1 and parts[1].len > 0: parts[1] else: "r"
    let sess = if parts.len > 2 and parts[2].len > 0: parts[2] else: "default"
    let code = if body.len > 0: body elif parts.len > 3: parts[3] else: ""
    if strutils.strip(code).len == 0: return "(no code)"
    let s = getSession(app, lang, sess)
    if s == nil: return "(no session for '" & lang & "')"
    result = s.runBlock(code)
  of "command":
    if parts.len > 1 and gCommands.hasKey(parts[1]):
      app.msg = ""
      gCommands[parts[1]].run(app)
      # Echo the resulting status line so scripts/agents can read outcome/state.
      result = "ok: " & parts[1] & (if app.msg.len > 0: " -- " & app.msg else: "")
    else: result = "unknown command"
  of "diff":                             # show a side-by-side diff: body = OLD \x1e NEW
    let title = if parts.len > 1: parts[1] else: "diff"
    let sep = body.find('\x1e')
    if sep < 0: return "diff: body must be OLD\\x1eNEW"
    showDiff(app, body[0 ..< sep], body[sep + 1 .. ^1], title)
    result = "ok: diff (" & title & ")"
  of "set-buffer":                       # replace the whole buffer with <body>
    app.ed.setText(body)
    app.ed.markChanged()
    result = "ok: buffer set (" & $app.ed.getLineCount() & " lines)"
  of "insert", "replace":
    # insert\t<line>\n<text>            -- insert <text> before 1-based <line>
    # replace\t<from>\t<to>\n<text>     -- replace 1-based lines [from..to] with <text>
    let total = app.ed.getLineCount()
    var newBody = body.split('\n')
    if newBody.len > 0 and newBody[^1] == "": newBody.setLen(newBody.len - 1)
    let frm = (if parts.len > 1: (try: parseInt(parts[1]) except: 1) else: 1) - 1
    let a = clamp(frm, 0, total)
    let b = if parts[0] == "replace":
              clamp((if parts.len > 2: (try: parseInt(parts[2]) except: a) else: a), a, total)
            else: a                       # insert removes nothing
    var lines: seq[string]
    for i in 0 ..< total: lines.add app.ed.getLineText(i)
    let res = lines[0 ..< a] & newBody & lines[b ..< total]
    app.ed.setText(res.join("\n"))
    app.ed.markChanged()
    result = "ok: " & parts[0] & " at " & $(a + 1) &
             (if parts[0] == "replace": ".." & $b else: "")
  of "goto":                             # move the cursor to 1-based <line>
    let ln = (if parts.len > 1: (try: parseInt(parts[1]) except: 1) else: 1) - 1
    # `ln` is a 0-based index; gotoLine is 1-based, so pass +1.
    app.ed.gotoLine(clamp(ln, 0, app.ed.getLineCount() - 1) + 1, 0)
    result = "ok: goto " & $(ln + 1)
  of "run-block":                        # run the src block at/containing 1-based <line>
    # Position + run in ONE request (so the cursor is right when babel runs), the
    # editor's own C-c C-c: executes in the block's :session and writes #+RESULTS.
    var ln = (if parts.len > 1: (try: parseInt(parts[1]) except: 1) else:
                app.ed.currentLine + 1) - 1
    ln = clamp(ln, 0, app.ed.getLineCount() - 1)
    # `blocks` reports the header line; babel wants a body line.
    let low = strutils.strip(app.ed.getLineText(ln)).toLowerAscii
    if low.startsWith("#+begin_src") or low.startsWith("```"):
      ln = min(ln + 1, app.ed.getLineCount() - 1)
    app.ed.gotoLine(ln + 1, 0)           # `ln` is 0-based; gotoLine is 1-based
    babelExecute(app)
    result = "ok: " & app.msg
  of "blocks":
    let total = app.ed.getLineCount()
    var i = 0
    while i < total:
      let ln = strutils.strip(app.ed.getLineText(i))
      let low = ln.toLowerAscii
      if low.startsWith("#+begin_src") or low.startsWith("```{r"):
        result.add $(i + 1) & ": " & ln & "\n"
      inc i
    if result.len == 0: result = "(no src blocks)"
  of "bib":                                # search BibTeX for citation keys
    let q = if parts.len > 1 and parts[1].len > 0: parts[1] else: strip(body)
    if q.len == 0: return "(usage: bib <query>)"
    result = bibSearch(app, q)
  of "cite-goto":                          # jump to a BibTeX @key entry (opens the .bib)
    let key = if parts.len > 1 and parts[1].len > 0: parts[1] else: strip(body)
    if key.len == 0: return "(usage: cite-goto <key>)"
    result = citeGoto(app, key)
  of "cite-prose":                         # paragraphs across your corpus citing @key
    let key = if parts.len > 1 and parts[1].len > 0: parts[1] else: strip(body)
    if key.len == 0: return "(usage: cite-prose <key>)"
    result = formatProse(key, citeProse(app.filePath, key), getHomeDir())
  of "cite-reindex":                       # force a rebuild of the prose index
    result = "ok: reindexed " & $reindexProse(app.filePath) & " citekeys"
  of "cite-notes":                         # your Zotero notes on @key
    let key = if parts.len > 1 and parts[1].len > 0: parts[1] else: strip(body)
    if key.len == 0: return "(usage: cite-notes <key>)"
    result = formatNotes(key, citeNotes(key))
  of "cite-paper":                         # the paper's own Markdown text (Mktero)
    let key = if parts.len > 1 and parts[1].len > 0: parts[1] else: strip(body)
    if key.len == 0: return "(usage: cite-paper <key>)"
    result = formatPaper(key, citePaper(key), getHomeDir())
  of "cite-context":                       # everything you've associated with @key
    let key = if parts.len > 1 and parts[1].len > 0: parts[1] else: strip(body)
    if key.len == 0: return "(usage: cite-context <key>)"
    result = formatContext(key, citeProse(app.filePath, key), citeNotes(key),
                           citePaper(key), getHomeDir())
  of "open":                               # open a file into a buffer
    let p = if parts.len > 1 and parts[1].len > 0: parts[1] else: strip(body)
    if p.len == 0: return "(usage: open <path>)"
    let path = expandTilde(p)
    if not fileExists(path): return "open: no such file: " & path
    openFile(app, path)
    result = "ok: open " & extractFilename(path) &
             " (" & $app.ed.getLineCount() & " lines)"
  of "where":                              # cursor location + current file
    var off = 0
    for i in 0 ..< app.ed.currentLine: off += app.ed.getLineText(i).len + 1
    let col = app.ed.cursor - off
    result = (if app.filePath.len > 0: app.filePath else: "*scratch*") &
             ":" & $(app.ed.currentLine + 1) & ":" & $(col + 1) &
             " (" & $app.ed.getLineCount() & " lines)"
  of "selection":                          # current selection text (empty if none)
    let sel = app.ed.getSelectedText()
    result = if sel.len > 0: sel else: "(no selection)"
  else:
    result = "unknown verb: " & parts[0]

proc portPath*(): string = getCacheDir() / "wkbenchless" / "control.port"

proc genToken(): string =
  var r = initRand()
  const hex = "0123456789abcdef"
  for _ in 0 ..< 32: result.add hex[r.rand(15)]

proc startControl*(): ControlServer =
  ## Bind a loopback listener on an ephemeral port; record port+token so clients
  ## can find and authenticate to it. On failure the listener stays nil and
  ## `poll` is a no-op.
  try:
    let s = newSocket()
    s.setSockOpt(OptReuseAddr, true)
    s.bindAddr(Port(0), "127.0.0.1")
    s.listen()
    let (_, port) = s.getLocalAddr()
    s.getFd.setBlocking(false)
    when defined(posix):
      discard fcntl(s.getFd.cint, F_SETFD, FD_CLOEXEC)   # don't leak into forked sessions
    result.listener = s
    result.token = genToken()
    try: createDir(portPath().parentDir) except CatchableError: discard
    writeFile(portPath(), $port.int & "\n" & result.token & "\n")
    when defined(posix):
      try: setFilePermissions(portPath(), {fpUserRead, fpUserWrite})
      except CatchableError: discard
  except CatchableError:
    result = ControlServer()

proc poll*(cs: var ControlServer; app: var App) =
  if cs.listener == nil: return
  if cs.client == nil:                  # accept a pending connection (non-blocking)
    var lfds = @[cs.listener.getFd]
    if selectRead(lfds, 0) > 0:
      try:
        var c: Socket
        cs.listener.accept(c)
        c.getFd.setBlocking(false)
        when defined(posix):
          discard fcntl(c.getFd.cint, F_SETFD, FD_CLOEXEC)
        cs.client = c; cs.inbuf = ""
      except CatchableError: discard
  if cs.client != nil:
    var cfds = @[cs.client.getFd]
    while selectRead(cfds, 0) > 0:
      var chunk = ""
      try: chunk = cs.client.recv(4096)
      except CatchableError: chunk = ""
      if chunk.len == 0:                # client half-closed: request complete
        let nl = cs.inbuf.find('\n')    # first line is the auth token
        let tok = if nl >= 0: cs.inbuf[0 ..< nl] else: ""
        let body = if nl >= 0: cs.inbuf[nl + 1 .. ^1] else: ""
        let resp = if tok == cs.token: handle(app, body) else: "unauthorized"
        try: cs.client.send(resp) except CatchableError: discard
        try: cs.client.close() except CatchableError: discard
        cs.client = nil
        break
      cs.inbuf.add chunk
      cfds = @[cs.client.getFd]
