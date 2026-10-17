## Live integration check for tmux-backed remote sessions (needs an
## authenticated ssh master to the host). Not part of the unit suite.
##   nim c -r src/test_tmux_remote.nim user@host /remote/dir
import std/[os, strutils, times]
import wkbcore

let host = paramStr(1)
let dir = paramStr(2)
let name = "tmuxtest@" & host

proc waitReady(s: Session; label: string): bool =
  let t0 = epochTime()
  while s.phase != spReady and s.phase != spFailed and epochTime() - t0 < 90:
    for j in pollSession(s): echo "  (failed job) ", j.output
    os.sleep(20)
  echo label, ": phase=", s.phase, " in ", formatFloat(epochTime() - t0, ffDecimal, 1), "s",
       (if s.startFailed.len > 0: " -- " & s.startFailed else: "")
  s.phase == spReady

proc runJob(s: Session; code: string): string =
  let j = s.submit(code)
  let t0 = epochTime()
  while j.state notin {jsDone, jsInterrupted} and epochTime() - t0 < 120:
    discard pollSession(s)
    os.sleep(20)
  j.output

proc check(ok: bool; what: string) =
  if not ok: raise newException(ValueError, what)

let spec = specFor(rSpec, name, dir)
check spec.tmuxName == "wkb-tmuxtest-R", spec.tmuxName
var live: seq[Session]
try:
  # 1. fresh: create the host session, launch R in the pane
  var s = startSession(spec)
  check s != nil, "spawn"
  live.add s
  check waitReady(s, "fresh"), "fresh session never became ready"

  # 1a. staging, by hand, so a failure shows what R actually answered
  var probe = newSeq[byte](3000)
  for i in 0 ..< probe.len: probe[i] = byte(32 + i mod 90)
  let t0 = epochTime()
  s.pty.feed(rSpec.writeBytesCode(probe, ".wkbenchless-run/probe.src", "WKBSTAGEP1"))
  let acc = s.pty.readUntil("WKBSTAGEP1", timeoutMs = 20_000, mirror = false)
  echo "stage probe: marker ", ("WKBSTAGEP1" in acc), " after ",
       formatFloat(epochTime() - t0, ffDecimal, 1), "s, ", acc.len, " bytes back"
  if "WKBSTAGEP1" notin acc:
    echo "---- last 2500 bytes R/pane sent back ----\n", acc[max(0, acc.len - 2500) .. ^1]
    check false, "staging marker never came back"

  # 1b. a real block through the job queue, with every awkward byte
  var big = "x_state <- 42\ncat('quote\\' \"dq\" back\\\\slash tab\\t pct% dollar$ ok\\n')\n"
  for i in 1 .. 300: big.add "v" & $i & " <- " & $i & "  # padding line " & $i & "\n"
  big.add "cat('sum', sum(sapply(1:300, function(i) get(paste0('v', i)))), '\\n')\n"
  let out1 = runJob(s, big)
  echo "run 1 output:\n", out1
  check "quote' \"dq\" back\\slash tab\t pct% dollar$ ok" in out1, "bytes mangled"
  check "sum 45150" in out1, "staged block truncated"

  # 2. drop the connection (as a crash would): the host session must survive
  s.pty.closePty()
  os.sleep(1500)

  # 3. reconnect: should REATTACH (no new R), state intact
  var s2 = startSession(spec)
  check s2 != nil, "respawn"
  live.add s2
  check waitReady(s2, "reattach"), "reattach never became ready"
  let out2 = runJob(s2, "cat('x_state is', x_state, '\\n')\n")
  echo "run 2 output:\n", out2
  check "x_state is 42" in out2, "state lost across reconnect"

  s2.pty.closePty(quit = spec.quit)   # quit R: ends the pane and the host session
  echo "ALL OK"
except CatchableError as e:
  echo "FAILED: ", e.msg
finally:
  for x in live: x.pty.closePty()     # never orphan an ssh channel
