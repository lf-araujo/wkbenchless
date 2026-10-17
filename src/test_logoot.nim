## The Logoot-split CRDT: unit tests + the convergence property.
##   nim c -r --hints:off src/test_logoot.nim

import std/[random, strutils, sequtils]
import wkbcrdt

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

proc applyRemote(d: var Doc; ops: seq[Op]) =
  ## Deliver ops in the given order, tolerating deletes-before-inserts.
  for op in ops:
    case op.kind
    of opInsert:
      discard remoteInsert(d, op.id, op.text)
      discard applyPending(d)
    of opDelete:
      let r = remoteDelete(d, op.runs)
      if r.missing.len > 0:
        d.pending.add Op(kind: opDelete, runs: r.missing)

# -- ID generation ------------------------------------------------------------
randomize(7)
block:
  let id = generateId(@[], 0, @[], 0, 42'u16)
  check "empty doc id is 3 pairs", id.len == 3
  check "empty doc id carries site", id[^2] == 42
  check "empty doc id offset 0", id[^1] == 0

block:
  # strictly between two adjacent chars at the same level -> deeper
  let low = @[5'u16, 1'u16, 3'u16]     # pos 5, site 1, offset 3
  let high = @[5'u16, 1'u16, 4'u16]
  let id = generateId(low, 3, high, 4, 9'u16)
  check "adjacent gap descends", id.len > 3
  check "new id > low", cmpId(id, low) > 0
  check "new id < high", cmpId(id, high) < 0

block:
  let a = @[1'u16, 2'u16, 3'u16]
  let b = @[1'u16, 2'u16]
  check "prefix sorts first", cmpId(b, a) < 0
  check "equal ids", cmpId(a, a) == 0

# -- single-site editing ------------------------------------------------------
block:
  var d: Doc
  var all: seq[Op]
  all.add d.localInsert(0, "hello", 1'u16)
  all.add d.localInsert(5, " world", 1'u16)
  all.add d.localInsert(0, "say: ", 1'u16)
  check "text after inserts", d.docText == "say: hello world"
  all.add d.localDelete(5, 6)          # "hello "
  check "text after delete", d.docText == "say: world"
  all.add d.localInsert(10, "!", 1'u16)
  check "text after tail insert", d.docText == "say: world!"
  # replay onto a fresh doc, in order
  var e: Doc
  e.applyRemote(all)
  check "replay converges", e.docText == d.docText

block:
  # same-site adjacent inserts merge into one block
  var d: Doc
  discard d.localInsert(0, "ab", 1'u16)
  discard d.localInsert(2, "cd", 1'u16)
  check "merge keeps one block", d.blocks.len == 1
  check "merged text", d.docText == "abcd"

block:
  # mid-block insert splits; the left half must not re-merge
  var d: Doc
  discard d.localInsert(0, "abcd", 1'u16)
  discard d.localInsert(2, "XY", 1'u16)
  check "split text", d.docText == "abXYcd"
  check "split makes blocks", d.blocks.len >= 2
  discard d.localInsert(2, "Z", 1'u16)
  check "no merge into split left", d.docText == "abZXYcd"

block:
  # duplicate delivery is idempotent
  var d: Doc
  let ops = d.localInsert(0, "hi", 1'u16)
  discard remoteInsert(d, ops[0].id, ops[0].text)
  check "duplicate insert dropped", remoteInsert(d, ops[0].id, ops[0].text).pos < 0

# -- sync ---------------------------------------------------------------------
block:
  var d: Doc
  discard d.localInsert(0, "one ", 1'u16)
  discard d.localInsert(4, "two ", 2'u16)
  discard d.localInsert(8, "three", 1'u16)
  let e = loadBlocks(d.dumpBlocks)
  check "sync roundtrip text", e.docText == "one two three"
  check "sync roundtrip blocks", e.blocks == d.blocks

# -- out-of-order: born deleted ------------------------------------------------
block:
  var d: Doc
  let ins = d.localInsert(0, "hello", 1'u16)
  let del = d.localDelete(0, 2)          # "he"
  var e: Doc
  e.applyRemote(del & ins)               # delete arrives first!
  check "born-deleted converges", e.docText == "llo"

# -- the convergence property --------------------------------------------------
block:
  randomize(42)
  proc randomEdit(d: var Doc; site: uint16): seq[Op] =
    let n = d.docLen
    if n == 0 or rand(2) == 0:
      let pos = rand(max(0, n))
      let txt = ["a", "hello ", "x\n", "the ", "q"][rand(4)]
      d.localInsert(pos, txt, site)
    else:
      let pos = rand(n - 1)
      let ln = min(rand(5) + 1, n - pos)
      d.localDelete(pos, ln)

  var a, b: Doc
  var opsA, opsB: seq[Op]
  for round in 1 .. 300:
    opsA.add a.randomEdit(1'u16)
    opsB.add b.randomEdit(2'u16)
  # both docs receive ALL ops, in the same shuffled order
  var all = opsA & opsB
  all.shuffle()
  var r1, r2: Doc
  r1.applyRemote(all)
  r2.applyRemote(all)
  check "convergence: same order", r1.docText == r2.docText
  # and in two DIFFERENT orders
  all.shuffle()
  var r3: Doc
  r3.applyRemote(all)
  check "convergence: any order", r3.docText == r1.docText
  # the locally-edited docs also converge when they exchange everything
  var a2 = a
  a2.applyRemote(opsB)
  var b2 = b
  b2.applyRemote(opsA)
  check "convergence: live peers", a2.docText == b2.docText
  echo "  (doc is ", r1.docLen, " chars, ", r1.blocks.len, " blocks)"

if fails > 0:
  echo $fails & " FAILURES"
  quit 1
echo "all ok"
