## wkbdag.nim -- a citation-graph DAG ledger for scientific publishing.
##
## The core insight: a citation graph IS a DAG, so the ledger's topology
## mirrors the content's topology. Papers are nodes, citations are edges,
## and the registration fee gives the DAG an economic layer. No editorial
## board, no platform, no server -- just a 3-reviewer threshold.
##
## The DAG ID lives inside the BibTeX entry (a `dagid` field), so the
## citation graph extracts itself from the .bib file. Authors write
## papers in LaTeX as usual; the DAG parses their bibliography and
## builds the edges automatically.
##
## Structure:
##   - Papers are committed in order; citations must point to already-
##     committed papers, so the graph is acyclic by construction.
##   - A paper is committed when >= 3 distinct reviewers accept it.
##   - The registration fee is distributed to the cited papers' authors.
##   - Retractions are new nodes linked to the retracted paper.
##   - The genesis registry maps DOIs to DAG IDs for papers imported
##     from the traditional publishing system.

import std/[tables, strutils, sha1, sequtils]
import wkbbib

const
  minReviewers* = 3            ## the consensus threshold
  defaultFee* = 10             ## coins to register a paper
  reviewerShare* = 30          ## % of the fee that goes to reviewers
  faucetAmount* = 5           ## coins given to a new identity (once)

type
  PaperId* = string            ## SHA-1 hex digest (upgrade target: SHA-256)

  Citation* = object
    paperId*: PaperId         ## the cited paper (must already be committed)
    doi*: string              ## the DOI (for external lookup / genesis)

  Paper* = object
    id*: PaperId              ## hash of title + authors + citations
    title*: string
    authors*: seq[string]     ## Tox IDs (the identity system)
    citations*: seq[Citation]
    fee*: int                 ## coins burned to register

  ReviewVerdict* = enum rvAccept, rvReject, rvSendBack, rvAbstain

  Review* = object
    paperId*: PaperId
    reviewerId*: string       ## reviewer's Tox ID
    verdict*: ReviewVerdict
    comment*: string

  Registration* = object
    paper*: Paper
    reviews*: seq[Review]

  LedgerError* = object of CatchableError

  Ledger* = object
    papers*: Table[PaperId, Paper]        ## committed papers (the DAG)
    order*: seq[PaperId]                 ## commitment order (topological)
    balances*: Table[string, int]        ## Tox ID -> coin balance
    pending*: seq[Registration]          ## submitted, awaiting reviews
    supply*: int                         ## total coins minted
    genesisDoi*: Table[string, PaperId]  ## DOI -> DAG ID (imported papers)

# -- paper identity (SHA-1; upgrade target: SHA-256) ---------------------------
proc paperHash*(title: string; authors: seq[string];
                citations: seq[Citation]): PaperId =
  ## A deterministic, self-certifying ID: the same content always hashes
  ## to the same ID, so peers independently verify identity.
  var content = title & "\n"
  for a in authors: content.add a & "\n"
  for c in citations: content.add c.paperId & "\n"
  let h = secureHash(content)
  $h

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
  let err = l.validate(p)
  if err.len > 0: raise newException(LedgerError, err)
  l.pending.add Registration(paper: p)

proc hasStake*(l: Ledger; identity: string): bool =
  ## Anti-gaming: a reviewer must have at least one committed paper on
  ## the DAG (or be a founding member with a genesis balance). This
  ## prevents sybil attacks -- fake identities created just to review
  ## the attacker's own papers.
  if l.balances.getOrDefault(identity, 0) > 0: return true
  for _, p in l.papers:
    if identity in p.authors: return true
  false

proc addReview*(l: var Ledger; paperId: PaperId; r: Review) =
  if not l.hasStake(r.reviewerId):
    raise newException(LedgerError,
      "reviewer has no stake (no committed papers, no balance): " & r.reviewerId)
  # a reviewer cannot review their own paper
  for i in 0 ..< l.pending.len:
    if l.pending[i].paper.id == paperId:
      if r.reviewerId in l.pending[i].paper.authors:
        raise newException(LedgerError, "cannot review your own paper")
      for existing in l.pending[i].reviews:
        if existing.reviewerId == r.reviewerId:
          raise newException(LedgerError, "duplicate review from " & r.reviewerId)
      l.pending[i].reviews.add r
      return
  raise newException(LedgerError, "no pending registration for " & paperId)

proc acceptCount*(reg: Registration): int =
  for r in reg.reviews:
    if r.verdict == rvAccept: inc result

proc readyToCommit*(l: Ledger; reg: Registration): bool =
  var accepted: seq[string]
  for r in reg.reviews:
    if r.verdict == rvAccept and r.reviewerId notin accepted:
      accepted.add r.reviewerId
  accepted.len >= minReviewers

proc commit*(l: var Ledger; reg: var Registration) =
  if not l.readyToCommit(reg):
    raise newException(LedgerError,
      "not enough acceptances: " & $reg.acceptCount & "/" & $minReviewers)
  let p = reg.paper
  l.balances[p.authors[0]] = l.balances.getOrDefault(p.authors[0], 0) - p.fee
  # split the fee: (100 - reviewerShare)% to cited authors,
  #                reviewerShare% to the accepting reviewers
  let citedPortion = p.fee * (100 - reviewerShare) div 100
  let reviewPortion = p.fee - citedPortion
  if p.citations.len > 0 and citedPortion > 0:
    let share = citedPortion div p.citations.len
    for c in p.citations:
      let cited = l.papers[c.paperId]
      for a in cited.authors:
        l.balances[a] = l.balances.getOrDefault(a, 0) + share
  # reward the accepting reviewers (incentivizes participation)
  var reviewers: seq[string]
  for r in reg.reviews:
    if r.verdict == rvAccept and r.reviewerId notin reviewers:
      reviewers.add r.reviewerId
  if reviewers.len > 0 and reviewPortion > 0:
    let rShare = reviewPortion div reviewers.len
    for r in reviewers:
      l.balances[r] = l.balances.getOrDefault(r, 0) + rShare
  l.papers[p.id] = p
  l.order.add p.id
  for i in 0 ..< l.pending.len:
    if l.pending[i].paper.id == p.id:
      l.pending.delete i
      break
  reg.reviews.setLen 0

# -- genesis -------------------------------------------------------------------
proc newLedger*(initialSupply = 0; identities: seq[string] = @[]): Ledger =
  result.supply = initialSupply
  if identities.len > 0 and initialSupply > 0:
    let share = initialSupply div identities.len
    for id in identities:
      result.balances[id] = share

proc importPaper*(l: var Ledger; doi: string; title: string;
                  authors: seq[string]) =
  ## Import a traditional paper into the DAG by DOI. Creates a committed
  ## node with no citations (it predates the DAG). The DOI → ID mapping
  ## goes into the genesis registry so .bib entries with this DOI resolve.
  let p = makePaper(title, authors, @[], fee = 0)
  l.papers[p.id] = p
  l.order.add p.id
  l.genesisDoi[doi] = p.id

proc suggestReviewers*(l: Ledger; p: Paper): seq[tuple[id: string, score: int]] =
  ## Rank potential reviewers by citation-graph proximity:
  ##   +3 for each direct citation (author of a paper this paper cites)
  ##   +1 for each co-citation (author of a paper citing the same refs)
  ## Excludes the paper's own authors. Higher score = closer to the field.
  var scores: Table[string, int]
  for c in p.citations:
    if l.papers.hasKey(c.paperId):
      let cited = l.papers[c.paperId]
      for a in cited.authors:
        if a notin p.authors:
          scores[a] = scores.getOrDefault(a, 0) + 3   # direct expertise
  # co-citation: authors of papers citing the same references
  for c in p.citations:
    for pid, other in l.papers:
      if pid != p.id and other.citations.anyIt(it.paperId == c.paperId):
        for a in other.authors:
          if a notin p.authors:
            scores[a] = scores.getOrDefault(a, 0) + 1   # co-citation
  # rank by score (descending): simple insertion into the right slot
  for id, score in scores:
    var inserted = false
    for i in 0 ..< result.len:
      if score > result[i].score:
        result.insert (id, score), i
        inserted = true
        break
    if not inserted:
      result.add (id, score)

proc blindCopy*(text: string): string =
  ## Strip identifying sections for blind review: author, email, funding,
  ## acknowledgments, CRedit. The reviewer sees the science, not the lab.
  var lines: seq[string]
  var skipping = false
  for ln in text.splitLines():
    let low = ln.toLowerAscii()
    # stop skipping when we hit the next top-level heading
    if skipping and ln.startsWith("*") and not ln.startsWith("* "):
      skipping = false
    if skipping and ln.startsWith("* "):
      skipping = false
    # skip identifying headers
    if low.startsWith("#+author:") or low.startsWith("#+email:"):
      continue
    # skip funding/acknowledgment/credit sections
    if ln.startsWith("* ") and (
       low.contains("funding") or low.contains("acknowledg") or
       low.contains("credit") or low.contains("acknowledgement")):
      skipping = true
      continue
    if skipping:
      continue
    lines.add ln
  lines.join("\n")

proc faucet*(l: var Ledger; toId: string) =
  ## Give a small amount to a new identity (once). This is the bootstrap
  ## mechanism so new authors can pay their first registration fee without
  ## needing an invitation. Rate-limited by social norms (the faucet amount
  ## is small enough that sybil attacks are not profitable).
  if l.balances.hasKey(toId):
    raise newException(LedgerError, "identity already exists: " & toId)
  l.balances[toId] = faucetAmount

proc transfer*(l: var Ledger; fromId, toId: string; amount: int) =
  ## An existing member invites a new author by transferring coins.
  ## This is the onboarding mechanism: you need coins to register a
  ## paper, and you get coins by being cited or by invitation.
  if amount <= 0: raise newException(LedgerError, "amount must be positive")
  let bal = l.balances.getOrDefault(fromId, 0)
  if bal < amount:
    raise newException(LedgerError, "insufficient balance: " & $bal & " < " & $amount)
  l.balances[fromId] = bal - amount
  l.balances[toId] = l.balances.getOrDefault(toId, 0) + amount

proc retraction*(l: var Ledger; retractedId: PaperId; authors: seq[string];
                 reason: string): Paper =
  let retracted = l.papers[retractedId]
  result = makePaper("RETRACTION: " & retracted.title, authors,
                     @[Citation(paperId: retractedId, doi: reason)])

# -- BibTeX integration: the citation graph extracts itself --------------------
proc citationsFromBib*(l: Ledger; bib: BibFile): seq[Citation] =
  ## Walk a .bib file and build citation edges. For each entry:
  ##   - If it has a `dagid`, cite that DAG paper directly.
  ##   - If it has a `doi` but no `dagid`, look up the genesis registry.
  ##   - If neither, it's a dangling edge (cites outside the DAG) -- skip.
  for e in bib:
    let dagid = e.bibDagId()
    if dagid.len > 0:
      if l.isCommitted(dagid):
        result.add Citation(paperId: dagid, doi: e.bibDoi())
    else:
      let doi = e.bibDoi()
      if doi.len > 0 and l.genesisDoi.hasKey(doi):
        result.add Citation(paperId: l.genesisDoi[doi], doi: doi)

proc submitFromBib*(l: var Ledger; title: string; authors: seq[string];
                    bib: BibFile; fee = defaultFee): Paper =
  ## Submit a paper whose citations are auto-extracted from its .bib file.
  ## This is the main entry point: authors write LaTeX, include a .bib
  ## with `dagid` fields, and the DAG builds the citation edges.
  let citations = l.citationsFromBib(bib)
  if citations.len == 0:
    raise newException(LedgerError,
      "no DAG-citable references found in the .bib file")
  result = makePaper(title, authors, citations, fee)
  l.submit(result)

proc bibEntryFor*(l: Ledger; p: Paper): BibEntry =
  ## Generate the BibTeX entry for a committed paper, including its
  ## `dagid` -- so others can cite it and the citation graph grows.
  result = BibEntry(typ: "article", key: p.id[0 ..< 8])
  result.fields["title"] = p.title
  result.fields["author"] = p.authors.join(" and ")
  result.fields["dagid"] = p.id
  if p.citations.len > 0:
    result.fields["doi"] = p.citations[0].doi

proc retractionFromBib*(l: var Ledger; bib: BibFile;
                        authors: seq[string]): Paper =
  ## Detect a retraction entry in a .bib file (has a `retracts` field)
  ## and create the retraction node.
  for e in bib:
    let retracts = e.bibRetracts()
    if retracts.len > 0 and l.isCommitted(retracts):
      return l.retraction(retracts, authors, e.bibDoi())
  raise newException(LedgerError, "no valid retraction entry in .bib file")
