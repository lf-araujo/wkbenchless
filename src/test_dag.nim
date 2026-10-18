## The citation-graph DAG ledger: BibTeX integration, SHA-1 IDs,
## genesis registry, retraction, and the full lifecycle.
##   nim c -r --hints:off src/test_dag.nim

import std/[strutils, tables, sequtils]
import wkbdag
import wkbbib

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

# -- BibTeX parser --------------------------------------------------------------
block:
  let bib = parseBib("""
@article{smith2024,
  title = {A Great Paper},
  author = {Smith, John and Doe, Jane},
  year = {2024},
  doi = {10.1234/smith2024},
  dagid = {a3f5b8c9d2e1f4a5b6c7d8e9f0a1b2c3d4e5f6a7b},
}

@inproceedings{jones2023,
  title = {Another Paper},
  author = {Jones, Bob},
  year = {2023},
  doi = {10.5678/jones2023},
}

@comment{this is a comment and should be skipped}

@string{venue = {Journal of Great Things}}

@article{brown2025,
  title = {A Third Paper},
  author = {Brown, Carol},
  year = {2025},
  dagid = {f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b},
  retracts = {a3f5b8c9d2e1f4a5b6c7d8e9f0a1b2c3d4e5f6a7b},
}
""")
  check "parsed 3 entries", bib.len == 3
  check "comment skipped", not bib.anyIt(it.key == "this")

  let e1 = bib[0]
  check "entry type", e1.typ == "article"
  check "entry key", e1.key == "smith2024"
  check "title field", e1.bibTitle() == "A Great Paper"
  check "doi field", e1.bibDoi() == "10.1234/smith2024"
  check "dagid field", e1.bibDagId().len >= 40
  check "authors parsed", e1.bibAuthors() == @["Smith, John", "Doe, Jane"]

  let e2 = bib[1]
  check "no dagid", e2.bibDagId() == ""
  check "has doi", e2.bibDoi() == "10.5678/jones2023"

  let e3 = bib[2]
  check "retracts field", e3.bibRetracts() == e1.bibDagId()

  # round-trip: render back to BibTeX
  let rendered = e1.toBib()
  check "round-trip contains dagid", "dagid" in rendered
  let reparsed = parseBib(rendered)
  check "round-trip reparses", reparsed.len == 1
  check "round-trip dagid matches", reparsed[0].bibDagId() == e1.bibDagId()

# -- SHA-1 paper IDs ------------------------------------------------------------
block:
  let c1 = @[Citation(paperId: "abc123")]
  let c2 = @[Citation(paperId: "abc123")]
  let id1 = paperHash("Same Title", @["alice"], c1)
  let id2 = paperHash("Same Title", @["alice"], c2)
  check "deterministic hash", id1 == id2
  check "hash is 40 chars (SHA-1)", id1.len == 40
  let id3 = paperHash("Different Title", @["alice"], c1)
  check "different content = different hash", id1 != id3

# -- full lifecycle with BibTeX auto-extraction ----------------------------------
block:
  var l = newLedger(1000, @["alice@tox", "bob@tox", "carol@tox", "dave@tox"])

  # import a traditional paper by DOI (the genesis registry)
  l.importPaper("10.1234/foundational", "The Foundational Paper",
                @["elder@tox"])
  check "imported paper committed", l.papers.len == 1
  check "genesis registry has DOI", l.genesisDoi.hasKey("10.1234/foundational")

  # alice writes a paper citing the foundational paper via its DOI
  # (the .bib entry has a doi but no dagid -- the genesis registry resolves it)
  let bib1 = parseBib("""
@article{foundational,
  title = {The Foundational Paper},
  author = {Elder, Wise},
  year = {1990},
  doi = {10.1234/foundational},
}
""")
  let p1 = l.submitFromBib("Alice's New Results", @["alice@tox"], bib1)
  check "auto-extracted citation from DOI", p1.citations.len == 1
  check "citation resolves to genesis", p1.citations[0].doi == "10.1234/foundational"
  check "submitted", l.pending.len == 1

  # 3 reviewers accept
  for r in ["bob@tox", "carol@tox", "dave@tox"]:
    l.addReview(p1.id, Review(paperId: p1.id, reviewerId: r, verdict: rvAccept))
  var reg = l.pending[0]
  check "ready to commit", l.readyToCommit(reg)

  # commit: alice pays, the foundational paper's author earns
  let aliceBefore = l.balances["alice@tox"]
  let elderBefore = l.balances.getOrDefault("elder@tox", 0)
  l.commit(reg)
  check "committed", l.isCommitted(p1.id)
  check "alice paid", l.balances["alice@tox"] == aliceBefore - 10
  check "elder earned", l.balances["elder@tox"] == elderBefore + 7

  # generate the BibTeX entry for alice's paper (with its dagid)
  let bibOut = l.bibEntryFor(p1)
  check "generated entry has dagid", bibOut.bibDagId() == p1.id
  check "generated entry has title", bibOut.bibTitle() == "Alice's New Results"

  # bob cites alice's paper using the generated .bib entry
  let bib2 = parseBib(bibOut.toBib())
  check "bob's bib parses", bib2.len == 1
  check "bob's bib has alice's dagid", bib2[0].bibDagId() == p1.id

  let p2 = l.submitFromBib("Bob Follows Up", @["bob@tox"], bib2)
  check "bob cites alice via dagid", p2.citations.len == 1
  check "citation points to alice's paper", p2.citations[0].paperId == p1.id

  # 3 reviewers accept bob's paper
  for r in ["alice@tox", "carol@tox", "dave@tox"]:
    l.addReview(p2.id, Review(paperId: p2.id, reviewerId: r, verdict: rvAccept))
  reg = l.pending[0]
  let aliceMid = l.balances["alice@tox"]
  l.commit(reg)
  check "alice earned from bob's citation",
    l.balances["alice@tox"] == aliceMid + 8

  # the DAG: foundational <- p1 <- p2 (topological order)
  check "DAG has 3 papers", l.papers.len == 3
  check "topological order", l.order.len == 3

  # retraction via BibTeX
  let retBib = parseBib("""
@article{retraction1,
  title = {RETRACTION: Bob Follows Up},
  author = {Bob},
  year = {2025},
  retracts = {""" & p2.id & """},
}
""")
  let ret = l.retractionFromBib(retBib, @["bob@tox"])
  check "retraction created", ret.title.startsWith("RETRACTION:")
  check "retraction links to p2", ret.citations[0].paperId == p2.id

  # dangling edges: a .bib entry with no dagid and no genesis DOI is skipped
  let bib3 = parseBib("""
@article{unknown,
  title = {Some Random Paper},
  author = {Nobody},
  year = {2020},
}
""")
  let cites = l.citationsFromBib(bib3)
  check "dangling edge skipped", cites.len == 0

  # mixed: one DAG paper + one unknown
  let bib4 = parseBib("""
@article{known,
  title = {Alice's New Results},
  dagid = {""" & p1.id & """},
}

@article{unknown2,
  title = {Unknown Paper},
  year = {2020},
}
""")
  let mixedCites = l.citationsFromBib(bib4)
  check "mixed: only DAG-citable found", mixedCites.len == 1

# -- reviewer reward: the fee splits between cited authors and reviewers ----
block:
  var l = newLedger(1000, @["alice@tox", "bob@tox", "carol@tox", "dave@tox"])
  l.importPaper("10.1/genesis", "Genesis Paper", @["elder@tox"])
  let p1 = makePaper("Test Paper", @["alice@tox"],
                     @[Citation(paperId: l.genesisDoi["10.1/genesis"],
                                doi: "10.1/genesis")])
  l.submit(p1)
  for r in ["bob@tox", "carol@tox", "dave@tox"]:
    l.addReview(p1.id, Review(paperId: p1.id, reviewerId: r, verdict: rvAccept))
  var reg = l.pending[0]
  let aliceBefore = l.balances["alice@tox"]
  let bobBefore = l.balances["bob@tox"]
  let elderBefore = l.balances.getOrDefault("elder@tox", 0)
  l.commit(reg)
  # fee = 10; citedPortion = 7 (70%), reviewPortion = 3 (30%)
  # elder gets 7 (the only cited author)
  # bob, carol, dave each get 1 (3 split among 3 reviewers)
  check "alice paid full fee", l.balances["alice@tox"] == aliceBefore - 10
  check "elder earned cited portion", l.balances["elder@tox"] == elderBefore + 7
  check "bob earned reviewer reward", l.balances["bob@tox"] == bobBefore + 1

# -- faucet: new author bootstrap ----------------------------------------------
block:
  var l = newLedger(1000, @["alice@tox"])
  l.faucet("newbie@tox")
  check "faucet gives coins", l.balances["newbie@tox"] == faucetAmount
  try:
    l.faucet("newbie@tox")
    check "faucet is once-only", false
  except LedgerError:
    check "faucet is once-only", true

# -- anti-gaming: reviewer must have stake --------------------------------------
block:
  var l = newLedger(1000, @["alice@tox", "bob@tox"])
  l.importPaper("10.2/genesis", "G2", @["system"])
  let p = makePaper("Stake Test", @["alice@tox"],
                    @[Citation(paperId: l.genesisDoi["10.2/genesis"])])
  l.submit(p)
  # nobody@tox has no coins and no papers -- no stake
  try:
    l.addReview(p.id, Review(paperId: p.id, reviewerId: "nobody@tox", verdict: rvAccept))
    check "no-stake reviewer rejected", false
  except LedgerError:
    check "no-stake reviewer rejected", true
  # alice is the author -- can't review her own paper
  try:
    l.addReview(p.id, Review(paperId: p.id, reviewerId: "alice@tox", verdict: rvAccept))
    check "self-review rejected", false
  except LedgerError:
    check "self-review rejected", true
  # bob has coins (genesis) -- has stake
  l.addReview(p.id, Review(paperId: p.id, reviewerId: "bob@tox", verdict: rvAccept))
  check "staked reviewer accepted", true

if fails > 0:
  echo $fails, " FAILURES"
  quit 1
echo "all ok"

# -- blind copy: strips identifying sections ------------------------------------
block:
  let paper = """#+TITLE: A Great Paper
#+AUTHOR: Alice Smith, Bob Jones
#+EMAIL: alice@university.edu

* Introduction
We study the thing.

* Methods
We used the method.

* Funding
This work was funded by Grant #12345.

* Acknowledgments
Thanks to the lab.

* CRedit
Alice: Conceptualization. Bob: Writing.
"""
  let blind = blindCopy(paper)
  check "blind strips author", not blind.contains("Alice Smith")
  check "blind strips email", not blind.contains("alice@university.edu")
  check "blind strips funding", not blind.contains("Grant #12345")
  check "blind strips acknowledgments", not blind.contains("Thanks to the lab")
  check "blind strips credit", not blind.contains("Conceptualization")
  check "blind keeps title", blind.contains("A Great Paper")
  check "blind keeps methods", blind.contains("We used the method")

# -- reviewer suggestion: citation-graph proximity ------------------------------
block:
  var l = newLedger(1000, @["alice@tox", "bob@tox", "carol@tox", "dave@tox"])
  l.importPaper("10.1/genesis", "Genesis", @["system"])
  # alice's paper cites genesis
  let p1 = makePaper("P1", @["alice@tox"],
                     @[Citation(paperId: l.genesisDoi["10.1/genesis"])])
  l.submit(p1)
  for r in ["bob@tox", "carol@tox", "dave@tox"]:
    l.addReview(p1.id, Review(paperId: p1.id, reviewerId: r, verdict: rvAccept))
  var reg = l.pending[0]
  l.commit(reg)
  # bob's paper also cites genesis (co-citation with alice's)
  let p2 = makePaper("P2", @["bob@tox"],
                     @[Citation(paperId: l.genesisDoi["10.1/genesis"])])
  l.submit(p2)
  for r in ["alice@tox", "carol@tox", "dave@tox"]:
    l.addReview(p2.id, Review(paperId: p2.id, reviewerId: r, verdict: rvAccept))
  reg = l.pending[0]
  l.commit(reg)
  # carol's paper cites both p1 and p2 -- who should review it?
  let p3 = makePaper("P3", @["carol@tox"],
                     @[Citation(paperId: p1.id), Citation(paperId: p2.id)])
  let suggestions = l.suggestReviewers(p3)
  check "suggests reviewers", suggestions.len > 0
  # alice and bob are authors of cited papers (score 3 each)
  # dave is a co-citing author (score 1)
  var found = false
  for s in suggestions:
    if s.id == "alice@tox" and s.score >= 3: found = true
  check "alice suggested with high score", found
  # carol (the author) is not suggested
  for s in suggestions:
    check "author not suggested", s.id != "carol@tox"

# -- send-back: reviewer requests amendments -------------------------------------
block:
  var l = newLedger(1000, @["alice@tox", "bob@tox", "carol@tox", "dave@tox"])
  l.importPaper("10.2/genesis", "G", @["system"])
  let p = makePaper("Needs Work", @["alice@tox"],
                    @[Citation(paperId: l.genesisDoi["10.2/genesis"])])
  l.submit(p)
  # bob sends back for amendments
  l.addReview(p.id, Review(paperId: p.id, reviewerId: "bob@tox",
                           verdict: rvSendBack, comment: "fix the stats"))
  # carol accepts anyway
  l.addReview(p.id, Review(paperId: p.id, reviewerId: "carol@tox",
                           verdict: rvAccept))
  # dave accepts
  l.addReview(p.id, Review(paperId: p.id, reviewerId: "dave@tox",
                           verdict: rvAccept))
  # 2 accepts (bob sent back, doesn't count) -- not enough
  var reg = l.pending[0]
  check "send-back doesn't count as accept", not l.readyToCommit(reg)
  check "accept count is 2", reg.acceptCount() == 2

if fails > 0:
  echo $fails, " FAILURES"
  quit 1
echo "all ok"
