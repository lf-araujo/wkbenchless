## nim-host -- the `nimteractive` warm Nim session, driven over wkbenchless's
## session text protocol instead of a python carrier or an external binary.
##
## Spawned as `wkbenchless nim-host` (see wkbenchless.nim's subcommand
## dispatch) and wired up as the `nimteractive` REPL in agent_tools.nim. On
## startup it prints the ready token; then for each `RUN <file> <nonce>` line
## it evals the file's code in the warm session (nimsession.nim) and brackets
## that block's captured output with the BEGIN/END markers + nonce the session
## reader (wkbsession.nim) keys on. `QUIT` exits.

import std/[strutils, os]
import nimsession

const                       # split literals so they never appear contiguously
  BOR = "__NIMACS" & "_BOR__"
  EOR = "__NIMACS" & "_END__"
  RDY = "NIMACS" & "xREADY"

proc nimHost*(): int =
  initGlobalSession()
  try: gSession.key = cacheKey(@[])   # version/lockfile-keyed persistent nimcache
  except CatchableError: discard
  stdout.writeLine(RDY)               # handshake: startSession waits for this
  stdout.flushFile()
  for raw in stdin.lines:
    let line = raw.strip()
    if line.len == 0: continue
    if line == "QUIT": break
    if not line.startsWith("RUN "): continue
    # "RUN <path> <nonce>": nonce is the last token, path is everything before.
    let rest = line[4 .. ^1].strip()
    let sp = rest.rfind(' ')
    if sp < 0: continue
    let path = rest[0 ..< sp].strip()
    let nonce = rest[sp + 1 .. ^1].strip()
    stdout.writeLine(BOR & " " & nonce)   # printed BEFORE eval redirects FD 1
    stdout.flushFile()
    var body = ""
    try:
      let code = readFile(path)
      let (outp, err) = gSession.evalBlock(code)
      body =
        if err.len > 0: (if outp.len > 0: outp & "\n" else: "") & err
        else: outp
    except CatchableError:
      body = "nim-host error: " & getCurrentExceptionMsg()
    stdout.write(body)
    if body.len == 0 or body[^1] != '\n': stdout.write("\n")
    stdout.writeLine(EOR & " " & nonce)
    stdout.flushFile()
  0
