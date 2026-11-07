## wkbenchless interpreted config: real Nim, run by the embedded VM.
##
## Press C-c r (M-x reload-config) to apply changes. There is no recompile and
## no restart, and sessions keep running. If this file has an error, the status
## bar shows it and the previous config stays active.
##
## Deep changes that need direct access to the editor model (App) still belong
## in the compiled wkbconfig.nim (M-x edit-compiled-config, then M-x rebuild).
## This file loads after it, so settings here win.
import wkbhost
import std/strutils

# Key bindings.
# bindkey("C-c d", "insert-date")

# Remote session methods, for org `:dir` headers.
# defineRemoteMethod("gpu", "env SHELL=/bin/sh qsub -I -q gpu -l ncpus=8")

# Settings.
# setOpt("gRemoteLaunchTimeout", 600)
# setOpt("gBufferTabs", true)
# setOpt("gClaudeCmd", "claude --continue || claude")

# A command is an exported proc, registered by name.
proc shoutFileName*() =
  status(currentFile().toUpperAscii)
defcommand("shout-file-name", "Show the file name in capitals", "shoutFileName")

proc insertDate*() =
  insertText(formatNow("yyyy-MM-dd"))
defcommand("insert-today", "Insert today's date", "insertDate")
