## setPtySize must reach the child, not just the on-screen grid: a program in
## the terminal asks the kernel for its width, so a failed TIOCSWINSZ leaves it
## wrapping at 80 columns however wide the window is. The ioctl's number differs
## by platform, and a wrong one fails silently.
import wkbpty
import std/strutils

when defined(windows):
  echo "ptysize: skipped (ConPTY)"
else:
  var t = spawnPty(["/bin/sh", "-c", "sleep 0.4; stty size; echo done"])
  doAssert t.alive
  setPtySize(t, 40, 123)
  let got = t.readUntil("done", timeoutMs = 5000, mirror = false)
  doAssert "40 123" in got, "child sees: " & got
  closePty(t)
  echo "ptysize ok"
