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
  Session* = ref object
    pty*: Pty
    spec*: ReplSpec
    job*: RunJob                       ## the run in flight, or nil
    queue*: seq[RunJob]                ## runs waiting for the session, FIFO

const
  markerBegin = "__NIMACS_BOR__"
  markerEnd = "__NIMACS_END__"

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
  reset: "try(sink(type=\"message\"), silent=TRUE); while (sink.number() > 0) sink()\n")

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
  quit: "exit()\n")

let bashSpec* = ReplSpec(
  argv: @["bash", "--norc", "--noprofile"],
  env: @[("PS1", ""), ("PS2", "")],
  # adjacent quoted strings are concatenated by bash, so the marker literal
  # never appears contiguously in this function's definition.
  prime: "nimacs_run() { echo \"__NIMACS\"\"_BOR__\" \"$2\"; source \"$1\" 2>&1; echo \"__NIMACS\"\"_END__\" \"$2\"; }\n",
  ready: "echo \"NIMACS\"\"xREADY\"\n",
  run: "nimacs_run '{file}' '{nonce}'\n",
  quit: "exit\n")

proc startSession*(spec: ReplSpec): Session =
  var pty = spawnPty(spec.argv, env = spec.env)
  if not pty.alive: return nil
  result = Session(pty: pty, spec: spec)
  result.pty.feed(spec.prime)
  result.pty.feed(spec.ready)                    # sync past banner + prime echo
  # mirror=false: the banner, the multi-line prime definition, and the REPL's
  # continuation prompts must NOT land in the terminal (python's def spans many
  # lines that don't carry the "nimacs" token the display filter keys on).
  discard result.pty.readUntil("NIMACSxREADY", mirror = false)

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
  let path = genTempPath("wkbenchless-", ".src")
  writeFile(path, code)
  s.pty.feed(s.spec.run.replace("{file}", path).replace("{nonce}", nonce))
  let acc = s.pty.readUntil(endTok, timeoutMs = timeoutMs, mirror = not quiet)
  removeFile(path)
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
  if s.job != nil or s.queue.len == 0 or not s.pty.alive: return
  let j = s.queue[0]
  s.queue.delete(0)
  inc gRunSeq
  let nonce = "N" & $gRunSeq
  j.beginTok = markerBegin & " " & nonce
  j.endTok = markerEnd & " " & nonce
  j.path = genTempPath("wkbenchless-", ".src")
  writeFile(j.path, j.code)
  j.code = ""
  s.pty.tap = ""
  s.pty.tapping = true
  s.pty.feed(s.spec.run.replace("{file}", j.path).replace("{nonce}", nonce))
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
  startNext(s)
  if s.job == nil: return
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
