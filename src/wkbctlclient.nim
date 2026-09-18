## Control-socket client shared by the standalone `wkbctl` binary and the
## `wkbenchless ctl <verb>` subcommand -- so shipping just `wkbenchless` is
## enough. Loopback TCP (127.0.0.1), cross-platform (works on Windows too).
##
## Reads <cache>/wkbenchless/control.port ("port\ntoken"), connects, and sends
## "token\n<request>"; the token authenticates to the running editor.

import std/[net, os, strutils, nativesockets, json, md5]

when defined(windows):
  # winsock's shutdown(SD_SEND) to half-close the write side after the request.
  proc winShutdown(s: SocketHandle; how: cint): cint
    {.importc: "shutdown", stdcall, dynlib: "ws2_32.dll".}
else:
  from std/posix import shutdown, SHUT_WR

proc portPath(): string = getCacheDir() / "wkbenchless" / "control.port"

proc buildRequest(args: seq[string]; req: var string): string =
  ## Fill `req` from CLI args; return "" on success, else an error message.
  if args.len == 0:
    return "usage: ctl buffer|blocks|command <name>|eval [lang] [session]|\n" &
           "           set-buffer|insert <line>|replace <from> <to>|goto <line>|\n" &
           "           run-block [line]|run-all|diff <old> <new> [title]|bib <query>\n" &
           "           cite-goto <key>|open <path>|where|selection\n" &
           "  (verbs that take text read it from stdin)"
  case args[0]
  of "buffer", "blocks", "run-all":
    req = args[0]
  of "command":
    if args.len < 2: return "ctl command <name>"
    req = "command\t" & args[1]
  of "eval":
    let lang = if args.len > 1: args[1] else: "r"
    let sess = if args.len > 2: args[2] else: "default"
    req = "eval\t" & lang & "\t" & sess & "\n" & stdin.readAll()
  of "set-buffer":
    req = "set-buffer\n" & stdin.readAll()
  of "insert":
    if args.len < 2: return "ctl insert <line>   (text on stdin)"
    req = "insert\t" & args[1] & "\n" & stdin.readAll()
  of "replace":
    if args.len < 3: return "ctl replace <from> <to>   (text on stdin)"
    req = "replace\t" & args[1] & "\t" & args[2] & "\n" & stdin.readAll()
  of "goto":
    if args.len < 2: return "ctl goto <line>"
    req = "goto\t" & args[1]
  of "run-block":
    req = "run-block" & (if args.len > 1: "\t" & args[1] else: "")
  of "bib":
    if args.len < 2: return "ctl bib <query>"
    req = "bib\t" & args[1 .. ^1].join(" ")
  of "cite-goto":
    if args.len < 2: return "ctl cite-goto <key>"
    req = "cite-goto\t" & args[1]
  of "cite-prose":
    if args.len < 2: return "ctl cite-prose <key>"
    req = "cite-prose\t" & args[1]
  of "cite-notes":
    if args.len < 2: return "ctl cite-notes <key>"
    req = "cite-notes\t" & args[1]
  of "cite-paper":
    if args.len < 2: return "ctl cite-paper <key>"
    req = "cite-paper\t" & args[1]
  of "zotero-search":
    if args.len < 2: return "ctl zotero-search <query>"
    req = "zotero-search\t" & args[1 .. ^1].join(" ")
  of "cite-context":
    if args.len < 2: return "ctl cite-context <key>"
    req = "cite-context\t" & args[1]
  of "cite-reindex":
    req = "cite-reindex"
  of "open":
    if args.len < 2: return "ctl open <path>"
    req = "open\t" & args[1]
  of "where", "selection":
    req = args[0]
  of "diff":
    if args.len < 3: return "ctl diff <oldfile> <newfile> [title]"
    let title = if args.len > 3: args[3] else: extractFilename(args[2])
    req = "diff\t" & title & "\n" & readFile(args[1]) & "\x1e" & readFile(args[2])
  else:
    return "unknown verb: " & args[0]

proc ctlClient*(args: seq[string]): int =
  ## Run one control request; returns a process exit code.
  var req = ""
  let err = buildRequest(args, req)
  if err.len > 0:
    stderr.writeLine err
    return 1
  var port = 0
  var token = ""
  # Prefer this-instance coordinates from the env (exported by the launching
  # editor), so a hook targets the editor Claude was launched from; otherwise
  # fall back to the shared control.port file.
  let envPort = getEnv("WKB_CTL_PORT")
  let envTok  = getEnv("WKB_CTL_TOKEN")
  if envPort.len > 0 and envTok.len > 0:
    port = try: parseInt(envPort) except CatchableError: 0
    token = envTok
  else:
    let pf = portPath()
    if not fileExists(pf):
      stderr.writeLine "wkbenchless is not running (no control port at " & pf & ")"
      return 1
    try:
      let lines = readFile(pf).splitLines()
      port = parseInt(lines[0].strip())
      if lines.len > 1: token = lines[1].strip()
    except CatchableError:
      stderr.writeLine "bad control port file: " & pf
      return 1
  var s = newSocket()
  try:
    s.connect("127.0.0.1", Port(port))
  except CatchableError:
    stderr.writeLine "wkbenchless is not running (cannot connect 127.0.0.1:" & $port & ")"
    return 1
  s.send(token & "\n" & req)              # auth token line, then the request
  when defined(windows): discard winShutdown(s.getFd, 1)   # SD_SEND
  else: discard shutdown(s.getFd, SHUT_WR)
  var resp = ""
  while true:
    let chunk = s.recv(4096)
    if chunk.len == 0: break
    resp.add chunk
  s.close()
  stdout.write(resp)
  if resp.len > 0 and resp[^1] != '\n': stdout.write("\n")
  return 0

proc prediffDir(): string = getCacheDir() / "wkbenchless" / "prediff"

proc editDiff*(args: seq[string]): int =
  ## Hook entry point: `wkbenchless edit-diff pre|post`, fed a Claude Code hook
  ## JSON payload on stdin. `pre` snapshots the file about to be edited; `post`
  ## pops old->new into this instance's diff pane (targeted via WKB_CTL_*).
  ## Always exits 0 -- a diff popup must never block or fail an edit.
  let mode = if args.len > 0: args[0] else: ""
  var fp = ""
  try:
    let j = parseJson(stdin.readAll())
    fp = j{"tool_input", "file_path"}.getStr("")
  except CatchableError: discard
  if fp.len == 0: return 0
  let snap = prediffDir() / getMD5(fp)
  case mode
  of "pre":
    try:
      createDir(prediffDir())
      if fileExists(fp): copyFile(fp, snap)
    except CatchableError: discard
  of "post":
    if not fileExists(fp): return 0
    var old = snap
    if not fileExists(old):                    # brand-new file: diff against empty
      try: (createDir(prediffDir()); writeFile(snap, "")) except CatchableError: discard
    discard ctlClient(@["diff", old, fp, "Claude edited " & extractFilename(fp)])
  else: discard
  return 0
