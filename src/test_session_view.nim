## A REPL session's pane is the same screen grid a terminal uses, minus the
## run driver's own lines: the filter in front of the grid, then real bash / R
## / python sessions, and the tab model every chip and `ctl tabs` draw from.
##   nim c -r --hints:off src/test_session_view.nim

import std/[strutils, times, tables]
from std/os import findExe
from std/os as stdos import nil
import wkbcore
import wkbpty {.all.}   # showOutput, to feed the filter by hand

proc screenText(t: Pty): string =
  ## Scrollback + grid as plain text, one line per row, trailing blanks cut.
  var rows: seq[string]
  for row in t.vt.scrollback & t.vt.grid:
    var s = ""
    for c in row: s.add (if c.ch.len == 0: " " else: c.ch)
    rows.add s.strip(leading = false)
  while rows.len > 0 and rows[^1].len == 0: rows.setLen(rows.len - 1)
  rows.join("\n")

proc viewPty(cols = 80): Pty =
  result = notRunningPty()
  result.useSessionView()
  result.vt.resize(24, cols)

# -- the filter, fed by hand --------------------------------------------------
block:
  var p = viewPty()
  p.showOutput("> ")                      # a prompt arrives alone: shown
  doAssert p.screenText == ">", p.screenText
  p.showOutput(".nimacs_run(\"/tmp/x.src\",\"N1\")\r\n")   # ...then its echo
  doAssert p.screenText == "", "the prompt goes with the run call's echo: " & p.screenText
  p.showOutput("__NIMACS_BOR__ N1 \r\n[1] 42\r\n\r\n__NIMACS_")
  p.showOutput("END__ N1 \r\n> ")         # a marker split across reads
  doAssert "nimacs" notin p.screenText.toLowerAscii, p.screenText
  doAssert p.screenText == "[1] 42\n\n>", p.screenText
  echo "filter ok"

block:                                    # an echo long enough to wrap
  var p = viewPty(cols = 20)
  p.showOutput("out\r\n> .nim")
  p.showOutput("acs_run(\"/a/very/long/path/to/a/file.src\",\"N7\")\r\n")
  doAssert p.screenText == "out", p.screenText
  echo "wrapped echo ok"

block:                                    # a terminal is never filtered
  var t = notRunningPty()
  t.vt = newVTerm(24, 80, color(0, 0, 0), color(255, 255, 255))
  t.showOutput("grep nimacs file\r\n")
  doAssert "grep nimacs file" in t.screenText
  echo "terminal unfiltered ok"

# -- real sessions --------------------------------------------------------------
# REPL sessions over Windows' ConPTY are not verified yet (the CI runner's
# bash never answered the handshake), so real REPLs run on POSIX only; the
# filter tests above run everywhere.
const realSessions = not defined(windows)
when not realSessions:
  echo "real REPL sessions skipped on Windows (ConPTY sessions unverified)"
proc runIn(s: Session; code: string): RunJob =
  result = s.submit(code)
  let t0 = epochTime()
  while result.state notin {jsDone, jsInterrupted} and epochTime() - t0 < 20:
    discard pollSession(s)
    stdos.sleep(10)
  for _ in 0 ..< 20:                      # let the trailing prompt arrive
    discard pollSession(s)
    stdos.sleep(10)

proc checkSession(spec: ReplSpec; code, want, name: string) =
  let s = startSession(spec)
  doAssert s != nil, name & " did not start"
  doAssert s.pty.vt != nil and s.pty.driverView
  let j = runIn(s, code)
  doAssert j.state == jsDone and want in j.output, name & ": " & j.output
  let scr = s.pty.screenText
  doAssert want in scr, name & " output not on screen:\n" & scr
  doAssert "nimacs" notin scr.toLowerAscii, name & " driver lines on screen:\n" & scr
  doAssert "nimacs" in s.pty.outbuf.toLowerAscii, name & ": outbuf keeps the raw log"
  closeSession(s)
  echo name & " session view ok"

if realSessions and findExe("bash").len > 0:
  checkSession(bashSpec, "echo hello-from-bash", "hello-from-bash", "bash")
if realSessions and findExe("R").len > 0:
  checkSession(rSpec, "cat('hello-from-r\\n'); 1 + 41", "[1] 42", "R")
if realSessions and findExe("python3").len > 0:
  checkSession(pySpec, "print('hello-from-py')", "hello-from-py", "python")

# -- the tab model --------------------------------------------------------------
if realSessions and findExe("bash").len > 0:
  var app = App()
  let s = startSession(bashSpec)
  app.sessions["bash/default"] = s
  var ti = tabInfo(app, "bash/default")
  doAssert ti.kind == tkRepl and ti.state == tsReady and ti.host == "", $ti
  let j = s.submit("sleep 1")
  ti = tabInfo(app, "bash/default")
  doAssert ti.state == tsRunning and ti.detail == "job " & $j.id, $ti
  discard s.interrupt(j.id)
  app.terminals.add Terminal(label: "claude", cmd: "claude", started: true,
                             kind: tkAgent, pty: notRunningPty())
  app.terminals.add Terminal(label: "login", cmd: "sh", host: "hpc",
                             pty: notRunningPty())
  doAssert tabInfo(app, terminalTabKey(0)).kind == tkAgent
  ti = tabInfo(app, terminalTabKey(1))
  doAssert ti.kind == tkShell and ti.host == "hpc" and ti.state == tsStarting, $ti
  doAssert displayHost("me@login.cluster.org|qsub") == "login.cluster.org"
  ti = tabInfo(app, "r/main@me@hpc")      # a remote session not started yet
  doAssert ti.name == "r/main" and ti.host == "hpc" and ti.state == tsEnded, $ti
  let summary = tabsSummary(app)
  doAssert summary.splitLines.len == 3 and "\tagent\t" in summary, summary
  closeSession(s)
  echo "tab model ok"

echo "ALL OK"
