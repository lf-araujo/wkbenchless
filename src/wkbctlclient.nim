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
           "           jobs|status <id>|wait <id>...|interrupt <id>\n" &
           "           run-block [line] [--deps] [--force]|run-stale|infer-deps\n" &
           "  (verbs that take text read it from stdin; run-block/run-all/eval wait\n" &
           "   for their jobs unless given --async, which prints the job id(s))"
  case args[0]
  of "buffer", "blocks", "run-all", "jobs", "run-stale", "infer-deps":
    req = args[0]
  of "status", "interrupt":
    if args.len < 2: return "ctl " & args[0] & " <job id>"
    req = args[0] & "\t" & args[1]
  of "wait":
    if args.len < 2: return "ctl wait <job id>..."
    req = "jobs"                         # (unused: `wait` polls status client-side)
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
    # run-block [line] [--deps] [--force]: an empty line field means "the cursor"
    var line = ""
    var flags: seq[string]
    for a in args[1 .. ^1]:
      if a.startsWith("--"): flags.add a
      elif line.len == 0: line = a
    req = "run-block\t" & line & "\t" & flags.join(" ")
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
    # the new file's path lets the editor jump to the change when the diff closes
    req = "diff\t" & title & "\t" & absolutePath(args[2]) & "\n" &
          readFile(args[1]) & "\x1e" & readFile(args[2])
  else:
    return "unknown verb: " & args[0]

proc ctlCoordinates(port: var int; token: var string): string =
  ## Find the editor to talk to; "" on success, else an error message.
  # Prefer this-instance coordinates from the env (exported by the launching
  # editor), so a hook targets the editor Claude was launched from; otherwise
  # fall back to the shared control.port file.
  let envPort = getEnv("WKB_CTL_PORT")
  let envTok  = getEnv("WKB_CTL_TOKEN")
  if envPort.len > 0 and envTok.len > 0:
    port = try: parseInt(envPort) except CatchableError: 0
    token = envTok
    return ""
  let pf = portPath()
  if not fileExists(pf):
    return "wkbenchless is not running (no control port at " & pf & ")"
  try:
    let lines = readFile(pf).splitLines()
    port = parseInt(lines[0].strip())
    if lines.len > 1: token = lines[1].strip()
  except CatchableError:
    return "bad control port file: " & pf
  ""

proc request(port: int; token, req: string; resp: var string): string =
  ## One request/response round trip; "" on success, else an error message.
  var s = newSocket()
  try:
    s.connect("127.0.0.1", Port(port))
  except CatchableError:
    return "wkbenchless is not running (cannot connect 127.0.0.1:" & $port & ")"
  s.send(token & "\n" & req)              # auth token line, then the request
  when defined(windows): discard winShutdown(s.getFd, 1)   # SD_SEND
  else: discard shutdown(s.getFd, SHUT_WR)
  resp = ""
  while true:
    let chunk = s.recv(4096)
    if chunk.len == 0: break
    resp.add chunk
  s.close()
  ""

proc queuedIds(resp: string): seq[int] =
  ## "queued: job 7" / "queued: jobs 7 8 9" -> the ids.
  if not resp.startsWith("queued:"): return
  for tok in resp.splitWhitespace():
    try: result.add parseInt(tok) except ValueError: discard

type JobResult = tuple[id: int; state, label, secs, output: string]

proc waitJobs(port: int; token: string; ids: seq[int]; res: var seq[JobResult]): string =
  ## Poll `status` until every job has finished. Each poll is a quick request,
  ## so the editor stays responsive however long the jobs run.
  res.setLen(0)
  var pending = ids
  var got: seq[JobResult]
  while pending.len > 0:
    var still: seq[int]
    for id in pending:
      var resp = ""
      let err = request(port, token, "status\t" & $id, resp)
      if err.len > 0: return err
      let nl = resp.find('\n')
      let head = if nl >= 0: resp[0 ..< nl] else: resp
      let f = head.split('\t')
      let state = if f.len > 1: f[1] else: "unknown"
      if state in ["done", "interrupted", "unknown"]:
        got.add (id, state, (if f.len > 2: f[2] else: ""), (if f.len > 3: f[3] else: ""),
                 (if nl >= 0: resp[nl + 1 .. ^1] else: ""))
      else: still.add id
    pending = still
    if pending.len > 0: sleep(300)
  for id in ids:                          # report in the order they were queued
    for r in got:
      if r.id == id: res.add r
  ""

proc hasError(output: string): bool = "\nError" in ("\n" & output)

proc errorLines(output: string): string =
  for ln in output.splitLines():
    if ln.startsWith("Error"): result.add "  " & ln & "\n"

proc ctlClient*(args: seq[string]): int =
  ## Run one control request; returns a process exit code.
  var args = args
  let async = "--async" in args
  if async: args.delete(args.find("--async"))
  var req = ""
  let err = buildRequest(args, req)
  if err.len > 0:
    stderr.writeLine err
    return 1
  var port = 0
  var token = ""
  let cerr = ctlCoordinates(port, token)
  if cerr.len > 0:
    stderr.writeLine cerr
    return 1
  var resp = ""
  var ids: seq[int]
  if args[0] == "wait":
    for a in args[1 .. ^1]:
      try: ids.add parseInt(a) except ValueError: discard
  else:
    let rerr = request(port, token, req, resp)
    if rerr.len > 0:
      stderr.writeLine rerr
      return 1
    if not async and args[0] in ["run-block", "run-all", "run-stale", "eval"]:
      ids = queuedIds(resp)
  if ids.len > 0:
    var res: seq[JobResult]
    let werr = waitJobs(port, token, ids, res)
    if werr.len > 0:
      stderr.writeLine werr
      return 1
    resp = ""
    case args[0]
    of "eval":
      for r in res: resp.add r.output
    of "run-block":
      for r in res:
        resp.add (if r.state == "done": "ok: babel: ran " else: r.state & ": ") &
                 r.label & " (job " & $r.id & ", " & r.secs & ")" &
                 (if hasError(r.output): " -- errors:\n" & errorLines(r.output) else: "")
    else:                                 # run-all / wait: a per-job report
      var okCount, errCount = 0
      if args[0] in ["run-all", "run-stale"]: resp.add args[0] & ": " & $res.len & " jobs\n"
      for i, r in res:
        let bad = r.state != "done" or hasError(r.output)
        if bad: inc errCount else: inc okCount
        resp.add "  [" & (if bad: "ERR" else: "ok ") & "] " &
                 (if args[0] in ["run-all", "run-stale"]: $(i + 1) & "/" & $res.len & " " else: "") &
                 "job " & $r.id & " " & r.label & " (" & r.state & ", " & r.secs & ")\n" &
                 errorLines(r.output)
      resp.add args[0] & ": " & $okCount & " ok, " & $errCount & " with errors\n"
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
