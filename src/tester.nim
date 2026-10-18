## Central test runner: builds and runs every self-contained test in
## src/test_*.nim, in process order, and reports a PASS/FAIL line per test.
## Exits non-zero if any test fails, so `nimble test` works in CI.
##
##   nim c -r --hints:off -o:build/tester src/tester.nim
##
## Not run here (needs arguments or an external host):
##   test_highlight_perf  -- takes a .org file path
##   test_tmux_remote    -- needs an authenticated ssh master
##   test_async_session   -- needs R on PATH (run by hand when R matters)
import std/[os, osproc, strutils, terminal, algorithm]

const skipped = ["test_highlight_perf", "test_tmux_remote", "test_async_session",
                 "tester"]

proc main() =
  var names: seq[string]
  for t in walkFiles(getAppDir() / "../src/test_*.nim"):
    let name = t.splitFile.name
    if name notin skipped: names.add name
  names.sort()

  var failed: seq[string]
  for i, name in names:
    let src = getAppDir() / "../src" / (name & ".nim")
    styledWriteLine stdout, styleBright, "[$#/$#] " % [$(i + 1), $names.len],
      resetStyle, name, " ... ", fgYellow, "building", resetStyle
    flushFile stdout
    let (outp, code) = execCmdEx("nim c --hints:off -o:" &
      (getAppDir() / name) & " " & src, options = {poStdErrToStdOut})
    if code != 0:
      failed.add name
      echo outp
      styledWriteLine stdout, fgRed, "FAIL (build)", resetStyle
      continue
    let (runOut, rcode) = execCmdEx(getAppDir() / name,
      options = {poStdErrToStdOut})
    if rcode != 0:
      failed.add name
      echo runOut
      styledWriteLine stdout, fgRed, "FAIL", resetStyle
    else:
      styledWriteLine stdout, fgGreen, "PASS", resetStyle

  echo ""
  if failed.len == 0:
    styledWriteLine stdout, fgGreen, "all ", $names.len, " tests passed", resetStyle
  else:
    styledWriteLine stdout, fgRed, $failed.len, "/", $names.len,
      " tests failed: ", failed.join(", "), resetStyle
    quit 1

main()
