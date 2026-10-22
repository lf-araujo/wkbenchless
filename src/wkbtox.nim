## wkbtox.nim -- in-process Tox tunneling for collab, via the nim-tuntox
## library (gjedeer/tuntox translated to Nim).
##
## License boundary (docs/tox-collab.org): nim-tuntox is GPLv3 (as tuntox
## and c-toxcore are), and it is now linked INTO the editor instead of
## spawned as a child -- so combined *binaries* of wkbenchless are GPL;
## the wkbenchless source stays MIT. That trade buys the guest a tunnel
## with no external binary to install: the status line never again says
## "tuntox is not on PATH".
##
##   host:  spawnServer()    ->  TunnelServer with a stable identity in
##                               <cache>/wkbenchless/tox; the Tox ID is
##                               available immediately (no file polling)
##                               and still written to our_id for other tools
##   guest: spawnClient(id)  ->  TunnelClient forwarding 127.0.0.1:<local>
##                               to the collab port on the host behind ID;
##                               connect any time -- data flows once the
##                               tunnel is up (the library holds early
##                               connections in the backlog until the Tox
##                               friend connection is established)
##
## Config (env-first, since the user config cannot import extension modules):
##   gToxSecret   $TUNTOX_SHARED_SECRET -- strongly recommended on both
##                sides: without it, anyone holding the host's Tox ID can
##                tunnel to ANY local port, not just the collab one.
##
## The editor tick calls poll() every frame; each poll drives tox_iterate
## plus the tunnel sockets. No threads, no child processes.

import std/[os, strutils, net]
import tuntox

const toxIdLen = 76     ## TOX_ADDRESS_SIZE (38 bytes) as hex

var
  gToxSecret* = getEnv("TUNTOX_SHARED_SECRET")
  gToxLocalPort* = 0    ## guest: the local port the forward binds (0 = the host port)

proc isToxId*(s: string): bool =
  ## True for a Tox address (76 hex chars); a host:port target never matches.
  s.len == toxIdLen and s.allCharsInSet(HexDigits)

proc toxDir*(): string =
  ## Where the tox identity lives -- stable across sessions, so the
  ## host's Tox ID does not change every share.
  getCacheDir() / "wkbenchless" / "tox"

proc forwardUp*(port: int): bool =
  ## Whether 127.0.0.1:PORT accepts a connection right now -- the guest's
  ## signal that the local forward is listening. Instant either way.
  var sock = newSocket()
  defer: sock.close()
  try: sock.connect("127.0.0.1", Port(port))
  except OSError, IOError: return false
  true

type
  ToxTransport* = ref object
    server*: TunnelServer    ## host side (nil on the guest)
    client*: TunnelClient    ## guest side (nil on the host)
    id*: string              ## host: our Tox ID, set at spawn
    idPath*: string          ## host: where our_id is written for other tools
    announced: bool          ## host: poll() reported the ID once

proc spawnServer*(stateDir = ""): ToxTransport =
  ## Server mode: stable identity in the cache dir (or STATEDIR), the
  ## printable Tox ID available immediately (and mirrored to our_id).
  let d = if stateDir.len > 0: stateDir else: toxDir()
  let srv = newTunnelServer(d, gToxSecret)
  result = ToxTransport(server: srv, id: srv.toxId(), idPath: d / "our_id")
  writeFile(result.idPath, result.id & "\n")

proc spawnClient*(toxId: string; localPort, remotePort: int;
    stateDir = ""): ToxTransport =
  ## Client mode: forward 127.0.0.1:LOCALPORT to the collab port on the
  ## host behind TOXID. The listener binds immediately; the tunnel forms
  ## once the friend request (carrying the shared secret) is accepted.
  let cl = newTunnelClient(
    if stateDir.len > 0: stateDir else: toxDir(), gToxSecret, toxId)
  discard cl.addForward(localPort, "127.0.0.1", remotePort.uint16)
  ToxTransport(client: cl)

proc poll*(t: ToxTransport): bool =
  ## One non-blocking step: drive tox and the tunnel sockets. True when
  ## the Tox ID just became visible (host, first tick after spawn).
  if t == nil: return false
  if t.server != nil: t.server.poll()
  if t.client != nil: t.client.poll()
  if t.id.len > 0 and not t.announced:
    t.announced = true
    return true
  false

proc stop*(t: ToxTransport) =
  ## Nothing to kill anymore -- the identity is persisted in toxDir and
  ## the GC reclaims the tox instance with the session.
  if t == nil: return
  if t.server != nil: t.server.saveState()
  if t.client != nil: t.client.saveState()
