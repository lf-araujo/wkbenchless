## test_otd_spans -- the otd-export CriticMarkup fixes: emphasis shared by
## both sides of a substitution is hoisted out of the token (so pandoc can
## pair it past the stashed sentinel), and edge whitespace survives inside
## the w:ins/w:del spans (pandoc drops bare edge spaces in span content).
##   nim c -r --hints:off src/test_otd_spans.nim
import std/strutils
import ../extensions/org_tracked

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

# -- hoistCriticEmphasis: shared emphasis leaves the token --------------------
block hoist:
  check "shared leading italic is hoisted before the token",
    hoistCriticEmphasis("quote {~~/First, X~>/In sensitivity Y~~}/ tail") ==
      "quote /{~~First, X~>In sensitivity Y~~}/ tail"
  check "shared leading bold is hoisted before the token",
    hoistCriticEmphasis("{~~*a~>*b~~}") == "*{~~a~>b~~}"
  check "shared trailing emphasis is hoisted after the token",
    hoistCriticEmphasis("{~~a*~>b*~~}") == "{~~a~>b~~}*"
  check "author tags stay inside, the delimiter still hoists",
    hoistCriticEmphasis("{~~[Carol]/a~>[Carol]/b~~}") == "/{~~[Carol]a~>[Carol]b~~}"
  check "a delimiter on only one side is left alone",
    hoistCriticEmphasis("{~~/a~>b~~}") == "{~~/a~>b~~}"
  check "prose without emphasis is untouched",
    hoistCriticEmphasis("plain {~~old~>new~~} text") == "plain {~~old~>new~~} text"

# -- criticToSpans: edge whitespace is escaped so pandoc keeps it -------------
block edges:
  var doneIds: seq[int]
  check "a trailing space stays inside the insertion span",
    criticToSpans("{++… participants ++}in", doneIds).contains(
      "[… participants&#32;]{.insertion") and
    criticToSpans("{++… participants ++}in", doneIds).endsWith("}in")
  check "a leading space stays inside the insertion span",
    criticToSpans("x{++ word++}", doneIds).contains("[&#32;word]{.insertion")
  check "a deletion's edge space is escaped too",
    criticToSpans("x{--gone --}y", doneIds).contains("[gone&#32;]{.deletion")
  check "a substitution's new side keeps its edge space",
    criticToSpans("{~~old~>new ~~}", doneIds).contains("[new&#32;]{.insertion")
  check "text without edge spaces is emitted plain",
    criticToSpans("{++clean++}", doneIds).contains("[clean]{.insertion") and
      not criticToSpans("{++clean++}", doneIds).contains("&#32;")

if fails > 0:
  echo "test_otd_spans: ", fails, " FAILED"
  quit 1
echo "test_otd_spans: all assertions passed"
