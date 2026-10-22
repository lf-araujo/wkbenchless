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
## Robustness to dropped links: the guest keeps the session when the
## host link dies and redials for as long as the session lives (the tox
## forward re-requests a tunnel on accept; the library retries the friend
## request if the tox link itself died). Local edits made while apart are
## recorded; on reconnect they are replayed when only the guest moved,
## adopted when only the host moved, and -- when BOTH sides edited --
## turned into a CriticMarkup review ({++[Name] ... ++} per side, tagged
## with the name the handshake exchanged, consensus plain) that a human
## resolves with the critic commands and M-x tox-resolve. First resolver
## wins: a resolving peer still drains the wire, and the other side's
## resolution arrives as a `resync` doc dump that is adopted verbatim;
## the reviewed text becomes the doc for everyone.
##
## STATUS: text sync + relay + remote cursors + in-process tox transport
## + offline divergence review. Emacs interop (crdt.el's sexp protocol) is
## explicitly out of scope -- this speaks only to other wkbenchless
## instances.

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
var gCollabName* = ""             ## your name in divergence reviews ("": git user.name)

proc collabName(): string =
  ## The identity this side shows in divergence reviews and the handshake:
  ## gCollabName (config), else the git user.name of the checkout.
  (if gCollabName.len > 0: gCollabName else: gitUserName())

type
  Peer = object
    sock: Socket
    site: uint16
    name: string                  ## the peer's identity (handshake)
    buf: string                   ## partial line data
    outbuf: string                ## unsent wire data (a full socket buffer
                                  ## must not drop ops: flush each tick)
    cursorId: CrdtId              ## last reported cursor position

  CollabSession = ref object
    doc: Doc                      ## the authoritative CRDT state
    filePath: string              ## the shared buffer, found by path each tick
    shadow: string                ## buffer text as last seen (edit capture)
    lastVersion: int
    busy: bool                    ## applying remote ops: don't re-diff
    isHost: bool
    site: uint16                  ## our site ID
    hostName: string              ## guest: the host's identity (welcome)
    nextSite: uint16              ## host: the next guest's site ID
    remoteCursors: seq[tuple[site: uint16, id: CrdtId]]  ## peers' cursors
    listen: Socket                ## host only
    peers: Table[int, Peer]       ## fd -> peer (host: guests; guest: the host)
    sel: Selector[int]
    tox: ToxTransport             ## the in-process tox tunnel (nil: plain LAN TCP)
    pendingToxPort: int           ## guest: port to (re)connect to while a link is due
    pendingLanHost: string        ## guest: LAN host to redial ("": the tox forward)
    joinDeadline: float           ## guest: epoch seconds to give up at
    redialHost: string            ## guest: "" = the tox forward, else the LAN host
    redialPort: int               ## guest: 0 = do not redial after a drop
    baseText: string             ## doc text when the link dropped (divergence base)
    offlineOps: seq[Op]           ## guest: local ops created while disconnected
    resolving: bool              ## divergence review: the wire is frozen until tox-resolve

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

proc flushOut(p: var Peer) =
  ## Push as much pending wire data as the socket takes; a would-block
  ## leaves it buffered for the next tick. Without this, a full TCP window
  ## silently DROPPED ops -- the two docs diverged with no review offered.
  ## (The low-level send: the stdlib string send retries a would-block 100
  ## times and then raises, which is exactly the drop we are avoiding.)
  while p.outbuf.len > 0:
    let n = try: send(p.sock, cstring(p.outbuf), p.outbuf.len)
             except OSError, IOError: -1
    if n <= 0: break
    p.outbuf = p.outbuf[n .. ^1]

proc sendLine(p: var Peer; j: JsonNode) =
  p.outbuf.add($j & "\n")
  p.flushOut()

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
  if s.busy or s.resolving: return
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
  if (not s.isHost) and s.peers.len == 0:
    s.offlineOps.add ops    # nobody to send to: replay these on reconnect
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

proc sendDocDump(s: CollabSession; kind: string) =
  ## Our whole doc as one message (resync: the resolved text after a review).
  var blocks = newJArray()
  for b in s.doc.blocks:
    blocks.add %[wireId(b.id), newJBool(b.eob), newJString(b.text)]
  for fd, p in s.peers.mpairs:
    p.sendLine(%*{"t": kind, "blocks": blocks})

proc sendOp(s: CollabSession; op: Op) =
  ## One recorded op onto the wire, in the same shape live edits use.
  for fd, p in s.peers.mpairs:
    case op.kind
    of opInsert:
      p.sendLine(%*{"t": "ins", "id": wireId(op.id), "s": op.text})
    of opDelete:
      var runs = newJArray()
      for r in op.runs:
        runs.add %[wireId(r.id), newJInt(r.count)]
      p.sendLine(%*{"t": "del", "runs": runs})

proc adoptDoc(app: var App; s: CollabSession) =
  ## Push s.doc into the shared buffer and reset the edit-capture shadow.
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

proc enterResolve(app: var App; s: CollabSession; markedUp: string) =
  ## Freeze the wire and show the divergence as CriticMarkup for review;
  ## M-x tox-resolve resumes sharing from the reviewed text.
  s.resolving = true
  s.busy = true
  let idx = app.sharedIdx(s)
  if idx == app.curBuf: app.ed.setText(markedUp)
  else: app.buffers[idx].ed.setText(markedUp)
  s.busy = false
  app.msg = "collab: both sides edited while apart -- review the {++ --} marks, then M-x tox-resolve"

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

proc endSession*(app: var App) {.used.}   # fwd: defined below

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
      p.name = j.getOrDefault("name").getStr("")
      inc s.nextSite
      s.peers[fd] = p
      p.sendLine(%*{"t": "welcome", "site": p.site.int, "name": collabName()})
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
      s.hostName = j.getOrDefault("name").getStr("")
      app.msg = "collab: joined as site " & $s.site &
        (if s.hostName.len > 0: " (host: " & s.hostName & ")" else: "")
  of "sync":
    if not s.isHost:
      if s.resolving: return      # frozen: a divergence review is in progress
      var blocks: seq[Block]
      for b in j["blocks"]:
        blocks.add Block(id: parseId(b[0]), eob: b[1].getBool(),
                         text: b[2].getStr())
      # a reconnect after a drop: reconcile against the divergence base
      # before adopting -- the host's sync may not be the whole story
      if s.baseText.len > 0:
        var remoteText = ""
        for b in blocks: remoteText.add b.text
        let localText = s.doc.docText()
        if localText != s.baseText and remoteText == s.baseText:
          # only we moved while apart: keep our doc, replay the offline ops
          s.baseText = ""
          if s.offlineOps.len > 0:
            for op in s.offlineOps: s.sendOp(op)
          else:
            # no ops but the text moved (e.g. a divergence review resolved
            # while disconnected): a full dump carries it across
            s.sendDocDump("resync")
          s.offlineOps = @[]
          app.msg = "collab: reconnected -- replayed your offline edits"
          return
        if localText != s.baseText and remoteText != s.baseText:
          # both sides moved: human review of the divergence, on both ends
          for ofd, p in s.peers.mpairs:
            p.sendLine(%*{"t": "diverge", "text": localText})
          enterResolve(app, s, divergeMarkup(s.baseText, localText,
            remoteText, s.site.int, 1, collabName(), s.hostName))
          return
        # only the host moved (or nothing did): adopt below
        s.baseText = ""
        s.offlineOps = @[]
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
    if s.resolving: return      # frozen: a divergence review is in progress
    applyInsert(app, s, parseId(j["id"]), j["s"].getStr())
    drainPending(app, s)
    if s.isHost:                       # relay to the other guests
      for ofd, p in s.peers.mpairs:
        if ofd != fd: p.sendLine(j)
  of "del":
    if s.resolving: return      # frozen: a divergence review is in progress
    var runs: seq[IdRun]
    for r in j["runs"].getElems():
      runs.add (parseId(r[0]), r[1].getInt().int)
    applyDelete(app, s, runs)
    drainPending(app, s)
    if s.isHost:
      for ofd, p in s.peers.mpairs:
        if ofd != fd: p.sendLine(j)
  of "cur":
    if s.resolving: return      # frozen: a divergence review is in progress
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
                    "' -- wkbctl dag-review " & p.id[0 ..< 8] & " accept"
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
  of "diverge":
    # a returning guest edited while apart, and so did we: review it too.
    # First resolver wins; the review snapshot is the base at the drop.
    if s.isHost and s.baseText.len > 0 and not s.resolving and
        s.peers.hasKey(fd):
      enterResolve(app, s, divergeMarkup(s.baseText, s.doc.docText(),
        j["text"].getStr(), 1, s.peers[fd].site.int,
        collabName(), s.peers[fd].name))
  of "resync":
    # the reviewed text, as a full doc dump: adopt it, resume sharing,
    # and bring every other peer along. Both directions: a guest that
    # resolved sends it to the host; a host that resolved first sends it
    # to its guests, whose own review (if any) is discarded in favour of
    # the resolution that arrived -- first resolver wins.
    if s.isHost:
      var blocks: seq[Block]
      for b in j["blocks"]:
        blocks.add Block(id: parseId(b[0]), eob: b[1].getBool(),
                         text: b[2].getStr())
      s.doc = loadBlocks(blocks)
      s.baseText = ""
      s.offlineOps = @[]
      s.resolving = false
      adoptDoc(app, s)
      for ofd, p in s.peers.mpairs:
        if ofd != fd: s.sendSync(p, app.sessionName(s))
      app.msg = "collab: divergence resolved -- sharing resumed"
    else:
      var blocks: seq[Block]
      for b in j["blocks"]:
        blocks.add Block(id: parseId(b[0]), eob: b[1].getBool(),
                         text: b[2].getStr())
      s.doc = loadBlocks(blocks)
      s.baseText = ""
      s.offlineOps = @[]
      let wasResolving = s.resolving
      s.resolving = false
      adoptDoc(app, s)
      app.msg = if wasResolving:
        "collab: the host resolved the divergence -- adopted their review"
      else: "collab: adopted the host's reviewed text"
  of "bye":
    if not s.isHost:
      endSession(app)            # the host left deliberately: do not redial
      return
    dropPeer(s, fd)
    app.msg = "collab: peer left"
  else: discard


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
  # divergence review freezes EDITS, not the wire: the other side's
  # resolution (resync), a bye, or the link dying must be seen while the
  # review is open -- captureLocal below is what stays frozen
  # guest: a link is due (first join, or a redial after a drop) -- try the
  # connect each tick; the tox forward re-requests a tunnel on accept
  if s.pendingToxPort > 0:
    if s.baseText.len == 0 and epochTime() > s.joinDeadline:
      # only the FIRST join expires (the tunnel never came up). A redial
      # after a dropped link never gives up: offline edits are kept, the
      # status line shows "redialing", and M-x tox-leave ends it on demand
      app.msg = "collab: the tox tunnel never came up -- is the host sharing?"
      endSession(app)
      return
    var sock = newSocket()
    try:
      let host = if s.pendingLanHost.len > 0: s.pendingLanHost else: "127.0.0.1"
      sock.connect(host, Port(s.pendingToxPort))
      sock.getFd().setBlocking(false)
      let fd = sock.getFd().int
      s.sel.registerHandle(fd, {selectors.Event.Read}, 0)
      s.peers[fd] = Peer(sock: sock, site: 1, buf: "")
      s.peers[fd].sendLine(%*{"t": "hello", "v": wireVersion,
                              "name": collabName()})
      s.pendingToxPort = 0
      app.msg = if s.baseText.len > 0: "collab: reconnected -- syncing ..."
                else: "collab: tox tunnel up -- syncing ..."
    except CatchableError:
      try: sock.close()          # forward not listening yet; retry next tick
      except OSError, IOError: discard
  var closed: seq[int]
  # first push any wire data a full socket window refused on an earlier tick
  for fd, p in s.peers.mpairs:
    p.flushOut()
    if p.outbuf.len > 4_000_000:
      closed.add fd                # wedged link: treat it as dropped
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
    # the doc as it stood IS the divergence base: whatever each side edits
    # from here on happened while the other side could not see it. During
    # a review the base stays the pre-drop snapshot -- the markup in the
    # buffer is not doc text
    if not s.resolving: s.baseText = s.doc.docText()
    if s.isHost:
      app.msg = "collab: peer disconnected"
    else:
      dropPeer(s, fd)
      if s.redialPort > 0:
        # keep the session: redial the forward (or the LAN host) and keep
        # editing -- offline ops are recorded and reconciled on reconnect
        s.pendingToxPort = s.redialPort
        s.pendingLanHost = s.redialHost
        app.msg = "collab: connection lost -- redialing (your edits stay local)"
      else:
        app.msg = "collab: the host connection was lost"
      continue
    dropPeer(s, fd)
  if s.resolving: return         # edits stay local until M-x tox-resolve
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
    tox: t, pendingToxPort: localPort, joinDeadline: epochTime() + 120,
    redialPort: localPort)   # the forward outlives any one tunnel
  s.shadow = app.ed.fullText()      # don't broadcast pre-sync content
  s.lastVersion = app.ed.editVersion()
  session = s
  app.msg = "collab: opening a tox tunnel to " & toxId[0 ..< 8] &
    "... (can take a minute over the DHT)"

proc joinSession*(app: var App; target: string) =
  if session != nil:
    app.msg = "collab: already in a session (M-x tox-leave first)"; return
  # a Tox ID (optionally "<id>:<port>") goes through tuntox; host:port is
  # plain LAN TCP. The target is pasted more often than typed, so strip
  # the newline a clipboard copy usually carries.
  let target = target.strip()
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
    isHost: false, site: 0, sel: newSelector[int](), filePath: app.filePath,
    redialHost: host, redialPort: port.int)
  s.sel.registerHandle(sock.getFd().int, {selectors.Event.Read}, 0)
  s.peers[sock.getFd().int] = Peer(sock: sock, site: 1, buf: "")
  s.shadow = app.ed.fullText()      # don't broadcast pre-sync content
  s.lastVersion = app.ed.editVersion()
  session = s
  s.peers[sock.getFd().int].sendLine(%*{"t": "hello", "v": wireVersion,
                                        "name": collabName()})
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
  defcommand("tox-resolve",
    "Accept the reviewed divergence merge and resume sharing",
    proc (a: var App) =
      if session == nil or not session.resolving:
        a.msg = "collab: no divergence to resolve"; return
      # unresolved tokens resolve as accepted (insertions kept); the
      # reviewed text becomes the doc, and everyone adopts it
      let idx = a.sharedIdx(session)
      let marked = if idx == a.curBuf: a.ed.fullText()
                   else: a.buffers[idx].ed.fullText()
      let text = applyCriticMarkup(marked, accept = true)
      var d: Doc
      discard d.localInsert(0, text, session.site)
      session.doc = d
      session.resolving = false
      session.baseText = ""
      session.offlineOps = @[]
      adoptDoc(a, session)
      # resync, both directions: the other side adopts the reviewed text
      # verbatim (a resolving peer discards its own review in favour of the
      # resolution that arrived first)
      session.sendDocDump("resync")
      a.msg = "collab: divergence resolved -- sharing resumed")
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
    if session.resolving: tox = ", RESOLVING DIVERGENCE (M-x tox-resolve)"
    elif session.tox != nil:
      if session.tox.id.len > 0: tox = ", tox " & session.tox.id[0 ..< 8]
      elif session.pendingToxPort > 0:
        tox = if session.baseText.len > 0: ", redialing" else: ", tox tunnel opening"
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
