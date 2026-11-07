## Interpreted user config: ~/.config/wkbenchless/config.nims, run in-process by
## Nim's VM (compiler/nimeval), so M-x reload-config applies it with no rebuild
## and no restart. The compiled wkbconfig.nim stays for deep App access.
##
## The host API is the stub module wkbhost.nim; every stub is bound to native
## code below (see spike/DESIGN.md for the model and its gotchas). The VM needs
## the Nim stdlib as source at runtime, so it is embedded here and unpacked to
## the cache directory on first use.
##
## A reload is a transaction. The new config is evaluated with its requests
## queued, and only a clean evaluation commits them: the compiled baseline is
## restored (so a deleted line really goes away) and the queue is replayed. A
## failed evaluation discards the queue, so the previous config stays active.

import compiler/[ast, vmdef, vm, nimeval, llstream, lineinfos, options, msgs]
import wkbcore
import std/[os, tables, strutils, hashes, sequtils, times]

const
  hostApiSrc = staticRead("wkbhost.nim")
  nimLibRoot = findNimStdLibCompileTime()

proc collectStdlib(): seq[tuple[rel, text: string]] {.compileTime.} =
  ## The parts of the stdlib a config can reach, as (relative path, source).
  result.add ("system.nim", staticRead(nimLibRoot / "system.nim"))
  for sub in ["system", "core", "pure", "std", "posix", "windows", "wrappers"]:
    if dirExists(nimLibRoot / sub):
      for f in walkDirRec(nimLibRoot / sub):
        if f.endsWith(".nim"):
          result.add (f[nimLibRoot.len + 1 .. ^1], staticRead(f))

const embeddedLib = collectStdlib()
const libStamp = NimVersion & "-" & toHex(hash(hostApiSrc) !& embeddedLib.len, 8)

type
  VmConfigError = object of CatchableError
  Baseline = object
    ## Everything a config can change, as the compiled config left it.
    commands: OrderedTable[string, wkbcore.Command]
    keymap: Table[string, string]
    hooks: Table[string, seq[Hook]]
    remoteMethods: Table[string, string]
    extraPaths: seq[string]
    margins: Table[string, int]
    corpusRoots: seq[string]
    claudeCmd, terminalDir, zoteroDir: string
    remoteTimeout, latexDpi: int
    bufferTabs, claudeDiffHooks, claudeMod: bool

var
  gInterp: Interpreter          ## the config now active (nil = none)
  gBase: Baseline
  gLoading = false              ## queue requests instead of applying them
  gOps: seq[Hook]               ## requests queued by the config being loaded
  gProcRefs: seq[string]        ## config procs named by defcommand/addHook
  gLiveApp: ptr App             ## the editor, while a config proc runs

proc captureBaseline() =
  gBase = Baseline(commands: gCommands, keymap: gKeymap, hooks: gHooks,
    remoteMethods: gRemoteMethods, extraPaths: gExtraPaths,
    margins: gReadingMargins, corpusRoots: gCorpusRoots,
    claudeCmd: gClaudeCmd, terminalDir: gTerminalDir, zoteroDir: gZoteroDir,
    remoteTimeout: gRemoteLaunchTimeout, latexDpi: gLatexDpi,
    bufferTabs: gBufferTabs, claudeDiffHooks: gClaudeDiffHooks,
    claudeMod: gClaudeMod)

proc restoreBaseline() =
  gCommands = gBase.commands
  gKeymap = gBase.keymap
  gHooks = gBase.hooks
  gRemoteMethods = gBase.remoteMethods
  gExtraPaths = gBase.extraPaths
  gReadingMargins = gBase.margins
  gCorpusRoots = gBase.corpusRoots
  gClaudeCmd = gBase.claudeCmd
  gTerminalDir = gBase.terminalDir
  gZoteroDir = gBase.zoteroDir
  gRemoteLaunchTimeout = gBase.remoteTimeout
  gLatexDpi = gBase.latexDpi
  gBufferTabs = gBase.bufferTabs
  gClaudeDiffHooks = gBase.claudeDiffHooks
  gClaudeMod = gBase.claudeMod

proc vmRuntimeDir(): string =
  ## The directory holding the unpacked stdlib and host API, created on first
  ## use. The stamp changes with the Nim version and the embedded files.
  result = getCacheDir() / "wkbenchless" / ("vm-" & libStamp)
  let marker = result / ".complete"
  if fileExists(marker): return
  for (rel, text) in embeddedLib:
    let dest = result / "lib" / rel
    createDir(dest.parentDir)
    writeFile(dest, text)
  createDir(result / "host")
  writeFile(result / "host" / "wkbhost.nim", hostApiSrc)
  # implementRoutine matches on the nimble package name of the stub's directory.
  writeFile(result / "host" / "wkbenchless.nimble", "")
  writeFile(marker, libStamp)

proc whenLoaded(op: Hook) =
  ## Queue a request while a config loads; apply it at once from a config proc.
  {.cast(gcsafe).}:
    if gLoading: gOps.add op
    elif gLiveApp != nil: op(gLiveApp[])

proc callConfigProc(a: var App; procName: string) =
  ## Run a parameterless config proc. Its errors reach the status bar.
  if gInterp == nil: return
  let routine = gInterp.selectRoutine(procName)
  if routine == nil:
    a.msg = "config: no proc named " & procName
    return
  let outer = gLiveApp
  gLiveApp = addr a
  defer: gLiveApp = outer
  try:
    discard gInterp.callRoutine(routine, @[])
  except VmConfigError as e:
    a.msg = "config: " & e.msg.splitLines()[0]

proc setStringOption(name, value: string): bool =
  result = true
  case name
  of "gClaudeCmd": gClaudeCmd = value
  of "gTerminalDir": gTerminalDir = value
  of "gZoteroDir": gZoteroDir = value
  else: result = false

proc setIntOption(name: string; value: int): bool =
  result = true
  case name
  of "gRemoteLaunchTimeout": gRemoteLaunchTimeout = value
  of "gLatexDpi": gLatexDpi = value
  else: result = false

proc setBoolOption(name: string; value: bool): bool =
  result = true
  case name
  of "gBufferTabs": gBufferTabs = value
  of "gClaudeDiffHooks": gClaudeDiffHooks = value
  of "gClaudeMod": gClaudeMod = value
  else: result = false

proc bindHostApi(i: Interpreter) =
  template host(name: string; body: untyped) =
    i.implementRoutine("wkbenchless", "wkbhost", name,
      proc(a {.inject.}: VmArgs) {.gcsafe.} =
        {.cast(gcsafe).}:
          body)
  template unknownOption(ok: bool; name: string) =
    if not ok:
      raise newException(VmConfigError, "setOpt: unknown setting " & name)

  host("bindkey"):
    let chord = getString(a, 0); let command = getString(a, 1)
    whenLoaded(proc(x: var App) = bindkey(chord, command))
  host("unbindkey"):
    let chord = getString(a, 0)
    whenLoaded(proc(x: var App) = gKeymap.del(chord))
  host("defcommand"):
    let name = getString(a, 0); let label = getString(a, 1)
    let procName = getString(a, 2)
    gProcRefs.add procName
    whenLoaded(proc(x: var App) =
      defcommand(name, label, proc(z: var App) = callConfigProc(z, procName)))
  host("addHook"):
    let event = getString(a, 0); let procName = getString(a, 1)
    gProcRefs.add procName
    whenLoaded(proc(x: var App) =
      addHook(event, proc(z: var App) = callConfigProc(z, procName)))
  host("defineRemoteMethod"):
    let name = getString(a, 0); let loginCmd = getString(a, 1)
    whenLoaded(proc(x: var App) = defineRemoteMethod(name, loginCmd))
  host("addExecPath"):
    let dir = getString(a, 0)
    whenLoaded(proc(x: var App) = addExecPath(dir))
  host("setReadingMargin"):
    let ext = getString(a, 0); let px = int(getInt(a, 1))
    whenLoaded(proc(x: var App) = setReadingMargin(ext, px))
  host("addCorpusRoot"):
    let dir = getString(a, 0)
    whenLoaded(proc(x: var App) = gCorpusRoots.add dir)
  host("applyTheme"):
    let name = getString(a, 0)
    whenLoaded(proc(x: var App) = applyThemeByName(x, name))
  host("setStringOpt"):
    let name = getString(a, 0); let value = getString(a, 1)
    let saved = (gClaudeCmd, gTerminalDir, gZoteroDir)
    unknownOption(setStringOption(name, value), name)
    (gClaudeCmd, gTerminalDir, gZoteroDir) = saved
    whenLoaded(proc(x: var App) = discard setStringOption(name, value))
  host("setIntOpt"):
    let name = getString(a, 0); let value = int(getInt(a, 1))
    let saved = (gRemoteLaunchTimeout, gLatexDpi)
    unknownOption(setIntOption(name, value), name)
    (gRemoteLaunchTimeout, gLatexDpi) = saved
    whenLoaded(proc(x: var App) = discard setIntOption(name, value))
  host("setBoolOpt"):
    let name = getString(a, 0); let value = getBool(a, 1)
    let saved = (gBufferTabs, gClaudeDiffHooks, gClaudeMod)
    unknownOption(setBoolOption(name, value), name)
    (gBufferTabs, gClaudeDiffHooks, gClaudeMod) = saved
    whenLoaded(proc(x: var App) = discard setBoolOption(name, value))
  host("status"):
    let msg = getString(a, 0)
    whenLoaded(proc(x: var App) = x.msg = msg)
  host("insertText"):
    let text = getString(a, 0)
    whenLoaded(proc(x: var App) = x.ed.insertText(text))
  host("runCommand"):
    let name = getString(a, 0)
    whenLoaded(proc(x: var App) =
      if gCommands.hasKey(name): gCommands[name].run(x)
      else: x.msg = "config: no command named " & name)
  host("currentFile"):
    setResult(a, (if gLiveApp != nil: gLiveApp[].filePath else: ""))
  host("envVar"):
    setResult(a, getEnv(getString(a, 0)))
  host("formatNow"):
    setResult(a, now().format(getString(a, 0)))

proc applyNewExecPaths() =
  ## addExecPath after startup: setupExecPath has already run, so extend PATH.
  let current = getEnv("PATH").split(PathSep)
  var added: seq[string]
  for dir in gExtraPaths:
    let full = if dir.startsWith("~"): expandTilde(dir) else: dir
    if full notin current and full notin added: added.add full
  if added.len > 0: putEnv("PATH", (added & current).join($PathSep))

proc loadVmConfig*(app: var App; atStartup = false): string =
  ## Evaluate the config and, if that succeeds, commit it. Returns the message
  ## for the status bar. A failure leaves the active config untouched.
  let path = userVmConfigPath()
  if not fileExists(path):
    restoreBaseline()
    if gInterp != nil:
      destroyInterpreter(gInterp)
      gInterp = nil
    return "no config at " & path & " -- M-x edit-config creates it"

  var fresh: Interpreter
  gOps = @[]
  gProcRefs = @[]
  gLoading = true
  try:
    let lib = vmRuntimeDir() / "lib"
    fresh = createInterpreter(path,
      [lib, lib / "pure", lib / "core", lib / "pure" / "collections",
       lib.parentDir / "host", path.parentDir])
    fresh.registerErrorHook(proc(config: ConfigRef; info: TLineInfo; msg: string;
                                 sev: Severity) {.gcsafe.} =
      # The compiler reports errors from speculative `compiles` checks too, with
      # output silenced. Those are meant to fail quietly.
      if sev == Severity.Error and config.m.errorOutputs != {}:
        raise newException(VmConfigError, toFileLineCol(config, info) & ": " & msg)
      # The VM announces `quit` just before it exits the process. Raising here
      # is the only way in: a stray quit must not take the sessions down.
      if sev == Severity.Hint and "quit() called" in msg:
        raise newException(VmConfigError, "quit is not allowed in a config"))
    bindHostApi(fresh)
    fresh.evalScript(llStreamOpen(readFile(path)))
    for name in gProcRefs:
      if fresh.selectRoutine(name) == nil:
        raise newException(VmConfigError, "no exported proc named " & name & " (is it marked with *?)")
  except VmConfigError, IOError, OSError, ValueError:
    let e = getCurrentException()
    gLoading = false
    gOps = @[]
    if fresh != nil: destroyInterpreter(fresh)
    return "config error, previous config kept: " &
      e.msg.splitLines().filterIt(it.strip.len > 0)[0]
  gLoading = false

  let previous = gInterp
  let ops = gOps
  gOps = @[]
  restoreBaseline()
  gInterp = fresh
  for op in ops: op(app)
  if previous != nil: destroyInterpreter(previous)
  if not atStartup: applyNewExecPaths()
  result = "config reloaded from " & path

proc reloadVmConfig(app: var App): string =
  result = loadVmConfig(app)

proc vmConfigStartup*(app: var App) =
  ## Called once, after the compiled config and the extensions.
  captureBaseline()
  gVmReload = reloadVmConfig
  if fileExists(userVmConfigPath()):
    let outcome = loadVmConfig(app, atStartup = true)
    if outcome.startsWith("config error"): app.msg = outcome
