## dag_ledger.nim -- the citation-graph DAG ledger as editor verbs.
##
## Papers are org files (org-babel, not LaTeX). The title comes from
## #+TITLE:, authors from #+AUTHOR:, and citations from [[cite:key]]
## links resolved against the ledger's genesis registry or a .bib file.
## The DAG ID lives in a #+DAG_ID: header once committed.
##
## Ctl verbs:
##   dag-init <supply> <id1,id2,...>   -- create a ledger with founding members
##   dag-import <doi> <title>          -- import a traditional paper by DOI
##   dag-submit                       -- submit the current org buffer as a paper
##   dag-review <paperId> <accept|reject>  -- review a pending paper
##   dag-status                        -- ledger summary
##   dag-pending                       -- list pending registrations
##   dag-citedby <paperId>             -- who cites this paper
##   dag-bib <paperId>                 -- generate the BibTeX entry
##   dag-sync                          -- request the full ledger from the host
##
## Review channel: DAG messages travel over the collab TCP session
## (tox_collab.nim) as new message types. The host relays them like
## any other message.

import wkbcore
import wkbdag
import wkbbib
import std/[strutils, tables, json, sequtils]

var ledger*: Ledger
var dagReady* = false
var gDagSend*: proc(j: JsonNode) = nil   ## set by tox_collab: send a DAG message to peers

# -- org header extraction -----------------------------------------------------
proc orgHeader*(text: string; name: string): string =
  ## Extract a #+NAME: value from the first ~30 lines of an org file.
  for ln in text.splitLines():
    if ln.len > 0 and ln[0] != '#': break
    if ln.toLowerAscii().startsWith("#+" & name.toLowerAscii() & ":"):
      return ln[name.len + 3 ..^ 1].strip()
  ""

proc orgAuthors*(text: string): seq[string] =
  ## Parse #+AUTHOR: "Alice Smith, Bob Jones" or "Alice Smith and Bob Jones".
  let raw = text.orgHeader("AUTHOR")
  if raw.len == 0: return
  for a in raw.split(","):
    for b in a.split(" and "):
      let c = b.strip
      if c.len > 0: result.add c

proc orgCiteKeys*(text: string): seq[string] =
  ## Extract all [[cite:key]] links from the buffer text.
  var i = 0
  while true:
    let start = text.find("[[cite:", i)
    if start < 0: break
    let close = text.find("]]", start)
    if close < 0: break
    let key = text[start + 7 ..< close].strip
    if key.len > 0 and key notin result: result.add key
    i = close + 2

# -- paper extraction from the current buffer ----------------------------------
proc extractPaper*(app: App): tuple[title: string; authors: seq[string];
                                     citeKeys: seq[string]] =
  let text = app.ed.fullText()
  result.title = text.orgHeader("TITLE")
  result.authors = text.orgAuthors()
  result.citeKeys = text.orgCiteKeys()

proc resolveCitations*(l: Ledger; citeKeys: seq[string]): seq[Citation] =
  ## Resolve cite keys to DAG citations. Supports:
  ##   [[cite:dag:<paperId>]]  -- direct DAG citation
  ##   [[cite:<doi>]]          -- looked up in the genesis registry
  ##   [[cite:<bibkey>]]       -- looked up by title match in committed papers
  for key in citeKeys:
    if key.toLowerAscii().startsWith("dag:"):
      let pid = key[4 ..^ 1].strip
      if l.isCommitted(pid):
        result.add Citation(paperId: pid)
    elif l.genesisDoi.hasKey(key):
      result.add Citation(paperId: l.genesisDoi[key], doi: key)
    else:
      # try title match against committed papers
      for pid, p in l.papers:
        if p.title.toLowerAscii() == key.toLowerAscii():
          result.add Citation(paperId: pid)
          break

# -- ctl verbs ------------------------------------------------------------------
proc extend*(app: var App) =
  registerCtlVerb("dag-init", "create a ledger: <supply> <id1,id2,...>",
    proc(a: var App; args: seq[string]; body: string): string =
      if args.len < 2: return "usage: dag-init <supply> <id1,id2,...>"
      let supply = try: parseInt(args[0]) except: 1000
      let ids = args[1].split(",").mapIt(it.strip)
      ledger = newLedger(supply, ids)
      dagReady = true
      a.msg = "dag: ledger created, supply=" & $supply & ", " & $ids.len & " members"
      a.msg)

  registerCtlVerb("dag-import", "import a paper by DOI: <doi> <title>",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger (run dag-init first)"
      if args.len < 2: return "usage: dag-import <doi> <title>"
      let authors = if body.len > 0: body.splitLines().filterIt(it.len > 0) else: @["imported"]
      ledger.importPaper(args[0], args[1].join(" "), authors)
      a.msg = "dag: imported '" & args[1] & "' (DOI: " & args[0] & ")"
      a.msg)

  registerCtlVerb("dag-submit", "submit the current org buffer as a paper",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger (run dag-init first)"
      let (title, authors, citeKeys) = a.extractPaper()
      if title.len == 0: return "dag: no #+TITLE: header"
      if authors.len == 0: return "dag: no #+AUTHOR: header"
      let citations = ledger.resolveCitations(citeKeys)
      if citations.len == 0:
        return "dag: no citable references found (" & $citeKeys.len &
               " cite keys, 0 resolvable -- dag-import first?)"
      try:
        let p = makePaper(title, authors, citations)
        ledger.submit(p)
        a.msg = "dag: submitted '" & title & "' (" & $citations.len &
                " citations) -- id=" & p.id[0 ..< 8] &
                " -- awaiting " & $minReviewers & " reviews"
        result = p.id
      except LedgerError as e:
        result = "dag: " & e.msg)

  registerCtlVerb("dag-review", "review: <paperId> <accept|reject|sendback|abstain> <reviewerId>",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if args.len < 3:
        return "usage: dag-review <paperId> <accept|reject|sendback|abstain> <reviewerId>"
      var pid = args[0]
      let verdict = case args[1].toLowerAscii()
        of "accept": rvAccept
        of "reject": rvReject
        of "sendback": rvSendBack
        of "abstain": rvAbstain
        else: rvAccept
      let reviewer = args[2]
      # accept a prefix: expand short IDs against pending papers
      if pid.len < 40:
        for reg in ledger.pending:
          if reg.paper.id.startsWith(pid):
            pid = reg.paper.id; break
      try:
        ledger.addReview(pid, Review(paperId: pid, reviewerId: reviewer,
                                     verdict: verdict, comment: ""))
        # broadcast the review to collab peers
        if gDagSend != nil:
          gDagSend(%*{"t": "dag-review", "paperId": pid,
                      "reviewer": reviewer, "verdict": $verdict})
        # check if ready to commit
        for i in 0 ..< ledger.pending.len:
          if ledger.pending[i].paper.id == pid:
            if ledger.readyToCommit(ledger.pending[i]):
              var reg = ledger.pending[i]
              ledger.commit(reg)
              a.msg = "dag: committed '" & reg.paper.title & "'"
              # inject the #+DAG_ID: header into the org file
              let text = a.ed.fullText()
              if text.orgHeader("DAG_ID").len == 0:
                a.ed.gotoPos(0)
                a.ed.insertText("#+DAG_ID: " & reg.paper.id & "\n")
              result = "committed"
            elif verdict == rvSendBack:
              a.msg = "dag: sent back for amendments"
              result = a.msg
            else:
              a.msg = "dag: review recorded (" & $ledger.pending[i].acceptCount &
                      "/" & $minReviewers & " accepts)"
              result = a.msg
            return
        result = "dag: review recorded"
      except LedgerError as e:
        result = "dag: " & e.msg)

  registerCtlVerb("dag-status", "ledger summary",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      var lines: seq[string]
      lines.add "papers: " & $ledger.papers.len
      lines.add "pending: " & $ledger.pending.len
      lines.add "supply: " & $ledger.supply
      lines.add "balances:"
      for id, bal in ledger.balances:
        lines.add "  " & id & ": " & $bal
      lines.join("\n"))

  registerCtlVerb("dag-pending", "list pending registrations",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if ledger.pending.len == 0: return "dag: no pending papers"
      var lines: seq[string]
      for reg in ledger.pending:
        lines.add reg.paper.id[0 ..< 8] & "  '" & reg.paper.title &
                 "'  (" & $reg.acceptCount & "/" & $minReviewers & " accepts)"
      lines.join("\n"))

  registerCtlVerb("dag-citedby", "who cites this paper: <paperId>",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if args.len < 1: return "usage: dag-citedby <paperId>"
      let cites = ledger.citedBy(args[0])
      if cites.len == 0: return "dag: nobody cites this"
      var lines: seq[string]
      for c in cites:
        let p = ledger.papers[c]
        lines.add p.id[0 ..< 8] & "  '" & p.title & "'"
      lines.join("\n"))

  registerCtlVerb("dag-bib", "generate BibTeX for a paper: <paperId>",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if args.len < 1: return "usage: dag-bib <paperId>"
      if not ledger.isCommitted(args[0]): return "dag: paper not found"
      let p = ledger.papers[args[0]]
      let e = ledger.bibEntryFor(p)
      result = e.toBib())

  registerCtlVerb("dag-suggest", "suggest reviewers for a pending paper: <paperId>",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if args.len < 1: return "usage: dag-suggest <paperId>"
      var pid = args[0]
      if pid.len < 40:
        for reg in ledger.pending:
          if reg.paper.id.startsWith(pid):
            pid = reg.paper.id; break
      for reg in ledger.pending:
        if reg.paper.id == pid:
          let suggestions = ledger.suggestReviewers(reg.paper)
          if suggestions.len == 0: return "dag: no reviewers found in field"
          var lines: seq[string]
          for s in suggestions:
            lines.add s.id & "  (score: " & $s.score & ")"
          return lines.join("\n")
      return "dag: paper not pending")

  registerCtlVerb("dag-blind", "show the blind review copy of a pending paper",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if args.len < 1: return "usage: dag-blind <paperId>"
      var pid = args[0]
      if pid.len < 40:
        for reg in ledger.pending:
          if reg.paper.id.startsWith(pid):
            pid = reg.paper.id; break
      for reg in ledger.pending:
        if reg.paper.id == pid:
          return "dag: blind copy is " & $blindCopy(a.ed.fullText()).len &
                 " chars (original: " & $a.ed.fullText().len & ")"
      return "dag: paper not pending")

  registerCtlVerb("dag-faucet", "bootstrap a new identity: <toId>",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if args.len < 1: return "usage: dag-faucet <toId>"
      try:
        ledger.faucet(args[0])
        a.msg = "dag: faucet gave " & $faucetAmount & " coins to " & args[0]
        result = a.msg
      except LedgerError as e:
        result = "dag: " & e.msg)

  registerCtlVerb("dag-transfer", "invite a new author: <from> <to> <amount>",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      if args.len < 3: return "usage: dag-transfer <from> <to> <amount>"
      let amount = try: parseInt(args[2]) except: 0
      try:
        ledger.transfer(args[0], args[1], amount)
        a.msg = "dag: transferred " & $amount & " from " & args[0] & " to " & args[1]
        result = a.msg
      except LedgerError as e:
        result = "dag: " & e.msg)

  registerCtlVerb("dag-sync", "request the full ledger from the collab host",
    proc(a: var App; args: seq[string]; body: string): string =
      if not dagReady: return "dag: no ledger"
      # TODO: send a dag-sync-request over the collab channel
      "dag: sync not yet implemented (next phase)")

  # commands for interactive use
  defcommand("dag-submit", "Submit this buffer as a paper to the DAG",
             proc(a: var App) =
    if not dagReady:
      a.msg = "dag: no ledger (wkbctl dag-init first)"; return
    let (title, authors, citeKeys) = a.extractPaper()
    if title.len == 0:
      a.msg = "dag: no #+TITLE: header"; return
    if authors.len == 0:
      a.msg = "dag: no #+AUTHOR: header"; return
    let citations = ledger.resolveCitations(citeKeys)
    if citations.len == 0:
      a.msg = "dag: no citable references (" & $citeKeys.len &
              " keys, 0 resolvable)"; return
    try:
      let p = makePaper(title, authors, citations)
      ledger.submit(p)
      a.msg = "dag: submitted '" & title & "' -- " &
              $citations.len & " citations, id=" & p.id[0 ..< 8]
    except LedgerError as e:
      a.msg = "dag: " & e.msg)
  defcommand("dag-status", "Show the DAG ledger status",
             proc(a: var App) =
    a.msg = "dag: " & $ledger.papers.len & " papers, " &
            $ledger.pending.len & " pending")
