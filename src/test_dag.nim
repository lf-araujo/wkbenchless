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
    l.addReview(p1.id, Review(paperId: p1.id, reviewerId: r, accept: true))
  var reg = l.pending[0]
  check "ready to commit", l.readyToCommit(reg)

  # commit: alice pays, the foundational paper's author earns
  let aliceBefore = l.balances["alice@tox"]
  let elderBefore = l.balances.getOrDefault("elder@tox", 0)
  l.commit(reg)
  check "committed", l.isCommitted(p1.id)
  check "alice paid", l.balances["alice@tox"] == aliceBefore - 10
  check "elder earned", l.balances["elder@tox"] == elderBefore + 10

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
    l.addReview(p2.id, Review(paperId: p2.id, reviewerId: r, accept: true))
  reg = l.pending[0]
  let aliceMid = l.balances["alice@tox"]
  l.commit(reg)
  check "alice earned from bob's citation",
    l.balances["alice@tox"] == aliceMid + 10

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

if fails > 0:
  echo $fails, " FAILURES"
  quit 1
echo "all ok"
