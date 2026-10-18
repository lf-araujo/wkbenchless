## The citation-graph DAG ledger: data model + validation + lifecycle.
##   nim c -r --hints:off src/test_dag.nim

import std/[strutils, tables]
import wkbdag

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

# -- genesis -------------------------------------------------------------------
block:
  let l = newLedger(1000, @["alice@tox", "bob@tox", "carol@tox"])
  check "genesis splits supply", l.balances["alice@tox"] == 333
  check "genesis supply", l.supply == 1000
  check "empty DAG", l.papers.len == 0

# -- first paper (cites nothing -- must fail) -----------------------------------
block:
  var l = newLedger(100, @["alice@tox"])
  let p = makePaper("First Paper", @["alice@tox"], @[])
  try:
    l.submit(p)
    check "no citations rejected", false
  except LedgerError:
    check "no citations rejected", true

# -- bootstrap: a genesis paper with a self-citation exemption ------------------
# In practice, the first papers cite a "genesis paper" that is seeded
# into the ledger at creation time.
block:
  var l = newLedger(1000, @["alice@tox", "bob@tox"])
  # seed a genesis paper so there's something to cite
  let genesis = makePaper("Genesis: The Scientific Method", @["system"],
                         @[], fee = 0)
  # hack: commit the genesis paper directly (no reviews needed)
  l.papers[genesis.id] = genesis
  l.order.add genesis.id
  check "genesis paper committed", l.isCommitted(genesis.id)

  # alice submits a paper citing the genesis paper
  let p1 = makePaper("A Good Paper", @["alice@tox"],
                     @[Citation(paperId: genesis.id)])
  l.submit(p1)
  check "submitted", l.pending.len == 1

  # not enough reviews yet
  var reg = l.pending[0]
  check "not ready with 0 reviews", not l.readyToCommit(reg)

  # two accepts -- still not enough
  l.addReview(p1.id, Review(paperId: p1.id, reviewerId: "bob@tox", accept: true))
  l.addReview(p1.id, Review(paperId: p1.id, reviewerId: "carol@tox", accept: true))
  reg = l.pending[0]
  check "not ready with 2 accepts", not l.readyToCommit(reg)

  # third accept -- ready
  l.addReview(p1.id, Review(paperId: p1.id, reviewerId: "dave@tox", accept: true))
  reg = l.pending[0]
  check "ready with 3 accepts", l.readyToCommit(reg)

  # commit: alice pays 10, genesis author (system) earns 10
  let aliceBefore = l.balances["alice@tox"]
  l.commit(reg)
  check "committed", l.isCommitted(p1.id)
  check "pending cleared", l.pending.len == 0
  check "alice paid fee", l.balances["alice@tox"] == aliceBefore - 10

  # bob cites alice's paper -- alice earns coins
  let p2 = makePaper("A Follow-Up", @["bob@tox"],
                     @[Citation(paperId: p1.id)])
  l.submit(p2)
  l.addReview(p2.id, Review(paperId: p2.id, reviewerId: "alice@tox", accept: true))
  l.addReview(p2.id, Review(paperId: p2.id, reviewerId: "carol@tox", accept: true))
  l.addReview(p2.id, Review(paperId: p2.id, reviewerId: "dave@tox", accept: true))
  var reg2 = l.pending[0]
  let aliceMid = l.balances["alice@tox"]
  l.commit(reg2)
  check "alice earned from citation", l.balances["alice@tox"] == aliceMid + 10
  check "bob paid fee", l.balances["bob@tox"] == 500 - 10

# -- DAG properties --------------------------------------------------------------
block:
  var l = newLedger(1000, @["alice@tox", "bob@tox", "carol@tox", "dave@tox"])
  let genesis = makePaper("Genesis", @["system"], @[], fee = 0)
  l.papers[genesis.id] = genesis
  l.order.add genesis.id

  # build a chain: g <- p1 <- p2 <- p3
  let p1 = makePaper("P1", @["alice@tox"], @[Citation(paperId: genesis.id)])
  l.submit(p1)
  for r in ["bob@tox", "carol@tox", "dave@tox"]:
    l.addReview(p1.id, Review(paperId: p1.id, reviewerId: r, accept: true))
  var reg = l.pending[0]
  l.commit(reg)

  let p2 = makePaper("P2", @["bob@tox"], @[Citation(paperId: p1.id)])
  l.submit(p2)
  for r in ["alice@tox", "carol@tox", "dave@tox"]:
    l.addReview(p2.id, Review(paperId: p2.id, reviewerId: r, accept: true))
  reg = l.pending[0]
  l.commit(reg)

  let p3 = makePaper("P3", @["carol@tox"],
                     @[Citation(paperId: p1.id), Citation(paperId: p2.id)])
  l.submit(p3)
  for r in ["alice@tox", "bob@tox", "dave@tox"]:
    l.addReview(p3.id, Review(paperId: p3.id, reviewerId: r, accept: true))
  reg = l.pending[0]
  l.commit(reg)

  # topological order: genesis before p1 before p2 before p3
  let gIdx = l.order.find(genesis.id)
  let p1Idx = l.order.find(p1.id)
  let p2Idx = l.order.find(p2.id)
  let p3Idx = l.order.find(p3.id)
  check "topological order", gIdx < p1Idx and p1Idx < p2Idx and p2Idx < p3Idx

  # citedBy: p1 is cited by both p2 and p3
  let p1Cites = l.citedBy(p1.id)
  check "citedBy finds both", p1Cites.len == 2

  # can't cite an unregistered paper
  let fake = makePaper("Fake", @["alice@tox"],
                       @[Citation(paperId: "nonexistent")])
  try:
    l.submit(fake)
    check "unregistered citation rejected", false
  except LedgerError:
    check "unregistered citation rejected", true

  # can't submit the same paper twice
  try:
    l.submit(p1)
    check "duplicate rejected", false
  except LedgerError:
    check "duplicate rejected", true

  # retraction: a new node linked to the retracted one
  let ret = l.retraction(p2.id, @["bob@tox"], "data error")
  check "retraction links to original",
    ret.citations[0].paperId == p2.id
  check "retraction title", ret.title.startsWith("RETRACTION:")

  # duplicate review rejected
  let p4 = makePaper("P4", @["alice@tox"], @[Citation(paperId: p3.id)])
  l.submit(p4)
  l.addReview(p4.id, Review(paperId: p4.id, reviewerId: "bob@tox", accept: true))
  try:
    l.addReview(p4.id, Review(paperId: p4.id, reviewerId: "bob@tox", accept: true))
    check "duplicate review rejected", false
  except LedgerError:
    check "duplicate review rejected", true

  # insufficient coins
  var poor = newLedger(5, @["poor@tox"])
  poor.papers[genesis.id] = genesis
  poor.order.add genesis.id
  let expensive = makePaper("Expensive", @["poor@tox"],
                             @[Citation(paperId: genesis.id)], fee = 100)
  try:
    poor.submit(expensive)
    check "insufficient coins rejected", false
  except LedgerError:
    check "insufficient coins rejected", true

if fails > 0:
  echo $fails, " FAILURES"
  quit 1
echo "all ok"
