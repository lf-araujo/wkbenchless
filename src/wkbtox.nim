## wkbtox.nim -- manage the tuntox child that tunnels collab TCP over Tox.
##
## License boundary (docs/tox-collab.org): c-toxcore and tuntox are GPLv3, so
## tox stays OUT of process -- this module only spawns and supervises the
## tuntox binary, the way the editor already spawns terminals and REPLs. The
## collab session itself stays stdlib TCP; tuntox forwards it P2P through the
## Tox DHT, so two machines behind NATs co-edit with no server anywhere.
##
##   host:  spawnServer()    ->  tuntox -C <cache>/tox -I <cache>/tox/our_id
##   guest: spawnClient(id)  ->  tuntox -i <id> -L <local>:127.0.0.1:<remote>
##          then connect to 127.0.0.1:<local> once it accepts.
##
## Config (env-first, since the user config cannot import extension modules):
##   gToxBinary   $WKB_TUNTOX, default "tuntox" (PATH lookup)
##   gToxSecret   $TUNTOX_SHARED_SECRET -- strongly recommended on both
##                sides: without it, anyone holding the host's Tox ID can
##                tunnel to ANY local port, not just the collab one. The
##                child inherits our environment, so exporting
##                TUNTOX_SHARED_SECRET in the shell that runs wkbenchless
##                is enough.
##
## POSIX-only for now (spawns /bin/sh to redirect the child's output to a
## log file -- osproc cannot redirect to a file, and a GUI must never block
## reading a pipe). Windows/macOS packaging is a later step.

import std/[os, osproc, strutils, strtabs, net]

var
  gToxBinary* = getEnv("WKB_TUNTOX", "tuntox")
  gToxSecret* = getEnv("TUNTOX_SHARED_SECRET")
  gToxLocalPort* = 0    ## guest: the local port tuntox -L binds (0 = the host port)

const toxIdLen = 76     ## TOX_ADDRESS_SIZE (38 bytes) as hex

proc isToxId*(s: string): bool =
  ## True for a Tox address (76 hex chars); a host:port target never matches.
  s.len == toxIdLen and s.allCharsInSet(HexDigits)

proc toxDir*(): string =
  ## Where the tuntox identity lives -- stable across sessions, so the
  ## host's Tox ID does not change every share.
  getCacheDir() / "wkbenchless" / "tox"

proc forwardUp*(port: int): bool =
  ## Whether 127.0.0.1:PORT accepts a connection right now -- the guest's
  ## signal that the tuntox forward is listening. Instant either way.
  var sock = newSocket()
  defer: sock.close()
  try: sock.connect("127.0.0.1", Port(port))
  except OSError, IOError: return false
  true

type
  ToxChild* = ref object
    p*: Process           ## the supervised tuntox
    logPath*: string      ## its stdout+stderr, for the curious
    idPath*: string       ## server: tuntox -I writes the Tox ID here
    id*: string           ## our Tox ID, once the file appears
    dead*: bool

proc spawnTox(args: openArray[string]; logPath, idPath: string): ToxChild =
  ## Start the tuntox binary with ARGS; stdout+stderr append to LOGPATH.
  ## Nil when the binary is not on the machine.
  let bin = findExe(gToxBinary)
  if bin.len == 0: return nil
  createDir(logPath.parentDir())
  var env: StringTableRef = nil
  if gToxSecret.len > 0:
    env = newStringTable()
    for k, v in envPairs(): env[k] = v
    env["TUNTOX_SHARED_SECRET"] = gToxSecret
  # osproc cannot redirect a child's output to a file, and a GUI must never
  # block reading a pipe: go through /bin/sh, `exec` so there is exactly one
  # child to supervise, and poll the files instead.
  var cmd = "exec " & quoteShell(bin)
  for a in args: cmd.add " " & quoteShell(a)
  cmd.add " >> " & quoteShell(logPath) & " 2>&1"
  let p = startProcess("/bin/sh", "", ["-c", cmd], env = env)
  ToxChild(p: p, logPath: logPath, idPath: idPath)

proc spawnServer*(): ToxChild =
  ## tuntox in server mode: stable identity in the cache dir, the printable
  ## Tox ID written to <toxDir>/our_id (its -I switch).
  let d = toxDir()
  spawnTox(["-C", d, "-I", d / "our_id"], d / "tuntox.log", d / "our_id")

proc spawnClient*(toxId: string; localPort, remotePort: int): ToxChild =
  ## tuntox in client mode: forward LOCALPORT to the collab port on the host
  ## behind TOXID.
  let d = toxDir()
  spawnTox(["-i", toxId, "-L", $localPort & ":127.0.0.1:" & $remotePort],
           d / "tuntox-client.log", "")

proc poll*(c: ToxChild): bool =
  ## One non-blocking supervision step: pick up the Tox ID when the file
  ## appears, notice the child dying. True when something changed.
  if c == nil or c.dead: return false
  if c.id.len == 0 and c.idPath.len > 0 and fileExists(c.idPath):
    c.id = readFile(c.idPath).strip()
    if c.id.len > 0: return true
  if not c.p.running:
    c.dead = true
    return true
  false

proc stop*(c: ToxChild) =
  ## Terminate (then kill) the child; best effort.
  if c == nil or c.p == nil: return
  try:
    c.p.terminate()
    if c.p.waitForExit(2000) == -1:
      c.p.kill()
  except CatchableError: discard
  try: c.p.close()
  except CatchableError: discard
