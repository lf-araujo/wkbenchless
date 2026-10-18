## wkbdag.nim -- a citation-graph DAG ledger for scientific publishing.
##
## The core insight: a citation graph IS a DAG, so the ledger's topology
## mirrors the content's topology. Papers are nodes, citations are edges,
## and the registration fee gives the DAG an economic layer. No editorial
## board, no platform, no server -- just a 3-reviewer threshold.
##
## Structure:
##   - Papers are committed in order; citations must point to already-
##     committed papers, so the graph is acyclic by construction.
##   - A paper is committed when >= 3 distinct reviewers (each with a
##     registered identity) accept it. Reviews travel over Tox (the
##     editor's collab channel), not through this module.
##   - The registration fee is distributed to the cited papers' authors,
##     creating a self-reinforcing citation economy.
##   - Retractions are new nodes linked to the retracted paper (the DAG
##     is append-only; nothing is ever mutated or removed).
##
## STATUS: investigation -- data model + validation + tests. The network
## layer (Tox transport, peer sync) and the economic model (coin supply,
## inflation, anti-gaming) are the next phases.

import std/[tables, strutils, hashes, sequtils]

const
  minReviewers* = 3            ## the consensus threshold
  defaultFee* = 10             ## coins to register a paper

type
  PaperId* = string            ## SHA-256 hex digest of the paper content

  Citation* = object
    paperId*: PaperId         ## the cited paper (must already be committed)
    doi*: string              ## optional: the DOI for external lookup

  Paper* = object
    id*: PaperId              ## hash of title + authors + citations
    title*: string
    authors*: seq[string]     ## Tox IDs (the identity system)
    citations*: seq[Citation]
    fee*: int                 ## coins burned to register

  Review* = object
    paperId*: PaperId         ## which paper
    reviewerId*: string       ## reviewer's Tox ID
    accept*: bool
    comment*: string

  Registration* = object
    paper*: Paper
    reviews*: seq[Review]

  LedgerError* = object of CatchableError

  Ledger* = object
    papers*: Table[PaperId, Paper]        ## committed papers (the DAG)
    order*: seq[PaperId]                 ## commitment order (the topological sort)
    balances*: Table[string, int]        ## Tox ID -> coin balance
    pending*: seq[Registration]          ## submitted, awaiting reviews
    supply*: int                         ## total coins minted so far

# -- paper identity -----------------------------------------------------------
proc paperHash*(title: string; authors: seq[string];
                citations: seq[Citation]): PaperId =
  ## A deterministic ID: the same paper content always hashes to the same
  ## ID, so peers that see the same paper agree on its identity.
  var h: Hash = 0
  h = h !& title.hash
  for a in authors: h = h !& a.hash
  for c in citations:
    h = h !& c.paperId.hash
    h = h !& c.doi.hash
  result = $h

proc makePaper*(title: string; authors: seq[string];
                citations: seq[Citation];
                fee = defaultFee): Paper =
  Paper(id: paperHash(title, authors, citations),
        title: title, authors: authors, citations: citations, fee: fee)

# -- validation ---------------------------------------------------------------
proc validate*(l: Ledger; p: Paper): string =
  ## Check a paper against the DAG. Returns "" if valid, else an error.
  if p.title.len == 0: return "empty title"
  if p.authors.len == 0: return "no authors"
  if p.citations.len == 0: return "no citations (a paper must cite something)"
  if l.papers.hasKey(p.id): return "paper already registered"
  for c in p.citations:
    if not l.papers.hasKey(c.paperId):
      return "cites unregistered paper: " & c.paperId
  for a in p.authors:
    if not l.balances.hasKey(a):
      return "author has no identity on the ledger: " & a
  if l.balances.getOrDefault(p.authors[0], 0) < p.fee:
    return "insufficient coins: need " & $p.fee

proc isCommitted*(l: Ledger; id: PaperId): bool = l.papers.hasKey(id)

proc citedBy*(l: Ledger; id: PaperId): seq[PaperId] =
  ## Papers that cite this one (the reverse edges -- the "impact" set).
  for pid, p in l.papers:
    if p.citations.anyIt(it.paperId == id):
      result.add pid

# -- registration lifecycle ---------------------------------------------------
proc submit*(l: var Ledger; p: Paper) =
  ## Submit a paper for review. The fee is held (not yet distributed).
  let err = l.validate(p)
  if err.len > 0: raise newException(LedgerError, err)
  l.pending.add Registration(paper: p)

proc addReview*(l: var Ledger; paperId: PaperId; r: Review) =
  ## Attach a review to a pending registration.
  for i in 0 ..< l.pending.len:
    if l.pending[i].paper.id == paperId:
      # a reviewer can only review once
      for existing in l.pending[i].reviews:
        if existing.reviewerId == r.reviewerId:
          raise newException(LedgerError, "duplicate review from " & r.reviewerId)
      l.pending[i].reviews.add r
      return
  raise newException(LedgerError, "no pending registration for " & paperId)

proc acceptCount*(reg: Registration): int =
  for r in reg.reviews:
    if r.accept: inc result

proc readyToCommit*(l: Ledger; reg: Registration): bool =
  ## True when >= `minReviewers` distinct reviewers have accepted.
  var accepted: seq[string]
  for r in reg.reviews:
    if r.accept and r.reviewerId notin accepted:
      accepted.add r.reviewerId
  accepted.len >= minReviewers

proc commit*(l: var Ledger; reg: var Registration) =
  ## Commit a registration to the DAG. Distributes the fee to the cited
  ## papers' authors. The paper becomes citable by others.
  if not l.readyToCommit(reg):
    raise newException(LedgerError,
      "not enough acceptances: " & $reg.acceptCount & "/" & $minReviewers)
  let p = reg.paper
  # burn the fee from the first author
  l.balances[p.authors[0]] = l.balances.getOrDefault(p.authors[0], 0) - p.fee
  # distribute to cited papers' authors (split evenly)
  if p.citations.len > 0:
    let share = p.fee div p.citations.len
    for c in p.citations:
      let cited = l.papers[c.paperId]
      for a in cited.authors:
        l.balances[a] = l.balances.getOrDefault(a, 0) + share
  # commit
  l.papers[p.id] = p
  l.order.add p.id
  # remove from pending
  for i in 0 ..< l.pending.len:
    if l.pending[i].paper.id == p.id:
      l.pending.delete i
      break
  reg.reviews.setLen 0   # consumed

# -- genesis -------------------------------------------------------------------
proc newLedger*(initialSupply = 0; identities: seq[string] = @[]): Ledger =
  ## Create a fresh ledger. `identities` are the founding members who
  ## receive the initial coin supply (split evenly).
  result.supply = initialSupply
  if identities.len > 0 and initialSupply > 0:
    let share = initialSupply div identities.len
    for id in identities:
      result.balances[id] = share

proc retraction*(l: var Ledger; retractedId: PaperId; authors: seq[string];
                 reason: string): Paper =
  ## A retraction is a new node linked to the retracted paper. The DAG
  ## is append-only -- nothing is removed, but the retraction marks the
  ## original as no longer citable in good faith.
  let retracted = l.papers[retractedId]
  result = makePaper("RETRACTION: " & retracted.title, authors,
                     @[Citation(paperId: retractedId, doi: reason)])
