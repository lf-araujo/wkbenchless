## Interactive REPL sessions -- a `ReplSpec` driving a `Pty` (see wkbpty.nim).
## The driver brackets each block's output with markers whose literals are split
## (paste0 / adjacent quoted strings) so they never appear in the driver's own
## echo and desync the reader. The session runs on the SAME thread-free PTY
## primitive the in-pane terminal uses -- one spawn path, and `session.pty.outbuf`
## already holds a live log we can surface as a terminal later.

import std/[os, tempfiles, strutils, times]
import wkbpty
export wkbpty   # Pty / alive / newVTerm ... visible wherever a Session is used

type
  ReplSpec* = object
    argv*: seq[string]
    env*: seq[(string, string)]   ## extra env for the child (before execv)
    prime*, ready*, run*, quit*: string
    reset*: string   ## sent after an interrupt, to undo what the run driver left
                     ## half-done (R's output sinks); "" if the REPL needs nothing
    launch*: seq[string]
      ## Shell lines typed before the interpreter exists (argv then starts a
      ## shell, e.g. an ssh login): each is sent once the current shell answers
      ## a probe, so a hop like `exec qsub -I ...` can wait in a batch queue
      ## before the next line (the one that execs the interpreter) is sent.
    launchTimeoutMs*: int   ## max wait for each launch shell to answer (0 = 120 s)
    cwd*: string            ## working directory for a LOCAL REPL ("" = inherit)
    tmuxName*: string
      ## Non-empty: argv runs `tmux -CC new-session -A -s <tmuxName>` on a host
      ## (after printing WKBxTMUXNEW/OLD), so the REPL outlives the connection.
      ## A NEW session runs `launch` inside the pane; an OLD one is reattached
      ## and only re-primed -- whatever it was running is still there.
    stage*: proc(pty: var Pty; code, nonce: string): string
      ## Puts a run's code where the interpreter can read it and returns that
      ## path ("" = failed). nil = a local temp file (the REPL runs here). Takes
      ## the session's own pty so a remote stager can write the file through
      ## the SAME already-open channel (see `writeBytesCode`) instead of a
      ## second ssh connection -- a second channel can be refused outright by
      ## a server that caps sessions per connection (sshd's MaxSessions), no
      ## matter how many times the one channel it does allow logs back in.
    writeBytesCode*: proc(bytes: openArray[byte]; path, marker: string): string
      ## REPL-specific source that writes `bytes` to `path` then prints
      ## `marker` on its own line -- the byte-value encoding (not a base64 or
      ## quoted-text one) needs no escaping for arbitrary source bytes and no
      ## library beyond this REPL's own built-ins. nil = this REPL has no
      ## pty-based stager (only a local temp file, or the old second-channel
      ## one, is available to it).
  JobState* = enum jsQueued, jsRunning, jsDone, jsInterrupted
  RunJob* = ref object
    ## One asynchronous run of `code` in a session: queued, then started when the
    ## session is free, then completed by `pollSession` when its END marker shows
    ## up. Nothing blocks -- the host polls every frame.
    id*: int
    state*: JobState
    code: string
    path: string
    beginTok, endTok: string
    output*: string                    ## captured output, once done
    started*, finished*: float         ## epochTime; 0 while unset
  StartPhase* = enum
    spReady    ## handshake done (the default -- a local session is ready at once)
    spLaunch   ## working through spec.launch (an ssh login hop, e.g. qsub -I,
               ## that can queue for an arbitrary time on a shared cluster)
    spPriming  ## launch done; waiting for the REPL to answer spec.ready
    spFailed   ## the handshake died or timed out -- spec.startFailed says how
    spAttach   ## tmux spec: waiting to learn whether the host session is new
    spReattach ## tmux spec, existing session: waiting for its live REPL to answer
    spBooting  ## last launch line sent alone; waiting for the REPL to answer
  Session* = ref object
    pty*: Pty
    spec*: ReplSpec
    job*: RunJob                       ## the run in flight, or nil
    queue*: seq[RunJob]                ## runs waiting for the session, FIFO
    phase*: StartPhase                 ## spReady unless still mid-handshake
    startFailed*: string               ## why, once phase == spFailed
    launchIdx: int                     ## next spec.launch step to answer
    hsAcc: string                      ## handshake bytes not yet matched
    hsWaitStart, hsLastProbe: float    ## epochTime; this step's budget/probe

const
  markerBegin = "__NIMACS_BOR__"
  markerEnd = "__NIMACS_END__"

const stageChunk = 400
  ## Bytes per staging line: at most ~4 chars each, so every typed line stays
  ## well under R's 4096-byte console line limit (and any tty's line buffer).
  ## The marker the stager prints is split in its source (paste0 / adjacent
  ## literals) so the echo of the typed line can't satisfy the wait for it.

proc byteList(bytes: openArray[byte]): string =
  ## "12,3,255,...": plain decimal, so the REPL's own integer-literal syntax
  ## can rebuild the bytes with zero escaping, whatever they are.
  var parts = newSeq[string](bytes.len)
  for i, b in bytes: parts[i] = $int(b)
  parts.join(",")

let rSpec* = ReplSpec(
  argv: @["R", "--no-save", "--no-restore", "--quiet"],
  # Each run carries a unique `nonce` so a stale END marker (left in the PTY
  # buffer by an earlier run whose reader timed out) can never be mistaken for
  # this run's END -- the reader keys on END+nonce, so it skips stale markers
  # instead of desyncing the temp-file lifecycle. The block is evaluated
  # expression-by-expression (like ESS sends top-level forms), so an error in
  # one statement is reported but does not abort the rest of the block.
  # Output goes straight to the terminal between the markers (no sink), so the
  # session pane shows it as it is produced -- model-fit progress included --
  # and the job captures the same text from the PTY.
  prime: ".nimacs_run <- function(path, nonce) { cat(paste0(\"__NIMACS\",\"_BOR__\"), nonce, \"\\n\"); " &
         "options(warn=1); " &
         "._ex <- tryCatch(parse(path), error=function(e) { cat(\"Error:\",conditionMessage(e),\"\\n\"); expression() }); " &
         "for (._e in ._ex) tryCatch({ ._v <- withVisible(eval(._e, envir=globalenv())); if (._v$visible) print(._v$value) }, " &
         "error=function(e) cat(\"Error:\",conditionMessage(e),\"\\n\")); " &
         "cat(paste0(\"\\n__NIMACS\",\"_END__\"), nonce, \"\\n\"); flush(stdout()) }\n",
  ready: "cat(paste0(\"NIMACSx\",\"READY\"),\"\\n\")\n",
  run: ".nimacs_run(\"{file}\",\"{nonce}\")\n",
  quit: "q('no')\n",
  # A session primed by an older driver may still have output sinks active
  # when a run is interrupted; drop them (a no-op otherwise).
  reset: "try(sink(type=\"message\"), silent=TRUE); while (sink.number() > 0) sink()\n",
  writeBytesCode: proc(bytes: openArray[byte]; path, marker: string): string =
    result = "dir.create(dirname(\"" & path & "\"), recursive=TRUE, showWarnings=FALSE); " &
             ".wkbf <- file(\"" & path & "\", \"wb\")\n"
    var i = 0
    while i < bytes.len:
      let j = min(i + stageChunk, bytes.len)
      result.add "writeBin(as.raw(c(" & byteList(bytes.toOpenArray(i, j - 1)) & ")), .wkbf)\n"
      i = j
    result.add "close(.wkbf); cat(paste0(\"" & marker[0 ..< 3] & "\",\"" &
               marker[3 .. ^1] & "\"), \"\\n\")\n")

let pySpec* = ReplSpec(
  argv: @["python3", "-q", "-u"],
  env: @[("PYTHON_BASIC_REPL", "1")],   # kill PyREPL's ANSI so the PTY stays clean
  # Unbuffered (-u) and printed as it happens: the session pane streams output.
  prime: "import sys as _sys, traceback as _tb\n" &
         "def _nimacs_run(path, nonce):\n" &
         "    print('__NIMACS' '_BOR__', nonce)\n" &
         "    try:\n" &
         "        exec(compile(open(path).read(),path,'exec'), globals())\n" &
         "    except Exception:\n" &
         "        _tb.print_exc(file=_sys.stdout)\n" &
         "    print('\\n__NIMACS' '_END__', nonce)\n" &
         "    _sys.stdout.flush()\n" &
         "\n",
  ready: "print('NIMACS' 'xREADY')\n",
  run: "_nimacs_run('{file}','{nonce}')\n",
  quit: "exit()\n",
  writeBytesCode: proc(bytes: openArray[byte]; path, marker: string): string =
    result = "import os as _os_s\n" &
             "_os_s.makedirs(_os_s.path.dirname('" & path & "') or '.', exist_ok=True)\n" &
             "_wkbf = open('" & path & "','wb')\n"
    var i = 0
    while i < bytes.len:
      let j = min(i + stageChunk, bytes.len)
      result.add "_ = _wkbf.write(bytes([" & byteList(bytes.toOpenArray(i, j - 1)) & "]))\n"
      i = j
    result.add "_wkbf.close(); print('" & marker[0 ..< 3] & "' '" & marker[3 .. ^1] & "')\n")

let bashSpec* = ReplSpec(
  argv: @["bash", "--norc", "--noprofile"],
  env: @[("PS1", ""), ("PS2", "")],
  # adjacent quoted strings are concatenated by bash, so the marker literal
  # never appears contiguously in this function's definition.
  prime: "nimacs_run() { echo \"__NIMACS\"\"_BOR__\" \"$2\"; source \"$1\" 2>&1; echo \"__NIMACS\"\"_END__\" \"$2\"; }\n",
  ready: "echo \"NIMACS\"\"xREADY\"\n",
  run: "nimacs_run '{file}' '{nonce}'\n",
  quit: "exit\n",
  writeBytesCode: proc(bytes: openArray[byte]; path, marker: string): string =
    # \NNN octal escapes: printf resolves each before any %-scanning touches
    # the result, so an escaped '%' or '\' byte can never reopen a spec.
    result = "mkdir -p \"$(dirname \"" & path & "\")\" && : > \"" & path & "\"\n"
    var i = 0
    while i < bytes.len:
      let j = min(i + stageChunk, bytes.len)
      var esc = ""
      for k in i ..< j: esc.add "\\" & toOct(BiggestInt(bytes[k]), 3)
      result.add "printf '" & esc & "' >> \"" & path & "\"\n"
      i = j
    result.add "echo \"" & marker[0 ..< 3] & "\"\"" & marker[3 .. ^1] & "\"\n")

proc probeWaitMs(spec: ReplSpec): int =
  if spec.launchTimeoutMs > 0: spec.launchTimeoutMs else: 120_000

proc startSession*(spec: ReplSpec): Session =
  ## A plain (no `launch`) spec starts synchronously here, same as always --
  ## spawning and priming a local REPL is near-instant. A spec WITH a `launch`
  ## (an ssh login hop, e.g. `qsub -I`, that can sit queued for an arbitrary
  ## time on a shared cluster) must not block here: it is handed back right
  ## away in phase `spLaunch`, and `pollSession` -- already called every frame
  ## by the host -- advances the handshake a non-blocking step at a time via
  ## `advanceStart`, so a slow login never freezes the single-threaded host.
  ## Any run queued on it meanwhile just waits (`startNext` checks `phase`).
  var pty = spawnPty(spec.argv, dir = spec.cwd, env = spec.env)
  if not pty.alive: return nil
  if spec.tmuxName.len > 0:
    pty.tmuxTarget = spec.tmuxName
    pty.tmuxCommand("refresh-client -C 250,50")   # wide pane: no wrapping
    pty.tapping = true                            # see hsRead
    return Session(pty: pty, spec: spec, phase: spAttach, hsWaitStart: epochTime())
  if spec.launch.len > 0:
    pty.tapping = true                            # see hsRead
    return Session(pty: pty, spec: spec, phase: spLaunch, hsWaitStart: epochTime())
  result = Session(pty: pty, spec: spec)
  result.pty.feed(spec.prime)
  result.pty.feed(spec.ready)                    # sync past banner + prime echo
  # mirror=false: the banner, the multi-line prime definition, and the REPL's
  # continuation prompts must NOT land in the terminal (python's def spans many
  # lines that don't carry the "nimacs" token the display filter keys on).
  # Must actually check for the marker: an interpreter that never starts (R
  # missing on a remote host, a qsub login that silently dropped back to a
  # plain shell, ...) leaves this PTY sitting at some other prompt forever --
  # discarding the result used to hand back that broken session as if it were
  # ready, so every later run against it hung or failed with a useless error.
  if "NIMACSxREADY" notin result.pty.readUntil("NIMACSxREADY", timeoutMs = probeWaitMs(spec), mirror = false):
    result.pty.closePty(); return nil

proc hsRead(s: Session) =
  ## Collect handshake output via the tap -- the same single-reader scheme jobs
  ## use. The host pumps the visible session pane every frame; reading the pty
  ## directly here raced that pump, which swallowed the probe/ready tokens into
  ## the pane and left the handshake waiting forever. Whoever drains, the tap
  ## sees every byte (and the login/qsub progress shows in the pane).
  discard drain(s.pty)
  s.hsAcc.add s.pty.tap
  s.pty.tap = ""

proc advanceStart(s: Session) =
  ## One non-blocking step of a session's login handshake (`s.phase !=
  ## spReady`); called from `pollSession` every frame. Mirrors the old
  ## blocking `startSession` loop step for step, just spread across frames
  ## instead of sleeping in a loop: a re-probe every 2s (a shell still
  ## starting, or a qsub that flushes typed-ahead input, may drop one), the
  ## same per-step timeout budget, and the same final wait for the REPL's
  ## own `ready` token once the last hop answers.
  if s.phase in [spReady, spFailed]: return
  if not s.pty.alive:
    s.phase = spFailed; s.startFailed = "session ended during login"; return
  let budget = probeWaitMs(s.spec).float / 1000.0
  case s.phase
  of spAttach:
    hsRead(s)
    let isNew = "WKBxTMUXNEW" in s.hsAcc
    if isNew or "WKBxTMUXOLD" in s.hsAcc:
      s.hsAcc = ""; s.hsWaitStart = epochTime(); s.hsLastProbe = 0
      if isNew:
        s.phase = spLaunch             # a fresh pane: log in and start the REPL
      else:
        s.pty.feed(s.spec.ready)       # reattached: is its REPL there and free?
        s.phase = spReattach
      return
    if epochTime() - s.hsWaitStart >= budget:
      s.phase = spFailed; s.startFailed = "could not start tmux on the host"
  of spReattach:
    hsRead(s)
    if "NIMACSxREADY" in s.hsAcc:
      s.pty.feed(s.spec.prime)         # (re)define the run driver -- idempotent
      s.pty.feed(s.spec.ready)
      s.hsAcc = ""; s.hsWaitStart = epochTime()
      s.phase = spPriming
      return
    if epochTime() - s.hsWaitStart >= budget:
      # Never type login steps blind into a pane whose state we don't know
      # (still queued in qsub, busy with an old run, ...): say where to look.
      s.phase = spFailed
      s.startFailed = "reattached to tmux session '" & s.spec.tmuxName &
        "' but its REPL did not answer (still busy, or not running) -- " &
        "`tmux attach -t " & s.spec.tmuxName & "` on the host to look, " &
        "or `tmux kill-session -t " & s.spec.tmuxName & "` to start over"
  of spLaunch:
    let tok = "WKBxSHELL" & $s.launchIdx
    if s.hsLastProbe == 0:
      s.pty.feed("echo WKBx\"\"SHELL" & $s.launchIdx & "\n")
      s.hsLastProbe = epochTime()
    hsRead(s)
    if tok in s.hsAcc:
      s.pty.feed(s.spec.launch[s.launchIdx] & "\n")
      inc s.launchIdx
      s.hsAcc = ""; s.hsLastProbe = 0; s.hsWaitStart = epochTime()
      if s.launchIdx >= s.spec.launch.len:
        # Don't type the prime right behind the line that starts the REPL:
        # a shell with a line-editor add-on (ble.sh on a qsub compute node,
        # whatever SHELL says) takes a multi-line burst for a paste and turns
        # Enter into "insert newline", so the REPL never even starts. Let
        # that line run alone; spBooting waits for the REPL itself to answer.
        s.hsLastProbe = epochTime()
        s.phase = spBooting
      return
    if epochTime() - s.hsWaitStart >= budget:
      s.phase = spFailed; s.startFailed = "login timed out"; return
    if epochTime() - s.hsLastProbe >= 2.0:
      s.pty.feed("echo WKBx\"\"SHELL" & $s.launchIdx & "\n")
      s.hsLastProbe = epochTime()
  of spBooting:
    # Re-send the bare ready probe every 2 s until the REPL (not the shell
    # that exec'd it) answers; only then send the prime. Extra probes that
    # queue up are harmless: input order still puts the prime before any run.
    hsRead(s)
    if "NIMACSxREADY" in s.hsAcc:
      s.pty.feed(s.spec.prime)
      s.pty.feed(s.spec.ready)
      s.hsAcc = ""; s.hsWaitStart = epochTime()
      s.phase = spPriming
      return
    if epochTime() - s.hsWaitStart >= budget:
      s.phase = spFailed; s.startFailed = "the interpreter never started on the host"; return
    if epochTime() - s.hsLastProbe >= 2.0:
      s.pty.feed(s.spec.ready)
      s.hsLastProbe = epochTime()
  of spPriming:
    hsRead(s)
    if "NIMACSxREADY" in s.hsAcc:
      s.phase = spReady
      s.pty.tapping = false; s.pty.tap = ""   # jobs own the tap from here
      return
    if epochTime() - s.hsWaitStart >= budget:
      s.phase = spFailed; s.startFailed = "REPL never answered ready"
  else: discard

var gRunSeq = 0   ## monotonic per-process counter -> a unique nonce per run

proc extractOutput(acc, beginTok, endTok: string): string =
  ## The lines between this run's BEGIN and END markers, trailing blanks dropped.
  var lines: seq[string]
  var collecting = false
  for raw in acc.split('\n'):
    let line = raw.strip(leading = false, trailing = true, chars = {'\r'})
    if endTok in line: break
    if collecting: lines.add(line)
    if beginTok in line: collecting = true
  while lines.len > 0 and strutils.strip(lines[^1]) == "": lines.setLen(lines.len - 1)
  lines.join("\n")

proc stageCode(s: Session; code, nonce: string): tuple[path: string; local: bool] =
  ## Where the interpreter reads this run's code from: the spec's stager (a
  ## remote session copies it to the host), else a local temp file.
  if s.spec.stage != nil: return (s.spec.stage(s.pty, code, nonce), false)
  let path = genTempPath("wkbenchless-", ".src")
  writeFile(path, code)
  (path, true)

proc runBlock*(s: Session; code: string; quiet = false;
               timeoutMs = 15_000): string =
  ## Run `code` in the session, returning the captured output. `quiet` keeps the
  ## run off the live terminal display (for internal object/help queries).
  ## `timeoutMs` is the max *silence* the reader tolerates before giving up
  ## (model fits can be silent for a while -- callers running user blocks pass a
  ## large value). Each run gets a unique `nonce`: the reader keys BEGIN/END on
  ## it, so a stale END left over by an earlier timed-out run is skipped rather
  ## than mistaken for this one (which previously deleted the temp file before R
  ## could source it -- the "/tmp/wkbenchless-*.src: No such file" desync).
  if s == nil or not s.pty.alive: return ""
  inc gRunSeq
  let nonce = "N" & $gRunSeq
  let beginTok = markerBegin & " " & nonce
  let endTok = markerEnd & " " & nonce
  let (path, local) = stageCode(s, code, nonce)
  if path.len == 0: return "Error: could not send the block to the session's host"
  s.pty.feed(s.spec.run.replace("{file}", path).replace("{nonce}", nonce))
  let acc = s.pty.readUntil(endTok, timeoutMs = timeoutMs, mirror = not quiet)
  if local: removeFile(path)
  extractOutput(acc, beginTok, endTok)

# -- asynchronous runs ------------------------------------------------------
# `submit` queues code and returns at once; the host calls `pollSession` every
# frame, which drains the PTY without blocking and completes the in-flight run
# when its END marker arrives. One run at a time per session (a REPL is
# serial); different sessions run in parallel. There is no silence timeout: a
# model fit that prints nothing for an hour is simply still running, and
# `interrupt` is how a user stops it.

var gJobSeq = 0   ## job ids, unique across sessions (what `ctl status <id>` names)

proc busy*(s: Session): bool =
  ## A run is in flight or waiting: synchronous queries must not interleave.
  s != nil and (s.job != nil or s.queue.len > 0)

proc startNext(s: Session) =
  if s.job != nil or s.queue.len == 0 or not s.pty.alive or s.phase != spReady: return
  let j = s.queue[0]
  s.queue.delete(0)
  inc gRunSeq
  let nonce = "N" & $gRunSeq
  j.beginTok = markerBegin & " " & nonce
  j.endTok = markerEnd & " " & nonce
  let (path, local) = stageCode(s, j.code, nonce)
  if local: j.path = path        # finish() deletes it; a remote copy is the stager's
  j.code = ""
  s.pty.tap = ""
  s.pty.tapping = true
  if path.len > 0:
    s.pty.feed(s.spec.run.replace("{file}", path).replace("{nonce}", nonce))
  else:                          # nothing to run: complete the job with the error
    s.pty.tap = j.beginTok & "\nError: could not send the block to the session's host\n" &
                j.endTok & "\n"
  j.state = jsRunning
  j.started = epochTime()
  s.job = j

proc finish(s: Session; j: RunJob; state: JobState; output: string) =
  j.output = output
  j.state = state
  j.finished = epochTime()
  if j.path.len > 0:
    try: removeFile(j.path) except CatchableError: discard
  if s.job == j:
    s.job = nil
    s.pty.tapping = false
    s.pty.tap = ""

proc submit*(s: Session; code: string): RunJob =
  ## Queue `code` for this session; returns immediately. Starts it now if the
  ## session is idle.
  inc gJobSeq
  result = RunJob(id: gJobSeq, state: jsQueued, code: code)
  s.queue.add result
  startNext(s)

proc pollSession*(s: Session): seq[RunJob] =
  ## Non-blocking: drain the session's output and return the runs that completed
  ## since the last call (at most one, plus any failed because the REPL died).
  if s == nil: return
  if s.phase != spReady:
    advanceStart(s)                 # one non-blocking login-handshake step
    if s.phase != spFailed: return  # still logging in: nothing else to do yet
    s.pty.closePty()                # so `getSession` starts a fresh one next time
    for q in s.queue:
      q.state = jsDone; q.finished = epochTime()
      q.output = "Error: " & s.startFailed
      result.add q
    s.queue.setLen(0)
    return
  startNext(s)
  if s.job == nil and s.pty.alive:
    # Idle: still drain, so output the REPL prints between runs reaches the
    # pane and its ssh/tmux child never blocks on a full pty.
    discard drain(s.pty)
  if s.job == nil:
    # A REPL that died before running anything (e.g. R crashing at startup on a
    # remote host) never starts its queue: fail those runs instead of leaving
    # their placeholders "running" forever.
    if not s.pty.alive and s.queue.len > 0:
      let tail = s.pty.outbuf[max(0, s.pty.outbuf.len - 600) .. ^1].strip
      for q in s.queue:
        q.state = jsDone; q.finished = epochTime()
        q.output = "Error: session ended before the run started" &
                   (if tail.len > 0: "\n" & tail else: "")
        result.add q
      s.queue.setLen(0)
    return
  if drain(s.pty) < 0 or not s.pty.alive:      # the REPL exited under the run
    let j = s.job
    finish(s, j, jsDone, extractOutput(s.pty.tap, j.beginTok, j.endTok) &
                         "\nError: session ended")
    result.add j
    for q in s.queue:
      q.state = jsDone; q.output = "Error: session ended"; q.finished = epochTime()
      result.add q
    s.queue.setLen(0)
    return
  let j = s.job
  if j.endTok in s.pty.tap:
    finish(s, j, jsDone, extractOutput(s.pty.tap, j.beginTok, j.endTok))
    result.add j
    startNext(s)

proc interrupt*(s: Session; id: int): RunJob =
  ## Stop job `id`: a queued one is dropped, the running one gets a Ctrl-C (and
  ## the REPL's reset string). Returns the job (now finished) or nil if unknown.
  if s == nil: return nil
  for i, q in s.queue:
    if q.id == id:
      s.queue.delete(i)
      q.state = jsInterrupted; q.output = "(cancelled before it started)"
      q.finished = epochTime()
      return q
  if s.job != nil and s.job.id == id:
    let j = s.job
    s.pty.feed("\x03")
    if s.spec.reset.len > 0: s.pty.feed(s.spec.reset)
    discard drain(s.pty)
    finish(s, j, jsInterrupted,
           extractOutput(s.pty.tap & "\n", j.beginTok, j.endTok) & "\n(interrupted)")
    startNext(s)
    return j
  nil

proc closeSession*(s: Session) =
  if s == nil: return
  s.pty.closePty(s.spec.quit)
