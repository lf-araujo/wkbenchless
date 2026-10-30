## The find/replace engine behind the subl-style panel: plain, regex (".*"),
## case ("Aa") and whole-word ("ab") toggles, and the replace actions.
##   nim c -r --hints:off src/test_search.nim

import std/strutils
import wkbcore

var app: App
app = App()
app.theme = base16Theme("test", defaultBase16())
app.ed = createSynEdit(app.font)
app.ed.setText("the cat sat on the mat\nCat-5 cable\nconcatenate\n")

proc check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; quit 1

# plain, case-insensitive by default: cat, Cat, cat(enate)
app.searchQuery = "cat"
app.recomputeMatches()
check "plain finds 3", app.searchMatches.len == 3
check "plain ends", app.searchMatchEnds == @[7, 26, 41]

# "Aa" case toggle: only the exact-case ones
app.searchCase = true
app.recomputeMatches()
check "case-sensitive finds 2", app.searchMatches.len == 2
app.searchCase = false

# "ab" whole-word: drops "concatenate"
app.searchWord = true
app.recomputeMatches()
check "whole-word finds 2", app.searchMatches.len == 2
app.searchWord = false

# ".*" regex: c.t matches cat, Cat (in cable? no: C-a-t... "Cat-5" yes), mat
app.searchRegex = true
app.searchQuery = "c.t"
app.recomputeMatches()
check "regex finds 3", app.searchMatches.len == 3
check "regex ends vary", app.searchMatchEnds == @[7, 26, 41]

# regex + word: "Cat-5" still whole-word (hyphen is a boundary), but the
# "cat" inside "concatenate" is not
app.searchWord = true
app.recomputeMatches()
check "regex+word finds 2", app.searchMatches.len == 2
app.searchQuery = "at"
app.recomputeMatches()
check "regex+word 'at' finds 0", app.searchMatches.len == 0
app.searchWord = false

# a bad regex reports, not crashes
app.searchQuery = "c(t"
app.recomputeMatches()
check "bad regex -> no matches", app.searchMatches.len == 0

# replaceCurrent with a variable-length regex match
app.searchQuery = "c.+t"
app.recomputeMatches()
check "greedy c.+t finds 3", app.searchMatches.len == 3
app.searchIdx = 0
app.searchReplace = "dog"
replaceCurrent(app)
check "replaceCurrent edits", "the dog\n" in app.ed.fullText()
check "rescan after replace", app.searchMatches.len == 2

# replaceAll with regex
app.searchQuery = "[cm]at"
app.recomputeMatches()
replaceAll(app)
let text = app.ed.fullText()
check "replaceAll both", "the dog\n" in text and "dog-5 cable" in text
check "replaceAll gone", "mat" notin text and "Cat" notin text

# findAllMatches lands on the first and reports the count
app.searchQuery = "dog"
app.searchRegex = false
app.recomputeMatches()
findAllMatches(app)
check "findAll count msg", app.msg == "3 matches"
check "findAll first", app.searchIdx == 0

# the panel always shows both rows: text typed into the replace field lands
# there even when the panel was opened as plain find (C-f, then Tab/click)
app.ed.setText("alpha beta alpha\n")
openFind(app)
searchFieldAdd(app, "alpha")
app.searchField = sfReplace
searchFieldAdd(app, "gamma")
check "replace field takes text after find-open", app.searchReplace == "gamma"
check "find field untouched", app.searchQuery == "alpha"
searchFieldAdd(app, "!")
check "'!' is ordinary text", app.searchReplace == "gamma!" and
  app.ed.fullText() == "alpha beta alpha\n"
searchFieldBackspace(app)
check "backspace edits the replace field", app.searchReplace == "gamma"
app.searchField = sfQuery
searchFieldAdd(app, "ε")
searchFieldBackspace(app)
check "backspace drops a whole UTF-8 char", app.searchQuery == "alpha"

# replaceAll when the replacement contains the needle (used to loop forever)
app.searchReplace = "alphaalpha"
replaceAll(app)
check "replaceAll self-containing", app.ed.fullText() == "alphaalpha beta alphaalpha\n"
check "replaceAll count msg", app.msg == "replaced 2"
check "replaceAll closes the panel", not app.searchActive

# zero-width regex matches insert without deleting
app.ed.setText("a\nb\n")
openReplace(app)
app.searchRegex = true
searchFieldAdd(app, "^")
app.searchField = sfReplace
searchFieldAdd(app, "> ")
replaceAll(app)
check "zero-width replaceAll", app.ed.fullText().startsWith("> a\n> b")
app.searchRegex = false

echo "all ok"
