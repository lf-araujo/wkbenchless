## tox_transport tests -- against a FAKE tuntox (a python3 script): no network,
## no real tox. Verifies Tox-ID detection, server spawn + ID pickup + death
## detection, client spawn + the local forward coming up, and stop().
##   nim c -r src/test_tox_transport.nim

import std/[os, strutils, times]
import wkbtox

const fakeId = "AB".repeat(38)     # 76 hex chars, the shape of a Tox address

proc writeFakeTuntox(): string =
  ## A stand-in tuntox: server mode writes the ID file and sleeps; client
  ## mode (-i ... -L l:h:r) opens the local forward after a short delay.
  let path = getTempDir() / "fake-tuntox.py"
  writeFile(path, """
import sys, time, socket
args = sys.argv[1:]
if "-i" in args:
    lport = int(args[args.index("-L") + 1].split(":")[0])
    time.sleep(0.3)
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", lport))
    s.listen(4)
    time.sleep(120)
else:
    open(args[args.index("-I") + 1], "w").write("$#")
    time.sleep(120)
""" % fakeId)
  let exe = getTempDir() / "fake-tuntox"
  writeFile(exe, "#!/bin/sh\nexec python3 " & quoteShell(path) & " \"$@\"\n")
  discard execShellCmd("chmod +x " & quoteShell(exe))
  exe

proc waitFor(deadlineS: float; cond: proc(): bool): bool =
  let limit = epochTime() + deadlineS
  while epochTime() < limit:
    if cond(): return true
    sleep 50
  false

# -- isToxId ------------------------------------------------------------------
block tox_id_shape:
  doAssert isToxId(fakeId), "76 hex chars are a Tox ID"
  doAssert not isToxId("127.0.0.1:6543"), "host:port is not a Tox ID"
  doAssert not isToxId("AB".repeat(37)), "too short"
  doAssert not isToxId("G".repeat(76)), "not hex"
  doAssert not isToxId(""), "empty"

# -- missing binary -----------------------------------------------------------
block no_binary:
  gToxBinary = "definitely-not-on-any-path-xyz"
  doAssert spawnServer() == nil, "missing binary -> nil child"
  gToxBinary = writeFakeTuntox()

# -- server: spawn, ID pickup, death detection, stop ---------------------------
block server:
  let c = spawnServer()
  doAssert c != nil, "fake tuntox spawns"
  doAssert waitFor(5, proc(): bool = c.poll() and c.id.len > 0), "ID file appears"
  doAssert c.id == fakeId, "ID read verbatim: " & c.id
  doAssert not c.dead, "child alive while sleeping"
  doAssert fileExists(c.logPath), "log file created"
  c.stop()
  doAssert waitFor(5, proc(): bool =
    (discard c.poll(); c.dead)), "stop() kills the child"

# -- client: spawn, forward comes up, stop -------------------------------------
block client:
  let port = 44543
  doAssert not forwardUp(port), "nothing listening yet"
  let c = spawnClient(fakeId, port, 6543)
  doAssert c != nil, "fake tuntox client spawns"
  doAssert waitFor(5, proc(): bool = forwardUp(port)), "forward comes up"
  c.stop()
  doAssert waitFor(5, proc(): bool =
    (discard c.poll(); c.dead)), "stop() kills the client child"

echo "test_tox_transport: all assertions passed"
