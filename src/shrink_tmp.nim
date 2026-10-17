import std/[random, strutils]
import wkbcrdt

proc applyRemote(d: var Doc; ops: seq[Op]) =
  for op in ops:
    case op.kind
    of opInsert:
      discard remoteInsert(d, op.id, op.text)
      discard applyPending(d)
    of opDelete:
      let r = remoteDelete(d, op.runs)
      if r.missing.len > 0:
        d.pending.add Op(kind: opDelete, runs: r.missing)

randomize(99)
proc randomEdit(d: var Doc; site: uint16): seq[Op] =
  let n = d.docLen
  if n == 0 or rand(2) == 0:
    let pos = rand(max(0, n))
    let txt = ["a", "hello ", "x\n", "the ", "q", "zz ", "end\n"][rand(6)]
    d.localInsert(pos, txt, site)
  else:
    let pos = rand(n - 1)
    let ln = min(rand(8) + 1, n - pos)
    d.localDelete(pos, ln)

var docs: array[3, Doc]
var allOps: seq[Op]
for round in 1 .. 1000:
  for si in 0 ..< 3:
    allOps.add docs[si].randomEdit((si + 1).uint16)

proc diverges(ops: seq[Op]): bool =
  # deterministic: fixed shuffle seeds; try several
  for seed in 1 .. 5:
    var r0, r1: Doc
    r0.applyRemote(ops)
    var shuffled = ops
    randomize(seed)
    shuffled.shuffle()
    r1.applyRemote(shuffled)
    if r0.docText != r1.docText: return true
  false

var lo = 1
var hi = allOps.len
while lo < hi:
  let mid = (lo + hi) div 2
  if diverges(allOps[0 ..< mid]): hi = mid
  else: lo = mid + 1
echo "first diverging prefix: ", lo, " ops"
var cand = allOps[0 ..< lo]
while true:
  var reduced = false
  for i in 0 ..< cand.len:
    var trial = cand
    trial.delete(i)
    if trial.len > 0 and diverges(trial):
      cand = trial
      reduced = true
      break
  if not reduced: break
echo "minimal: ", cand.len, " ops"
for op in cand:
  if op.kind == opInsert:
    echo "ins id=", $op.id, " text=", repr(op.text)
  else:
    echo "del runs=", $op.runs
var r0, r1: Doc
r0.applyRemote(cand)
var sh = cand
randomize(1)
sh.shuffle()
r1.applyRemote(sh)
echo "gen-order:  ", repr(r0.docText)
echo "shuffled:   ", repr(r1.docText)
