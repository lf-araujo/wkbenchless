## The three-way divergence renderer (offline collab reconnects) and the
## CriticMarkup author-tag fix it depends on.
##   nim c -r --hints:off src/test_collab_diverge.nim

import std/strutils
import wkbcore

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

# -- applyCriticMarkup strips the [Author] tag from the kept side -------------
block author_tags:
  check "accept strips the insertion's author tag",
    applyCriticMarkup("{++[Elman, Jeremy]text++}", true) == "text"
  check "reject strips the deletion's author tag",
    applyCriticMarkup("{--[lf-araujo]text--}", false) == "text"
  check "accept strips the substitution's new-side tag",
    applyCriticMarkup("{~~[a]old~>[b]new~~}", true) == "new"
  check "reject strips the substitution's old-side tag",
    applyCriticMarkup("{~~[a]old~>[b]new~~}", false) == "old"
  check "a bracket without a close is not an author tag",
    applyCriticMarkup("{++[not a tag, no close++}", true) ==
      "[not a tag, no close"

# -- comments: the editor's accept/reject-all keeps them, the merge drops them --
block comments:
  check "accept-all keeps comments when asked",
    applyCriticMarkup("a{>>[Carol] fix this<<}b", true, keepComments = true) ==
      "a{>>[Carol] fix this<<}b"
  check "reject-all keeps comments when asked",
    applyCriticMarkup("a{>>[Carol] fix this<<}b", false, keepComments = true) ==
      "a{>>[Carol] fix this<<}b"
  check "the merge fingerprint still drops them",
    applyCriticMarkup("a{>>[Carol] fix this<<}b", true) == "ab"

# -- no divergence: unchanged text passes through plain ------------------------
block no_divergence:
  let base = "alpha\nbeta\ngamma\n"
  check "nothing changed anywhere -> plain base",
    divergeMarkup(base, base, base, 2, 1) == base

# -- one-sided changes get marked (the other side reviews them) ---------------
block one_sided:
  let base = "alpha\nbeta\ngamma\n"
  let mine = "alpha\nBETA\ngamma\n"
  let theirs = base
  check "only mine changed -> my substitution marked",
    divergeMarkup(base, mine, theirs, 2, 1) ==
      "alpha\n{--[s2]beta\n--}{++[s2]BETA\n++}gamma\n"
  check "only theirs changed -> their substitution marked",
    divergeMarkup(base, theirs, mine, 2, 1) ==
      "alpha\n{--[s1]beta\n--}{++[s1]BETA\n++}gamma\n"

# -- disjoint changes: both marked, context plain ------------------------------
block disjoint:
  let base = "one\ntwo\nthree\nfour\n"
  let mine = "ONE\ntwo\nthree\nfour\n"          # line 1 rewritten
  let theirs = "one\ntwo\nthree\nfour\nFIVE\n"   # line 5 appended
  check "disjoint edits both appear as marked regions",
    divergeMarkup(base, mine, theirs, 2, 1) ==
      "{--[s2]one\n--}{++[s2]ONE\n++}two\nthree\nfour\n{++[s1]FIVE\n++}"

# -- consensus: both sides made the same change -> plain -----------------------
block consensus:
  let base = "alpha\nbeta\n"
  let same = "alpha\nBETA\n"
  check "identical edits are consensus, no markup",
    divergeMarkup(base, same, same, 2, 1) == same
  check "both deleting the same lines is consensus",
    divergeMarkup(base, "alpha\n", "alpha\n", 2, 1) == "alpha\n"

# -- true conflict: both rewrote the same region differently --------------------
block conflict:
  let base = "alpha\nbeta\ngamma\n"
  let mine = "alpha\nmine1\nmine2\ngamma\n"
  let theirs = "alpha\ntheirs\ngamma\n"
  let view = divergeMarkup(base, mine, theirs, 2, 1)
  check "conflict shows the base as a deletion",
    view.contains("{--[s1+s2]beta\n--}") or view.contains("{--beta\n--}")
  check "conflict shows their proposal tagged",
    view.contains("{++[s1]theirs\n++}")
  check "conflict shows my proposal tagged",
    view.contains("{++[s2]mine1\nmine2\n++}")
  check "conflict keeps surrounding context plain",
    view.startsWith("alpha\n{--") and view.endsWith("++}gamma\n")

# -- the review round-trips: accept-all resolves to a sane merge ---------------
block roundtrip:
  let base = "alpha\nbeta\ngamma\ndelta\n"
  let mine = "alpha\nBETA\ngamma\ndelta\nEPSILON\n"
  let theirs = "alpha\nbeta\nGAMMA\ndelta\n"
  let view = divergeMarkup(base, mine, theirs, 2, 1)
  let kept = applyCriticMarkup(view, accept = true)
  check "accept keeps both sides' insertions",
    kept.contains("BETA") and kept.contains("GAMMA") and kept.contains("EPSILON")
  check "accept drops the deleted base text",
    not kept.contains("{--") and not kept.contains("beta\n")

# -- exact text preservation ----------------------------------------------------
block exactness:
  let base = "alpha\n"
  let mine = "alpha\nbeta\n"
  let theirs = base
  check "an appended line survives exactly, newline and all",
    divergeMarkup(base, mine, theirs, 2, 1) == "alpha\n{++[s2]beta\n++}"

if fails > 0:
  echo "test_collab_diverge: ", fails, " FAILED"
  quit 1
echo "test_collab_diverge: all assertions passed"
