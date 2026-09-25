## Block dependencies, staleness, :cache, streaming output and the ctl tab
## hand-off.   nim c -r --hints:off src/test_blocks.nim

import std/[strutils, times, sets, tables]
from std/os as stdos import nil
from std/os import `/`
import wkbcore

template sleep(ms: int) = stdos.sleep(ms)

proc settle(app: var App; limit = 30.0) =
  let t0 = epochTime()
  while runningJobsLabel(app).len > 0 and epochTime() - t0 < limit:
    discard pollJobs(app)
    sleep(10)
  doAssert runningJobsLabel(app).len == 0, "jobs did not finish: " & jobsSummary(app)

proc lineOf(app: App; text: string): int =
  for i in 0 ..< app.ed.getLineCount():
    if app.ed.getLineText(i).strip() == text: return i
  -1

# -- parsing, hashes, order ----------------------------------------------------
let doc = """#+name: a
#+begin_src bash :session t
echo A
#+end_src

#+RESULTS[abc123]:
: A

#+caption: uses a
#+name: b
#+begin_src bash :session t :depends a :cache yes
echo B
#+end_src

#+begin_src python :var x=b() :var y=3
print(x)
#+end_src
"""
var blocks = parseBlocks(doc.splitLines())
doAssert blocks.len == 3
doAssert blocks[0].name == "a" and blocks[0].storedHash == "abc123"
doAssert blocks[1].name == "b" and blocks[1].depends == @["a"] and blocks[1].cache
doAssert blocks[2].depends == @["b"], $blocks[2].depends     # :var ref, literal skipped
doAssert computeHashes(blocks).len == 0
let hb = blocks[1].hash
var edited = parseBlocks(doc.replace("echo A", "echo A2").splitLines())
discard computeHashes(edited)
doAssert edited[1].hash != hb and edited[2].hash != blocks[2].hash, "upstream edit must propagate"
var probs: seq[string]
doAssert dependencyOrder(blocks, 2, probs) == @[0, 1, 2] and probs.len == 0
var cyc = parseBlocks("""#+name: p
#+begin_src bash :depends q
#+end_src
#+name: q
#+begin_src bash :depends p :depends nope
#+end_src""".splitLines())
doAssert computeHashes(cyc).len >= 2                          # cycle + unknown name
echo "parse/hash/order ok"

# -- run-block --deps, freshness, run-stale (bash) --------------------------------
registerBuiltins()
let tmp = stdos.getTempDir() / "wkb-test-blocks"
stdos.createDir(tmp)
var app: App
app.ed.lang = langOrg
app.filePath = tmp / "nb.org"
app.termActive = -1
app.ed.setText("""* nb

#+name: base
#+begin_src bash :session t
echo base
#+end_src

#+name: mid
#+begin_src bash :session t :depends base
echo mid
#+end_src

#+begin_src bash :session t :depends mid
echo top
#+end_src
""")
app.ed.gotoLine(lineOf(app, "echo top") + 1, 0)
let reply = babelExecuteDeps(app)
doAssert reply.startsWith("queued: jobs ") and app.lastJobIds.len == 3, reply
settle(app)
var bs = blockTable(app)
for b in bs:
  doAssert b.storedHash == b.hash and isFresh(app, b), "block " & $b.idx & " not fresh"
doAssert "#+RESULTS[" & bs[2].hash & "]:\n: top" in app.ed.fullText()
discard runStale(app)
doAssert app.lastJobIds.len == 0, "nothing should be stale"
# editing the base block makes the whole chain stale
let l = lineOf(app, "echo base")
var lines = app.ed.fullText().splitLines()
lines[l] = "echo base2"
app.ed.setText(lines.join("\n"))
discard runStale(app)
doAssert app.lastJobIds.len == 3, "stale after upstream edit: " & $app.lastJobIds.len
settle(app)
doAssert ": base2" in app.ed.fullText()
# a restarted session knows nothing: everything is stale again
app.ranIn.clear()
discard runStale(app)
doAssert app.lastJobIds.len == 3
settle(app)
echo "deps / stale ok"

# -- :cache yes (R): save objects, restore them in a fresh session ---------------------
if stdos.findExe("R").len > 0:
  var r: App
  r.ed.lang = langOrg
  r.filePath = tmp / "cache.org"
  r.termActive = -1
  r.ed.setText("""#+name: fit
#+begin_src R :session c :cache yes
fitted <- 40 + 2
cat("fitted", fitted, "\n")
#+end_src
""")
  stdos.removeDir(tmp / ".wkb-cache")
  r.ed.gotoLine(3, 0)
  babelExecute(r)
  settle(r)
  let h = blockTable(r)[0].hash
  doAssert stdos.fileExists(tmp / ".wkb-cache" / (h & ".RData")), "no cache file"
  doAssert ": fitted 42" in r.ed.fullText(), r.ed.fullText()
  # up to date in this session: a cache hit runs nothing
  r.ed.gotoLine(3, 0)
  r.lastJobIds.setLen(0)
  babelExecute(r)
  doAssert r.lastJobIds.len == 0 and "cache hit" in r.msg, r.msg
  # new session: the hit restores the objects instead of re-running
  closeSession(r.sessions["r/c"])
  r.sessions.del("r/c")
  r.ranIn.clear()
  r.ed.gotoLine(3, 0)
  babelExecute(r)
  doAssert r.lastJobIds.len == 1 and "restoring" in r.msg, r.msg
  settle(r)
  let s = r.sessions["r/c"]
  doAssert "[1] 42" in s.runBlock("print(fitted)"), "cached object not restored"
  doAssert isFresh(r, blockTable(r)[0])
  echo "R cache ok"

  # -- streaming: output reaches the pane while the block still runs ----------------
  let js = s.submit("cat('early\\n'); Sys.sleep(2); cat('late\\n')")
  let t0 = epochTime()
  var sawEarlyWhileRunning = false
  while js.state != jsDone and epochTime() - t0 < 10:
    discard pollSession(s)
    if js.state == jsRunning and "early" in s.pty.outbuf and "late" notin s.pty.tap:
      sawEarlyWhileRunning = true
    sleep(20)
  doAssert sawEarlyWhileRunning, "output only appeared at the end"
  doAssert "early" in js.output and "late" in js.output
  echo "streaming ok"

  # -- inference ------------------------------------------------------------------------
  var inf: App
  inf.ed.lang = langOrg
  inf.ed.setText("""#+begin_src R :session i
a <- 1
#+end_src

#+begin_src R :session i
b <- a + 1
helper <- function(z) z * a
#+end_src

#+begin_src R :session i :depends stale-name
print(helper(b))
d <- data.frame(q = 1) |> subset(q > 0)
#+end_src
""")
  discard inferBlockDeps(inf)
  let t = inf.ed.fullText()
  doAssert "#+name: a\n#+begin_src R :session i\na <- 1" in t, t
  doAssert "#+name: b\n#+begin_src R :session i :depends a\nb <- a + 1" in t, t
  doAssert "#+begin_src R :session i :depends b\nprint(helper(b))" in t, t   # helper and b both from block 2
  doAssert "stale-name" notin t
  echo "infer ok"
else:
  echo "R not found: skipped cache / streaming / infer tests"

# -- ctl-started runs show their session tab, then return to the terminal ------------------
var c: App
c.ed.lang = langOrg
c.terminals.add Terminal(label: "claude", cmd: "claude")
c.termActive = 0
c.ctlOrigin = true
let id = submitEval(c, "bash", "ctl", "sleep 0.3; echo hi")
c.ctlOrigin = false
doAssert id > 0 and c.termActive == -1 and c.curSession == "ctl", "session tab not shown"
settle(c)
doAssert c.termActive == 0, "did not return to the claude tab"
echo "ctl tab hand-off ok"
echo "ALL OK"
