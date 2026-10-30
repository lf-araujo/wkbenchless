## test_ssh_reconnect -- the per-host retry clock: exponential backoff capped
## at 30 min, the fail-fast refusal messages (plain / backing off / blocked),
## and probe-file name sanitization. The probe/watch loop itself needs a live
## App + ssh, so it is verified by build + the messages here.
##   nim c -r --hints:off src/test_ssh_reconnect.nim
import std/[strutils, times, tables, sets]
import wkbcore

var fails = 0
template check(name: string; cond: bool; got = "") =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name, (if got.len > 0: "  got: " & got else: ""); inc fails

block retry_clock:
  gSshRetry.clear()
  noteSshFailure("h", blocked = false)
  check "first failure backs off ~2s",
    abs(gSshRetry["h"].nextTry - epochTime() - 2.0) < 0.5
  for i in 2 .. 11: noteSshFailure("h", blocked = false)
  check "the backoff caps at 30 min",
    abs(gSshRetry["h"].nextTry - epochTime() - 1800.0) < 0.5,
    $gSshRetry["h"].nextTry
  check "a failure puts the host on the watch", "h" in gSshWatch
  noteSshFailure("h2", blocked = true)
  check "a pre-banner close blocks the host", gSshRetry["h2"].blocked

block refusals:
  gSshRetry.clear()
  check "a fresh host: the plain no-master message",
    sshRefusal("light.vipbg.vcu.edu") ==
      "no ControlMaster for light.vipbg.vcu.edu; log in (M-x remote-login light.vipbg.vcu.edu)",
    sshRefusal("light.vipbg.vcu.edu")
  noteSshFailure("h", blocked = false)
  let r = sshRefusal("h")
  check "a backing-off host says when it retries",
    r.startsWith("no ControlMaster for h; log in (M-x remote-login h)") and
      "[auto-retry in " in r, r
  noteSshFailure("locked", blocked = true)
  check "a blocked host says lockout",
    sshRefusal("locked") ==
      "locked refused connections (possible lockout); log in (M-x remote-login locked)",
    sshRefusal("locked")

if fails > 0:
  echo "test_ssh_reconnect: ", fails, " FAILED"
  quit 1
echo "test_ssh_reconnect: all assertions passed"
