## The interpreted config: reload applies changes in place, a removed line goes
## away, and a broken config leaves the active one untouched. Needs a build with
## the VM (see config.nims); otherwise there is nothing to test.
when not defined(wkbVmConfig):
  echo "vmconfig: skipped (built without the VM)"
else:
  import wkbcore, wkbvmconfig
  import std/[os, strutils, tables]

  let dir = getTempDir() / "wkb-test-vmconfig"
  createDir(dir)
  let cfg = dir / "config.nims"
  putEnv("WKB_VM_CONFIG", cfg)

  proc write(src: string) = writeFile(cfg, "import wkbhost\n" & src)

  registerBuiltins()
  bindkey("C-c z", "palette")       # stands in for a compiled binding
  gRemoteMethods["workq"] = "qsub -I -q workq"
  var app: App
  app.termActive = -1
  app.filePath = "/tmp/note.org"
  app.ed.setText("")
  vmConfigStartup(app)

  template reload(): string =
    reloadConfig(app)
    app.msg

  # A new remote method needs no rebuild.
  doAssert "giant" notin gRemoteMethods
  write """defineRemoteMethod("giant", "qsub -I -l select=1:host=giant")
bindkey("C-c q", "palette")
setOpt("gRemoteLaunchTimeout", 77)
setOpt("gBufferTabs", true)
setOpt("gClaudeCmd", "claude")
"""
  doAssert reload().startsWith("config reloaded"), app.msg
  doAssert gRemoteMethods["giant"] == "qsub -I -l select=1:host=giant"
  doAssert gRemoteMethods["workq"] == "qsub -I -q workq"     # compiled entry kept
  doAssert gKeymap["C-c q"] == "palette"
  doAssert gRemoteLaunchTimeout == 77 and gBufferTabs and gClaudeCmd == "claude"

  # A broken config changes nothing, whatever kind of error it has.
  for broken in ["""bindkey("C-c w", "palette")
bindkey("C-c w", 1)
""", """bindkey("C-c w", "palette")
import no_such_module
""", """bindkey("C-c w", "palette")
let v = @[1]
status($v[5])
""", """bindkey("C-c w", "palette")
setOpt("gNoSuchSetting", 1)
""", """bindkey("C-c w", "palette")
defcommand("x", "x", "noSuchProc")
""", "bindkey(\"C-c w\"\n"]:
    write broken
    doAssert reload().startsWith("config error, previous config kept"), app.msg
    doAssert "C-c w" notin gKeymap, broken
    doAssert gRemoteMethods.hasKey("giant"), broken
    doAssert gRemoteLaunchTimeout == 77, broken

  # Removing a line removes its effect, and compiled values come back.
  write """unbindkey("C-c z")
"""
  doAssert reload().startsWith("config reloaded"), app.msg
  doAssert "giant" notin gRemoteMethods and "C-c q" notin gKeymap
  doAssert "C-c z" notin gKeymap
  doAssert gRemoteLaunchTimeout == 600 and not gBufferTabs
  write ""
  doAssert reload().startsWith("config reloaded"), app.msg
  doAssert gKeymap["C-c z"] == "palette"        # unbindkey undone with its line

  # A proc the host calls must be exported, and the error says so.
  write """proc hidden() = status("x")
defcommand("hidden", "Hidden", "hidden")
"""
  doAssert "marked with *" in reload(), app.msg

  # A command and a hook run in the VM, and reach the editor.
  write """import std/strutils
var calls = 0
proc shout*() =
  inc calls
  status(currentFile().toUpperAscii & " " & $calls)
proc onEvent*() = status("hook ran")
defcommand("shout", "Shout", "shout")
addHook("test-event", "onEvent")
"""
  doAssert reload().startsWith("config reloaded"), app.msg
  gCommands["shout"].run(app)
  doAssert app.msg == "/TMP/NOTE.ORG 1", app.msg
  gCommands["shout"].run(app)
  doAssert app.msg == "/TMP/NOTE.ORG 2", app.msg     # VM state survives calls
  runHooks(app, "test-event")
  doAssert app.msg == "hook ran", app.msg
  write ""
  doAssert reload().startsWith("config reloaded"), app.msg
  doAssert "shout" notin gCommands and "test-event" notin gHooks

  # An error inside a command reaches the status bar, not the process.
  write """proc boom*() =
  let v = @[1]
  status($v[5])
defcommand("boom", "Boom", "boom")
"""
  doAssert reload().startsWith("config reloaded"), app.msg
  gCommands["boom"].run(app)
  doAssert app.msg.startsWith("config:"), app.msg

  # `quit` in a config is an error, never the end of the editor.
  write """bindkey("C-c v", "palette")
quit(3)
"""
  doAssert "quit is not allowed" in reload(), app.msg
  doAssert "C-c v" notin gKeymap
  write """proc leave*() = quit(4)
defcommand("leave", "Leave", "leave")
"""
  doAssert reload().startsWith("config reloaded"), app.msg
  gCommands["leave"].run(app)
  doAssert "quit is not allowed" in app.msg, app.msg

  # Globals keep working: `var` in a config relies on the VM's REPL mode.
  write """var n = 41
proc bump*() =
  inc n
  status($n)
defcommand("bump", "Bump", "bump")
"""
  doAssert reload().startsWith("config reloaded"), app.msg
  gCommands["bump"].run(app)
  doAssert app.msg == "42", app.msg

  # Host helpers stand in for std/os and std/times, which the VM cannot run.
  write """proc dated*() =
  insertText(formatNow("yyyy"))
  status(envVar("WKB_VM_CONFIG"))
defcommand("dated", "Dated", "dated")
"""
  doAssert reload().startsWith("config reloaded"), app.msg
  gCommands["dated"].run(app)
  doAssert app.msg == cfg, app.msg
  doAssert app.ed.fullText().len == 4, app.ed.fullText()

  # Reloading repeatedly is stable.
  write """defineRemoteMethod("giant", "x")
"""
  for _ in 1 .. 30:
    doAssert reload().startsWith("config reloaded"), app.msg
  doAssert gRemoteMethods["giant"] == "x"

  # No file at all: back to the compiled baseline.
  removeFile(cfg)
  doAssert reload().startsWith("no config at"), app.msg
  doAssert "giant" notin gRemoteMethods

  removeDir(dir)
  echo "vmconfig ok"
