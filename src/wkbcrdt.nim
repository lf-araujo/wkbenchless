## wkbcrdt.nim -- the Logoot-split sequence CRDT, ported from CRDT.el
## (crdt--generate-id and friends). Pure data + operations: no editor,
## no I/O. The tox_collab extension (and its tests) import this; nothing
## in the editor core does -- promoting it is a separate decision.
##
## An ID is CRDT.el's unibyte string read as big-endian uint16 pairs:
## positions ++ site ++ offset. Characters are totally ordered by ID;
## a block is a run of text whose chars share everything but the offset.
## The empty ID is the boundary sentinel (reads as 0 from the left,
## maxValue from the right).

import std/random

const
  maxValue* = 65536          ## crdt--max-value: exclusive position bound
  maxBlockChars* = 65536      ## a block holds at most this many chars

type
  CrdtId* = seq[uint16]      ## positions ++ site ++ offset

  Block* = object
    id*: CrdtId              ## FULL ID of the block's first char
    eob*: bool               ## end-of-block: a same-site insert may extend me
    text*: string

  IdRun* = tuple[id: CrdtId, count: int]  ## id = first deleted char's FULL id

  OpKind* = enum opInsert, opDelete
  Op* = object
    case kind*: OpKind
    of opInsert:
      id*: CrdtId            ## first char's FULL ID
      text*: string
    of opDelete:
      runs*: seq[IdRun]
    hint*: int               ## buffer position where it happened locally

  Doc* = object
    blocks*: seq[Block]      ## ordered by first-char ID
    pending*: seq[Op]        ## deletes waiting for their inserts

proc base*(id: CrdtId): CrdtId = id[0 ..< id.len - 2]
proc offset*(id: CrdtId): int = id[^1].int
proc site*(id: CrdtId): uint16 = id[^2]

proc cmpId*(a, b: CrdtId): int =
  ## Lexicographic order; a shorter ID that is a prefix sorts first.
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return a[i].int - b[i].int
  a.len - b.len

proc withOffset(id: CrdtId; off: uint16): CrdtId =
  ## The same ID with a different offset pair (the last uint16).
  result = id[0 ..< id.len - 1]
  result.add off

proc idPos(id: CrdtId; i: int; off: int; default: int): int =
  ## CRDT.el's get-two-bytes-with-offset: the pair at index i, with the
  ## offset pair (the last one) overridden by `off`, padded by `default`.
  if id.len == 0: return default
  if i == id.len - 1: return off
  if i < id.len: return id[i].int
  default

proc generateId*(lowId: CrdtId; lowOff: int; highId: CrdtId; highOff: int;
                 site: uint16): CrdtId =
  ## A fresh ID strictly between the char (lowId overridden at lowOff)
  ## and (highId overridden at highOff). Port of crdt--generate-id:
  ## descend while there is no room, copying the shared prefix, then
  ## pick a random position in the gap.
  var l = idPos(lowId, 0, lowOff, 0)
  var h = idPos(highId, 0, highOff, maxValue)
  var depth = 0
  while h - l < 2:
    result.add l.uint16
    inc depth
    l = idPos(lowId, depth, lowOff, 0)
    h = idPos(highId, depth, highOff, maxValue)
  let m = l + 1 + rand(h - l - 2)
  result.add m.uint16
  result.add site
  result.add 0'u16

# -- doc structure ----------------------------------------------------------
proc docLen*(d: Doc): int =
  for b in d.blocks: result += b.text.len

proc docText*(d: Doc): string =
  for b in d.blocks: result.add b.text

proc blockStart(d: Doc, i: int): int =
  for j in 0 ..< i: result += d.blocks[j].text.len

proc blockAt(d: Doc, pos: int): tuple[bi, bo: int] =
  ## The block containing buffer position `pos`, or (-1, -1) if none.
  if pos < 0: return (-1, -1)
  var start = 0
  for i, b in d.blocks:
    if pos < start + b.text.len: return (i, pos - start)
    start += b.text.len
  (-1, -1)

# -- local edits -------------------------------------------------------------
proc localInsert*(d: var Doc; pos: int; text: string; site: uint16): seq[Op] =
  ## Apply a local insertion at buffer offset `pos`; returns ops to send.
  if text.len == 0: return
  # 1. split: an insertion strictly inside a block cuts it there. The
  #    right half keeps its original char IDs (offsets never change);
  #    the left half loses its end-of-block flag so nothing merges into it.
  var left = -1
  let (rb, ro) = blockAt(d, pos)
  if rb >= 0 and ro > 0:
    let b = d.blocks[rb]
    d.blocks[rb] = Block(id: b.id, eob: false, text: b.text[0 ..< ro])
    let rightId = withOffset(b.id, b.id[^1] + ro.uint16)
    d.blocks.insert(Block(id: rightId, eob: b.eob, text: b.text[ro ..^ 1]), rb + 1)
    left = rb
  else:
    let (lb, lo) = blockAt(d, pos - 1)
    if lb >= 0 and lo == d.blocks[lb].text.len - 1: left = lb
  # 2. merge: extend the left block when it is a same-site block end
  var consumed = 0
  if left >= 0:
    let L = d.blocks[left]
    let lastOff = L.id[^1].int + L.text.len - 1
    if L.eob and L.id[^2] == site and lastOff < maxValue - 1:
      let n = min(text.len, maxValue - 1 - lastOff)
      d.blocks[left].text.add text[0 ..< n]
      result.add Op(kind: opInsert,
                    id: withOffset(L.id, (lastOff + 1).uint16),
                    text: text[0 ..< n], hint: pos)
      consumed = n
  # 3. fresh blocks for the rest, chunked to maxBlockChars, each with a
  #    new ID generated between the current neighbors
  while consumed < text.len:
    let n = min(text.len - consumed, maxBlockChars)
    let chunk = text[consumed ..< consumed + n]
    let lowId = if left >= 0: d.blocks[left].id else: CrdtId(@[])
    let lowOff = if left >= 0:
        d.blocks[left].id[^1].int + d.blocks[left].text.len - 1 else: 0
    let rIdx = left + 1
    let highId = if rIdx < d.blocks.len: d.blocks[rIdx].id else: CrdtId(@[])
    let highOff = if rIdx < d.blocks.len: d.blocks[rIdx].id[^1].int else: 0
    let newId = generateId(lowId, lowOff, highId, highOff, site)
    d.blocks.insert(Block(id: newId, eob: true, text: chunk), left + 1)
    result.add Op(kind: opInsert, id: newId, text: chunk, hint: pos + consumed)
    inc left
    inc consumed, n

proc trimBlock(d: var Doc; bi, bo, take: int) =
  ## Remove `take` chars starting at in-block offset `bo`. Any cut clears
  ## the left segment's end-of-block flag: the base continues past the
  ## cut in ID space (tombstones own their offsets), so merging into it
  ## would collide.
  let b = d.blocks[bi]
  if bo == 0 and take >= b.text.len:
    d.blocks.delete bi
  elif bo == 0:
    d.blocks[bi] = Block(id: withOffset(b.id, b.id[^1] + take.uint16),
                         eob: b.eob, text: b.text[take ..^ 1])
  elif bo + take >= b.text.len:
    d.blocks[bi] = Block(id: b.id, eob: false, text: b.text[0 ..< bo])
  else:
    d.blocks[bi] = Block(id: b.id, eob: false, text: b.text[0 ..< bo])
    let rightId = withOffset(b.id, b.id[^1] + (bo + take).uint16)
    d.blocks.insert(Block(id: rightId, eob: b.eob,
                          text: b.text[bo + take ..^ 1]), bi + 1)

proc localDelete*(d: var Doc; pos, len: int): seq[Op] =
  ## Apply a local deletion; returns the op describing the removed IDs.
  if len == 0 or pos >= d.docLen: return
  var runs: seq[IdRun]
  var p = pos
  var remaining = len
  while remaining > 0:
    let (bi, bo) = blockAt(d, p)
    if bi < 0: break
    let take = min(remaining, d.blocks[bi].text.len - bo)
    let firstId = withOffset(d.blocks[bi].id, d.blocks[bi].id[^1] + bo.uint16)
    runs.add (firstId, take)
    trimBlock(d, bi, bo, take)
    dec remaining, take
  if runs.len > 0:
    result.add Op(kind: opDelete, runs: runs, hint: pos)

# -- remote ops --------------------------------------------------------------
proc findBlockFor(d: Doc, id: CrdtId): int =
  ## Index of the last block whose first-char ID <= `id` (-1 if none).
  var lo = 0
  var hi = d.blocks.len - 1
  result = -1
  while lo <= hi:
    let mid = (lo + hi) div 2
    if cmpId(d.blocks[mid].id, id) <= 0:
      result = mid; lo = mid + 1
    else: hi = mid - 1

proc remoteInsert*(d: var Doc; id: CrdtId; text: string): tuple[pos: int, text: string] =
  ## Apply a remote insert; returns where it landed (pos < 0: dropped as
  ## a duplicate). Merges into the left block when the ID extends it, and
  ## splits a block when the ID descends into it (a deeper ID carries
  ## the split offset in the pair right after the block's base -- the
  ## local split that generated it is never sent as an op).
  let i = findBlockFor(d, id)
  if i >= 0:
    let B = d.blocks[i]
    if cmpId(B.id, id) == 0: return (-1, "")          # same first char
    if id.len == B.id.len:
      # sibling in the same base: duplicate, merge, or fall through
      if B.id[0 ..< B.id.len - 1] == id[0 ..< id.len - 1]:
        if id[^1].int < B.id[^1].int + B.text.len:
          return (-1, "")                              # char already exists
        if id[^1].int == B.id[^1].int + B.text.len:
          let pos = blockStart(d, i) + B.text.len      # extends: merge
          d.blocks[i].text.add text
          return (pos, text)
    elif id.len > B.id.len and
         id[0 ..< B.id.len - 1] == B.id[0 ..< B.id.len - 1] and
         id[B.id.len - 1].int >= B.id[^1].int and
         id[B.id.len - 1].int < B.id[^1].int + B.text.len - 1:
      # descends into this block: split it after the char named by the
      # offset pair, and place the new block between the halves
      let k = id[B.id.len - 1].int - B.id[^1].int + 1
      let left = Block(id: B.id, eob: false, text: B.text[0 ..< k])
      let right = Block(id: withOffset(B.id, B.id[^1] + k.uint16),
                        eob: B.eob, text: B.text[k ..^ 1])
      d.blocks[i] = left
      d.blocks.insert(Block(id: id, eob: true, text: text), i + 1)
      d.blocks.insert(right, i + 2)
      return (blockStart(d, i + 1), text)
  # generic placement -- but with unordered delivery the new block's
  # range may already contain deeper blocks (descendants of its base
  # that arrived earlier): split the text around them, piece by piece
  var
    rest = text
    restOff = id[^1]
    at = i + 1
    pos = -1
  let base = id[0 ..< id.len - 1]
  while rest.len > 0:
    # skip deeper blocks of ours that sort before the remaining text
    while at < d.blocks.len:
      let N = d.blocks[at]
      if N.id.len > id.len and N.id[0 ..< id.len - 1] == base and
         N.id[id.len - 1].int < restOff.int: inc at
      else: break
    var cut = rest.len
    if at < d.blocks.len:
      let N = d.blocks[at]
      if N.id.len > id.len and N.id[0 ..< id.len - 1] == base and
         N.id[id.len - 1].int >= restOff.int and
         N.id[id.len - 1].int < restOff.int + rest.len:
        cut = N.id[id.len - 1].int - restOff.int + 1
    d.blocks.insert(Block(id: withOffset(id, restOff), eob: cut >= rest.len,
                          text: rest[0 ..< cut]), at)
    if pos < 0: pos = blockStart(d, at)
    if cut >= rest.len: break
    inc at, 2                    # the piece + the deeper block it split for
    rest = rest[cut ..^ 1]
    restOff = restOff + cut.uint16
  (pos, text)

proc remoteDelete*(d: var Doc; runs: seq[IdRun]): tuple[
    ranges: seq[tuple[pos, len: int]], missing: seq[IdRun]] =
  ## Apply a remote delete. Returns the buffer ranges it removed, plus
  ## the runs whose start char is not (yet) present -- with unordered
  ## delivery a character can be born deleted, so the caller buffers
  ## those in `pending` and retries after later inserts.
  for run in runs:
    var
      firstId = run.id
      count = run.count
    while count > 0:
      let i = findBlockFor(d, firstId)
      if i < 0: break
      let B = d.blocks[i]
      if B.id[0 ..< B.id.len - 1] != firstId[0 ..< firstId.len - 1] or
         firstId[^1].int < B.id[^1].int or
         firstId[^1].int >= B.id[^1].int + B.text.len:
        break                                    # gap: not present (yet)
      let bo = firstId[^1].int - B.id[^1].int
      let take = min(count, B.text.len - bo)
      result.ranges.add (blockStart(d, i) + bo, take)
      trimBlock(d, i, bo, take)
      dec count, take
      # continue into the next same-base block, if the run reaches it
      firstId = withOffset(firstId, firstId[^1] + take.uint16)
    if count > 0:
      result.missing.add (firstId, count)

proc applyPending*(d: var Doc): seq[tuple[pos, len: int]] =
  ## Retry buffered deletes (call after every remote insert).
  var still: seq[IdRun]
  for op in d.pending:
    let r = remoteDelete(d, op.runs)
    result.add r.ranges
    still.add r.missing
  d.pending = @[]
  if still.len > 0:
    d.pending.add Op(kind: opDelete, runs: still)

# -- initial sync ------------------------------------------------------------
proc dumpBlocks*(d: Doc): seq[Block] = d.blocks

proc loadBlocks*(blocks: seq[Block]): Doc =
  ## Rebuild a doc from a sync dump; blocks must arrive in ID order.
  var prev: CrdtId
  for b in blocks:
    if result.blocks.len > 0 and cmpId(b.id, prev) <= 0:
      raise newException(ValueError, "sync dump out of order")
    result.blocks.add b
    prev = b.id
