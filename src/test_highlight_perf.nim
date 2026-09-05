import std/[times, os]
import widgets/synedit

proc main() =
  if paramCount() < 1:
    quit("usage: test_highlight_perf <file.org>", 1)
  let path = paramStr(1)
  let text = readFile(path)

  var s: SynEdit
  s.tabSize = 4
  s.lang = langOrg
  s.setText(text)

  # Count cells with non-default token classes to verify highlighting applied
  var nonDefault = 0
  var total = 0
  for i in 0 ..< s.len:
    let c = s.getCell(i)
    inc total
    if c.s != TokenClass.None and c.s != TokenClass.Text:
      inc nonDefault
  echo "total cells: ", total
  echo "non-default token cells: ", nonDefault
  echo "highlighting applied: ", nonDefault > 0

main()