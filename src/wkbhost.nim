## wkbenchless host API for the interpreted config (config.nims).
##
## These are the signatures a config compiles against. The bodies are stubs:
## wkbvmconfig.nim binds each one to native code when the VM loads the config.
## Everything here is applied atomically: if the config fails to load, nothing
## it asked for takes effect and the previous config stays active.
##
## Pure stdlib modules work (strutils, sequtils, tables, sets, ...). Modules that
## call native code do not (std/os, std/times, ...): use envVar and formatNow.

# -- applied when the config loads -------------------------------------------
proc bindkey*(chord, command: string) = discard
  ## Bind a chord ("C-c d", "M-x") to a command name.
proc unbindkey*(chord: string) = discard
  ## Remove a binding, including one made by the compiled config.
proc defcommand*(name, label, procName: string) = discard
  ## Register a palette command that runs the config proc named `procName`.
  ## It takes no arguments and must be exported (`proc name*()`), or the config
  ## fails to load.
proc addHook*(event, procName: string) = discard
  ## Run the exported config proc named `procName` at an editor event
  ## ("startup", "after-babel", ...). "startup" fires once per launch, so a
  ## reload does not run it again.
proc defineRemoteMethod*(name, loginCmd: string) = discard
  ## A TRAMP-style method for `:dir "/ssh:host|NAME:user@host:/path"`.
proc addExecPath*(dir: string) = discard
  ## Prepend a directory to PATH for sessions and terminals (~ expanded).
  ## A removed line leaves the directory on PATH until the editor restarts.
proc setReadingMargin*(ext: string; px: int) = discard
  ## Side margin in pixels for files with this extension (no dot).
proc addCorpusRoot*(dir: string) = discard
  ## A folder of manuscripts to index for citation context.
proc applyTheme*(name: string) = discard
  ## Switch to a registered theme by name.

proc setStringOpt(name, value: string) = discard
proc setIntOpt(name: string; value: int) = discard
proc setBoolOpt(name: string; value: bool) = discard
proc setOpt*(name: string; value: string) = setStringOpt(name, value)
  ## String settings: gClaudeCmd, gTerminalDir, gZoteroDir.
proc setOpt*(name: string; value: int) = setIntOpt(name, value)
  ## Integer settings: gRemoteLaunchTimeout, gLatexDpi.
proc setOpt*(name: string; value: bool) = setBoolOpt(name, value)
  ## Boolean settings: gBufferTabs, gClaudeDiffHooks, gClaudeMod.

# -- editor operations, for commands and hooks -------------------------------
proc status*(msg: string) = discard
  ## Show a message in the status bar.
proc insertText*(text: string) = discard
  ## Insert text at the cursor.
proc runCommand*(name: string) = discard
  ## Run any M-x command by name.
proc currentFile*(): string = ""
  ## The path of the current buffer ("" for a scratch buffer).
proc envVar*(name: string): string = ""
  ## An environment variable ("" if unset).
proc formatNow*(format: string): string = ""
  ## The current local time, as in std/times.format: formatNow("yyyy-MM-dd").
