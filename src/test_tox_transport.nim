## tox_transport tests -- against the real in-process nim-tuntox library:
## no child process, no fake binary, no network assertions (the DHT
## handshake is covered hermetically by nim-tuntox's own integration
## test). Verifies Tox-ID shape, server spawn + immediate ID + our_id
## file + poll announcing once, client spawn + the local forward binding,
## and stop().
##
##   nim c -r src/test_tox_transport.nim

import std/[os, strutils]
import wkbtox

const fakeId = "AB".repeat(38)     # 76 hex chars, the shape of a Tox address

# -- isToxId ------------------------------------------------------------------
block tox_id_shape:
  doAssert isToxId(fakeId), "76 hex chars are a Tox ID"
  doAssert not isToxId("127.0.0.1:6543"), "host:port is not a Tox ID"
  doAssert not isToxId("AB".repeat(37)), "too short"
  doAssert not isToxId("G".repeat(76)), "not hex"
  doAssert not isToxId(""), "empty"

# -- keep the test off the real identities in the cache dir --------------------
let dirA = getTempDir() / "wkb_tox_transport_A"   # the host's identity
let dirB = getTempDir() / "wkb_tox_transport_B"   # the guest's identity
removeDir(dirA)
removeDir(dirB)

# -- server: spawn, immediate ID, our_id file, poll announces once -------------
block server:
  let c = spawnServer(dirA)
  doAssert c != nil, "server spawns in-process"
  doAssert c.id.len == 76 and isToxId(c.id), "Tox ID available immediately"
  doAssert fileExists(c.idPath), "our_id written for other tools"
  doAssert readFile(c.idPath).strip() == c.id, "our_id matches"
  doAssert c.poll(), "first poll announces the ID"
  doAssert not c.poll(), "later polls have nothing new"
  c.stop()

# -- client: spawn, forward binds immediately ----------------------------------
block client:
  let port = 44543
  doAssert not forwardUp(port), "nothing listening yet"
  # a real (valid-checksum) Tox ID to befriend; the request just queues
  let srv = spawnServer(dirA)
  let c = spawnClient(srv.id, port, 6543, dirB)
  doAssert c != nil, "client spawns in-process"
  doAssert forwardUp(port), "the local forward binds right away"
  doAssert not c.poll(), "client polls have nothing to announce"
  c.stop()

echo "test_tox_transport: all assertions passed"
