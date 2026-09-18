## Interactive REPL sessions -- a `ReplSpec` driving a `Pty` (see wkbpty.nim).
## The driver brackets each block's output with markers whose literals are split
## (paste0 / adjacent quoted strings) so they never appear in the driver's own
## echo and desync the reader. The session runs on the SAME thread-free PTY
## primitive the in-pane terminal uses -- one spawn path, and `session.pty.outbuf`
## already holds a live log we can surface as a terminal later.

import std/[os, tempfiles, strutils]
import wkbpty
export wkbpty   # Pty / alive / newVTerm ... visible wherever a Session is used

type
  ReplSpec* = object
    argv*: seq[string]
    env*: seq[(string, string)]   ## extra env for the child (before execv)
    prime*, ready*, run*, quit*: string
  Session* = ref object
    pty*: Pty
    spec*: ReplSpec

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
  prime: ".nimacs_run <- function(path, nonce) { cat(paste0(\"__NIMACS\",\"_BOR__\"), nonce, \"\\n\"); " &
         "con <- textConnection(\"._b\",\"w\"); sink(con); sink(con,type=\"message\"); options(warn=1); " &
         "._ex <- tryCatch(parse(path), error=function(e) { cat(\"Error:\",conditionMessage(e),\"\\n\"); expression() }); " &
         "for (._e in ._ex) tryCatch({ ._v <- withVisible(eval(._e, envir=globalenv())); if (._v$visible) print(._v$value) }, " &
         "error=function(e) cat(\"Error:\",conditionMessage(e),\"\\n\")); " &
         "sink(type=\"message\"); sink(); close(con); cat(._b,sep=\"\\n\"); " &
         "cat(paste0(\"\\n__NIMACS\",\"_END__\"), nonce, \"\\n\"); flush(stdout()) }\n",
  ready: "cat(paste0(\"NIMACSx\",\"READY\"),\"\\n\")\n",
  run: ".nimacs_run(\"{file}\",\"{nonce}\")\n",
  quit: "q('no')\n")

let pySpec* = ReplSpec(
  argv: @["python3", "-q", "-u"],
  env: @[("PYTHON_BASIC_REPL", "1")],   # kill PyREPL's ANSI so the PTY stays clean
  prime: "import sys as _sys, io as _io, contextlib as _cl, traceback as _tb\n" &
         "def _nimacs_run(path, nonce):\n" &
         "    print('__NIMACS' '_BOR__', nonce)\n" &
         "    _b=_io.StringIO()\n" &
         "    try:\n" &
         "        with _cl.redirect_stdout(_b), _cl.redirect_stderr(_b):\n" &
         "            exec(compile(open(path).read(),path,'exec'), globals())\n" &
         "    except Exception:\n" &
         "        _b.write(_tb.format_exc())\n" &
         "    print(_b.getvalue(), end='')\n" &
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
  var lines: seq[string]
  var collecting = false
  for raw in acc.split('\n'):
    let line = raw.strip(leading = false, trailing = true, chars = {'\r'})
    if endTok in line: break
    if collecting: lines.add(line)
    if beginTok in line: collecting = true
  while lines.len > 0 and strutils.strip(lines[^1]) == "": lines.setLen(lines.len - 1)
  lines.join("\n")

proc closeSession*(s: Session) =
  if s == nil: return
  s.pty.closePty(s.spec.quit)
