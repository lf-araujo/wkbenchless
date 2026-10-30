## test_cite -- keyAtPoint: the citekey at/near a column, with a distance
## bound for the Ctrl-click hook (a click wants the citation it landed on,
## not the nearest one anywhere on the line).
##   nim c -r --hints:off src/test_cite.nim
import std/strutils
import wkbcore

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

block key_at_point:
  let line = "As shown in [cite:@reynolds2005] and [cite:@posthuma2010], the"
  check "on the key itself",
    keyAtPoint(line, line.find("@reynolds") + 3) == "reynolds2005"
  check "on the [cite: prefix, within the wrapper tolerance",
    keyAtPoint(line, line.find("[cite:"), maxDist = 12) == "reynolds2005"
  check "on the closing bracket, within the wrapper tolerance",
    keyAtPoint(line, line.find("]"), maxDist = 12) == "reynolds2005"
  check "nearest-unbounded still finds a distant key (M-x cite-context)",
    keyAtPoint(line, 0) == "reynolds2005"
  check "a bounded click far from any key finds nothing",
    keyAtPoint(line, 0, maxDist = 12) == ""
  check "the second citation is found on its own",
    keyAtPoint(line, line.find("@posthuma") + 2) == "posthuma2010"
  check "crossref labels are ignored",
    keyAtPoint("see Figure [cite:@fig:one]", 15) == ""
  check "a line without keys yields empty",
    keyAtPoint("plain prose, no citations here", 10) == ""

if fails > 0:
  echo "test_cite: ", fails, " FAILED"
  quit 1
echo "test_cite: all assertions passed"
