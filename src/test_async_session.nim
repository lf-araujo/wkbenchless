## Async session runs: submit/poll never block, runs finish in FIFO order,
## interrupt stops a long run (and R's sinks are restored), and babel blocks
## get a placeholder that the finished run replaces.
##   nim c -r --hints:off src/test_async_session.nim

import std/[strutils, times]
from std/os import findExe
from std/os as stdos import nil
template sleep(ms: int) = stdos.sleep(ms)
import wkbcore

proc waitDone(s: Session; n: int; limit = 20.0): seq[RunJob] =
  let t0 = epochTime()
  while result.len < n and epochTime() - t0 < limit:
    result.add pollSession(s)
    sleep(10)

# -- session level (bash) ----------------------------------------------------
let sh = startSession(bashSpec)
doAssert sh != nil
let a = sh.submit("echo first")
let b = sh.submit("sleep 1; echo second")
let c = sh.submit("echo third")
doAssert a.state == jsRunning and b.state == jsQueued and c.state == jsQueued
doAssert sh.busy

# a poll while `sleep 1` runs must return at once
var worst = 0.0
var done: seq[RunJob]
let t0 = epochTime()
while done.len < 3 and epochTime() - t0 < 20:
  let p0 = epochTime()
  done.add pollSession(sh)
  worst = max(worst, epochTime() - p0)
  sleep(10)
doAssert done.len == 3, "only " & $done.len & " runs finished"
doAssert done[0] == a and done[1] == b and done[2] == c, "FIFO order"
doAssert a.output == "first" and b.output == "second" and c.output == "third",
  a.output & " | " & b.output & " | " & c.output
doAssert worst < 0.05, "a poll blocked for " & $worst & "s"
doAssert not sh.busy
echo "bash FIFO ok (slowest poll ", formatFloat(worst * 1000, ffDecimal, 1), " ms)"

# interrupt a long run; the session keeps working afterwards
let long = sh.submit("sleep 30; echo never")
let after = sh.submit("echo after")
discard pollSession(sh)
sleep(200)
let t1 = epochTime()
doAssert sh.interrupt(long.id) == long
doAssert long.state == jsInterrupted and "(interrupted)" in long.output
let rest = waitDone(sh, 1)
doAssert rest.len == 1 and rest[0] == after and after.output == "after", after.output
doAssert epochTime() - t1 < 5
echo "bash interrupt ok"
closeSession(sh)

# -- session level (R): interrupt restores the output sinks --------------------
if findExe("R").len > 0:
  let r = startSession(rSpec)
  doAssert r != nil
  let slow = r.submit("Sys.sleep(30); cat('never\\n')")
  discard pollSession(r)
  sleep(500)
  doAssert r.interrupt(slow.id) == slow
  let chk = r.submit("cat('sinks', sink.number(), '\\n'); x <- 41 + 1; print(x)")
  let got = waitDone(r, 1)
  doAssert got.len == 1 and got[0] == chk, "R run after interrupt did not finish"
  # the driver no longer sinks output: nothing may be left diverted after an interrupt
  doAssert "sinks 0" in chk.output and "[1] 42" in chk.output, chk.output
  echo "R interrupt ok"
  closeSession(r)
else:
  echo "R not found: skipped R interrupt test"

# -- babel level: placeholder, then results --------------------------------------
registerBuiltins()
var app: App
app.ed.lang = langOrg
app.ed.setText("""* Notebook

#+begin_src bash :session t
sleep 1; echo one
#+end_src

#+begin_src bash :session t
echo two
#+end_src
""")
app.ed.gotoLine(4, 0)                      # body of block 1 (1-based)
babelExecute(app)
doAssert app.lastJobIds.len == 1
let job1 = app.lastJobIds[0]
doAssert (runningPrefix & $job1 & "]") in app.ed.fullText(), app.ed.fullText()

# re-running a block that is still running is refused (its placeholder stays)
app.lastJobIds.setLen(0)
app.ed.gotoLine(4, 0)
babelExecute(app)
doAssert app.lastJobIds.len == 0 and "already running" in app.msg, app.msg

let t2 = epochTime()
while runningJobsLabel(app).len > 0 and epochTime() - t2 < 20:
  discard pollJobs(app)
  sleep(10)
let txt = app.ed.fullText()
doAssert runningPrefix notin txt, txt
doAssert "]:\n: one" in txt, txt                 # #+RESULTS[<hash>]:
echo "babel placeholder -> results ok"

# run-all queues every block; same session runs them in buffer order
let reply = babelExecuteBuffer(app)
doAssert reply.startsWith("queued: jobs "), reply
let t3 = epochTime()
while runningJobsLabel(app).len > 0 and epochTime() - t3 < 20:
  discard pollJobs(app)
  sleep(10)
let txt2 = app.ed.fullText()
doAssert "]:\n: one" in txt2 and "]:\n: two" in txt2, txt2
doAssert txt2.count("#+RESULTS[") == 2, txt2
echo "run-all ok: ", reply
echo "ALL OK"
