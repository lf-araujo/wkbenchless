## The tiny regex engine behind the find panel's ".*" toggle.
##   nim c -r --hints:off src/test_regex.nim

import std/strutils
import wkbcore

var fails = 0
proc eq(pattern, s: string; ic = false; want: seq[tuple[a, e: int]]) =
  var got: seq[tuple[a, e: int]]
  try:
    got = rxSearch(pattern, s, ic)
  except ValueError as ex:
    echo "FAIL ", pattern.repr, " raised: ", ex.msg
    inc fails; return
  if got != want:
    echo "FAIL ", pattern.repr, " on ", s.repr, ": got ", got, " want ", want
    inc fails
  else:
    echo "ok   ", pattern.repr, " -> ", got

# literals & dot
eq("abc", "xxabcxxabc", want = @[(2, 5), (7, 10)])
eq("a.c", "abc a-c a\nc", want = @[(0, 3), (4, 7)])
# star / plus / question
eq("ab*c", "ac abc abbc", want = @[(0, 2), (3, 6), (7, 11)])
eq("ab+c", "ac abc abbc", want = @[(3, 6), (7, 11)])
eq("colou?r", "color colour", want = @[(0, 5), (6, 12)])
# classes
eq("[bB]anana", "Banana banana", want = @[(0, 6), (7, 13)])
eq("[a-c]+", "abcd", want = @[(0, 3)])
eq("[^a-c]+", "abcd", want = @[(3, 4)])
eq("x[0-9]y", "x1y xay x42y", want = @[(0, 3)])
eq("x[0-9]+y", "x1y xay x42y", want = @[(0, 3), (8, 12)])
# anchors
eq("^ab", "ab ab", want = @[(0, 2)])
eq("ab$", "ab ab", want = @[(3, 5)])
eq("^$", "a\n\nb", want = @[(2, 2)])
eq("^b", "a\nb", want = @[(2, 3)])
eq("a$", "a\nab", want = @[(0, 1)])
# alternation & groups
eq("cat|dog", "catdog", want = @[(0, 3), (3, 6)])
eq("(ab)+", "ababab", want = @[(0, 6)])
eq("(a|b)+c", "abbc", want = @[(0, 4)])
# escapes
eq(r"\d+", "ab 12 cd 345", want = @[(3, 5), (9, 12)])
eq(r"\w+", "a_1 !!", want = @[(0, 3)])
eq(r"\s\d", "a 1", want = @[(1, 3)])
eq(r"a\.b", "a.b axb", want = @[(0, 3)])
# case-insensitive
eq("ABC", "abc ABC", ic = true, want = @[(0, 3), (4, 7)])
eq("ABC", "abc ABC", ic = false, want = @[(4, 7)])
# empty-match storm stays finite
eq("a*", "baa", want = @[(0, 0), (1, 3), (3, 3)])
# bad patterns raise (and recomputeMatches catches)
for bad in ["(", "[", "a)", "*"]:
  try:
    discard rxSearch(bad, "x", false)
    echo "FAIL ", bad.repr, " should have raised"; inc fails
  except ValueError:
    echo "ok   ", bad.repr, " raises"

# word-boundary helper (the "ab" toggle)
doAssert isWordBounded("the cat", 4, 7)
doAssert not isWordBounded("the caterpillar", 4, 7)
doAssert isWordBounded("cat", 0, 3)
doAssert not isWordBounded("concat", 3, 6)

if fails > 0:
  echo $fails & " FAILURES"
  quit 1
echo "all ok"
