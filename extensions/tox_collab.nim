## tox_collab.nim -- serverless collaborative editing, CRDT.el-style.
##
## The editing model is wkbcrdt.nim (Logoot split, ported from CRDT.el);
## the transport is plain TCP (stdlib net) -- over LAN as-is, or P2P
## anywhere by tunneling that TCP over Tox. wkbtox.nim runs the nim-tuntox
## library IN-PROCESS on BOTH sides, so neither user installs anything:
##
##   host:  M-x tox-share   (listens on :6543, starts the tox server, copies
##                          the Tox ID to the clipboard once it appears)
##   peer:  M-x tox-join <host's Tox ID>   (opens the local forward, joins
##                                          through it when it's up)
##     or:  M-x tox-join <host:port>       (plain LAN TCP, no tox at all)
##
## Set TUNTOX_SHARED_SECRET in the environment (or gToxSecret) on both
## sides: without it, anyone holding the host's Tox ID can tunnel to ANY
## local port, not just the collab one.
##
## Phase 1 is CRDT.el's host-relayed star: the host owns the session,
## assigns site IDs, sends the initial sync dump, and relays every op to
## the other peers. Logoot convergence means the relay is a convenience,
## not a correctness requirement -- the peers' docs converge under any
## delivery order (see src/test_logoot.nim).
##
## STATUS: text sync + relay + remote cursors + tuntox transport; the
## crdt.el sexp protocol (Emacs interop) is the next phase.

import wkbcore
import wkbcrdt
import dag_ledger
import wkbdag
import wkbtox
import std/[net, json, selectors, strutils, os, tables, sequtils, times]
from std/nativesockets import setBlocking
import std/nativesockets except `\$`

const wireVersion = 1
var gToxPort* = 6543              ## TCP port the host listens on

type
  Peer = object
    sock: Socket
    site: uint16
    buf: string                   ## partial line data
    cursorId: CrdtId              ## last reported cursor position

  CollabSession = ref object
    doc: Doc                      ## the authoritative CRDT state
    filePath: string              ## the shared buffer, found by path each tick
    shadow: string                ## buffer text as last seen (edit capture)
    lastVersion: int
    busy: bool                    ## applying remote ops: don't re-diff
    isHost: bool
    site: uint16                  ## our site ID
    nextSite: uint16              ## host: the next guest's site ID
    remoteCursors: seq[tuple[site: uint16, id: CrdtId]]  ## peers' cursors
    listen: Socket                ## host only
    peers: Table[int, Peer]       ## fd -> peer (host: guests; guest: the host)
    sel: Selector[int]
    tox: ToxTransport             ## the in-process tox tunnel (nil: plain LAN TCP)
    pendingToxPort: int           ## guest: local forward port while it comes up
    joinDeadline: float           ## guest: epoch seconds to give up at

var session: CollabSession        ## the one live session, or nil

# -- wire format ---------------------------------------------------------------
proc wireId(id: CrdtId): JsonNode =
  result = newJArray()
  for x in id: result.add newJInt(x.int)

proc parseId(n: JsonNode): CrdtId =
  for x in n: result.add x.getInt.uint16

proc opToJson(op: Op): JsonNode =
  case op.kind
  of opInsert:
    %*{"t": "ins", "id": wireId(op.id), "s": op.text}
  of opDelete:
    var runs = newJArray()
    for r in op.runs:
      runs.add %[wireId(r.id), newJInt(r.count)]
    %*{"t": "del", "runs": runs}

proc sendLine(p: var Peer; j: JsonNode) =
  try: p.sock.send($j & "\n")
  except OSError, IOError: discard   # would-block: the next tick retries

# -- buffer <-> doc glue -------------------------------------------------------
proc findBuffer(app: App; path: string): int =
  ## The index of the buffer with this path (-1 if gone).
  for i, b in app.buffers:
    if b.filePath == path: return i
  -1

proc sharedIdx(app: App; s: CollabSession): int =
  ## The buffer index of the shared buffer. SynEdit is a VALUE type, so
  ## edits must go through `app.ed` (the live editor) when the shared
  ## buffer is current, or `app.buffers[idx].ed` (the stored copy) via
  ## direct field access -- never through a `var` return binding, which
  ## Nim silently copies.
  app.findBuffer(s.filePath)
proc diffRange(a, b: string): tuple[pos, delLen, insLen: int] =
  ## The single replaced range that turns `a` into `b` (first diff from
  ## the front, last diff from the back).
  var pos = 0
  while pos < a.len and pos < b.len and a[pos] == b[pos]: inc pos
  var ea = a.len
  var eb = b.len
  while ea > pos and eb > pos and a[ea - 1] == b[eb - 1]: dec ea; dec eb
  (pos, ea - pos, eb - pos)

proc captureLocal(app: var App; s: CollabSession) =
  ## Turn local buffer edits (typed anywhere: keys, paste, babel, org
  ## commands) into CRDT ops and broadcast them.
  if s.busy: return
  let idx = app.sharedIdx(s)
  let text = if idx == app.curBuf: app.ed.fullText()
             else: app.buffers[idx].ed.fullText()
  let ver = if idx == app.curBuf: app.ed.editVersion()
            else: app.buffers[idx].ed.editVersion()
  if ver == s.lastVersion: return
  s.lastVersion = ver
  if text == s.shadow: return
  let (pos, delLen, insLen) = diffRange(s.shadow, text)
  var ops: seq[Op]
  if delLen > 0: ops.add s.doc.localDelete(pos, delLen)
  if insLen > 0: ops.add s.doc.localInsert(pos, text[pos ..< pos + insLen], s.site)
  s.shadow = text
  for op in ops:
    let line = opToJson(op)
    if s.isHost:
      for fd, p in s.peers.mpairs: p.sendLine(line)
    else:
      for fd, p in s.peers.mpairs: p.sendLine(line); break
  # broadcast our cursor position (as a CRDT ID, stable across edits)
  let curId = s.doc.posToId(if idx == app.curBuf: app.ed.cursor.int
                            else: app.buffers[idx].ed.cursor.int)
  let curLine = %*{"t": "cur", "u": s.site.int, "id": wireId(curId)}
  if s.isHost:
    for fd, p in s.peers.mpairs: p.sendLine(curLine)
  else:
    for fd, p in s.peers.mpairs: p.sendLine(curLine); break

proc applyInsert(app: var App; s: CollabSession; id: CrdtId; text: string) =
  let (pos, _) = s.doc.remoteInsert(id, text)
  if pos >= 0:
    s.busy = true
    let idx = app.sharedIdx(s)
    if idx == app.curBuf:
      # save the cursor: remote edits must not drag the local author's point
      let savedCursor = app.ed.cursor
      app.ed.gotoPos(pos)
      app.ed.insertText(text)
      # restore, shifted past the insertion if it landed at/before the cursor
      let adjusted = if savedCursor.int <= pos: savedCursor
                     else: savedCursor.int + text.len
      app.ed.gotoPos(adjusted)
    else:
      app.buffers[idx].ed.gotoPos(pos)
      app.buffers[idx].ed.insertText(text)
    s.busy = false

proc applyDelete(app: var App; s: CollabSession; runs: seq[IdRun]) =
  let r = s.doc.remoteDelete(runs)
  if r.ranges.len > 0 or r.missing.len > 0:
    s.busy = true
    let idx = app.sharedIdx(s)
    var savedCursor = if idx == app.curBuf: app.ed.cursor else: 0
    # delete back-to-front so earlier positions stay valid
    for i in countdown(r.ranges.len - 1, 0):
      let (pos, ln) = r.ranges[i]
      if idx == app.curBuf:
        app.ed.selectRange(pos, pos + ln - 1)
        app.ed.deleteSelection()
        # shift the saved cursor past the deletion
        if savedCursor.int > pos + ln: dec savedCursor, ln
        elif savedCursor.int > pos: savedCursor = pos.Natural
      else:
        app.buffers[idx].ed.selectRange(pos, pos + ln - 1)
        app.buffers[idx].ed.deleteSelection()
    if idx == app.curBuf:
      app.ed.gotoPos(savedCursor.int)
    s.busy = false
    if r.missing.len > 0:
      s.doc.pending.add Op(kind: opDelete, runs: r.missing)

proc drainPending(app: var App; s: CollabSession) =
  let ranges = s.doc.applyPending()
  if ranges.len > 0:
    s.busy = true
    let idx = app.sharedIdx(s)
    for i in countdown(ranges.len - 1, 0):
      let (pos, ln) = ranges[i]
      if idx == app.curBuf:
        app.ed.selectRange(pos, pos + ln - 1)
        app.ed.deleteSelection()
      else:
        app.buffers[idx].ed.selectRange(pos, pos + ln - 1)
        app.buffers[idx].ed.deleteSelection()
    s.busy = false
  let idx = app.sharedIdx(s)
  if idx == app.curBuf:
    s.shadow = app.ed.fullText()
    s.lastVersion = app.ed.editVersion()
  else:
    s.shadow = app.buffers[idx].ed.fullText()
    s.lastVersion = app.buffers[idx].ed.editVersion()

# -- message handling ----------------------------------------------------------
proc sendSync(s: CollabSession; p: var Peer; name: string) =
  var blocks = newJArray()
  for b in s.doc.blocks:
    blocks.add %[wireId(b.id), newJBool(b.eob), newJString(b.text)]
  p.sendLine(%*{"t": "sync", "name": name, "blocks": blocks})
  p.sendLine(%*{"t": "ready"})

proc dropPeer(s: CollabSession; fd: int) =
  if not s.peers.hasKey(fd): return
  try: s.sel.unregister(fd)
  except CatchableError: discard
  try: s.peers[fd].sock.close()
  except OSError, IOError: discard
  s.peers.del(fd)

proc sessionName(app: App; s: CollabSession): string =
  ## The shared buffer's file path, for the sync message.
  if s.filePath.len > 0: s.filePath else: "*scratch*"

proc handleLine(app: var App; s: CollabSession; fd: int; line: string) =
  var j: JsonNode
  try: j = parseJson(line)
  except ValueError, JsonParsingError: return
  if j.kind != JObject or not j.hasKey("t"): return
  case j["t"].getStr()
  of "hello":
    if s.isHost and j["v"].getInt() == wireVersion:
      var p = s.peers[fd]
      p.site = s.nextSite
      inc s.nextSite
      s.peers[fd] = p
      p.sendLine(%*{"t": "welcome", "site": p.site.int})
      s.sendSync(p, app.sessionName(s))
      # auto-sync the DAG ledger to the new peer
      if dagReady:
        var papers = newJArray()
        for pid, pp in ledger.papers:
          papers.add %*{"id": pp.id, "title": pp.title,
                        "authors": pp.authors, "fee": pp.fee,
                        "citations": pp.citations.mapIt(
                          %*{"paperId": it.paperId, "doi": it.doi})}
        var balances = newJObject()
        for id, bal in ledger.balances:
          balances[id] = newJInt(bal)
        var genesis = newJObject()
        for doi, pid in ledger.genesisDoi:
          genesis[doi] = newJString(pid)
        p.sendLine(%*{"t": "dag-ledger",
          "papers": papers, "balances": balances, "genesis": genesis,
          "order": ledger.order.mapIt(newJString(it))})
        # also send pending registrations so the peer can review them
        for reg in ledger.pending:
          p.sendLine(%*{"t": "dag-paper", "id": reg.paper.id,
                        "title": reg.paper.title,
                        "authors": reg.paper.authors,
                        "citations": reg.paper.citations.mapIt(
                          %*{"paperId": it.paperId, "doi": it.doi})})
      app.msg = "collab: peer joined (site " & $p.site & ")"
  of "welcome":
    if not s.isHost:
      s.site = j["site"].getInt().uint16
      app.msg = "collab: joined as site " & $s.site
  of "sync":
    if not s.isHost:
      var blocks: seq[Block]
      for b in j["blocks"]:
        blocks.add Block(id: parseId(b[0]), eob: b[1].getBool(),
                         text: b[2].getStr())
      s.doc = loadBlocks(blocks)
      # adopt the shared document's extension so the guest gets the right
      # language (org highlighting, folding, babel...) -- not whatever the
      # guest happened to have open. The buffer's path must change too, or
      # findBuffer (which keys on filePath) loses it on the next tick.
      let sharedName = j.getOrDefault("name").getStr("")
      if sharedName.len > 0:
        let ext = splitFile(sharedName).ext
        let lang = fileExtToLanguage(ext)
        let oldIdx = app.sharedIdx(s)
        if oldIdx >= 0:
          # rename the buffer slot so the tab shows the shared doc's name
          var b = app.buffers[oldIdx]
          b.filePath = sharedName
          app.buffers[oldIdx] = b
          if oldIdx == app.curBuf:
            app.filePath = sharedName
            app.ed.lang = lang
            if lang in {langOrg, langMarkdown}:
              app.ed.setRenderFlag(rfInlineImages)
              app.ed.foldAllPending = true
          else:
            app.buffers[oldIdx].ed.lang = lang
          s.filePath = sharedName
      s.busy = true
      let idx = app.sharedIdx(s)
      if idx == app.curBuf:
        app.ed.setText(s.doc.docText())
        s.shadow = app.ed.fullText()
        s.lastVersion = app.ed.editVersion()
      else:
        app.buffers[idx].ed.setText(s.doc.docText())
        s.shadow = app.buffers[idx].ed.fullText()
        s.lastVersion = app.buffers[idx].ed.editVersion()
      s.busy = false
      app.msg = "collab: synced (" & $s.doc.docLen & " chars)"
  of "ins":
    applyInsert(app, s, parseId(j["id"]), j["s"].getStr())
    drainPending(app, s)
    if s.isHost:                       # relay to the other guests
      for ofd, p in s.peers.mpairs:
        if ofd != fd: p.sendLine(j)
  of "del":
    var runs: seq[IdRun]
    for r in j["runs"].getElems():
      runs.add (parseId(r[0]), r[1].getInt().int)
    applyDelete(app, s, runs)
    drainPending(app, s)
    if s.isHost:
      for ofd, p in s.peers.mpairs:
        if ofd != fd: p.sendLine(j)
  of "cur":
    let site = j["u"].getInt().uint16
    let cid = parseId(j["id"])
    var found = false
    for i in 0 ..< s.remoteCursors.len:
      if s.remoteCursors[i].site == site:
        s.remoteCursors[i] = (site, cid); found = true; break
    if not found: s.remoteCursors.add (site, cid)
    if s.isHost:                       # relay to the other guests
      for ofd, p in s.peers.mpairs:
        if ofd != fd: p.sendLine(j)
  of "dag-paper":
    # a paper submitted for review -- add to the local pending list
    if s.isHost:
      for ofd, p in s.peers.mpairs:
        if ofd != fd: p.sendLine(j)
    # reconstruct the paper and add it to our pending list
    try:
      var cites: seq[Citation]
      for c in j["citations"]:
        cites.add Citation(paperId: c["paperId"].getStr(),
                            doi: c["doi"].getStr())
      let p = Paper(id: j["id"].getStr(),
                    title: j["title"].getStr(),
                    authors: j["authors"].mapIt(it.getStr()),
                    citations: cites, fee: defaultFee)
      if not ledger.isCommitted(p.id):
        var already = false
        for reg in ledger.pending:
          if reg.paper.id == p.id: already = true; break
        if not already:
          ledger.pending.add Registration(paper: p)
          app.msg = "dag: paper for review -- '" & p.title &
                    "' -- wkbctl dag-review " & p.id[0 ..< 8] & " accept <your-id>"
    except CatchableError:
      app.msg = "dag: malformed dag-paper message"
  of "dag-review":
    # a review response -- apply locally and relay
    if s.isHost:
      for ofd, p in s.peers.mpairs:
        if ofd != fd: p.sendLine(j)
    let pid = j["paperId"].getStr()
    let reviewer = j["reviewer"].getStr()
    let verdict = case j["verdict"].getStr()
      of "rvAccept": rvAccept
      of "rvReject": rvReject
      of "rvSendBack": rvSendBack
      of "rvAbstain": rvAbstain
      else: rvAccept
    try:
      ledger.addReview(pid, Review(paperId: pid, reviewerId: reviewer,
                                   verdict: verdict, comment: ""))
      for i in 0 ..< ledger.pending.len:
        if ledger.pending[i].paper.id == pid:
          if ledger.readyToCommit(ledger.pending[i]):
            var reg = ledger.pending[i]
            ledger.commit(reg)
            app.msg = "dag: committed '" & reg.paper.title & "'"
          else:
            app.msg = "dag: review (" & $ledger.pending[i].acceptCount &
                      "/" & $minReviewers & ")"
          break
    except LedgerError as e:
      app.msg = "dag review: " & e.msg
  of "dag-sync-request":
    # send the full ledger state
    if s.isHost:
      var papers = newJArray()
      for pid, p in ledger.papers:
        papers.add %*{"id": p.id, "title": p.title,
                      "authors": p.authors, "fee": p.fee,
                      "citations": p.citations.mapIt(
                        %*{"paperId": it.paperId, "doi": it.doi})}
      var balances = newJObject()
      for id, bal in ledger.balances:
        balances[id] = newJInt(bal)
      var genesis = newJObject()
      for doi, pid in ledger.genesisDoi:
        genesis[doi] = newJString(pid)
      s.peers[fd].sendLine(%*{"t": "dag-ledger",
        "papers": papers, "balances": balances, "genesis": genesis,
        "order": ledger.order.mapIt(newJString(it))})
  of "dag-ledger":
    # receive the full ledger state
    if not s.isHost:
      var l = Ledger(supply: 0)
      for p in j["papers"]:
        var cites: seq[Citation]
        for c in p["citations"]:
          cites.add Citation(paperId: c["paperId"].getStr(),
                              doi: c["doi"].getStr())
        let paper = Paper(id: p["id"].getStr(),
                          title: p["title"].getStr(),
                          authors: p["authors"].mapIt(it.getStr()),
                          citations: cites, fee: p["fee"].getInt())
        l.papers[paper.id] = paper
      for k, v in j["balances"]:
        l.balances[k] = v.getInt()
      for k, v in j["genesis"]:
        l.genesisDoi[k] = v.getStr()
      for o in j["order"]:
        l.order.add o.getStr()
      ledger = l
      dagReady = true
      app.msg = "dag: synced (" & $l.papers.len & " papers)"
  of "bye":
    dropPeer(s, fd)
    if s.isHost: app.msg = "collab: peer left"
  else: discard

proc endSession*(app: var App) {.used.}   # fwd: defined below

proc tick(app: var App; s: CollabSession) =
  app.syncActive()               # write live edits into the buffer slot
  if app.findBuffer(s.filePath) < 0:
    endSession(app)              # the shared buffer was closed
    return
  # drive the in-process tox tunnel; the host's Tox ID shows up on the
  # first poll after spawn
  if s.tox != nil and s.tox.poll():
    if s.tox.id.len > 0:
      putClipboardText(s.tox.id)
      app.msg = "collab: tox ID " & s.tox.id & " (copied) -- peer: M-x tox-join <ID>" &
        (if gToxSecret.len == 0: "  [no shared secret!]" else: "")
  # guest: the tox forward is coming up -- try the local connect each tick
  if s.pendingToxPort > 0:
    if epochTime() > s.joinDeadline:
      app.msg = "collab: the tox tunnel never came up -- is the host sharing?"
      endSession(app)
      return
    var sock = newSocket()
    try:
      sock.connect("127.0.0.1", Port(s.pendingToxPort))
      sock.getFd().setBlocking(false)
      let fd = sock.getFd().int
      s.sel.registerHandle(fd, {selectors.Event.Read}, 0)
      s.peers[fd] = Peer(sock: sock, site: 1, buf: "")
      s.peers[fd].sendLine(%*{"t": "hello", "v": wireVersion})
      s.pendingToxPort = 0
      app.msg = "collab: tox tunnel up -- syncing ..."
    except CatchableError:
      try: sock.close()          # forward not listening yet; retry next tick
      except OSError, IOError: discard
  var closed: seq[int]
  for ready in s.sel.select(0):
    if selectors.Event.Read notin ready.events: continue
    if s.isHost and ready.fd == s.listen.getFd().int:
      # a guest is waiting to connect
      var client: Socket
      try:
        accept(s.listen, client)
        client.getFd().setBlocking(false)
        let fd = client.getFd().int
        s.sel.registerHandle(fd, {selectors.Event.Read}, 0)
        s.peers[fd] = Peer(sock: client, site: 0, buf: "")
      except OSError: discard
      continue
    if not s.peers.hasKey(ready.fd): continue
    var chunk = newString(8192)
    let n = try: s.peers[ready.fd].sock.recv(chunk, 8192)
             except OSError, IOError: -1
    if n < 0:
      continue                  # no data yet (non-blocking)
    if n == 0:
      closed.add ready.fd       # peer closed the connection
      continue
    let fd = ready.fd
    s.peers[fd].buf.add chunk[0 ..< n]
    while true:
      let nl = s.peers[fd].buf.find('\n')
      if nl < 0: break
      let line = s.peers[fd].buf[0 ..< nl]
      s.peers[fd].buf = s.peers[fd].buf[nl + 1 ..^ 1]
      # The wire is a trust boundary: a peer's malformed message (missing /
      # wrongly-typed fields) must not escape into the tick hook, whose handler
      # ends the session on any error. Drop the message, keep the connection.
      try: app.handleLine(s, fd, line)
      except CatchableError: app.msg = "collab: dropped a malformed message"
  for fd in closed:
    if s.isHost: app.msg = "collab: peer disconnected"
    dropPeer(s, fd)
  captureLocal(app, s)

# -- session lifecycle ---------------------------------------------------------
proc endSession*(app: var App) =
  if session == nil: return
  if session.isHost:
    for fd, p in session.peers.mpairs: p.sendLine(%*{"t": "bye"})
  else:
    for fd, p in session.peers.mpairs: p.sendLine(%*{"t": "bye"})
  for fd in toSeq(session.peers.keys): session.dropPeer(fd)
  if session.isHost:
    try: session.sel.unregister(session.listen.getFd().int)
    except CatchableError: discard
    try: session.listen.close()
    except OSError, IOError: discard
  if session.tox != nil:
    session.tox.stop()
  session = nil
  app.msg = "collab: session ended"

proc startShare*(app: var App) =
  if session != nil:
    app.msg = "collab: already sharing (M-x tox-leave first)"; return
  if app.ed.fullText().len == 0:
    app.msg = "collab: nothing to share (empty buffer)"; return
  var listen = newSocket()
  try:
    listen.setSockOpt(OptReuseAddr, true)
    listen.bindAddr(Port(gToxPort))
    listen.listen()
  except OSError, IOError:
    app.msg = "collab: cannot bind port " & $gToxPort; return
  let s = CollabSession(
    isHost: true, site: 1, nextSite: 2, listen: listen,
    sel: newSelector[int](), filePath: app.filePath)
  s.sel.registerHandle(listen.getFd().int, {selectors.Event.Read}, 0)
  # the current buffer becomes the document
  let text = app.ed.fullText()
  discard s.doc.localInsert(0, text, s.site)
  s.shadow = text
  s.lastVersion = app.ed.editVersion()
  session = s
  # the tox transport: in-process, so peers behind NATs can reach :PORT too.
  # LAN sharing works either way -- tox is additive.
  s.tox = spawnServer()
  app.msg = "collab: sharing on :" & $gToxPort & " (LAN) + tox -- waiting for the Tox ID..."

proc joinOverTox(app: var App; toxId: string; remotePort: int) =
  ## Join through a tox tunnel: open the client forward, then connect
  ## through it (the tick hook retries; DHT traversal can take a minute).
  if app.ed.changed:
    app.msg = "collab: save or discard this buffer first"; return
  let localPort = if gToxLocalPort > 0: gToxLocalPort else: gToxPort
  let t = spawnClient(toxId, localPort, remotePort)
  let s = CollabSession(
    isHost: false, site: 0, sel: newSelector[int](), filePath: app.filePath,
    tox: t, pendingToxPort: localPort, joinDeadline: epochTime() + 120)
  s.shadow = app.ed.fullText()      # don't broadcast pre-sync content
  s.lastVersion = app.ed.editVersion()
  session = s
  app.msg = "collab: opening a tox tunnel to " & toxId[0 ..< 8] &
    "... (can take a minute over the DHT)"

proc joinSession*(app: var App; target: string) =
  if session != nil:
    app.msg = "collab: already in a session (M-x tox-leave first)"; return
  # a Tox ID (optionally "<id>:<port>") goes through tuntox; host:port is
  # plain LAN TCP.
  let parts = target.rsplit(":", 1)
  if parts.len == 2:
    let port = try: parts[1].parseInt except ValueError: 0
    if port > 0 and isToxId(parts[0]):
      joinOverTox(app, parts[0], port)
      return
  if isToxId(target):
    joinOverTox(app, target, gToxPort)
    return
  let host = if parts.len == 2: parts[0] else: "127.0.0.1"
  let port = if parts.len == 2: parts[1].parseInt.Port else: Port(gToxPort)
  var sock = newSocket()
  try:
    sock.connect(host, port)
    sock.getFd().setBlocking(false)
  except OSError, IOError, CatchableError:
    app.msg = "collab: cannot connect to " & target; return
  let s = CollabSession(
    isHost: false, site: 0, sel: newSelector[int](), filePath: app.filePath)
  s.sel.registerHandle(sock.getFd().int, {selectors.Event.Read}, 0)
  s.peers[sock.getFd().int] = Peer(sock: sock, site: 1, buf: "")
  s.shadow = app.ed.fullText()      # don't broadcast pre-sync content
  s.lastVersion = app.ed.editVersion()
  session = s
  s.peers[sock.getFd().int].sendLine(%*{"t": "hello", "v": wireVersion})
  app.msg = "collab: connecting to " & target & " ..."

proc extend*(app: var App) =
  defcommand("tox-share", "Share this buffer for collaborative editing", startShare)
  defcommand("tox-join", "Join a collab session (host:port or the host's tox ID)",
             proc(a: var App) =
    # 1. an org header: #+TOX_ADDRESS: host:port
    for i in 0 ..< min(a.ed.getLineCount(), 30):
      let ln = a.ed.getLineText(i)
      if ln.len > 0 and ln[0] != '#': break    # past the header
      if ln.len > 14 and ln.toLowerAscii().startsWith("#+tox_address:"):
        let hostAddr = ln[15 ..^ 1].strip()
        if hostAddr.len > 0:
          try: joinSession(a, hostAddr)
          except CatchableError as e: a.msg = "tox-join: " & e.msg
          return
    # 2. a host:port or Tox-ID word at the cursor
    let target = wordAtCursor(a)
    if (target.contains(":") and target.contains(".")) or isToxId(target):
      try: joinSession(a, target)
      except CatchableError as e: a.msg = "tox-join: " & e.msg
      return
    # 3. prompt in the status line
    a.palettePrompt = "join host:port or tox ID: "
    gPromptHandler = proc(app: var App; text: string) =
      if text.len > 0:
        try: joinSession(app, text)
        except CatchableError as e: app.msg = "tox-join: " & e.msg
    openPalette(a, pmPrompt))
  defcommand("tox-leave", "Leave the collaborative session", endSession)
  bindkey("C-c j", "tox-share")
  bindkey("C-c n", "tox-join")
  registerCtlVerb("tox-join", "join a collab session: <host:port | tox ID>",
                  proc(a: var App; args: seq[string]; body: string): string =
    if args.len < 1: return "usage: tox-join <host:port | tox ID>"
    joinSession(a, args[0])
    a.msg)
  registerCtlVerb("tox-share", "share the current buffer for collab",
                  proc(a: var App; args: seq[string]; body: string): string =
    startShare(a)
    a.msg)
  registerCtlVerb("tox-leave", "leave the collab session",
                  proc(a: var App; args: seq[string]; body: string): string =
    endSession(a)
    a.msg)
  registerCtlVerb("tox-msg", "read the status bar message",
                  proc(a: var App; args: seq[string]; body: string): string =
    a.msg)
  registerCtlVerb("tox-status", "collab session status",
                  proc(a: var App; args: seq[string]; body: string): string =
    if session == nil: return "no session"
    var tox = ""
    if session.tox != nil:
      if session.tox.id.len > 0: tox = ", tox " & session.tox.id[0 ..< 8]
      elif session.pendingToxPort > 0: tox = ", tox tunnel opening"
      else: tox = ", tox"
    (if session.isHost: "host site " & $session.site & ", " &
      $session.peers.len & " peer(s), " & $session.doc.docLen & " chars" & tox
     else: "guest (site " & $session.site & "), " & $session.doc.docLen & " chars" & tox))
  # DAG messages travel over the collab channel
  gDagSend = proc(j: JsonNode) =
    if session != nil:
      if session.isHost:
        for fd, p in session.peers.mpairs: p.sendLine(j)
      else:
        for fd, p in session.peers.mpairs: p.sendLine(j); break

  addHook("tick", proc(a: var App) =
    # update the status circle color
    if session == nil and (not dagReady or ledger.pending.len == 0):
      gStatusCircle = color(0xb0, 0xb0, 0xb0)   # gray: offline
    elif session != nil and (not dagReady or ledger.pending.len == 0):
      gStatusCircle = color(0x40, 0xc0, 0x40)   # green: connected, idle
    elif dagReady and ledger.pending.len > 0:
      gStatusCircle = color(0xe0, 0xc0, 0x00)   # yellow: papers to review
      for reg in ledger.pending:
        for r in reg.reviews:
          if r.verdict == rvSendBack or r.verdict == rvReject:
            gStatusCircle = color(0xe0, 0x40, 0x40)  # red: action needed
    if session != nil:
      try: tick(a, session)
      except CatchableError as e:
        a.msg = "collab tick error: " & e.msg & " -- ending"
        try: endSession(a)
        except CatchableError: session = nil)
