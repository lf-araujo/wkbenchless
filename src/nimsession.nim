## nimsession -- a persistent *warm* Nim session: a growing script replayed
## through a real compiler on each eval. Vendored (and merged to one module)
## from lf-araujo/nimteractive (MIT) so wkbenchless needs no external
## `nimteractive` binary and no python carrier. Driven by `nimhost.nim`.
##
## Each eval re-runs imports+procs+history+newCode as one program: write a
## .nim, `nim c --app:lib` it against a persistent nimcache (keyed by
## imports/nim-version/lockfile), load the resulting .so/.dll (Nim runs NimMain
## as the library loads -- a POSIX constructor, DllMain on Windows -- so
## top-level statements and their stdout run as part of the load), capture
## stdout by pointing FD 1 at a temp file, unload, remove.
## State "persists" because the whole history is replayed every time; a block
## that redeclares a name hot-reloads (the old entry is dropped, see
## withoutShadowed). This replaced an earlier NimScript-VM design that had no
## FFI (so it could never import datamancer/arraymancer/fastsem-style packages).

import std/[dynlib, os, osproc, sha1, algorithm, strutils, sequtils]

# FD-level stdout redirection: the C runtime's calls, spelled per platform.
when defined(windows):
  proc cDup(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
  proc cDup2(fd, fd2: cint): cint {.importc: "_dup2", header: "<io.h>".}
  proc cClose(fd: cint): cint {.importc: "_close", header: "<io.h>".}
  proc cFileno(f: File): cint {.importc: "_fileno", header: "<stdio.h>".}
  const libExt = ".dll"
else:
  proc cDup(fd: cint): cint {.importc: "dup", header: "<unistd.h>".}
  proc cDup2(fd, fd2: cint): cint {.importc: "dup2", header: "<unistd.h>".}
  proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
  proc cFileno(f: File): cint {.importc: "fileno", header: "<stdio.h>".}
  const libExt = ".so"

# ---- cache keys / compile ---------------------------------------------------

proc cacheDir(): string = getCacheDir() / "wkbenchless" / "nim-sessions"

proc nimVersion(): string =
  let (output, _) = execCmdEx("nim --version")
  result = output.splitLines()[0]

proc lockfileHash(): string =
  let lf = getCurrentDir() / "nimble.lock"
  if fileExists(lf): $secureHash(readFile(lf))
  else: ""

proc cacheKey*(imports: seq[string]): string =
  let raw = imports.sorted.join("|") & "|" & nimVersion() & "|" & lockfileHash()
  result = ($secureHash(raw))[0..15]

proc sessionCacheDir(key: string): string = cacheDir() / key
proc tmpDir(key: string): string = sessionCacheDir(key) / "tmp"
proc nimcacheDir(key: string): string = sessionCacheDir(key) / "nimcache"

proc compileToLib(key, source, tag: string): tuple[soPath: string, err: string] =
  ## Compile `source` into a shared library, reusing a persistent nimcache dir
  ## keyed by `key` so heavy imports only pay generic instantiation / C
  ## compilation once. `tag` is unique per call (caller's job).
  let dir = tmpDir(key)
  createDir(dir)
  createDir(nimcacheDir(key))
  let srcPath = dir / (tag & ".nim")
  let soPath = dir / (tag & libExt)
  writeFile(srcPath, source)
  let cmd = "nim c --app:lib -d:release -d:ssl --hints:off --warnings:off " &
            "--nimcache:" & quoteShell(nimcacheDir(key)) & " " &
            "-o:" & quoteShell(soPath) & " " & quoteShell(srcPath)
  let (output, code) = execCmdEx(cmd)
  if code != 0: return ("", output)
  result = (soPath, "")

# ---- session ----------------------------------------------------------------

type
  HistEntry = object
    code: string
    names: seq[string]   ## top-level let/var/const/proc names this entry declares

  Session* = ref object
    key*: string
    blockCounter: int
    imports: string
    procs: string
    history: seq[HistEntry]

var gSession*: Session

proc newSession*(): Session = Session()
proc initGlobalSession*() = gSession = newSession()

proc declaredNames(code: string): seq[string] =
  ## Heuristic line scan for names a block declares at top level -- enough to
  ## drive redefinition-shadowing (see evalBlock); misses multi-line decls.
  for rawLine in code.splitLines:
    let line = rawLine.strip()
    for prefix in ["let ", "var ", "const "]:
      if line.startsWith(prefix):
        let rest = line[prefix.len..^1]
        let eqIdx = rest.find('=')
        let namesPart = if eqIdx >= 0: rest[0..<eqIdx] else: rest
        for n in namesPart.split(','):
          var nm = n.strip(chars = Whitespace + {'(', ')'})
          let colonIdx = nm.find(':')
          if colonIdx >= 0: nm = nm[0..<colonIdx].strip()
          if nm.len > 0 and nm[0] in {'a'..'z', 'A'..'Z', '_'}:
            result.add(nm)
    if line.startsWith("proc "):
      let rest = line[5..^1]
      var nameEnd = rest.len
      let parenIdx = rest.find('(')
      if parenIdx >= 0 and parenIdx < nameEnd: nameEnd = parenIdx
      let starIdx = rest.find('*')
      if starIdx >= 0 and starIdx < nameEnd: nameEnd = starIdx
      let nm = rest[0..<nameEnd].strip()
      if nm.len > 0: result.add(nm)

proc withoutShadowed(entries: seq[HistEntry], names: seq[string]): seq[HistEntry] =
  ## Drop any history entry that declares a name being redefined -- the "hot
  ## reload" mechanism: re-running an edited block replaces its old entry
  ## instead of erroring with "redefinition of ...".
  if names.len == 0: return entries
  for e in entries:
    var shadowed = false
    for n in e.names:
      if n in names: shadowed = true; break
    if not shadowed: result.add(e)

proc scriptFor(s: Session, entries: seq[HistEntry]): string =
  result = s.imports
  if s.procs != "": result &= "\n" & s.procs
  for entry in entries: result &= "\n" & entry.code

proc fullScript(s: Session): string = s.scriptFor(s.history)

proc nextTag(s: Session; suffix = ""): string =
  inc s.blockCounter
  result = "block_" & $s.blockCounter
  if suffix != "": result &= "_" & suffix

proc runLib(soPath: string): tuple[stdout: string, err: string] =
  ## Load `soPath`: `--app:lib` runs NimMain as the library loads (a POSIX
  ## constructor; DllMain on Windows), so top-level statements -- and their
  ## stdout -- run inside loadLib itself. FD 1 points at a temp file meanwhile:
  ## a file never fills up, where a pipe nobody reads until the load returns
  ## blocked the block's writes for good once it held 64 KB.
  let capPath = soPath & ".out"
  var cap: File
  if not open(cap, capPath, fmWrite): return ("", "could not create " & capPath)
  stdout.flushFile()
  let savedOut = cDup(1)
  discard cDup2(cFileno(cap), 1)   # the C runtime's fd (getFileHandle is an
                                    # OS HANDLE on Windows in newer Nims)
  var runErr = ""
  let lib = loadLib(soPath)
  if lib == nil: runErr = "could not load " & soPath
  else: unloadLib(lib)
  stdout.flushFile()
  discard cDup2(savedOut, 1)
  discard cClose(savedOut)
  cap.close()
  let captured = try: readFile(capPath) except IOError: ""
  try: removeFile(capPath) except OSError: discard
  result = (captured.strip(leading = false), runErr)

proc evalRaw(s: Session, script, tag: string): tuple[stdout: string, err: string] =
  let (soPath, compileErr) = compileToLib(s.key, script, tag)
  if compileErr != "": return ("", compileErr)
  result = runLib(soPath)
  removeFile(soPath)
  removeFile(s.key.tmpDir / (tag & ".nim"))

const
  RuntimeErrorMarker = "\x01NIMTERACTIVE_RUNTIME_ERROR\x01"
  BeginMarker = "\x02NIMTERACTIVE_BEGIN\x02"
  EndMarker = "\x02NIMTERACTIVE_END\x02"

proc wrapGuarded(code: string): string =
  ## Run the block inside `try: ... except CatchableError, Defect:` (a bare
  ## `except:` would let a Defect like IndexDefect abort the whole host), with
  ## imports hoisted out (Nim only allows them at top level). Begin/End markers
  ## bracket this block's own output so runGuarded can extract exactly it.
  var imports, body: seq[string]
  for line in code.splitLines:
    let s = line.strip()
    if s.startsWith("import ") or s.startsWith("import\t") or s.startsWith("from "):
      imports.add(line)
    else:
      body.add(line)
  result = ""
  if imports.len > 0: result &= imports.join("\n") & "\n"
  result &= "echo \"" & BeginMarker & "\"\n"
  result &= "try:\n" & indent(body.join("\n"), 2) &
    "\nexcept CatchableError, Defect:\n" &
    "  echo \"" & RuntimeErrorMarker & "\", getCurrentExceptionMsg()\n"
  result &= "echo \"" & EndMarker & "\""

proc runGuarded(s: Session; prefix, code, tag: string): tuple[stdout: string, err: string] =
  let (full, err) = s.evalRaw(prefix & "\n" & wrapGuarded(code), tag)
  if err != "": return ("", err)
  let beginIdx = full.find(BeginMarker)
  if beginIdx < 0:
    return ("", "internal error: output markers not found in: " & full)
  let contentStart = full.find('\n', beginIdx) + 1
  let endIdx = full.find(EndMarker, contentStart)
  let content = if endIdx >= 0: full[contentStart ..< endIdx] else: full[contentStart..^1]
  let runtimeIdx = content.find(RuntimeErrorMarker)
  if runtimeIdx >= 0:
    return ("", content[runtimeIdx + RuntimeErrorMarker.len ..^ 1].strip())
  result = (content.strip(leading = false), "")

proc setImports*(s: Session; imports: seq[string]): tuple[stdout: string, err: string] =
  s.imports = imports.mapIt("import " & it).join("\n")
  s.procs = ""
  s.history = @[]
  s.key = cacheKey(imports)
  result = s.evalRaw(s.imports, s.nextTag())

proc setProcs*(s: Session; code: string): tuple[stdout: string, err: string] =
  s.procs = code
  s.history = @[]
  result = s.evalRaw(s.imports & "\n" & s.procs, s.nextTag())

proc evalBlock*(s: Session; code: string): tuple[stdout: string, err: string] =
  ## Append to history, replay the full script, return this block's own output.
  ## Hot-reload: a new entry redeclaring an earlier name drops the earlier
  ## entry first. If the expression "has to be used", retry wrapped in `echo`
  ## (prints the value like a REPL), then `discard` for types with no `$`.
  let trimmed = code.strip()
  block:
    let names = declaredNames(trimmed)
    let candidateHist = s.history.withoutShadowed(names)
    let (output, err) = s.runGuarded(s.scriptFor(candidateHist), trimmed, s.nextTag())
    if err == "":
      s.history = candidateHist & HistEntry(code: trimmed, names: names)
      return (output, "")
    elif "has to be used" notin err:
      return ("", err)
  block:
    let echoCode = "echo " & trimmed
    let (output, err) = s.runGuarded(s.fullScript(), echoCode, s.nextTag("echo"))
    if err == "":
      s.history.add HistEntry(code: echoCode, names: @[])
      return (output, "")
  block:
    let discardCode = "discard " & trimmed
    let (output, err) = s.runGuarded(s.fullScript(), discardCode, s.nextTag("discard"))
    if err == "":
      s.history.add HistEntry(code: discardCode, names: @[])
      return (output, "")
  result = ("", "error: " & trimmed)

proc resetSession*(s: Session) =
  s.imports = ""
  s.procs = ""
  s.history = @[]
