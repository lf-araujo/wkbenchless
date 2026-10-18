## wkbenchless core: the editor model that user config can touch DIRECTLY -- the point
## of the pure-Nim rewrite. There is no ABI boundary: the host (wkbenchless.nim) does
## rendering, the user config (wkbconfig.nim) imports this module and calls
## defcommand / bindkey / registerRepl / addHook against the exact same App and
## SynEdit types the host uses. Commands are Nim procs; keys and languages are
## data; hooks fire at editor events.

import uirelays              # vendored: src/vendor/uirelays (see config.nims path)
import widgets/synedit          # our patched SynEdit (langR/langOrg, inline images)
import wkbsession
import wkblsp                    # pure std/json LSP client -- portable, no GTK
import wkbref                    # reference context: prose/notes/paper by citekey
import wkbblocks                 # src blocks as a dependency graph (hashes, :depends)
import std/[tables, strutils, os, osproc, algorithm, times, sets, sequtils,
           json]
import checksums/sha1         # std/sha1 is deprecated (moves out of stdlib)
when defined(posix): import std/posix

export uirelays, synedit, wkbsession, wkblsp, wkbref, wkbblocks   # config sees Event/SynEdit/ReplSpec/LspClient/gCorpusRoots/...
  # uirelays + `synedit` above come from the vendored tree in src/vendor/uirelays

type
  Terminal* = object
    pty*: Pty                            ## the live PTY (host pumps/renders it)
    label*: string                       ## tab label ("bash", "claude", ...)
    cmd*: string                         ## the shell command it runs
    started*: bool                       ## host has spawned the PTY at least once

  JobKind* = enum jkBlock, jkEval, jkCacheLoad, jkFetch
  AppJob* = object
    ## An async run the editor tracks: a babel block (its results replace
    ## `placeholder` in the buffer `filePath` when it finishes) or an ad-hoc eval.
    kind*: JobKind
    job*: RunJob
    sessKey*: string                      ## app.sessions key that runs it
    label*: string                        ## "r block @line 42" / "r eval"
    filePath*: string                     ## target buffer (jkBlock)
    placeholder*: string                  ## unique `#+RESULTS` line to replace
    fileOut*: string                      ## `:file` graphics output, if any
    localPath*: string                    ## jkFetch: where the fetched file goes
    rawResults*: bool
    drawerResults*: bool                  ## `:results drawer`: raw, in :RESULTS:/:END:
    hash*: string                         ## block content hash ("" if none)
    fromCtl*: bool                        ## started over the control socket (Claude)
    applied*: bool                        ## results written back (or given up)

  App* = object
    ed*, sess*, objects*, help*: SynEdit
    sessions*: Table[string, Session]     ## key: langId & "/" & sessionName
    jobs*: seq[AppJob]                    ## async runs: in flight + recent history
    lastJobIds*: seq[int]                 ## ids queued by the last babel command
    ranIn*: Table[string, HashSet[string]] ## session key -> block hashes run OK in it
    ctlOrigin*: bool                      ## a control-socket request is being handled
    ctlReturnTab*: int                    ## terminal tab to return to after ctl runs
    ctlReturnSet*: bool                   ## ctlReturnTab is pending
    curLang*, curSession*: string         ## the session objects/help track
    docLang*: string                      ## the buffer's LSP languageId ("" = none)
    lsp*: Table[string, LspClient]        ## langId -> language server
    font*: Font
    bigFont*: Font                        ## larger font for org headers/headings
    fontSize*: int                        ## desired editor font size (host applies)
    filePath*, msg*: string
    activeDiskMtime*: times.Time          ## mtime of app.filePath at last load/save
                                          ## (used by autoRevertActive)
    running*: bool
    srcEdit*: bool                        ## 4-quadrant (objects+help) vs plain
    pendingPrefix*: string
    lastBlockOutput*: string              ## captured output of the last babel run
    buffers*: seq[BufferState]            ## all open buffers (snapshots)
    curBuf*: int                          ## index of the active buffer
    pendingKill*: bool                    ## a kill-buffer of a dirty buffer awaits confirm
    pendingQuit*: bool                    ## a quit with unsaved buffer(s) awaits confirm
    pendingRevert*: bool                  ## a revert-buffer of a dirty buffer awaits confirm
    paletteActive*: bool
    paletteMode*: PaletteMode
    paletteQuery*: string
    paletteSel*: int
    paletteDir*: string                   ## current directory in pmFiles mode
    palettePrompt*: string                ## pmPrompt: the prompt text to show
    completionActive*: bool
    completionItems*: seq[string]
    completionSel*: int
    completionPrefix*: string
    searchActive*: bool                   ## find / find-replace minibuffer shown
    searchMode*: SearchMode
    searchField*: SearchField             ## which minibuffer field is being edited
    searchQuery*: string                  ## the needle
    searchReplace*: string                ## replacement text (smReplace)
    searchMatches*: seq[int]              ## buffer offsets of every match
    searchMatchEnds*: seq[int]            ## each match's end offset (exclusive)
    searchIdx*: int                       ## index into searchMatches (current)
    searchCase*: bool                     ## case-sensitive matching ("Aa")
    searchRegex*: bool                     ## the needle is a regex (".*")
    searchWord*: bool                      ## whole-word matches only ("ab")
    searchHistory*: seq[string]            ## past needles, newest first (Up in the panel)
    searchHistIdx*: int                    ## -1 = typing fresh; else index into history
    searchDraft*: string                   ## the half-typed needle saved on first Up
    replaceHistory*: seq[string]           ## past replacements, newest first
    replaceHistIdx*: int
    replaceDraft*: string
    snaps*: seq[tuple[t: float; text: string]]  ## time-versioned snapshots (history)
    histPreview*: int                     ## history palette entry being diff-previewed
    lastSeenDepth*: int                   ## undo depth last frame (activity tracking)
    lastActivity*: float                  ## epoch of the last buffer edit
    lastSnapAt*: float                    ## epoch of the last history snapshot
    focus*: string                        ## which pane gets keyboard events
    theme*: AppTheme                      ## active theme (chrome + editor)
    themeIdx*: int                        ## index into gThemes
    vimEnabled*: bool                     ## modal (vim) editing
    vimMode*: VimMode
    vimPending*: string                   ## pending operator/prefix (d, g, y)
    sessionHidden*: bool                  ## bottom panel hidden (x on the tab bar)
    terminals*: seq[Terminal]             ## standalone terminals (bash, claude, ...), one tab each
    termActive*: int                      ## index into `terminals` shown now, -1 if none
    termScroll*: int                      ## bottom-pane scrollback: lines up from tail
    reloadPending*: bool                  ## recompile done -> host snapshots + re-execs
    reloadBin*, reloadFile*: string       ## the freshly built binary + file to reopen
    reloadLine*: int                      ## cursor line to restore
    # two-pane diff view (Claude/agents push a before/after via wkbctl)
    diffActive*: bool
    diffTitle*: string
    diffL*, diffR*: seq[string]           ## aligned old / new lines
    diffLK*, diffRK*: seq[char]           ## per row: ' ' same, '-' removed, '+' added
    diffScroll*: int
    diffPath*: string                     ## file the diff is about ("" if unknown)
    diffJumpLine*: int                    ## 0-based line of the first change in it
    diffTokens*: bool                     ## word-level inline view (prose) vs side-by-side
    diffInline*: seq[InlineRow]           ## the word-level view's content
    diffSerial*: int                      ## bumps on every showDiff (layout cache key)
    diffShownAt*: float                   ## epochTime the diff appeared
    diffPinned*: bool                     ## user interacted: no auto-close
    # src-edit (org-edit-special / tangle): the buffer temporarily *becomes* the
    # extracted code; on exit it is spliced/detangled back into the org doc.
    editMode*: EditMode
    orgSaved*: seq[string]                ## the org document, by line
    orgFilePath*: string
    editRanges*: seq[tuple[a, b, indent: int]]  ## body ranges [a,b) in orgSaved
  InlineRow* = object
    ## One paragraph of the word-level diff: segments of (text, kind) with kind
    ## '=' unchanged, '-' removed, '+' added ("\n" inside text breaks the line);
    ## or a gap marker for `gap` unchanged lines that are not shown.
    segs*: seq[tuple[text: string; kind: char]]
    gap*: int
  Command* = object
    label*: string
    run*: proc(app: var App)
  Hook* = proc(app: var App)
  EditMode* = enum emNone, emBlock, emSession
  PaletteMode* = enum pmCommands, pmBuffers, pmFiles, pmThemes, pmOrg, pmRecent,
                   pmSaveAs, pmExport, pmHistory, pmPrompt
  ExportTarget* = tuple[id, label, cmd: string]   ## palette entry: id -> command
  SearchMode* = enum smFind, smReplace
  SearchField* = enum sfQuery, sfReplace
  VimMode* = enum vmNormal, vmInsert
  BufferState* = object
    ed*: SynEdit
    filePath*, docLang*: string
  Base16* = array[16, Color]   ## base00..base0F, a standard base16 palette
  AppTheme* = object
    ## One theme drives BOTH the editor buffers (`ed`: a SynEdit Theme) and the
    ## host chrome (panels, status bar, tabs, terminal, palette). Built from a
    ## base16 palette by `base16Theme`, or hand-tuned in the config.
    name*: string
    ed*: Theme                 ## editor/buffer colors (synedit)
    srcBlockBg*: Color         ## org src-block shading in the editor
    windowBg*, panelBg*, tabBarBg*: Color
    statusBg*, statusFg*: Color
    chipBg*, chipFg*, chipActiveBg*, chipActiveFg*: Color
    termFg*, dimFg*, dividerColor*: Color
    boxBg*, boxSelBg*, boxFg*: Color        ## palette / completion popups
    closeBg*, closeFg*: Color               ## the per-tab [X] close button
    minBg*: Color                           ## the [_] minimize button

var
  gCommands*: OrderedTable[string, Command]
  gLastCommand*: string                   ## last command run from the palette
                                          ## (M-x reopens preselecting it)
  gKeymap*: Table[string, string]         ## chord (or "C-c C-c") -> command name
  gReadingMargins*: Table[string, int]    ## file ext (no dot, lowercase) -> px side margin; 0/absent = none
  gRepls*: Table[string, ReplSpec]        ## langId -> interpreter spec
  gHooks*: Table[string, seq[Hook]]       ## event name -> hooks
  gObjectsQuery*: Table[string, string]   ## langId -> code listing the env
  gHelpQuery*: Table[string, string]      ## langId -> code, {word} substituted
  gRebuildCmd*: string                    ## shell command C-c r runs to rebuild
  gLspServers*: Table[string, string]     ## langId -> server command (argv, space-split)
  gThemes*: seq[AppTheme]                 ## themes the config registers (palette picks one)
  gExtraPaths*: seq[string]               ## dirs to prepend to PATH (config; ~ ok)
  gLoadLoginPath* = true                  ## seed PATH from the login shell at startup
  gClaudeCmd* = "claude --continue || claude"  ## command the `claude` action runs (config)
  gClaudeDiffHooks* = true                 ## inject --settings diff-on-edit hooks when
                                           ## launching claude, so its file edits pop into
                                           ## this editor's diff pane (config; set false off)
  gSshPersist* = "600"                    ## seconds an ssh master connection persists
  gRemoteMethods*: Table[string, string]  ## TRAMP-style :dir method -> login command
                                          ## run on the host first (defineRemoteMethod)
  gRemoteLaunchTimeout* = 600             ## seconds to wait for each remote login
  gRemoteTmux* = true                     ## remote REPLs live in a tmux session on
                                          ## the host: they survive a dropped
                                          ## connection and are reattached
                                          ## step's shell (e.g. a qsub -I queue wait)
  gInlineImageWidth* = 0                   ## default inline image width in px
                                           ## (org #+ATTR_* :width overrides it);
  gBufferTabs* = false                     ## show a tab per open buffer in the top
                                           ## toolbar (click to switch, [x] to close)
                                           ## 0 = use each image's native size
  gLatexDpi* = 140                         ## dvipng resolution for M-x latex-preview
                                           ## math images (higher = larger/crisper)

# -- registry (the config surface) -----------------------------------------
proc defcommand*(name, label: string; run: proc(app: var App)) =
  gCommands[name] = Command(label: label, run: run)
proc bindkey*(chord, name: string) = gKeymap[chord] = name
proc openPalette*(app: var App; mode: PaletteMode)   # defined below; fwd for openExportPalette
proc loadHistory*(app: var App)               # fwd: document history, below
proc persistUndo*(app: var App)
proc takeSnapshot*(app: var App)
proc relTime*(t: float): string
var gExportTargets*: seq[ExportTarget]   ## registered Export-button targets
var gPromptHandler*: proc(app: var App; text: string)  ## pmPrompt accept callback
var gStatusCircle*: Color = color(0xb0, 0xb0, 0xb0)  ## status circle: gray=offline
proc registerExport*(id, label, cmd: string) =
  ## Add a target to the Export button's palette ("Export…" opens it).
  gExportTargets.add (id, label, cmd)
proc openExportPalette*(app: var App) = openPalette(app, pmExport)
proc setReadingMargin*(ext: string; px: int) =
  ## Side margin (px) for files with this extension (no dot), e.g. "org", "rmd".
  gReadingMargins[ext.toLowerAscii] = px
proc registerRepl*(langId: string; spec: ReplSpec) =
  gRepls[langId.toLowerAscii] = spec
proc defineRemoteMethod*(name, loginCmd: string) =
  ## A TRAMP-style method for `:dir "/ssh:host|NAME:user@host:/path"` (or
  ## `/NAME:user@host:/path`): after ssh logs in to host, `loginCmd` replaces the
  ## login shell (e.g. `qsub -I -q workq` -> an interactive job's shell on a
  ## compute node), and the interpreter is started in THAT shell, in the path.
  gRemoteMethods[name] = loginCmd
type CtlVerbProc* = proc(app: var App; args: seq[string]; body: string): string
var
  gCtlVerbs*: Table[string, CtlVerbProc]  ## extra `wkbctl` verbs (extensions register)
  gCtlVerbHelp*: Table[string, string]     ## verb -> one-line usage, for `wkbctl help`
proc registerCtlVerb*(name, help: string; handler: CtlVerbProc) =
  ## Extensions add control-socket verbs; wkbctrl dispatches unknown verbs here.
  ## `help` is surfaced by `wkbctl help` so agents can discover verbs at runtime.
  gCtlVerbs[name.toLowerAscii] = handler
  gCtlVerbHelp[name.toLowerAscii] = help
proc addHook*(name: string; h: Hook) =
  gHooks.mgetOrPut(name, @[]).add h
proc runHooks*(app: var App; name: string) =
  if gHooks.hasKey(name):
    for h in gHooks[name]: h(app)

proc addExecPath*(dir: string) =
  ## Config helper: add a directory to PATH for sessions/terminals (~ expanded).
  gExtraPaths.add dir

proc setupExecPath*() =
  ## Make the login shell's PATH (plus gExtraPaths) the process PATH, so
  ## sessions, terminals, and findExe locate the user's executables even when
  ## wkbenchless was launched from a GUI with a stripped-down environment.
  ## Called once at startup, after configure() so gExtraPaths is set, before any
  ## session or terminal spawns. Order: extra paths first (highest priority),
  ## then the login shell's PATH, then whatever we already inherited.
  var parts: seq[string]
  proc addDir(d: string) =
    let e = (if d.startsWith("~"): expandTilde(d) else: d)
    if e.len > 0 and e notin parts: parts.add e
  for p in gExtraPaths: addDir(p)
  if gLoadLoginPath:
    let sh = getEnv("SHELL", "/bin/bash")
    try:
      let (outp, code) = execCmdEx(sh & " -lc 'printf %s \"$PATH\"'")
      if code == 0:
        for p in outp.strip.split(':'): addDir(p)
    except CatchableError: discard
  for p in getEnv("PATH").split(':'): addDir(p)
  if parts.len > 0: putEnv("PATH", parts.join(":"))

# -- themes: a base16 palette -> full editor + chrome theme ------------------
proc rgb*(hex: int): Color =
  ## 0xRRGGBB -> Color, so a config spells a palette the way base16 files do.
  color(uint8((hex shr 16) and 0xFF), uint8((hex shr 8) and 0xFF), uint8(hex and 0xFF))

proc nudged(c: Color; d: int): Color =
  ## Shift each channel toward the middle by `d` (for the src-block lift).
  proc n(v: int): uint8 = uint8(if v < 128: min(255, v + d) else: max(0, v - d))
  color(n(c.r.int), n(c.g.int), n(c.b.int))

proc base16Theme*(name: string; b: Base16): AppTheme =
  ## Derive a full theme from base16 slots using the standard styling guide:
  ## base00 bg .. base05 default fg; base08..0F the accent colors.
  result.name = name
  var t = default(Theme)
  for tc in low(TokenClass)..high(TokenClass): t.fg[tc] = b[0x5]   # default text
  t.fg[TokenClass.Keyword] = b[0xE]
  t.fg[TokenClass.Preprocessor] = b[0xE]
  t.fg[TokenClass.Directive] = b[0xC]
  t.fg[TokenClass.Comment] = b[0x3]
  t.fg[TokenClass.LongComment] = b[0x3]
  t.fg[TokenClass.MarkdownFence] = b[0x3]
  for tc in [TokenClass.StringLit, TokenClass.LongStringLit, TokenClass.CharLit,
             TokenClass.RawData, TokenClass.Backticks, TokenClass.Key]:
    t.fg[tc] = b[0xB]                                              # strings: green
  for tc in [TokenClass.DecNumber, TokenClass.BinNumber, TokenClass.HexNumber,
             TokenClass.OctNumber, TokenClass.FloatNumber, TokenClass.Value,
             TokenClass.Label, TokenClass.Reference]:
    t.fg[tc] = b[0x9]                                              # numbers: orange
  t.fg[TokenClass.EscapeSequence] = b[0xC]
  t.fg[TokenClass.RegularExpression] = b[0xC]
  t.fg[TokenClass.Link] = b[0xD]
  t.fg[TokenClass.Command] = b[0xD]     # function names / calls: blue
  t.fg[TokenClass.Rule] = b[0xA]
  for tc in [TokenClass.TagStart, TokenClass.TagStandalone, TokenClass.TagEnd,
             TokenClass.Assembler]:
    t.fg[tc] = b[0xA]
  t.fg[TokenClass.Green] = b[0xB]
  t.fg[TokenClass.Yellow] = b[0xA]
  t.fg[TokenClass.Red] = b[0x8]
  t.bg = b[0x0]
  t.selBg = b[0x2]
  t.bracketBg = b[0x3]
  t.cursorColor = b[0xD]
  t.lineNumColor = b[0x3]
  t.markerBg = b[0x2]
  t.scrollBarColor = b[0x2]
  t.scrollBarActiveColor = b[0x3]
  t.scrollTrackColor = b[0x1]
  t.activeLineBg = b[0x1]
  t.actionColor = b[0x2]
  t.closeColor = b[0xD]
  result.ed = t
  result.srcBlockBg = nudged(b[0x0], 8)
  # host chrome
  result.windowBg = b[0x0]; result.panelBg = b[0x0]; result.tabBarBg = b[0x1]
  result.statusBg = b[0x1]; result.statusFg = b[0x4]
  result.chipBg = b[0x1]; result.chipFg = b[0x5]
  result.chipActiveBg = b[0x2]; result.chipActiveFg = b[0xA]
  result.termFg = b[0x5]
  # On a light theme base03 (a pale grey) is too faint for dim text on the
  # near-white panel; use base04 so the scrollback/status hints stay readable.
  let light = b[0x0].r.int + b[0x0].g.int + b[0x0].b.int > 3 * 128
  result.dimFg = (if light: b[0x4] else: b[0x3])
  result.dividerColor = b[0x2]
  result.boxBg = b[0x1]; result.boxSelBg = b[0x2]; result.boxFg = b[0x5]
  result.closeBg = b[0x8]; result.closeFg = b[0x0]
  result.minBg = b[0xA]

proc registerTheme*(name: string; palette: Base16) =
  ## Register a base16 theme (the config surface). First registered = default.
  gThemes.add base16Theme(name, palette)
proc registerTheme*(t: AppTheme) = gThemes.add t   # a fully hand-tuned theme

proc applyTheme*(app: var App; idx: int) =
  ## Point every editor + the chrome at gThemes[idx].
  if idx < 0 or idx >= gThemes.len: return
  app.themeIdx = idx
  app.theme = gThemes[idx]
  let t = app.theme
  template paint(e: untyped) =
    e.theme = t.ed
    e.srcBlockBg = t.srcBlockBg
  paint(app.ed); paint(app.sess); paint(app.objects); paint(app.help)
  for b in app.buffers.mitems: paint(b.ed)
  app.msg = "theme: " & t.name

proc applyThemeByName*(app: var App; name: string) =
  for i in 0 ..< gThemes.len:
    if gThemes[i].name == name: applyTheme(app, i); return

proc defaultBase16*(): Base16 =
  ## A built-in dark palette (One-Dark-ish) so the app is never unstyled even
  ## if the config registers no theme. The config normally overrides this.
  [ rgb(0x15171b), rgb(0x20242d), rgb(0x2e3440), rgb(0x545b6b),
    rgb(0xa0a6b0), rgb(0xc8ccd4), rgb(0xe0e3e8), rgb(0xf0f2f5),
    rgb(0xe06c75), rgb(0xd19a66), rgb(0xe5c07b), rgb(0x98c379),
    rgb(0x56b6c2), rgb(0x61afef), rgb(0xc678dd), rgb(0xbe5046) ]

# -- persisted UI state (XDG config dir; e.g. ~/.config/wkbenchless/state.cfg) --
var gState*: Table[string, string]

proc stateDir*(): string = getConfigDir() / "wkbenchless"
proc statePath*(): string = stateDir() / "state.cfg"

proc loadState*() =
  gState.clear()
  let p = statePath()
  if fileExists(p):
    for line in readFile(p).splitLines():
      let eq = line.find('=')
      if eq > 0: gState[strutils.strip(line[0 ..< eq])] = strutils.strip(line[eq + 1 .. ^1])

proc setState*(key, val: string) =
  ## Remember a key and write the state file (created under the XDG config dir).
  gState[key] = val
  try:
    createDir(stateDir())
    var s = ""
    for k, v in gState: s.add k & " = " & v & "\n"
    writeFile(statePath(), s)
  except CatchableError as e:
    # In-memory state still holds the value for this session, but it will not
    # survive a restart -- say so instead of failing silently (a GUI has no
    # other channel here; stderr shows when run from a terminal).
    stderr.writeLine("wkbenchless: could not save state (" & e.msg & "): " &
      statePath())

proc sshControlPath*(): string =
  ## A per-user/host/port master socket shared by the interactive login and the
  ## marker sessions, so a password host is authenticated ONCE.
  getHomeDir() / ".ssh" / "wkb-cm-%C"

proc tmuxSessionName*(sessName: string; base: ReplSpec): string =
  ## "wkb-<session>-<interpreter>", tmux-safe (no ':' or '.'): the same name on
  ## every reconnect is what lets `new-session -A` find the running REPL.
  result = "wkb-"
  for c in sessName & "-" & (if base.argv.len > 0: extractFilename(base.argv[0]) else: "repl"):
    result.add(if c.isAlphaNumeric or c in {'-', '_'}: c else: '_')

proc remoteSpec(base: ReplSpec; host: string; dir = ""; meth = "";
                tmuxName = ""): ReplSpec =
  ## Wrap a REPL spec to run on `host` over ssh, so an org block executes on a
  ## remote machine and its output is captured the same way. `ssh -tt` forces a
  ## remote pty; the spec's env (PS1=, PYTHON_BASIC_REPL=1) is set remotely via
  ## `env`; ControlPath reuses an already-authenticated master (no password
  ## prompt). `dir` (if given) is the remote working directory (cd + exec).
  ## `meth` names a defineRemoteMethod login step (qsub -I ...) run first.
  result = base
  let ctrl = @["ssh", "-tt",
               "-o", "ControlPath=" & sshControlPath(),
               "-o", "ControlMaster=auto",
               "-o", "ControlPersist=" & gSshPersist, host]
  var remote: seq[string]
  if base.env.len > 0:
    remote.add "env"
    for (k, v) in base.env: remote.add k & "=" & v
  remote.add base.argv
  var cmd = "exec"
  for a in remote: cmd.add " " & quoteShell(a)
  if tmuxName.len > 0:
    # ssh runs tmux in control mode (one channel, a line protocol -- see the
    # adapter in wkbpty), creating the host session or reattaching to it. The
    # probe line says which, so a reattach skips the login and just re-primes.
    # Login + interpreter are typed into the pane, as on a TRAMP-style hop.
    # The pane starts a plain `sh -l` (login PATH, no .bashrc): an interactive
    # shell with line-editor add-ons (ble.sh) takes our burst of typed lines
    # for a paste and turns Enter into "insert newline", so nothing runs.
    result.tmuxName = tmuxName
    result.argv = ctrl & @["tmux has-session -t " & tmuxName & " 2>/dev/null" &
      " && echo WKBx\"\"TMUXOLD || echo WKBx\"\"TMUXNEW;" &
      " exec tmux -CC new-session -A -s " & tmuxName & " '/bin/sh -l'"]
    let hasMeth = meth.len > 0 and gRemoteMethods.hasKey(meth)
    result.launch = (if hasMeth: @["exec " & gRemoteMethods[meth]] else: @[]) &
                    @[(if dir.len > 0: "cd " & quoteShell(dir) & "; " else: "") & cmd]
    if hasMeth: result.launchTimeoutMs = gRemoteLaunchTimeout * 1000
  elif meth.len > 0 and gRemoteMethods.hasKey(meth):
    # Like TRAMP: an interactive login shell, then the method's login command
    # replaces it (waiting in a queue if need be), then the interpreter.
    result.argv = ctrl
    result.launch = @["exec " & gRemoteMethods[meth],
                      (if dir.len > 0: "cd " & quoteShell(dir) & "; " else: "") & cmd]
    result.launchTimeoutMs = gRemoteLaunchTimeout * 1000
  elif dir.len > 0:
    # ssh joins its arguments into ONE string for the remote shell, so pass the
    # command as one string (a `sh -c "..."` argv would lose its quoting).
    result.argv = ctrl & @["cd " & quoteShell(dir) & " && " & cmd]
  else:
    result.argv = ctrl & remote
  result.env = @[]           # applied remotely via `env` above, not locally
  # The interpreter can't read a temp file on this machine: stage each run's
  # code into ~/.wkbenchless-run on the host through the SAME channel the
  # interactive REPL is already using (writeBytesCode), relative to `dir` so
  # it lands wherever that REPL's cwd is. A second ssh connection used to copy
  # it there instead; some hosts (this cluster included) cap sessions per
  # connection, so that second channel got refused outright no matter how
  # many times the one channel it does allow logged back in -- the interactive
  # shell was already using the only slot the server would grant.
  let tag = "s" & $getCurrentProcessId() & "-" & $(epochTime() * 1000).int64
  result.stage = proc(pty: var Pty; code, nonce: string): string =
    if base.writeBytesCode == nil: return ""
    let f = ".wkbenchless-run/" & tag & "-" & nonce & ".src"
    let marker = "WKBSTAGE" & nonce
    var bytes = newSeq[byte](code.len)
    for i in 0 ..< code.len: bytes[i] = byte(code[i])
    pty.feed(base.writeBytesCode(bytes, f, marker))
    if marker in pty.readUntil(marker, timeoutMs = 15_000, mirror = false): f else: ""

proc specFor*(base: ReplSpec; name: string; dir = ""): ReplSpec =
  ## The spec a session called `name` runs: "name@user@host" (optionally
  ## "|method") is remote over ssh, a plain name local.
  let at = name.find('@')
  if at < 0 or at == name.len - 1: return base
  let target = name[at + 1 .. ^1]
  let bar = target.find('|')
  let tn = if gRemoteTmux: tmuxSessionName(name[0 ..< at], base) else: ""
  if bar < 0: remoteSpec(base, target, dir, tmuxName = tn)
  else: remoteSpec(base, target[0 ..< bar], dir, target[bar + 1 .. ^1], tn)

proc getSession*(app: var App; lang, name: string; dir = ""): Session =
  ## A session named "name@host" runs on `host` over ssh (remote REPL, in `dir`
  ## if given); a plain name runs locally. `dir` is used only when creating.
  let key = lang.toLowerAscii & "/" & name
  if app.sessions.hasKey(key) and app.sessions[key] != nil:
    if app.sessions[key].pty.alive or app.sessions[key].busy:
      return app.sessions[key]       # (a dead one with runs left fails them first)
    app.sessions.del(key)            # its REPL exited: start a fresh one
  if not gRepls.hasKey(lang.toLowerAscii): return nil
  var spec = specFor(gRepls[lang.toLowerAscii], name, dir)
  if '@' notin name:
    # Local REPLs start where org-babel starts them: in `:dir` if given (relative
    # to the file), else the org file's own directory -- not wherever the editor
    # process happens to be (often "/"), which broke every relative data path.
    let base = if app.filePath.len > 0: app.filePath.parentDir else: getCurrentDir()
    spec.cwd = if dir.len == 0: base elif dir.isAbsolute: dir else: base / dir
  let s = startSession(spec)
  if s != nil:
    app.sessions[key] = s
    app.ranIn.del(key)            # a fresh REPL has none of the earlier blocks' state
  s

const headerArgKeys = ["session", "dir", "results", "exports", "tangle", "eval",
  "var", "cache", "noweb", "comments", "padline", "hlines", "colnames",
  "rownames", "wrap", "file", "output-dir", "mkdirp", "ssh"]

proc parseSshDir*(v: string): tuple[host, path, meth: string] =
  ## TRAMP-style `/method:user@host:/path` -> (user@host, /path, method); a plain
  ## path -> ("", path, ""). Surrounding quotes are dropped (org allows `:dir "..."`).
  ## Multi-hop `/ssh:hop|method:user@host:/path` uses the last hop's host --
  ## `meth` is that hop's method ("" for ssh-like ones), which a
  ## defineRemoteMethod login step (e.g. `workq` -> qsub -I) can implement.
  let v = if v.len >= 2 and v[0] == '"' and v[^1] == '"': v[1 .. ^2] else: v
  let c0 = v.find(':')
  if not v.startsWith("/") or c0 < 0 or '/' in v[1 ..< c0]: return ("", v, "")
  let hop = v[1 .. ^1].split('|')[^1]        # "method:user@host:/path"
  let m = hop.find(':')
  if m < 0: return ("", v, "")
  let meth = hop[0 ..< m]
  let d = hop[m + 1 .. ^1]
  let c = d.find(':')
  let (host, path) = if c >= 0: (d[0 ..< c], d[c + 1 .. ^1]) else: (d, "")
  (host, path, if meth in ["ssh", "sshx", "scp", "scpx", "rsync"]: "" else: meth)

proc headerArgTokens*(app: App; lang: string): seq[string] =
  ## Default header args for `lang` from `#+PROPERTY: header-args[:LANG| LANG] ...`
  ## lines (both "header-args:R" and the "header-args R" spacing are accepted;
  ## all-language props first, language-specific appended so they win).
  var allLang, langSpec: seq[string]
  for i in 0 ..< app.ed.getLineCount():
    let ln = strutils.strip(app.ed.getLineText(i))
    if not ln.toLowerAscii.startsWith("#+property:"): continue
    var rest = strutils.strip(ln[ln.find(':') + 1 .. ^1])
    if not rest.toLowerAscii.startsWith("header-args"): continue
    rest = strutils.strip(rest["header-args".len .. ^1])
    let toks = strutils.splitWhitespace(rest)
    if toks.len == 0: continue
    var propLang = ""
    var start = 0
    let key0 = toks[0].strip(chars = {':'}).toLowerAscii
    if not (toks[0].startsWith(":") and key0 in headerArgKeys):
      propLang = key0; start = 1                 # a language token (":R" or "R")
    if propLang.len == 0: allLang.add toks[start .. ^1]
    elif propLang == lang.toLowerAscii: langSpec.add toks[start .. ^1]
  allLang & langSpec

proc currentSession*(app: var App): Session =
  ## The session the bottom pane tracks as a live terminal, or nil.
  let key = app.curLang.toLowerAscii & "/" & app.curSession   # keys use lower-lang
  if app.sessions.hasKey(key): app.sessions[key] else: nil

# -- keychords -------------------------------------------------------------
proc keyName*(k: KeyCode): string =
  if k in {KeyA..KeyZ}: return $chr(ord('a') + (ord(k) - ord(KeyA)))
  if k in {Key0..Key9}: return $chr(ord('0') + (ord(k) - ord(Key0)))
  if k in {KeyF1..KeyF12}: return "F" & $(ord(k) - ord(KeyF1) + 1)
  case k
  of KeyEnter: "Enter"
  of KeySpace: "Space"
  of KeySlash: "/"
  of KeyMinus: "-"
  of KeyEqual: "="
  of KeyPlus: "+"
  of KeyComma: ","
  of KeyPeriod: "."
  else: ""

proc chordOf*(e: Event): string =
  if e.kind != KeyDownEvent: return ""
  let kn = keyName(e.key)
  if kn.len == 0: return ""
  if CtrlPressed in e.mods: result &= "C-"
  if AltPressed in e.mods: result &= "M-"
  if ShiftPressed in e.mods: result &= "S-"
  result &= kn

proc isPrefix*(chord: string): bool =
  for k in gKeymap.keys:
    if k.startsWith(chord & " "): return true

# -- buffers ---------------------------------------------------------------
proc bufName*(b: BufferState): string =
  if b.filePath.len > 0: extractFilename(b.filePath) else: "*scratch*"

proc extToLangId(ext: string): string =
  case ext.toLowerAscii
  of ".nim", ".nims": "nim"
  of ".py", ".pyw": "python"
  of ".r": "r"
  of ".c", ".h": "c"
  of ".cpp", ".cxx", ".hpp": "cpp"
  of ".js": "javascript"
  else: ""

proc noteDiskMtime*(app: var App) =
  ## Record the active file's on-disk mtime, so autoRevertActive only fires on a
  ## *later* external change (not on our own load/save).
  app.activeDiskMtime =
    if app.filePath.len > 0 and fileExists(app.filePath):
      getLastModificationTime(app.filePath)
    else: times.Time()

proc syncActive*(app: var App) =
  ## Write the live active editor back into its buffer slot.
  if app.curBuf >= 0 and app.curBuf < app.buffers.len:
    app.buffers[app.curBuf] =
      BufferState(ed: app.ed, filePath: app.filePath, docLang: app.docLang)

proc activate(app: var App; idx: int) =
  let b = app.buffers[idx]
  app.ed = b.ed
  app.filePath = b.filePath
  app.docLang = b.docLang
  app.curBuf = idx
  app.noteDiskMtime()                     # baseline so we don't self-revert on switch

proc switchToBuffer*(app: var App; idx: int) =
  if idx < 0 or idx >= app.buffers.len or idx == app.curBuf: return
  app.syncActive()
  app.activate(idx)
  app.msg = "buffer: " & bufName(app.buffers[idx])

proc nextBuffer*(app: var App) =
  ## Cycle one buffer to the right (wraps) -- the toolbar's ▶, which reaches
  ## tabs overflowed off the tab line.
  if app.buffers.len < 2: app.msg = "no other buffers"; return
  switchToBuffer(app, (app.curBuf + 1) mod app.buffers.len)

proc prevBuffer*(app: var App) =
  ## Cycle one buffer to the left (wraps) -- the toolbar's ◀.
  if app.buffers.len < 2: app.msg = "no other buffers"; return
  switchToBuffer(app, (app.curBuf - 1 + app.buffers.len) mod app.buffers.len)

var gLastRevertCheck: float = 0.0        ## epochTime of last autoRevert poll

proc autoRevertActive*(app: var App): bool =
  ## Poll the active file's mtime; if it changed on disk since we last
  ## loaded/saved it AND the buffer has no unsaved edits, reload it in place
  ## (cursor preserved). Never clobbers unsaved edits — a modified buffer just
  ## gets a one-shot status message. Throttled so it costs nothing per frame.
  ## This is what keeps the buffer in sync when an external tool (an agent, a
  ## formatter, git) rewrites the file underneath the editor. Returns true if it
  ## changed anything visible (reloaded or set a status message), so the caller
  ## can redraw.
  if app.filePath.len == 0 or not fileExists(app.filePath): return false
  let now = epochTime()
  if now - gLastRevertCheck < 0.7: return false
  gLastRevertCheck = now
  let t = getLastModificationTime(app.filePath)
  if t <= app.activeDiskMtime: return false
  if app.ed.changed:                     # unsaved edits — do not clobber
    app.activeDiskMtime = t              # (and don't nag again for this change)
    app.msg = extractFilename(app.filePath) &
              " changed on disk (buffer modified — not reverted)"
    return true
  let pos = app.ed.cursor
  try: app.ed.loadFromFile(app.filePath)
  except CatchableError:
    app.msg = "auto-revert: cannot read " & extractFilename(app.filePath); return true
  app.ed.markSaved()
  app.ed.gotoPos(min(pos, app.ed.len))
  app.activeDiskMtime = t
  app.msg = "reverted " & extractFilename(app.filePath) & " (disk changed)"
  result = true

proc recentFilesPath(): string = getCacheDir() / "wkbenchless" / "recent"

proc loadRecentFiles*(): seq[string] =
  try:
    for line in lines(recentFilesPath()):
      let p = strutils.strip(line)
      if p.len > 0 and fileExists(p): result.add p
  except CatchableError: discard

proc noteRecentFile*(path: string) =
  if path.len == 0: return
  let abs = try: absolutePath(path) except CatchableError: path
  var recent = loadRecentFiles()
  recent.insert(abs, 0)
  var seen: seq[string]
  for p in recent:
    if p notin seen: seen.add p
    if seen.len >= 30: break
  try:
    createDir(recentFilesPath().parentDir)
    writeFile(recentFilesPath(), seen.join("\n"))
  except CatchableError: discard

proc applyOrgStartup*(app: var App)   # fwd decl: honours #+STARTUP: on open

proc openFile*(app: var App; path: string) =
  noteRecentFile(path)
  for i, b in app.buffers:
    if b.filePath == path: switchToBuffer(app, i); return   # already open
  var ed = createSynEdit(app.font)
  ed.theme = app.ed.theme      # inherit the active theme so new buffers match
  ed.bigFont = app.bigFont
  ed.setEmphasisFonts(app.ed.boldFont, app.ed.italicFont,
                      app.ed.boldItalicFont, app.ed.captionFont)
  ed.theme.fg[TokenClass.Link] = color(96, 160, 255)
  let ext = splitFile(path).ext
  ed.lang = fileExtToLanguage(ext)
  ed.showLineNumbers = ed.lang != langOrg   # on for code/prose; off for org
                                            # notebooks (toggle with C-c n)
  try: ed.loadFromFile(path)
  except CatchableError:
    app.msg = "could not open " & path; return
  if ed.lang in {langOrg, langMarkdown}:
    ed.setRenderFlag(rfInlineImages)          # [[file:x.bmp]] / ![](x.bmp) inline
    ed.imageBaseDir = parentDir(path)         # resolve relative image paths here
    ed.imageDefaultWidth = gInlineImageWidth  # 0 = native size
  if ed.lang in {langOrg, langMarkdown}:
    ed.foldAllPending = true
  app.syncActive()
  app.buffers.add BufferState(ed: ed, filePath: path, docLang: extToLangId(ext))
  app.activate(app.buffers.high)
  loadHistory(app)                             # snapshots + cross-session undo
  applyOrgStartup(app)                         # #+STARTUP: latexpreview / inlineimages
  app.msg = "opened " & extractFilename(path)

proc showInfoBuffer*(app: var App; name, text: string) =
  ## Show TEXT in a reusable, non-file info buffer named `*<name>*` (e.g.
  ## `*cite-context*`) -- always visible (unlike the src-edit-only side panes),
  ## org-fontified, and marked saved so a reload never writes it to disk.
  let tag = "*" & name & "*"
  var found = -1
  for i, b in app.buffers:
    if b.filePath == tag: found = i; break
  if found >= 0:
    switchToBuffer(app, found)
  else:
    var ed = createSynEdit(app.font)
    ed.theme = app.ed.theme
    ed.showLineNumbers = false
    ed.bigFont = app.bigFont
    ed.setEmphasisFonts(app.ed.boldFont, app.ed.italicFont,
                        app.ed.boldItalicFont, app.ed.captionFont)
    ed.lang = langOrg
    app.syncActive()
    app.buffers.add BufferState(ed: ed, filePath: tag, docLang: "")
    app.activate(app.buffers.high)
  app.ed.setText(text)
  app.ed.markSaved()                      # never dirty -> never saved on reload

# -- palette entries (commands / buffers / files) --------------------------
proc orgOutline*(app: App): seq[tuple[line: int; label: string]] =
  ## Navigable landmarks of the current org buffer: section headings, named /
  ## captioned src blocks, and figure / table captions. `line` is 0-based.
  var pendingName, pendingCaption = ""
  var pendingLine = -1
  let n = app.ed.getLineCount
  for i in 0 ..< n:
    let raw = app.ed.getLineText(i)
    let s = strutils.strip(raw)
    let low = s.toLowerAscii
    if s.len > 0 and s[0] == '*':
      var lvl = 0
      while lvl < s.len and s[lvl] == '*': inc lvl
      if lvl == s.len or s[lvl] == ' ':        # `*+ ` headline, not a *bold* line
        let title = strutils.strip(s[lvl .. ^1])
        result.add (i, repeat("  ", max(0, lvl - 1)) & "* " & title)
        pendingName = ""; pendingCaption = ""; pendingLine = -1
    elif low.startsWith("#+name:"):
      pendingName = strutils.strip(s["#+name:".len .. ^1])
      pendingLine = i
    elif low.startsWith("#+caption:"):
      pendingCaption = strutils.strip(s["#+caption:".len .. ^1])
      pendingLine = i
    elif low.startsWith("#+begin_src"):
      let parts = s.splitWhitespace()
      let lang = if parts.len >= 2: parts[1] else: ""
      let name = if pendingName.len > 0: pendingName
                 elif pendingCaption.len > 0: pendingCaption else: "(unnamed)"
      let jump = if pendingLine >= 0: pendingLine else: i
      result.add (jump, "  src[" & lang & "] " & name)
      pendingName = ""; pendingCaption = ""; pendingLine = -1
    elif low.startsWith("#+begin_") or low.startsWith("[[file:") or
         low.startsWith("#+results:"):
      if pendingCaption.len > 0:
        result.add ((if pendingLine >= 0: pendingLine else: i),
                    "  caption: " & pendingCaption)
      pendingName = ""; pendingCaption = ""; pendingLine = -1
    elif s.len == 0:
      pendingName = ""; pendingCaption = ""; pendingLine = -1

proc matchScore*(hay, needle: string): int =
  ## Rank a candidate against the (already lowercased) query: lower is better.
  ## Exact < prefix < word-boundary substring < plain substring; earlier hits
  ## rank above later ones. Assumes `needle` is non-empty and occurs in `hay`.
  let h = hay.toLowerAscii
  if h == needle: return 0
  if h.startsWith(needle): return 1
  let idx = h.find(needle)
  if idx < 0: return 100000
  if h[idx - 1] in {' ', '-', '_', '.', '/'}: return 100 + idx
  return 1000 + idx

proc paletteEntries*(app: App): seq[tuple[id, label: string]] =
  let q = app.paletteQuery.toLowerAscii
  case app.paletteMode
  of pmCommands:
    # Match the command NAME as well as its description, and show the name -- so
    # typing e.g. "cite" finds `cite-context` even when its label doesn't contain
    # that word. Rank so the best match is first (the selector starts at the top,
    # so a search never needs scrolling to reach the obvious hit).
    var scored: seq[tuple[score: int; id, label: string]]
    for name, c in gCommands:
      let nlow = name.toLowerAscii
      if q.len == 0 or q in nlow or q in c.label.toLowerAscii:
        let sc = if q.len == 0: 0
                 elif q in nlow: matchScore(name, q)
                 else: 100000 + matchScore(c.label, q)   # label-only hits rank last
        scored.add (sc, name, name & "  —  " & c.label)
    scored.sort(proc(a, b: (int, string, string)): int =
      result = cmp(a[0], b[0])
      if result == 0: result = cmp(a[1], b[1]))          # stable: then by name
    for s in scored: result.add (s.id, s.label)
  of pmBuffers:
    for i, b in app.buffers:
      let nm = bufName(b)
      if q.len == 0 or q in nm.toLowerAscii:
        let dirty = if b.ed.changed: " [+]" else: ""
        result.add ($i, nm & dirty & (if i == app.curBuf: "  (current)" else: ""))
  of pmFiles, pmSaveAs:
    result.add ("..", "../")
    var dirs, files: seq[tuple[id, label: string]]
    let filter = app.paletteMode == pmFiles
    for kind, path in walkDir(app.paletteDir):
      let nm = extractFilename(path)
      if nm.startsWith("."): continue
      if filter and q.len > 0 and q notin nm.toLowerAscii: continue
      if kind == pcDir: dirs.add (path, nm & "/")
      else: files.add (path, nm)
    dirs.sort(proc(a, b: (string, string)): int = cmp(a[1], b[1]))
    files.sort(proc(a, b: (string, string)): int = cmp(a[1], b[1]))
    result.add dirs; result.add files
  of pmThemes:
    for i in 0 ..< gThemes.len:
      let nm = gThemes[i].name
      if q.len == 0 or q in nm.toLowerAscii:
        result.add ($i, nm & (if i == app.themeIdx: "  (current)" else: ""))
  of pmHistory:
    # Snapshots newest first: id = index into app.snaps. The label shows the
    # age and the line delta vs the current buffer, so a scan of the list
    # already tells you where the text grew or shrank.
    let curLines = app.ed.getLineCount()
    for i in countdown(app.snaps.high, 0):
      let s = app.snaps[i]
      let lab = relTime(s.t)
      if q.len == 0 or q in lab.toLowerAscii:
        let dl = s.text.splitLines().len - curLines
        result.add ($i, lab & "  " & $s.text.splitLines().len & " lines" &
          (if dl != 0: "  (" & (if dl > 0: "+" else: "") & $dl & ")" else: "") &
          (if app.histPreview == i: "  [previewing -- Enter again to restore]" else: ""))
  of pmOrg:
    for (line, label) in orgOutline(app):
      if q.len == 0 or q in label.toLowerAscii:
        result.add ($line, label)
  of pmRecent:
    for p in loadRecentFiles():
      let nm = extractFilename(p)
      if q.len == 0 or q in p.toLowerAscii:
        result.add (p, nm & "    " & p.parentDir)
  of pmPrompt:
    discard   # free-text: the typed query is the answer, no list to filter
  of pmExport:
    # registered export targets (docx, notebook-html, ...): id -> command.
    # No match -> still show the list (the query is not a filter here), so the
    # palette works like a menu.
    for t in gExportTargets:
      result.add (t.id, t.label)

# -- objects / help panes --------------------------------------------------
proc isWordChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}

proc wordAtCursor*(app: App): string =
  let line = app.ed.getLineText(app.ed.currentLine)
  if line.len == 0: return ""
  var a = min(app.ed.currentCol, line.len - 1)
  if not isWordChar(line[a]) and a > 0: dec a   # cursor just past a word
  if not isWordChar(line[a]): return ""
  var s = a
  while s > 0 and isWordChar(line[s - 1]): dec s
  var e = a
  while e + 1 < line.len and isWordChar(line[e + 1]): inc e
  line[s .. e]

proc cleanOverstrike(s: string): string =
  ## R's Rd2txt renders bold/underline as "X\bX" / "_\bX"; drop the first glyph
  ## and the backspace, keeping what follows.
  var i = 0
  while i < s.len:
    if i + 1 < s.len and s[i + 1] == '\b': i += 2
    else: result.add s[i]; inc i

proc refreshObjects*(app: var App) =
  let lang = (if app.curLang.len > 0: app.curLang else: "r").toLowerAscii
  if not gObjectsQuery.hasKey(lang):
    app.objects.setText("(no objects query for " & lang & ")"); return
  let s = getSession(app, lang, (if app.curSession.len > 0: app.curSession else: "default"))
  if s == nil: app.objects.setText("(no session)"); return
  if s.busy or s.phase != spReady:   # a synchronous query would eat the job's
                                      # output, or hit a REPL still logging in
    app.objects.setText("Objects [" & lang & "/" & app.curSession & "]\n(session busy)")
    return
  let outp = s.runBlock(gObjectsQuery[lang], quiet = true)   # keep off the terminal
  app.objects.setText("Objects [" & lang & "/" & app.curSession & "]\n" &
                      (if strutils.strip(outp).len > 0: outp else: "(none)"))

proc showHelp*(app: var App) =
  let w = wordAtCursor(app)
  if w.len == 0: app.msg = "no word at cursor"; return
  let lang = (if app.curLang.len > 0: app.curLang else: "r").toLowerAscii
  if not gHelpQuery.hasKey(lang):
    app.help.setText("(no help query for " & lang & ")"); return
  let s = getSession(app, lang, (if app.curSession.len > 0: app.curSession else: "default"))
  if s == nil: app.help.setText("(no session)"); return
  if s.busy or s.phase != spReady:
    app.help.setText("Help: " & w & "\n\n(session busy -- try again when the run finishes)"); return
  let outp = cleanOverstrike(s.runBlock(gHelpQuery[lang].replace("{word}", w), quiet = true))
  app.help.setText("Help: " & w & "\n\n" & outp)
  app.msg = "help: " & w

# -- LSP completion --------------------------------------------------------
proc prefixBeforeCursor(app: App): string =
  let line = app.ed.getLineText(app.ed.currentLine)
  let upto = min(app.ed.currentCol, line.len)
  var s = upto
  while s > 0 and isWordChar(line[s - 1]): dec s
  line[s ..< upto]

proc getLspClient*(app: var App; lang: string): LspClient =
  let key = lang.toLowerAscii
  if app.lsp.hasKey(key) and app.lsp[key] != nil: return app.lsp[key]
  if not gLspServers.hasKey(key): return nil
  let root = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  let c = startLsp(gLspServers[key], uriOf(root))
  if c != nil: app.lsp[key] = c
  c

proc lspComplete*(app: var App) =
  if app.docLang.len == 0:
    app.msg = "no LSP language (open a source file)"; return
  let c = getLspClient(app, app.docLang)
  if c == nil:
    app.msg = "no LSP server for " & app.docLang & " (not installed?)"; return
  let uri = if app.filePath.len > 0: uriOf(app.filePath) else: "file:///wkbenchless-scratch"
  c.syncDoc(uri, app.docLang, app.ed.fullText())
  let items = c.completion(uri, app.ed.currentLine, app.ed.currentCol)
  if items.len == 0: app.msg = "no completions"; return
  let pre = prefixBeforeCursor(app)
  var filtered: seq[string]
  for it in items:
    if pre.len == 0 or it.toLowerAscii.startsWith(pre.toLowerAscii): filtered.add it
  app.completionItems = if filtered.len > 0: filtered else: items
  app.completionPrefix = pre
  app.completionSel = 0
  app.completionActive = true
  app.msg = $app.completionItems.len & " completions"

proc autoComplete*(app: var App) =
  ## Non-intrusive completion refresh for always-on mode: no "no completions"
  ## noise, dismisses itself when there's nothing (useful) to show.
  if app.docLang.len == 0: app.completionActive = false; return
  let pre = prefixBeforeCursor(app)
  if pre.len < 2:                     # wait for a couple of chars before firing
    app.completionActive = false; return
  let c = getLspClient(app, app.docLang)
  if c == nil: app.completionActive = false; return
  let uri = if app.filePath.len > 0: uriOf(app.filePath) else: "file:///wkbenchless-scratch"
  c.syncDoc(uri, app.docLang, app.ed.fullText())
  let items = c.completion(uri, app.ed.currentLine, app.ed.currentCol)
  var filtered: seq[string]
  for it in items:
    if it.toLowerAscii.startsWith(pre.toLowerAscii) and it != pre: filtered.add it
  if filtered.len == 0: app.completionActive = false; return
  app.completionItems = filtered
  app.completionPrefix = pre
  app.completionSel = 0
  app.completionActive = true

proc completionAccept*(app: var App) =
  app.completionActive = false
  if app.completionSel < 0 or app.completionSel >= app.completionItems.len: return
  let label = app.completionItems[app.completionSel]
  for _ in 0 ..< app.completionPrefix.len: app.ed.backspace(false)
  app.ed.insertText(label)
  app.msg = "inserted " & label

proc setGhostText*(app: var App; text: string) =
  ## Set (or clear, with "") the Copilot ghost-text inline completion.
  app.ed.ghostText = text

proc ghostAccept*(app: var App) =
  ## Insert the ghost text (Copilot inline completion) at the cursor.
  if app.ed.ghostText.len == 0: (app.msg = "no ghost text"; return)
  let t = app.ed.ghostText
  app.ed.ghostText = ""
  app.ed.insertText(t)
  app.msg = "copilot: accepted"

proc ghostDismiss*(app: var App) =
  app.ed.ghostText = ""

# -- built-in commands -----------------------------------------------------
proc dedentBody(lines: seq[string]): string =
  var minIndent = high(int)
  for ln in lines:
    if strutils.strip(ln).len == 0: continue
    var n = 0
    while n < ln.len and ln[n] in {' ', '\t'}: inc n
    minIndent = min(minIndent, n)
  if minIndent == high(int): minIndent = 0
  var outl: seq[string]
  for ln in lines:
    outl.add (if ln.len >= minIndent: ln[minIndent .. ^1] else: ln)
  outl.join("\n")

proc codeComplete(code: string): bool =
  ## True when `code` is a complete statement to send: balanced (), [], {}
  ## outside string literals / `# comments`, AND the last code line does not end
  ## with a continuation operator (a trailing pipe / `+` / `,` / `<-` / …).
  ## Used to gather a multi-line expression for run-line, RStudio-style.
  var stack: seq[char]
  var inStr = '\0'
  var tail = ""                                  # last few non-space code chars
  var i = 0
  while i < code.len:
    let c = code[i]
    if inStr != '\0':
      if c == '\\' and i + 1 < code.len: inc i   # skip escaped char
      elif c == inStr: inStr = '\0'
    else:
      case c
      of '"', '\'', '`': inStr = c               # ` = R backtick-quoted name
      of '#':                                     # comment: skip to end of line,
        while i < code.len and code[i] != '\n': inc i   # not the whole buffer
        continue
      of '(', '[', '{': stack.add c
      of ')', ']', '}':
        if stack.len == 0: return false
        let open = stack.pop()
        let expect = case c
          of ')': '('
          of ']': '['
          else: '{'
        if open != expect: return false
      else: discard
      if c notin {' ', '\t', '\n', '\r'}:        # remember the tail for the op check
        tail.add c
        if tail.len > 4: tail = tail[^4 .. ^1]
    inc i
  if inStr != '\0' or stack.len != 0: return false
  # A trailing continuation operator means the expression isn't finished yet.
  for op in ["%>%", "|>", "%in%", "<<-", "->>", "<-", "->", "&&", "||"]:
    if tail.endsWith(op): return false
  if tail.len > 0 and tail[^1] in {'+', '-', '*', '/', '^', '&', '|', ',', '~', '='}:
    return false
  true

# Defined later in this module; forward-declared so runLine can resolve the
# enclosing src block's language and :session.
proc findBlockAt(app: App; cur: int): tuple[b, e: int; header: string]
proc headerLangSession(header: string): (string, string)

proc runTarget(app: var App): tuple[lang, session: string; stopAt: int; ok: bool] =
  ## Where Ctrl+Enter sends, and how far a multi-line statement may be gathered:
  ##   1. inside a `#+begin_src <lang> :session` block / Rmd chunk -> that block's
  ##      language and session (gathering bounded to the block body);
  ##   2. otherwise a plain file whose own language has a registered REPL
  ##      (`.R` -> r, `.py` -> python, …) -> that language's default session;
  ##   3. otherwise the current live session, if any.
  ## `ok` is false when none apply (e.g. prose with no session).
  result.stopAt = app.ed.getLineCount()
  let blk = findBlockAt(app, app.ed.currentLine)
  if blk.b >= 0:                                   # 1. in a src block
    let (l, s) = headerLangSession(blk.header)
    if l.len > 0 and gRepls.hasKey(l.toLowerAscii):
      return (l.toLowerAscii, s, blk.e, true)      # stop at #+end_src / closing fence
  if app.docLang.len > 0 and gRepls.hasKey(app.docLang.toLowerAscii):
    return (app.docLang.toLowerAscii, "default", app.ed.getLineCount(), true)  # 2.
  if currentSession(app) != nil and gRepls.hasKey(app.curLang.toLowerAscii):
    return (app.curLang, app.curSession, app.ed.getLineCount(), true)          # 3.
  result.ok = false

proc submitEval*(app: var App; lang, name, code: string): int   # fwd: async queue, below

proc runLine*(app: var App) =
  ## Ctrl+Enter: send the current statement to the session for the language in
  ## context -- the enclosing src block's `:session`, else the file's own
  ## language (if it has a registered REPL), else the current session -- then
  ## advance to the next non-blank code line. A multi-line expression (unbalanced
  ## delimiters, or a trailing continuation operator like `%>%` / `+`) is
  ## gathered across lines until complete, bounded to the block body.
  let (lang, session, stopAt, ok) = runTarget(app)
  if not ok:
    app.msg = "Ctrl-Enter: no REPL in context -- open a code file or a src block"
    return
  var last = app.ed.currentLine
  var code = app.ed.getLineText(last)
  while not codeComplete(code) and last + 1 < stopAt:
    inc last
    code.add "\n"
    code.add app.ed.getLineText(last)
  if strutils.strip(code).len > 0:
    app.curLang = lang; app.curSession = session    # make this the current tab
    let id = submitEval(app, lang, session, code)   # queued: never blocks the editor
    if id == 0:
      app.msg = "could not start " & lang & " session"
      return
    app.msg = "sent line to " & lang & "/" & session & " (job " & $id & ")"
  # Advance to the next non-blank line so repeated C-Enter flows through the code
  # (bounded by stopAt, so inside a block we stop at #+end_src / the closing fence).
  var nxt = last + 1
  while nxt < stopAt and strutils.strip(app.ed.getLineText(nxt)).len == 0:
    inc nxt
  if nxt < stopAt:
    app.ed.gotoLine(nxt + 1, 0)       # gotoLine is 1-based
  elif last + 1 < app.ed.getLineCount():
    app.ed.gotoLine(last + 2, 0)      # only blanks left: just step down one

proc saveCmd*(app: var App) =
  if app.filePath.len > 0:
    app.ed.saveToFile(app.filePath); app.ed.markSaved()
    app.syncActive()                       # write the cleared dirty flag back into the
                                           # buffer snapshot the tab bar reads, else the
                                           # '*' lingers until the next buffer switch
    app.noteDiskMtime()                    # our own save must not trigger a revert
    persistUndo(app)                       # buffer == file: the undo sidecar is valid
    takeSnapshot(app)                      # a save is a moment worth remembering
    app.msg = "saved"
    app.runHooks("after-save")
  else: app.msg = "no file (pass a path on the command line)"

proc quitCmd*(app: var App) =
  ## Guard unsaved work: warn (naming the dirty buffers) and require a second
  ## quit to discard, mirroring `killBuffer`'s confirm pattern.
  app.syncActive()
  if not app.pendingQuit:
    var dirty: seq[string]
    for b in app.buffers:
      if b.ed.changed: dirty.add bufName(b)
    if dirty.len > 0:
      app.pendingQuit = true
      app.msg = "unsaved: " & dirty.join(", ") & " -- quit again to discard, or save first"
      return
  app.running = false

proc zoomIn*(app: var App) =
  app.fontSize = min(48, app.fontSize + 1); app.msg = "font " & $app.fontSize
proc zoomOut*(app: var App) =
  app.fontSize = max(8, app.fontSize - 1); app.msg = "font " & $app.fontSize
proc zoomReset*(app: var App) =
  app.fontSize = 15; app.msg = "font " & $app.fontSize

proc openPalette(app: var App; mode: PaletteMode) =
  app.paletteMode = mode
  app.paletteActive = true
  app.paletteQuery = ""
  app.paletteSel = 0
  if mode == pmCommands and gLastCommand.len > 0:   # reopen on the last-used item
    let entries = paletteEntries(app)
    for i, e in entries:
      if e.id == gLastCommand: app.paletteSel = i; break

proc paletteCmd*(app: var App) = openPalette(app, pmCommands)

proc saveBufferAs*(app: var App; path: string) =
  ## Save the buffer to PATH (becoming the buffer's file), for `save-as`.
  var p = expandTilde(path)
  if not isAbsolute(p): p = getCurrentDir() / p
  try:
    app.ed.saveToFile(p); app.filePath = p; app.ed.markSaved()
    app.syncActive()                       # cleared dirty flag -> tab-bar snapshot
    app.noteDiskMtime(); app.runHooks("after-save")
    app.msg = "saved as " & extractFilename(p)
  except CatchableError as ex:
    app.msg = "save failed: " & ex.msg

proc saveAsCmd*(app: var App) =
  ## Prompt (file palette) for a target path, prefilled with the current name.
  openPalette(app, pmSaveAs)
  app.paletteDir = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  app.paletteQuery = if app.filePath.len > 0: extractFilename(app.filePath) else: ""

proc orgNavCmd*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  openPalette(app, pmOrg)

proc openRecentCmd*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  if loadRecentFiles().len == 0: app.msg = "no recent files"; return
  openPalette(app, pmRecent)

proc themeCmd*(app: var App) =
  if gThemes.len == 0: app.msg = "no themes registered (see wkbconfig)"; return
  openPalette(app, pmThemes)
  app.paletteSel = app.themeIdx        # reopen on the currently-active theme

proc listBuffers*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.syncActive()                       # reflect the live active buffer
  openPalette(app, pmBuffers)

proc openFileCmd*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.paletteDir = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  openPalette(app, pmFiles)

# -- find / replace --------------------------------------------------------
# A tiny backtracking regex engine for the find panel's ".*" toggle: the
# everyday subset (literals, '.', '*', '+', '?', '[...]' classes, '^', '$',
# '|', '(...)', '\' escapes incl. \d \w \s). std/re would add a PCRE link-time
# dependency the dep-free mingw cross-build can't afford. Matching is
# continuation-passing: every node consumes input, then hands the rest of the
# pattern (as a closure) the new position, so alternation and repetition
# backtrack naturally.
type
  RxKind = enum rxChar, rxClass, rxAny, rxBol, rxEol, rxRep, rxAlt, rxGroup
  RxNode = ref object
    kind: RxKind
    ch: char                 ## rxChar
    neg: bool                ## rxClass: negate the set
    cs: array[32, uint8]     ## rxClass: 256-bit membership bitmap
    kid: RxNode              ## rxRep / rxGroup body
    alts: seq[RxNode]        ## rxAlt: one chain per option
    next: RxNode             ## concatenation: the rest of the pattern
    minR, maxR: int          ## rxRep counts (maxR < 0 = unbounded)

proc rxInSet(n: RxNode; c: char): bool =
  result = (n.cs[c.uint8 shr 3] and (1'u8 shl (c.uint8 and 7))) != 0
  if n.neg: result = not result

proc rxMatch(n: RxNode; s: string; pos: int; ic: bool;
             k: proc(p: int): bool): bool =
  if n == nil: return k(pos)
  case n.kind
  of rxChar:
    if pos < s.len and (s[pos] == n.ch or
        ic and toLowerAscii(s[pos]) == toLowerAscii(n.ch)):
      return rxMatch(n.next, s, pos + 1, ic, k)
  of rxAny:
    if pos < s.len and s[pos] != '\n':   # PCRE: '.' never crosses lines
      return rxMatch(n.next, s, pos + 1, ic, k)
  of rxClass:
    if pos < s.len and (rxInSet(n, s[pos]) or
        ic and (rxInSet(n, toLowerAscii(s[pos])) or rxInSet(n, toUpperAscii(s[pos])))):
      return rxMatch(n.next, s, pos + 1, ic, k)
  of rxBol:
    if pos == 0 or s[pos - 1] == '\n': return rxMatch(n.next, s, pos, ic, k)
  of rxEol:
    if pos == s.len or s[pos] == '\n': return rxMatch(n.next, s, pos, ic, k)
  of rxGroup:
    return rxMatch(n.kid, s, pos, ic,
                   proc(p: int): bool = rxMatch(n.next, s, p, ic, k))
  of rxAlt:
    for opt in n.alts:
      if rxMatch(opt, s, pos, ic,
                 proc(p: int): bool = rxMatch(n.next, s, p, ic, k)):
        return true
  of rxRep:
    proc rep(p, count: int): bool =
      if n.maxR < 0 or count < n.maxR:
        if rxMatch(n.kid, s, p, ic, proc(p2: int): bool =
            if p2 > p: rep(p2, count + 1) else: false):
          return true
      if count >= n.minR: return rxMatch(n.next, s, p, ic, k)
      false
    return rep(pos, 0)
  false

proc rxBit(n: RxNode; c: char) =
  n.cs[c.uint8 shr 3] = n.cs[c.uint8 shr 3] or (1'u8 shl (c.uint8 and 7))

proc rxParse(pattern: string): RxNode =
  ## Compile `pattern` into a match chain; raises ValueError on bad syntax.
  var i = 0
  proc parseAlt(): RxNode
  proc parseAtom(): RxNode =
    result = nil
    if i >= pattern.len: return
    template classNode(): untyped = RxNode(kind: rxClass)
    let c = pattern[i]
    case c
    of '(':
      inc i
      let body = parseAlt()
      if i < pattern.len and pattern[i] == ')': inc i
      else: raise newException(ValueError, "unclosed (")
      result = RxNode(kind: rxGroup, kid: body)
    of '[':
      inc i
      result = classNode()
      if i < pattern.len and pattern[i] == '^': result.neg = true; inc i
      var first = true
      while i < pattern.len and (pattern[i] != ']' or first):
        first = false
        var a = pattern[i]; inc i
        if a == '\\' and i < pattern.len: a = pattern[i]; inc i
        if i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']':
          inc i
          var b = pattern[i]; inc i
          if b == '\\' and i < pattern.len: b = pattern[i]; inc i
          if b < a: raise newException(ValueError, "bad class range")
          for ch in a .. b: rxBit(result, ch)
        else:
          rxBit(result, a)
      if i < pattern.len: inc i
      else: raise newException(ValueError, "unclosed [")
    of '.':
      inc i; result = RxNode(kind: rxAny)
    of '^':
      inc i; result = RxNode(kind: rxBol)
    of '$':
      inc i; result = RxNode(kind: rxEol)
    of '\\':
      inc i
      if i >= pattern.len: raise newException(ValueError, "dangling \\")
      let e = pattern[i]; inc i
      case e
      of 'd':
        result = classNode()
        for ch in '0' .. '9': rxBit(result, ch)
      of 'w':
        result = classNode()
        for ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}: rxBit(result, ch)
      of 's':
        result = classNode()
        for ch in {' ', '\t', '\n', '\r', '\f', '\v'}: rxBit(result, ch)
      else:
        result = RxNode(kind: rxChar, ch: e)   # \., \\, \( ... : the literal
    of '*', '+', '?':
      raise newException(ValueError, "nothing to repeat")
    else:
      inc i; result = RxNode(kind: rxChar, ch: c)
    if result != nil and i < pattern.len:
      case pattern[i]
      of '*': inc i; result = RxNode(kind: rxRep, kid: result, minR: 0, maxR: -1)
      of '+': inc i; result = RxNode(kind: rxRep, kid: result, minR: 1, maxR: -1)
      of '?': inc i; result = RxNode(kind: rxRep, kid: result, minR: 0, maxR: 1)
      else: discard
  proc parseConcat(): RxNode =
    var head, tail: RxNode
    while i < pattern.len and pattern[i] notin {'|', ')'}:
      let atom = parseAtom()
      if atom == nil: break
      if head == nil: head = atom
      else: tail.next = atom
      tail = atom
    head
  proc parseAlt(): RxNode =
    var opts = @[parseConcat()]
    while i < pattern.len and pattern[i] == '|':
      inc i
      opts.add parseConcat()
    if opts.len == 1: opts[0]
    else: RxNode(kind: rxAlt, alts: opts)
  result = parseAlt()
  if i < pattern.len: raise newException(ValueError, "unbalanced )")

proc rxSearch*(pattern, s: string; ic: bool): seq[tuple[a, e: int]] =
  ## Every non-overlapping match of `pattern` in `s`, as [start, end) pairs.
  ## Zero-width matches are reported (so "^$" finds empty lines) but the
  ## caller skips marking them.
  let re = rxParse(pattern)
  var start = 0
  while start <= s.len:
    var fin = -1
    if rxMatch(re, s, start, ic, proc(p: int): bool = fin = p; true):
      result.add (start, max(fin, start))
      start = if fin > start: fin else: start + 1
    else:
      inc start

proc isWordBounded*(s: string; a, e: int): bool =
  ## True when [a, e) has no word character glued to either end.
  proc wordy(c: char): bool =
    c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}
  (a == 0 or not s[a - 1].wordy) and (e >= s.len or not s[e].wordy)

proc recomputeMatches*(app: var App) =
  ## Rescan the buffer for the current needle -- plain or regex, honoring the
  ## case ("Aa") and whole-word ("ab") toggles -- refresh the highlight
  ## markers, and pick the match nearest the cursor as current.
  app.searchMatches.setLen 0
  app.searchMatchEnds.setLen 0
  app.ed.clearMarkers()
  if app.searchQuery.len == 0:
    app.searchIdx = -1
    return
  let hay = app.ed.fullText
  var badRx = false
  if app.searchRegex:
    try:
      for (a, e) in rxSearch(app.searchQuery, hay, not app.searchCase):
        if app.searchWord and not isWordBounded(hay, a, e): continue
        app.searchMatches.add a
        app.searchMatchEnds.add e
        if e > a: app.ed.addMarker(a, e - 1, app.theme.ed.selBg)
    except ValueError:
      badRx = true
  else:
    let needle = if app.searchCase: app.searchQuery else: app.searchQuery.toLowerAscii
    let hayL = if app.searchCase: hay else: hay.toLowerAscii
    var start = 0
    while true:
      let p = hayL.find(needle, start)
      if p < 0: break
      let e = p + needle.len
      start = e
      if app.searchWord and not isWordBounded(hay, p, e): continue
      app.searchMatches.add p
      app.searchMatchEnds.add e
      app.ed.addMarker(p, e - 1, app.theme.ed.selBg)
  if app.searchMatches.len == 0:
    app.searchIdx = -1
    if badRx: app.msg = "bad regex"
    return
  let cur = app.ed.cursor
  app.searchIdx = 0
  for i, p in app.searchMatches:
    if p >= cur: app.searchIdx = i; break
    app.searchIdx = i

proc gotoCurrentMatch*(app: var App) =
  if app.searchIdx < 0 or app.searchIdx >= app.searchMatches.len: return
  app.ed.gotoPos(app.searchMatches[app.searchIdx])
  app.msg = $(app.searchIdx + 1) & " of " & $app.searchMatches.len

proc searchNext*(app: var App) =
  if app.searchMatches.len == 0: app.msg = "no matches"; return
  app.searchIdx = (app.searchIdx + 1) mod app.searchMatches.len
  app.gotoCurrentMatch()

proc searchPrev*(app: var App) =
  if app.searchMatches.len == 0: app.msg = "no matches"; return
  app.searchIdx = (app.searchIdx - 1 + app.searchMatches.len) mod app.searchMatches.len
  app.gotoCurrentMatch()

proc endSearch*(app: var App) =
  app.searchActive = false
  app.ed.clearMarkers()
  # remember the queries for the panel's Up/Down history browsing
  if app.searchQuery.len > 0 and
      (app.searchHistory.len == 0 or app.searchQuery != app.searchHistory[0]):
    app.searchHistory.insert app.searchQuery
  if app.searchReplace.len > 0 and
      (app.replaceHistory.len == 0 or app.searchReplace != app.replaceHistory[0]):
    app.replaceHistory.insert app.searchReplace
  app.searchHistIdx = -1; app.replaceHistIdx = -1

proc browseSearchHistory*(app: var App; up: bool) =
  ## Up/Down in a panel field walks that field's past queries (newest first);
  ## stepping back below the newest restores what was being typed.
  let isQuery = app.searchField == sfQuery
  let hist = if isQuery: app.searchHistory else: app.replaceHistory
  var idx = if isQuery: app.searchHistIdx else: app.replaceHistIdx
  if hist.len == 0: return
  var txt: string
  if up:
    if idx < 0:
      if isQuery: app.searchDraft = app.searchQuery else: app.replaceDraft = app.searchReplace
      idx = 0
    elif idx < hist.high: inc idx
    txt = hist[idx]
  else:
    if idx >= 0: dec idx
    txt = if idx < 0: (if isQuery: app.searchDraft else: app.replaceDraft)
          else: hist[idx]
  if isQuery:
    app.searchHistIdx = idx
    app.searchQuery = txt
    recomputeMatches(app); gotoCurrentMatch(app)
  else:
    app.replaceHistIdx = idx
    app.searchReplace = txt

proc openFind*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.searchActive = true
  app.searchMode = smFind
  app.searchField = sfQuery
  app.searchQuery = ""
  app.searchReplace = ""
  app.searchIdx = -1
  app.searchMatches.setLen 0
  app.searchHistIdx = -1; app.replaceHistIdx = -1
  app.ed.clearMarkers()

proc openReplace*(app: var App) =
  openFind(app)
  app.searchMode = smReplace

proc replaceCurrent*(app: var App) =
  ## Replace the current match, then rescan (offsets shift) and advance.
  if app.searchIdx < 0 or app.searchIdx >= app.searchMatches.len:
    app.msg = "no match"; return
  let p = app.searchMatches[app.searchIdx]
  app.ed.selectRange(p, app.searchMatchEnds[app.searchIdx] - 1)
  app.ed.deleteSelection()
  app.ed.gotoPos(p)
  app.ed.insertText(app.searchReplace)
  app.ed.markChanged()
  app.recomputeMatches()
  app.gotoCurrentMatch()

proc replaceAll*(app: var App) =
  if app.searchQuery.len == 0: return
  var n = 0
  while app.searchMatches.len > 0:
    let p = app.searchMatches[0]
    app.ed.selectRange(p, app.searchMatchEnds[0] - 1)
    app.ed.deleteSelection()
    app.ed.gotoPos(p)
    app.ed.insertText(app.searchReplace)
    inc n
    app.recomputeMatches()
  app.ed.markChanged()
  app.msg = "replaced " & $n
  app.endSearch()

proc findAllMatches*(app: var App) =
  ## The find panel's [Find All]: every match is already marker-highlighted
  ## live; land on the first and report the total (the editor has no
  ## multi-selection to grab them all at once like Sublime does).
  if app.searchMatches.len == 0:
    app.msg = "no matches"
    return
  app.searchIdx = 0
  app.ed.gotoPos(app.searchMatches[0])
  app.msg = $app.searchMatches.len & " matches"

proc orgLinkAt(line: string; col: int): string =
  ## The TARGET of the [[TARGET]] / [[TARGET][DESC]] link under `col`, or "".
  var i = 0
  while i < line.len - 1:
    if line[i] == '[' and line[i + 1] == '[':
      let start = i
      var j = i + 2
      while j < line.len - 1 and not (line[j] == ']' and line[j + 1] == ']'): inc j
      if j < line.len - 1:
        let endB = j + 1
        if col >= start and col <= endB:
          let inner = line[start + 2 ..< j]
          let sep = inner.find("][")
          return if sep >= 0: inner[0 ..< sep] else: inner
        i = endB + 1
        continue
    inc i

proc lineStartOffset(app: App; line: int): int =
  ## Buffer offset of the first char of `line` (0-based) via a single scan.
  let txt = app.ed.fullText
  var off = 0
  var n = 0
  while off < txt.len and n < line:
    if txt[off] == '\L': inc n
    inc off
  off

proc blockStartLineAtCursor(app: App): int =
  ## Line index of the #+begin_src / Rmd ```{r} that opens the block the cursor
  ## sits in, -1.
  let cur = app.ed.currentLine
  var i = cur
  while i >= 0:
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src"): return i
    if low.startsWith("```{r"): return i
    if low.startsWith("#+end_src") and i < cur: return -1
    if low.startsWith("```") and i < cur: return -1   # a plain ``` above: not in a chunk
    dec i
  -1

proc toggleFold*(app: var App) =
  if app.ed.lang notin {langOrg, langMarkdown}:
    app.msg = "folding is for org / Rmd files"; return
  let line = blockStartLineAtCursor(app)
  if line < 0: app.msg = "not on a src block"; return
  let off = lineStartOffset(app, line)
  app.ed.toggleFold(off)
  app.msg = if app.ed.isFolded(off): "folded" else: "unfolded"

proc scrollRight*(app: var App) = app.ed.hScroll = min(app.ed.hScroll + 8, 400)
proc scrollLeft*(app: var App) = app.ed.hScroll = max(app.ed.hScroll - 8, 0)

proc foldAllSrc*(app: var App) =
  if app.ed.lang in {langOrg, langMarkdown}: app.ed.foldAllBlocks(); app.msg = "all blocks folded"
proc unfoldAllSrc*(app: var App) =
  if app.ed.lang in {langOrg, langMarkdown}: app.ed.unfoldAll(); app.msg = "all blocks unfolded"

proc linkAtCursor*(app: App): string =
  ## The org link target under the cursor, or "" (for plain-click activation).
  orgLinkAt(app.ed.getLineText(app.ed.currentLine), app.ed.currentCol)

const editableExts = [".org", ".md", ".markdown", ".txt", ".text", ".nim", ".nims",
  ".py", ".pyw", ".r", ".jl", ".el", ".lisp", ".c", ".h", ".cpp", ".hpp", ".cc",
  ".js", ".ts", ".json", ".yaml", ".yml", ".toml", ".cfg", ".conf", ".ini", ".sh",
  ".bash", ".zsh", ".tex", ".bib", ".csv", ".tsv", ".html", ".css", ".xml", ".rs",
  ".go", ".lua", ".vim", ".sql", ".rmd", ".qmd", ".log"]

proc openExternally(target: string) =
  when defined(windows):
    discard execShellCmd("start \"\" " & quoteShell(target))
  else:
    let opener = when defined(macosx): "open" else: "xdg-open"
    discard execShellCmd(opener & " " & quoteShell(target) & " &")

proc openLink*(app: var App) =
  ## Follow the org link at the cursor. A file link to a text/source file opens
  ## IN wkbenchless (like org-open-at-point in Emacs); a URL, mailto, or a
  ## non-text file (pdf, image, ...) hands off to the system opener. `file:` is
  ## optional -- a bare relative/absolute path is treated as a file link too.
  let target = orgLinkAt(app.ed.getLineText(app.ed.currentLine), app.ed.currentCol)
  if target.len == 0: app.msg = "no link at cursor"; return

  # URLs and mailto go straight to the system handler.
  if target.find("://") >= 0 or target.startsWith("mailto:"):
    openExternally(target); app.msg = "opening " & target; return

  var t = target
  if t.startsWith("file:"): t = t[5 .. ^1]
  # an org `::anchor` selects a line number or a heading within the file
  var anchor = ""
  let ai = t.find("::")
  if ai >= 0: (anchor = t[ai + 2 .. ^1]; t = t[0 ..< ai])
  t = expandTilde(t)
  if not isAbsolute(t) and app.filePath.len > 0:
    t = parentDir(app.filePath) / t      # resolve relative to the current file

  if not fileExists(t):
    app.msg = "link target not found: " & t; return
  if t.splitFile.ext.toLowerAscii in editableExts:
    openFile(app, t)                     # open in the editor
    if anchor.len > 0:
      try: app.ed.gotoLine(parseInt(anchor.strip(chars = {'*', ' '})) - 1, 0)
      except ValueError: discard         # (heading anchors: jump left to future work)
    app.msg = "opened " & extractFilename(t)
  else:
    openExternally(t); app.msg = "opening " & extractFilename(t)

# -- CriticMarkup (tracked changes), cf. org-tracked-docx --------------------
proc applyCriticMarkup*(text: string; accept: bool): string =
  ## Resolve every CriticMarkup token. accept: keep insertions & the NEW side of
  ## a substitution, drop deletions. reject: the opposite. Comments are dropped
  ## either way; a highlight always keeps its text (only the wrapper goes).
  ##   {++ins++}  {--del--}  {~~old~>new~~}  {>>comment<<}  {==highlight==}
  result = newStringOfCap(text.len)
  var i = 0
  proc closeOf(o, c: char): int =
    ## Index of the '}' ending `<o><o> ... <c><c>}` starting at i, or -1.
    var q = i + 3
    while q + 2 < text.len:
      if text[q] == c and text[q+1] == c and text[q+2] == '}': return q + 2
      inc q
    -1
  while i < text.len:
    if i + 4 < text.len and text[i] == '{':
      let a = text[i+1]; let b = text[i+2]
      if a == b and a in {'+', '-', '=', '~'}:
        let e = closeOf(a, a)
        if e >= 0:
          let inner = text[i+3 ..< e-2]
          case a
          of '+': (if accept: result.add inner)
          of '-': (if not accept: result.add inner)
          of '=': result.add inner
          of '~':
            let arrow = inner.find("~>")
            if arrow >= 0: result.add (if accept: inner[arrow+2 .. ^1] else: inner[0 ..< arrow])
            else: result.add inner
          else: discard
          i = e + 1; continue
      elif a == '>' and b == '>':          # {>>comment<<} -- asymmetric close
        let e = closeOf('<', '<')
        if e >= 0: (i = e + 1; continue)   # drop the comment entirely
    result.add text[i]; inc i

proc collectLatexHeader(app: App): string =
  ## Extra preamble from the buffer's `#+LATEX_HEADER:` lines (org convention),
  ## so user macros / packages are available to previews.
  for i in 0 ..< app.ed.getLineCount():
    let s = strutils.strip(app.ed.getLineText(i))
    if s.toLowerAscii.startsWith("#+latex_header:"):
      result.add strutils.strip(s[s.find(':') + 1 .. ^1]) & "\n"

proc renderLatexFragment(inner, header, outPng: string): bool =
  ## Compile one display-math fragment to `outPng` via latex -> dvipng (black on
  ## white). Returns false if the toolchain is missing or compilation fails.
  let tmp = getTempDir() / "wkbenchless-ltx"
  try: createDir(tmp) except CatchableError: return false
  let tex = tmp / "frag.tex"
  writeFile(tex,
    "\\documentclass[12pt]{article}\n" &
    "\\usepackage{amsmath,amssymb,amsfonts}\n" & header &
    "\\pagestyle{empty}\n\\begin{document}\n\\[\n" & inner &
    "\n\\]\n\\end{document}\n")
  let (_, c1) = execCmdEx("latex -interaction=nonstopmode -halt-on-error " &
                          quoteShell(tex), workingDir = tmp)
  if c1 != 0: return false
  let (_, c2) = execCmdEx("dvipng -q -T tight -D " & $gLatexDpi &
                          " -bg White -o " & quoteShell(outPng) & " " &
                          quoteShell(tmp / "frag.dvi"), workingDir = tmp)
  result = c2 == 0 and fileExists(outPng)

proc enableLatexPreview(app: var App): bool =
  ## Turn on LaTeX previews and render every whole-line display-math fragment
  ## ($$..$$, \[..\], \(..\), $..$) to a cached PNG. Returns false (and leaves
  ## the flag off) when the toolchain is missing.
  ##
  ## The `#+LATEX_HEADER:` preamble is often written for the export, not for
  ## `latex` + `article` (a beamer theme, fontspec fonts for lualatex), and then
  ## breaks every fragment. So a fragment that fails with it is retried without
  ## it; if that works, the rest of the document is rendered without it too.
  if findExe("latex").len == 0 or findExe("dvipng").len == 0:
    app.msg = "latex preview needs `latex` and `dvipng` on PATH"; return false
  app.ed.setRenderFlag(rfLatexPreview, true)
  var header = collectLatexHeader(app)
  var headerDropped = false
  try: createDir(getCacheDir() / "wkbenchless" / "ltximg") except CatchableError: discard
  var made, failed = 0
  var off = 0
  while off < app.ed.len:
    var inner = ""
    var blockEnd = -1
    if latexDisplayMathAt(app.ed, off, inner, blockEnd):
      let outPng = ltxCachePath(inner)
      if not fileExists(outPng):
        if renderLatexFragment(inner, header, outPng): inc made
        elif header.len > 0 and renderLatexFragment(inner, "", outPng):
          header = ""; headerDropped = true; inc made
        else: inc failed
      off = blockEnd
    else:
      while off < app.ed.len and app.ed[off] != '\L': inc off
      if off < app.ed.len: inc off
  app.msg = "latex preview on (" & $made & " rendered" &
            (if failed > 0: ", " & $failed & " failed" else: "") &
            (if headerDropped: "; #+LATEX_HEADER skipped: it does not compile " &
               "with latex -- move export-only lines to #+LATEX_HEADER_EXTRA" else: "") & ")"
  true

proc latexPreview*(app: var App) =
  ## Toggle inline LaTeX previews (org-latex-preview style); the source returns
  ## while the cursor is on a line, or when toggled off.
  if rfLatexPreview in app.ed.flags:
    app.ed.setRenderFlag(rfLatexPreview, false); app.msg = "latex preview off"
  else:
    discard enableLatexPreview(app)

proc applyOrgStartup*(app: var App) =
  ## Honour Emacs `#+STARTUP:` toggles when a document is opened:
  ## `inlineimages` / `noinlineimages` and `latexpreview` (rendered on open,
  ## like org-startup-with-latex-preview). Unknown tokens are ignored.
  var toks: seq[string]
  for i in 0 ..< app.ed.getLineCount():
    let s = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if s.startsWith("#+startup:"):
      for t in strutils.splitWhitespace(s["#+startup:".len .. ^1]): toks.add t
  if "noinlineimages" in toks: app.ed.setRenderFlag(rfInlineImages, false)
  elif "inlineimages" in toks: app.ed.setRenderFlag(rfInlineImages, true)
  if "latexpreview" in toks: discard enableLatexPreview(app)

proc isChunkStart(line: string): bool =
  ## True if `line` opens a runnable chunk: org #+begin_src or an Rmd ```{r} fence.
  let low = line.strip.toLowerAscii
  low.startsWith("#+begin_src") or low.startsWith("```{r")

# Defined later in this module; forward-declared so isLandmark can test fences.
proc rmdChunkOpen(line: string): bool
proc rmdChunkClose(line: string): bool

proc isLandmark(line: string; star, hash: bool): tuple[hit: bool; label: string] =
  ## True if `line` starts a navigable unit: a section heading, a runnable
  ## chunk, or a CriticMarkup comment. One scanner backs the unified ▼/▲
  ## toolbar pair and its commands, so all three kinds interleave in true
  ## document order (a comment between two headings is not skipped over).
  ## `star` = detect org `*` headings; `hash` = markdown `#` headings.
  let s = strutils.strip(line)
  if s.len == 0: return (false, "")
  if star and s[0] == '*':
    var lvl = 0
    while lvl < s.len and s[lvl] == '*': inc lvl
    if lvl == s.len or s[lvl] == ' ':    # stars then a space: a heading, not *bold*
      return (true, "section: " & strutils.strip(s[lvl .. ^1]))
  if hash and s[0] == '#':
    var lvl = 0
    while lvl < s.len and s[lvl] == '#': inc lvl
    if lvl == s.len or s[lvl] == ' ':    # ATX heading; #+begin_src has no space after #
      return (true, "section: " & strutils.strip(s[lvl .. ^1]))
  let low = s.toLowerAscii
  if low.startsWith("#+begin_src") or rmdChunkOpen(low):
    return (true, "src block")
  if "{>>" in s:
    return (true, "comment")
  (false, "")

proc jumpLandmark*(app: var App; forward: bool) =
  ## Core of next/prev-landmark: jump to the nearest landmark strictly
  ## after (or before) the cursor. Landmark = section heading / src chunk /
  ## CriticMarkup comment; works in both org and Rmd/markdown files.
  ## Plain-text buffers (e.g. the scratch file) get BOTH heading syntaxes;
  ## code files get neither, so an R `# comment` is never mistaken for one.
  ## Lines INSIDE a chunk body are skipped (they are code, not structure):
  ## a `# comment` or a `*` bullet inside an R block must not stop the scan.
  ## Chunk fences are tracked in one forward pass, so the skip is correct in
  ## both directions (a backward walk cannot see the opening fence).
  let star = app.ed.lang in {langOrg, langNone}
  let hash = app.ed.lang in {langMarkdown, langNone}
  let n = app.ed.getLineCount()
  var marks: seq[tuple[line: int; label: string]]
  var inChunk = false            # set on #+begin_src / ```{...}, cleared on the closer
  for i in 0 ..< n:
    let raw = strutils.strip(app.ed.getLineText(i))
    let low = raw.toLowerAscii
    let opens = low.startsWith("#+begin_src") or rmdChunkOpen(low)
    if opens: inChunk = true
    elif inChunk and (low.startsWith("#+end_src") or rmdChunkClose(low)):
      inChunk = false
    if not inChunk or opens:
      let (hit, label) = isLandmark(raw, star, hash)
      if hit: marks.add (i, label)
  # pick the first mark strictly after (or before) the cursor
  let cur = app.ed.currentLine
  if forward:
    for m in marks:
      if m.line > cur:
        app.ed.gotoLine(m.line + 1, 0); app.msg = "next " & m.label; return  # gotoLine is 1-based
  else:
    for m in reversed(marks):
      if m.line < cur:
        app.ed.gotoLine(m.line + 1, 0); app.msg = "previous " & m.label; return
  app.msg = if forward: "no next section / block / comment" else: "no previous section / block / comment"

proc nextLandmark*(app: var App) = jumpLandmark(app, forward = true)
proc prevLandmark*(app: var App) = jumpLandmark(app, forward = false)

proc nextChunk*(app: var App) =
  ## Jump to the next src block / Rmd chunk after the cursor.
  let n = app.ed.getLineCount()
  var i = app.ed.currentLine + 1
  while i < n:
    if isChunkStart(app.ed.getLineText(i)):
      app.ed.gotoLine(i + 1, 0); app.msg = "next src block"; return   # gotoLine is 1-based
    inc i
  app.msg = "no next src block"

proc prevChunk*(app: var App) =
  ## Jump to the previous src block / Rmd chunk before the cursor.
  var i = app.ed.currentLine - 1
  while i >= 0:
    if isChunkStart(app.ed.getLineText(i)):
      app.ed.gotoLine(i + 1, 0); app.msg = "previous src block"; return   # gotoLine is 1-based
    dec i
  app.msg = "no previous src block"

proc cancelOverlays*(app: var App) =
  ## Keyboard-quit (C-g): dismiss the command palette / find minibuffer overlays.
  app.paletteActive = false
  app.searchActive = false
  app.msg = ""

proc toggleInlineImages*(app: var App) =
  ## Toggle inline rendering of whole-line image links ([[file:x.bmp]] /
  ## ![](x.bmp)) in the current buffer, resolving relative paths against the
  ## file's directory (or the cwd for an unsaved buffer).
  let on = rfInlineImages notin app.ed.flags
  app.ed.setRenderFlag(rfInlineImages, on)
  app.ed.imageBaseDir =
    if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  app.ed.imageDefaultWidth = gInlineImageWidth
  app.msg = "inline images " & (if on: "on" else: "off")

proc criticAcceptAll*(app: var App) =
  if app.ed.lang != langOrg: app.msg = "CriticMarkup is for org files"; return
  app.ed.setText(applyCriticMarkup(app.ed.fullText(), accept = true))
  app.ed.markChanged(); app.msg = "accepted all tracked changes"

proc criticRejectAll*(app: var App) =
  if app.ed.lang != langOrg: app.msg = "CriticMarkup is for org files"; return
  app.ed.setText(applyCriticMarkup(app.ed.fullText(), accept = false))
  app.ed.markChanged(); app.msg = "rejected all tracked changes"

proc lineStartOffset(app: App): int =
  ## Byte offset of the start of the current line in fullText.
  for i in 0 ..< app.ed.currentLine: result += app.ed.getLineText(i).len + 1

proc criticFindToken(text: string; fromOff: int): tuple[s, e: int] =
  ## First CriticMarkup token whose end is > FROMOFF (so a token enclosing the
  ## cursor is caught, else the next one after it); (-1,-1) if none. `e` is the
  ## index just past the closing brace.
  proc closeOf(o: int; c: char): int =
    var q = o + 3
    while q + 2 < text.len:
      if text[q] == c and text[q+1] == c and text[q+2] == '}': return q + 3
      inc q
    -1
  var i = 0
  while i < text.len:
    if text[i] == '{' and i + 4 < text.len:
      let a = text[i+1]; let b = text[i+2]
      var e = -1
      if a == b and a in {'+', '-', '=', '~'}: e = closeOf(i, a)
      elif a == '>' and b == '>': e = closeOf(i, '<')
      if e > 0:
        if e > fromOff: return (i, e)
        i = e; continue
    inc i
  (-1, -1)

proc criticResolveOne(app: var App; accept: bool) =
  if app.ed.lang != langOrg: app.msg = "CriticMarkup is for org files"; return
  let ft = app.ed.fullText()
  let (s, e) = criticFindToken(ft, lineStartOffset(app))
  if s < 0: app.msg = "no tracked change here"; return
  let piece = ft[s ..< e]
  if piece.startsWith("{>>"):
    app.msg = "that is a comment (use Mark DONE / Clean DONE)"; return
  app.ed.setText(ft[0 ..< s] & applyCriticMarkup(piece, accept) & ft[e ..< ft.len])
  app.ed.markChanged()
  app.msg = (if accept: "accepted change" else: "rejected change")

proc criticAcceptOne*(app: var App) = criticResolveOne(app, true)
proc criticRejectOne*(app: var App) = criticResolveOne(app, false)

proc criticMarkDone*(app: var App) =
  ## Mark the comment at/after the cursor `[DONE]` (org-tracked-docx convention).
  if app.ed.lang != langOrg: app.msg = "CriticMarkup is for org files"; return
  let ft = app.ed.fullText()
  var off = lineStartOffset(app)
  while true:
    let (s, e) = criticFindToken(ft, off)
    if s < 0: app.msg = "no comment here"; return
    if ft[s ..< e].startsWith("{>>"):
      let inner = ft[s+3 ..< e-3]                 # between {>> and <<}
      if "[DONE]" in inner: (app.msg = "already DONE"; return)
      var ip = 0                                  # insert after a [Author] prefix
      if inner.startsWith("[") and ']' in inner:
        ip = inner.find(']') + 1
        while ip < inner.len and inner[ip] == ' ': inc ip
      let newInner = inner[0 ..< ip] & "[DONE] " & inner[ip ..< inner.len]
      app.ed.setText(ft[0 ..< s] & "{>>" & newInner & "<<}" & ft[e ..< ft.len])
      app.ed.markChanged(); app.msg = "marked DONE"; return
    off = e                                       # skip non-comment tokens

proc criticCleanDone*(app: var App) =
  ## Remove every comment already marked `[DONE]`; keep all other markup & text.
  if app.ed.lang != langOrg: app.msg = "CriticMarkup is for org files"; return
  let ft = app.ed.fullText()
  var res = newStringOfCap(ft.len)
  var i = 0
  var n = 0
  proc closeOf(o: int; c: char): int =
    var q = o + 3
    while q + 2 < ft.len:
      if ft[q] == c and ft[q+1] == c and ft[q+2] == '}': return q + 3
      inc q
    -1
  while i < ft.len:
    if ft[i] == '{' and i + 4 < ft.len and ft[i+1] == '>' and ft[i+2] == '>':
      let e = closeOf(i, '<')
      if e > 0:
        if "[DONE]" in ft[i+3 ..< e-3]: (inc n; i = e; continue)   # drop resolved
    res.add ft[i]; inc i
  if n == 0: app.msg = "no DONE comments to clean"; return
  app.ed.setText(res); app.ed.markChanged()
  app.msg = "cleaned " & $n & " DONE comment" & (if n == 1: "" else: "s")

proc nextComment*(app: var App) =
  let n = app.ed.getLineCount()
  var i = app.ed.currentLine + 1
  while i < n:
    if "{>>" in app.ed.getLineText(i): (app.ed.gotoLine(i + 1, 0); app.msg = "next comment"; return)
    inc i
  app.msg = "no next comment"

proc prevComment*(app: var App) =
  var i = app.ed.currentLine - 1
  while i >= 0:
    if "{>>" in app.ed.getLineText(i): (app.ed.gotoLine(i + 1, 0); app.msg = "previous comment"; return)
    dec i
  app.msg = "no previous comment"

# -- two-pane diff (for agents to show before/after) -------------------------
proc lineDiff(a, b: seq[string]): tuple[l, r: seq[string]; lk, rk: seq[char]] =
  ## LCS line alignment: each output row is (left, right) with a kind --
  ## ' ' unchanged, '-' removed (right blank), '+' added (left blank).
  let n = a.len; let m = b.len
  var dp = newSeq[seq[int]](n + 1)
  for i in 0 .. n: dp[i] = newSeq[int](m + 1)
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      dp[i][j] = if a[i] == b[j]: dp[i+1][j+1] + 1 else: max(dp[i+1][j], dp[i][j+1])
  var i = 0; var j = 0
  while i < n and j < m:
    if a[i] == b[j]:
      result.l.add a[i]; result.r.add b[j]; result.lk.add ' '; result.rk.add ' '; inc i; inc j
    elif dp[i+1][j] >= dp[i][j+1]:
      result.l.add a[i]; result.r.add ""; result.lk.add '-'; result.rk.add ' '; inc i
    else:
      result.l.add ""; result.r.add b[j]; result.lk.add ' '; result.rk.add '+'; inc j
  while i < n: (result.l.add a[i]; result.r.add ""; result.lk.add '-'; result.rk.add ' '; inc i)
  while j < m: (result.l.add ""; result.r.add b[j]; result.lk.add ' '; result.rk.add '+'; inc j)

var gDiffAutoClose* = 20.0   ## seconds an untouched diff stays up (0 = until closed)

proc diffTokenize*(s: string): seq[string] =
  ## Words, whitespace runs, single punctuation, and "\n" as its own token.
  var i = 0
  while i < s.len:
    let c = s[i]
    var j = i + 1
    if c == '\n': discard
    elif c in {' ', '\t'}:
      while j < s.len and s[j] in {' ', '\t'}: inc j
    elif c.isAlphaNumeric or c == '_' or ord(c) >= 128:
      while j < s.len and (s[j].isAlphaNumeric or s[j] == '_' or ord(s[j]) >= 128): inc j
    result.add s[i ..< j]
    i = j

proc tokenDiff(a, b: string): seq[tuple[text: string; kind: char]] =
  ## Word-level LCS of two texts, merged into runs of equal / removed / added.
  let x = diffTokenize(a)
  let y = diffTokenize(b)
  proc push(r: var seq[tuple[text: string; kind: char]]; t: string; k: char) =
    if r.len > 0 and r[^1].kind == k: r[^1].text.add t else: r.add (t, k)
  if x.len * y.len > 4_000_000:                  # too big for LCS: whole-block change
    if a.len > 0: result.push(a, '-')
    if b.len > 0: result.push(b, '+')
    return
  let n = x.len
  let m = y.len
  var dp = newSeq[seq[int32]](n + 1)
  for i in 0 .. n: dp[i] = newSeq[int32](m + 1)
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      dp[i][j] = if x[i] == y[j]: dp[i+1][j+1] + 1 else: max(dp[i+1][j], dp[i][j+1])
  var i = 0
  var j = 0
  while i < n and j < m:
    if x[i] == y[j]: (result.push(x[i], '='); inc i; inc j)
    elif dp[i+1][j] >= dp[i][j+1]: (result.push(x[i], '-'); inc i)
    else: (result.push(y[j], '+'); inc j)
  while i < n: (result.push(x[i], '-'); inc i)
  while j < m: (result.push(y[j], '+'); inc j)

proc inlineRows(d: tuple[l, r: seq[string]; lk, rk: seq[char]]; context = 2): seq[InlineRow] =
  ## Word-level view: each run of changed lines becomes one paragraph diffed by
  ## token, with `context` unchanged lines around it; the rest collapse to gaps.
  let n = d.l.len
  var changed = newSeq[bool](n)
  for k in 0 ..< n: changed[k] = d.lk[k] == '-' or d.rk[k] == '+'
  var show = newSeq[bool](n)
  for k in 0 ..< n:
    if changed[k]:
      for c in max(0, k - context) .. min(n - 1, k + context): show[c] = true
  var k = 0
  var gap = 0
  while k < n:
    if not show[k]:
      inc gap; inc k; continue
    if gap > 0: (result.add InlineRow(gap: gap); gap = 0)
    if not changed[k]:
      result.add InlineRow(segs: @[(d.l[k], '=')]); inc k; continue
    var olds, news: seq[string]
    while k < n and changed[k]:
      if d.lk[k] == '-': olds.add d.l[k]
      if d.rk[k] == '+': news.add d.r[k]
      inc k
    result.add InlineRow(segs: tokenDiff(olds.join("\n"), news.join("\n")))
  if gap > 0: result.add InlineRow(gap: gap)

proc isProsePath(p: string): bool =
  p.toLowerAscii.splitFile.ext in [".org", ".md", ".markdown", ".txt", ".rmd", ".qmd", ".tex"]

proc showDiff*(app: var App; oldText, newText, title: string; path = "") =
  ## Populate and open the diff view: word-level for prose (org/markdown/text),
  ## side-by-side for code (`t` toggles). It opens at the first change, and
  ## unless the user touches it, closes itself after gDiffAutoClose seconds.
  let d = lineDiff(oldText.splitLines(), newText.splitLines())
  app.diffL = d.l; app.diffR = d.r; app.diffLK = d.lk; app.diffRK = d.rk
  app.diffTitle = if title.len > 0: title else: "diff"
  app.diffPath = path
  app.diffTokens = isProsePath(if path.len > 0: path else: title) or
                   (path.len == 0 and app.ed.lang == langOrg)
  app.diffInline = inlineRows(d)
  inc app.diffSerial
  # First change: scroll the side-by-side view there, and remember its line in
  # the NEW text so closing the diff puts the editor cursor on it.
  var first = -1
  var newLine = 0
  app.diffJumpLine = -1
  for k in 0 ..< d.l.len:
    if d.lk[k] == '-' or d.rk[k] == '+':
      if first < 0:
        first = k
        app.diffJumpLine = newLine
    if d.lk[k] != '-': inc newLine               # the row has a line in the new text
  app.diffScroll = if app.diffTokens: 0 else: max(0, first - 3)
  app.diffActive = true
  app.diffPinned = false
  app.diffShownAt = epochTime()
  app.focus = "diff"
  var adds, dels = 0
  for k in d.lk: (if k == '-': inc dels)
  for k in d.rk: (if k == '+': inc adds)
  app.msg = "diff: " & app.diffTitle & "  +" & $adds & " -" & $dels & "  (Esc to close)"

# ---- document history: persistent undo + time-versioned snapshots ----------
#
# Layer 1: the session's undo stack persists to a per-file sidecar (written on
# save, when the buffer matches the file) and reloads on open -- C-z reaches
# back across sessions. Layer 2: full-text snapshots taken at moments the
# user STOPPED (idle after edits, or a save), pruned to adaptive time density,
# browsable via M-x history with a diff preview before restore; restoring is
# itself one undoable edit, so a time-jump is never a trap. Snapshots also
# feed cite-history: what we wrote about a citation over time.

proc histDir(): string = getCacheDir() / "wkbenchless" / "history"

proc histKey(app: App): string =
  ## Sidecar names keyed by the sha1 of the absolute path: no collisions, and
  ## nothing pollutes the manuscript's own (synced) folder.
  ($secureHash(app.filePath)).toLowerAscii

proc relTime*(t: float): string =
  ## Human "how long ago" for the history palette.
  let d = epochTime() - t
  if d < 90: "just now"
  elif d < 90 * 60: $(int(d / 60)) & " min ago"
  elif d < 22 * 3600: format(fromUnix(t.int64).local, "HH:mm")
  elif d < 2 * 86400: "yesterday " & format(fromUnix(t.int64).local, "HH:mm")
  else: format(fromUnix(t.int64).local, "MMM d HH:mm")

proc loadHistory*(app: var App) =
  ## Read the sidecars for the open file. Snapshots always load (they are past
  ## states of the text, valid whatever happened since); the undo stack only
  ## when the file on disk still matches what it was when the records were
  ## taken -- undoing against a changed file would corrupt the text.
  app.snaps.setLen(0)
  app.histPreview = -1
  if app.filePath.len == 0 or not fileExists(app.filePath): return
  try:
    let sj = parseJson(readFile(histDir() / histKey(app) & ".snaps.json"))
    for s in sj{"snaps"}:
      app.snaps.add (s{"t"}.getFloat, s{"text"}.getStr)
  except CatchableError: discard
  try:
    let uj = parseJson(readFile(histDir() / histKey(app) & ".undo.json"))
    if abs(getLastModificationTime(app.filePath).toUnixFloat -
           uj{"mtime"}.getFloat) < 0.5 and
       getFileSize(app.filePath) == uj{"size"}.getInt:
      var recs: seq[UndoRecord]
      for u in uj{"undo"}:
        recs.add UndoRecord(k: u{"k"}.getInt, pos: u{"pos"}.getInt,
                            version: u{"version"}.getInt, word: u{"word"}.getStr,
                            time: u{"time"}.getFloat)
      app.ed.loadUndoRecords(recs, uj{"undoAt"}.getInt)
      app.lastSeenDepth = app.ed.editStamp()
  except CatchableError: discard

proc persistUndo*(app: var App) =
  ## Write the undo sidecar. Call with a SAVED buffer: the records replay
  ## against the on-disk content, so the file's mtime/size are the guard a
  ## reload checks.
  if app.filePath.len == 0 or not fileExists(app.filePath): return
  try:
    createDir(histDir())
    var undo = newJArray()
    for r in app.ed.undoRecords():
      undo.add %*{"k": r.k, "pos": r.pos, "version": r.version,
                  "word": r.word, "time": r.time}
    writeFile(histDir() / histKey(app) & ".undo.json", $ %*{
      "file": app.filePath,
      "mtime": getLastModificationTime(app.filePath).toUnixFloat,
      "size": getFileSize(app.filePath),
      "undoAt": app.ed.undoIndex(), "undo": undo})
  except CatchableError: discard

proc persistSnaps(app: var App) =
  if app.filePath.len == 0: return
  try:
    createDir(histDir())
    var arr = newJArray()
    for s in app.snaps:
      arr.add %*{"t": s.t, "text": s.text}
    writeFile(histDir() / histKey(app) & ".snaps.json", $ %*{"snaps": arr})
  except CatchableError: discard

proc pruneSnaps(snaps: var seq[tuple[t: float; text: string]]) =
  ## Adaptive density, Time-Machine style: keep everything from the last two
  ## hours, then at most one per hour back to two days, then at most one per
  ## day, capped at 60 snapshots (oldest dropped).
  if snaps.len <= 1: return
  snaps.sort() do (a, b: tuple[t: float; text: string]) -> int:
    system.cmp(b.t, a.t)                    # newest first
  var kept: seq[tuple[t: float; text: string]]
  var lastHour = 0.0
  var lastDay = 0.0
  let now = epochTime()
  for s in snaps:
    let age = now - s.t
    let keep = age < 2 * 3600 or
               (age < 48 * 3600 and (lastHour == 0 or lastHour - s.t > 3600)) or
               (lastDay == 0 or lastDay - s.t > 24 * 3600)
    if keep:
      kept.add s
      if age >= 2 * 3600: lastHour = s.t
      if age >= 48 * 3600: lastDay = s.t
  if kept.len > 60: kept.setLen(60)
  snaps = kept

proc takeSnapshot*(app: var App) =
  ## Capture the buffer at a moment the user stopped, prune, persist.
  if app.filePath.len == 0: return
  let now = epochTime()
  app.snaps.add (now, app.ed.fullText())
  pruneSnaps(app.snaps)
  persistSnaps(app)
  app.lastSnapAt = now

proc historyCmd*(app: var App) =
  ## M-x history: browse this file's time-versioned snapshots.
  if app.snaps.len == 0:
    app.msg = "history: no snapshots yet -- they accrue as you pause and save"; return
  app.histPreview = -1
  openPalette(app, pmHistory)

proc citeHistory*(app: var App) =
  ## What we wrote about the citekey at point, over time: every snapshot's
  ## paragraphs citing it, newest first.
  let key = keyAtPoint(app.ed.getLineText(app.ed.currentLine), app.ed.currentCol)
  if key.len == 0:
    app.msg = "cite-history: put the cursor on a [cite:@key] citation"; return
  var outp = "Cite history: @" & key & "\n"
  for i in countdown(app.snaps.high, 0):
    var found = false
    for para in app.snaps[i].text.split("\n\n"):
      if ("@" & key) in para:
        if not found:
          outp.add "\n== " & relTime(app.snaps[i].t) & " ==\n"
          found = true
        outp.add para.strip & "\n\n"
  if outp == "Cite history: @" & key & "\n":
    app.msg = "cite-history: no mentions of @" & key & " in the snapshots"
    return
  showInfoBuffer(app, "cite-history", outp)
  app.msg = "cite-history @" & key

proc closeDiff*(app: var App) =
  ## Close the diff and, if it was about the active buffer, put the cursor on
  ## the change.
  let path = app.diffPath
  let jump = app.diffJumpLine
  app.diffActive = false
  app.diffL = @[]; app.diffR = @[]; app.diffLK = @[]; app.diffRK = @[]
  app.diffInline = @[]
  if app.focus == "diff": app.focus = "editor"
  if path.len > 0 and jump >= 0 and app.filePath.len > 0 and
     (try: absolutePath(app.filePath) == absolutePath(path) except CatchableError: false):
    app.ed.gotoLine(min(jump, app.ed.getLineCount() - 1) + 1, 0)

proc diffAutoClose*(app: var App): bool =
  ## Host loop: close an untouched diff after gDiffAutoClose seconds.
  if not app.diffActive or app.diffPinned or gDiffAutoClose <= 0: return false
  if epochTime() - app.diffShownAt < gDiffAutoClose: return false
  closeDiff(app)
  app.msg = "diff closed (untouched for " & $int(gDiffAutoClose) & "s)"
  true

proc diffSecondsLeft*(app: App): int =
  if app.diffPinned or gDiffAutoClose <= 0: -1
  else: max(0, int(gDiffAutoClose - (epochTime() - app.diffShownAt) + 0.999))

proc diffBuffer*(app: var App) =
  ## Diff the current buffer against its saved on-disk version.
  if app.filePath.len == 0 or not fileExists(app.filePath):
    app.msg = "no saved file to diff against"; return
  showDiff(app, readFile(app.filePath), app.ed.fullText(),
           extractFilename(app.filePath) & " (disk -> buffer)", app.filePath)

proc killBufferAt*(app: var App; idx: int) =
  ## Kill the buffer at `idx` (0-based), guarding unsaved work like killBuffer.
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  if idx < 0 or idx >= app.buffers.len: return
  if app.buffers.len <= 1: app.msg = "can't kill the last buffer"; return
  app.syncActive()
  if app.buffers[idx].ed.changed and not app.pendingKill:   # guard unsaved work
    app.pendingKill = true
    app.msg = "unsaved -- kill-buffer again to discard, or C-s to save"
    return
  app.pendingKill = false
  let killed = bufName(app.buffers[idx])
  app.buffers.delete(idx)
  if idx == app.curBuf: app.activate(max(0, idx - 1))
  elif idx < app.curBuf: dec app.curBuf
  app.msg = "killed " & killed

proc killBuffer*(app: var App) = killBufferAt(app, app.curBuf)

proc revertBuffer*(app: var App) =
  ## Revert the current buffer to its file on disk, discarding unsaved edits.
  ## Guards unsaved work like killBuffer: on a modified buffer the first call
  ## only warns; invoke revert-buffer again to discard and reload. Mirrors the
  ## auto-revert path (loadFromFile + markSaved + preserve cursor), but is the
  ## explicit user-driven counterpart that *does* overwrite local edits.
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  if app.filePath.len == 0 or not fileExists(app.filePath):
    app.msg = "no file on disk to revert to"; return
  if app.ed.changed and not app.pendingRevert:      # guard unsaved work
    app.pendingRevert = true
    app.msg = "unsaved -- revert-buffer again to discard and reload from disk"
    return
  app.pendingRevert = false
  let pos = app.ed.cursor
  try: app.ed.loadFromFile(app.filePath)
  except CatchableError:
    app.msg = "revert: cannot read " & extractFilename(app.filePath); return
  app.ed.markSaved()
  app.ed.gotoPos(min(pos, app.ed.len))
  app.activeDiskMtime = getLastModificationTime(app.filePath)
  app.msg = "reverted " & extractFilename(app.filePath) & " from disk"

proc toggleSrcEdit*(app: var App) =
  ## Show/hide the objects+help right column (the "src-edit environment").
  app.srcEdit = not app.srcEdit
  if app.srcEdit: refreshObjects(app)
  app.msg = "src-edit: " & (if app.srcEdit: "on" else: "off")

proc toggleBufferTabs*(app: var App) =
  ## Show/hide a tab per open buffer in the top toolbar.
  gBufferTabs = not gBufferTabs
  setState("bufferTabs", $gBufferTabs)      # remember across restarts
  app.msg = "buffer tabs: " & (if gBufferTabs: "on" else: "off")

# -- src-edit: org-edit-special + session tangle ---------------------------
proc commonIndent(lines: seq[string]): int =
  result = high(int)
  for ln in lines:
    if strutils.strip(ln).len == 0: continue
    var n = 0
    while n < ln.len and ln[n] in {' ', '\t'}: inc n
    result = min(result, n)
  if result == high(int): result = 0

proc langToExt(lang: string): string =
  case lang.toLowerAscii
  of "r": ".R"
  of "python": ".py"
  of "nim": ".nim"
  of "julia": ".jl"
  of "bash", "sh": ".sh"
  else: ".txt"

proc rmdChunkOpen(line: string): bool =
  ## True if `line` opens an Rmd chunk fence (```{lang ...} / ~~~{lang ...}).
  let s = strutils.strip(line)
  if s.startsWith("```") or s.startsWith("~~~"):
    let rest = s[3 .. ^1].strip
    return rest.len > 0 and rest[0] == '{'
  false

proc rmdChunkClose(line: string): bool =
  ## True if `line` is a plain Rmd fence closer (``` / ~~~ with nothing after).
  let s = strutils.strip(line)
  (s.startsWith("```") or s.startsWith("~~~")) and s[3 .. ^1].strip.len == 0

proc headerLangSession(header: string): (string, string) =
  let hdr = strutils.strip(header)
  if hdr.toLowerAscii.startsWith("#+begin_src"):
    let parts = strutils.splitWhitespace(hdr)
    let lang = if parts.len >= 2: parts[1] else: ""
    var sess = "default"
    var k = 2
    while k < parts.len:
      if parts[k] == ":session" and k + 1 < parts.len: sess = parts[k + 1]
      inc k
    (lang, sess)
  else:
    # Rmd chunk header: ```{lang, opt=val, ...} / ~~~{lang ...}. The language is
    # the token after the brace; `session=name` (quotes optional) sets the session.
    var inner = hdr
    if inner.startsWith("```"): inner = inner[3 .. ^1]
    elif inner.startsWith("~~~"): inner = inner[3 .. ^1]
    inner = inner.strip
    if inner.startsWith("{"): inner = inner[1 .. ^1]
    if inner.endsWith("}"): inner = inner[0 .. ^2]
    inner = inner.strip
    var i = 0
    while i < inner.len and inner[i] notin {',', ' ', '\t'}: inc i
    let lang = inner[0 ..< i].strip
    var sess = "default"
    for p in inner.split(','):
      let kv = p.strip
      let eq = kv.find('=')
      if eq > 0 and kv[0 ..< eq].strip == "session":
        var v = kv[eq + 1 .. ^1].strip
        if v.len >= 2 and v[0] == '"' and v[^1] == '"': v = v[1 .. ^2]
        sess = v
    (lang, sess)

proc findBlockAt(app: App; cur: int): tuple[b, e: int; header: string] =
  result = (-1, -1, "")
  let total = app.ed.getLineCount()
  var isRmd = false
  for i in countdown(cur, 0):
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src"):
      result.b = i; result.header = strutils.strip(app.ed.getLineText(i)); break
    if rmdChunkOpen(low):
      result.b = i; result.header = strutils.strip(app.ed.getLineText(i)); isRmd = true; break
    if low.startsWith("#+end_src") and i < cur: return
    if rmdChunkClose(low) and i < cur: return
  if result.b < 0: return
  for i in result.b + 1 ..< total:
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if (if isRmd: rmdChunkClose(low) else: low.startsWith("#+end_src")):
      result.e = i; break
  if result.e < 0 or cur > result.e: result = (-1, -1, "")

const blockSentinel = "#--- wkbenchless block "

proc srcEditEnter(app: var App; sessionWide: bool) =
  let cb = findBlockAt(app, app.ed.currentLine)
  if cb.b < 0: app.msg = "not in a src block"; return
  let (lang, sess) = headerLangSession(cb.header)
  let total = app.ed.getLineCount()
  app.editRanges = @[]
  if not sessionWide:
    var body: seq[string]
    for i in cb.b + 1 ..< cb.e: body.add app.ed.getLineText(i)
    app.editRanges.add (a: cb.b + 1, b: cb.e, indent: commonIndent(body))
  else:
    var i = 0
    while i < total:
      let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
      if low.startsWith("#+begin_src") or rmdChunkOpen(low):
        let isRmd = rmdChunkOpen(low)
        let (l2, s2) = headerLangSession(strutils.strip(app.ed.getLineText(i)))
        var e2 = -1
        for j in i + 1 ..< total:
          let lj = strutils.strip(app.ed.getLineText(j)).toLowerAscii
          if (if isRmd: rmdChunkClose(lj) else: lj.startsWith("#+end_src")):
            e2 = j; break
        if e2 < 0: break
        if l2.toLowerAscii == lang.toLowerAscii and s2 == sess:
          var body: seq[string]
          for k in i + 1 ..< e2: body.add app.ed.getLineText(k)
          app.editRanges.add (a: i + 1, b: e2, indent: commonIndent(body))
        i = e2 + 1
      else: inc i
  if app.editRanges.len == 0: app.msg = "no blocks for that session"; return

  app.orgSaved = @[]
  for i in 0 ..< total: app.orgSaved.add app.ed.getLineText(i)
  app.orgFilePath = app.filePath

  var tang: seq[string]
  for idx, r in app.editRanges:
    if sessionWide: tang.add blockSentinel & $idx & " ---"
    var body: seq[string]
    for i in r.a ..< r.b: body.add app.orgSaved[i]
    tang.add dedentBody(body)
  let text = tang.join("\n")

  let ext = langToExt(lang)
  let tmp = getTempDir() / ("wkbenchless-edit" & ext)
  try: writeFile(tmp, text) except CatchableError: discard
  app.filePath = tmp
  app.ed.lang = fileExtToLanguage(ext)   # before setText, so it highlights right
  app.ed.setText(text)
  app.docLang = lang.toLowerAscii
  app.curLang = lang.toLowerAscii; app.curSession = sess
  app.editMode = if sessionWide: emSession else: emBlock
  app.srcEdit = true
  refreshObjects(app)
  app.msg = (if sessionWide: "src-edit session '" & sess & "'" else: "src-edit block") &
            " (" & $app.editRanges.len & ")"

proc srcEditExit*(app: var App) =
  if app.editMode == emNone: return
  let edLines = app.ed.fullText().split('\n')
  var bodies: seq[seq[string]]
  if app.editMode == emBlock:
    bodies.add edLines
  else:
    var cur: seq[string]
    var started = false
    for ln in edLines:
      if strutils.strip(ln).startsWith(blockSentinel):
        if started: bodies.add cur
        cur = @[]; started = true
      elif started: cur.add ln
    if started: bodies.add cur
  # trim a trailing blank line off each body (fullText ends with \n)
  for b in bodies.mitems:
    while b.len > 0 and strutils.strip(b[^1]).len == 0: b.setLen(b.len - 1)

  var org = app.orgSaved
  for idx in countdown(app.editRanges.high, 0):
    if idx >= bodies.len: continue
    let r = app.editRanges[idx]
    var reindented: seq[string]
    for ln in bodies[idx]:
      reindented.add (if strutils.strip(ln).len == 0: "" else: spaces(r.indent) & ln)
    org[r.a ..< r.b] = reindented

  app.filePath = app.orgFilePath
  app.ed.lang = fileExtToLanguage(splitFile(app.orgFilePath).ext)  # before setText
  app.ed.setText(org.join("\n"))
  app.docLang = ""
  app.editMode = emNone
  app.srcEdit = false
  app.editRanges = @[]
  app.msg = "src-edit: spliced back"

proc srcEditBlock*(app: var App) =
  if app.editMode != emNone: srcEditExit(app) else: srcEditEnter(app, false)
proc srcEditSession*(app: var App) =
  if app.editMode != emNone: srcEditExit(app) else: srcEditEnter(app, true)

proc terminalTabKey*(i: int): string = "·term:" & $i   # tab key for terminal index i

proc sessionKeys*(app: App): seq[string] =
  for k in app.sessions.keys: result.add k
  sort(result)

proc tabKeys*(app: App): seq[string] =
  ## Every bottom-pane tab, in order: the REPL sessions, then each standalone
  ## terminal (one tab per open terminal). Used for rendering, clicking, cycling.
  result = app.sessionKeys()
  for i in 0 ..< app.terminals.len: result.add terminalTabKey(i)

proc currentTabKey*(app: App): string =
  ## Which tab the pane is showing right now.
  if app.termActive >= 0: terminalTabKey(app.termActive)
  else: app.curLang.toLowerAscii & "/" & app.curSession

proc selectTab*(app: var App; key: string) =
  ## Make `key` the current tab. Selecting a session turns the terminal off (and
  ## vice versa) -- the two were previously independent, so switching was
  ## invisible while the terminal was active.
  app.focus = "session"
  app.termScroll = 0                    # a freshly selected tab starts at the tail
  if key.startsWith("·term:"):
    let idx = (try: parseInt(key["·term:".len .. ^1]) except: -1)
    if idx >= 0 and idx < app.terminals.len:
      app.termActive = idx
      app.msg = "terminal: " & app.terminals[idx].label
    return
  app.termActive = -1
  let parts = key.split('/')
  app.curLang = parts[0]
  app.curSession = if parts.len > 1: parts[1] else: "default"
  refreshObjects(app)
  app.msg = "session: " & key

proc setSession*(app: var App; key: string) = selectTab(app, key)

proc closeTab*(app: var App; key: string) =
  ## Close a bottom-pane tab: kill a terminal, or shut down a REPL session. If
  ## the closed tab was current, fall back to the first remaining tab (or clear
  ## the pane when none are left).
  let wasCurrent = key == app.currentTabKey()
  if key.startsWith("·term:"):
    let idx = (try: parseInt(key["·term:".len .. ^1]) except: -1)
    if idx >= 0 and idx < app.terminals.len:
      closePty(app.terminals[idx].pty)
      app.terminals.delete(idx)
      if app.termActive == idx: app.termActive = -1
      elif app.termActive > idx: dec app.termActive
      app.msg = "closed terminal"
  elif app.sessions.hasKey(key):
    closeSession(app.sessions[key])
    app.sessions.del(key)
    app.msg = "closed session: " & key
  else:
    return
  if wasCurrent:
    let keys = app.tabKeys()
    if keys.len > 0: selectTab(app, keys[0])
    else:
      app.termActive = -1
      app.curLang = ""; app.curSession = ""
      app.focus = "editor"

proc switchSession*(app: var App) =
  ## Cycle to the next bottom-pane tab (sessions and the terminals alike).
  let keys = app.tabKeys()
  if keys.len == 0: app.msg = "no sessions yet"; return
  let cur = app.currentTabKey()
  var i = -1
  for k, name in keys:
    if name == cur: i = k
  selectTab(app, keys[(i + 1) mod keys.len])

proc focusNext*(app: var App) =
  const order = ["editor", "session", "objects", "help"]
  var i = 0
  for k, name in order:
    if name == app.focus: i = k
  app.focus = order[(i + 1) mod order.len]
  app.msg = "focus: " & app.focus

proc openTerminal*(app: var App; cmd: string)   # forward decl (defined below)

proc sshMasterUp(host: string): bool =
  ## Is there a live, authenticated ssh master connection to `host`?
  let (_, code) = execCmdEx("ssh -O check -o ControlPath=" &
    quoteShell(sshControlPath()) & " " & quoteShell(host) & " 2>/dev/null")
  code == 0

proc ensureSshMaster(app: var App; host: string): bool =
  ## True if a master to `host` is up. Otherwise open a terminal to log in (where
  ## the password prompt actually works) and return false -- the user authenticates
  ## once, then re-runs the block, and the marker session reuses the master.
  if sshMasterUp(host): return true
  try: createDir(getHomeDir() / ".ssh") except CatchableError: discard
  openTerminal(app, "ssh -tt -o ControlMaster=auto -o ControlPath=" & sshControlPath() &
                    " -o ControlPersist=" & gSshPersist & " " & host)
  app.msg = "log in to " & host & " in the terminal, then run the block again"
  false

const runningPrefix* = ": [running: job "   ## placeholder line while a block runs

proc resultLines(outp, fileOut: string; rawResults: bool; drawer = false): seq[string] =
  ## The body of a `#+RESULTS:` element for this output.
  if fileOut.len == 0 and drawer:
    # org's `:results drawer`: verbatim (tables render) inside a drawer, which
    # also keeps blank lines from ending the element.
    var lines = outp.split('\n')
    while lines.len > 0 and strutils.strip(lines[0]).len == 0: lines.delete(0)
    while lines.len > 0 and strutils.strip(lines[^1]).len == 0: lines.setLen(lines.len - 1)
    result = @[":RESULTS:"] & lines & @[":END:"]
    return
  if fileOut.len > 0:
    result.add "[[file:" & fileOut & "]]"
  elif strutils.strip(outp).len == 0:
    if not rawResults: result.add ": "
  elif rawResults:
    for ln in outp.split('\n'): result.add ln          # verbatim: org tables render as tables
  else:
    for ln in outp.split('\n'): result.add ": " & ln

proc replacePlaceholder(ed: var SynEdit; placeholder: string;
                        repl: seq[string]): bool =
  ## Swap the unique placeholder line for `repl`, keeping the cursor on the same
  ## text (lines below the placeholder shift by the size difference).
  let total = ed.getLineCount()
  var idx = -1
  for i in 0 ..< total:
    if ed.getLineText(i) == placeholder: idx = i; break
  if idx < 0: return false
  let curLine = ed.currentLine
  let curCol = ed.currentCol
  var lines: seq[string]
  for i in 0 ..< idx: lines.add ed.getLineText(i)
  lines.add repl
  for i in idx + 1 ..< total: lines.add ed.getLineText(i)
  ed.setText(lines.join("\n"))
  let line = if curLine > idx: curLine + repl.len - 1 else: curLine
  ed.gotoLine(min(line, ed.getLineCount() - 1) + 1, curCol)
  ed.markChanged()
  true

proc blockTable*(app: App): seq[BlockInfo] =
  ## The buffer's org src blocks with names, dependencies and current hashes
  ## (document `header-args` defaults included, as babel applies them).
  var lines: seq[string]
  var defaults: Table[string, seq[string]]
  for i in 0 ..< app.ed.getLineCount():
    let ln = app.ed.getLineText(i)
    lines.add ln
    let low = strutils.strip(ln).toLowerAscii
    if low.startsWith("#+begin_src"):
      let t = strutils.splitWhitespace(low)
      if t.len >= 2 and not defaults.hasKey(t[1]): defaults[t[1]] = headerArgTokens(app, t[1])
  result = parseBlocks(lines, defaults)
  discard computeHashes(result)

proc blockAtLine*(blocks: seq[BlockInfo]; line: int): int =
  ## Index of the block whose begin_src..end_src span holds 0-based `line`, or -1.
  for b in blocks:
    if line >= b.header and line <= b.endLine: return b.idx
  -1

proc isFresh*(app: App; b: BlockInfo): bool =
  ## Up to date: its results came from this exact code (and dependencies) AND it
  ## has run successfully in the live session, so its objects exist there.
  b.storedHash.len > 0 and b.storedHash == b.hash and
    b.hash in app.ranIn.getOrDefault(b.lang & "/" & b.session)

proc hasErrorOutput*(outp: string): bool = "\nError" in ("\n" & outp)

proc cacheDir*(app: App): string =
  ## Where `:cache yes` R blocks keep their objects: .wkb-cache/ next to the file.
  if app.filePath.len > 0: parentDir(absolutePath(app.filePath)) / ".wkb-cache"
  else: getTempDir() / "wkb-cache"

proc rStr(s: string): string =
  ## An R string literal.
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc rSaveSnippet(srcFile, rdata: string): string =
  ## Appended to a `:cache yes` R block: save every object the block assigns
  ## (found from its parse tree, as the dependency inference does) so a later
  ## cache hit can restore them instead of re-running -- e.g. after a crash.
  "local({\n" & rAssignedFn & "\n  .wkb_nm <- intersect(assigned(parse(" & rStr(srcFile) &
    ", keep.source = FALSE)), ls(globalenv(), all.names = TRUE))\n" &
    "  save(list = .wkb_nm, envir = globalenv(), file = " & rStr(rdata) & ")\n})\n"

proc noteCtlJob(app: var App; sessKey: string) =
  ## A run started over the control socket (Claude in a terminal tab): show its
  ## session so the output is visible, and remember the tab to return to.
  if not app.ctlOrigin: return
  if not app.ctlReturnSet and app.termActive >= 0:
    app.ctlReturnTab = app.termActive
    app.ctlReturnSet = true
  let parts = sessKey.split('/')
  app.termActive = -1
  app.curLang = parts[0]
  app.curSession = if parts.len > 1: parts[1] else: "default"
  app.sessionHidden = false
  app.termScroll = 0

proc maybeReturnTab(app: var App): bool =
  ## Back to the terminal (Claude) once every control-socket run has finished.
  if not app.ctlReturnSet: return false
  for aj in app.jobs:
    if aj.fromCtl and not aj.applied: return false
  app.ctlReturnSet = false
  if app.ctlReturnTab >= 0 and app.ctlReturnTab < app.terminals.len:
    app.termActive = app.ctlReturnTab
  true

proc noteRan(app: var App; aj: AppJob) =
  ## A block's code ran without errors in this session: it is fresh there.
  if aj.hash.len == 0 or aj.job.state != jsDone or hasErrorOutput(aj.job.output): return
  app.ranIn.mgetOrPut(aj.sessKey, initHashSet[string]()).incl aj.hash

proc overstrikeCR(s: string): string =
  ## What a terminal would leave on screen: progress meters (OpenMx's optimizer
  ## lines, say) redraw one line with bare "\r"; keep only what follows the
  ## last one on each line instead of every overwritten frame. A "\r\n" line
  ## end is not a redraw.
  var lines: seq[string]
  for raw in s.split('\n'):
    var ln = raw
    if ln.len > 0 and ln[^1] == '\r': ln.setLen(ln.len - 1)
    let cr = ln.rfind('\r')
    lines.add(if cr >= 0: ln[cr + 1 .. ^1] else: ln)
  lines.join("\n")

proc finishBabelJob(app: var App; aj: var AppJob) =
  ## Write a finished block's results into its buffer -- the active one or a
  ## background buffer (the user may have switched files while it ran).
  # A REPL on a real terminal (a remote tmux pane, say) colours its output --
  # tibbles via pillar/cli -- and those escapes must not land in #+RESULTS.
  let outp = stripAnsi(overstrikeCR(aj.job.output))
  let repl = resultLines(outp, aj.fileOut, aj.rawResults, aj.drawerResults)
  var placed = false
  if app.filePath == aj.filePath:
    placed = replacePlaceholder(app.ed, aj.placeholder, repl)
  else:
    for i in 0 ..< app.buffers.len:
      if app.buffers[i].filePath == aj.filePath:
        placed = replacePlaceholder(app.buffers[i].ed, aj.placeholder, repl)
        break
  aj.applied = true
  app.lastBlockOutput = outp
  let what = "job " & $aj.job.id & " (" & aj.label & ")"
  app.msg =
    if not placed: what & " finished, but its results placeholder is gone"
    elif aj.job.state == jsInterrupted: what & " interrupted"
    else: "babel: ran " & what
  app.runHooks("after-babel")

const fetchTag = "WKBIMG"

proc queueFetch(app: var App; aj: AppJob) =
  ## A figure block that ran in a REMOTE R session wrote its :file on the host;
  ## the [[file:...]] link points here. Bring the bytes back through the same
  ## session (hex on one line) -- a scp would need another ssh channel, and the
  ## host may refuse one (sessions per connection are capped).
  if aj.fileOut.len == 0 or '@' notin aj.sessKey or not aj.sessKey.startsWith("r/"): return
  if hasErrorOutput(aj.job.output) or not app.sessions.hasKey(aj.sessKey): return
  let s = app.sessions[aj.sessKey]
  if s == nil or not s.pty.alive: return
  let f = aj.fileOut.replace("\\", "\\\\").replace("\"", "\\\"")
  # hex in 4 KB lines: one huge line is hard on the live pane that shows it
  let code = "local({ f <- \"" & f & "\"; if (!file.exists(f)) cat(\"" & fetchTag &
    " missing\\n\") else { b <- readBin(f, \"raw\", file.size(f)); cat(\"" & fetchTag &
    "\", length(b), \"\\n\"); h <- sprintf(\"%02x\", as.integer(b)); " &
    "for (i in seq(1, length(h), by = 2048)) cat(paste(h[i:min(i + 2047, length(h))], " &
    "collapse = \"\"), \"\\n\", sep = \"\") } })\n"
  let j = s.submit(code)
  let base = if aj.filePath.len > 0: aj.filePath.parentDir else: getCurrentDir()
  app.jobs.add AppJob(kind: jkFetch, job: j, sessKey: aj.sessKey,
                      label: "fetch " & aj.fileOut, filePath: aj.filePath,
                      localPath: (if aj.fileOut.isAbsolute: aj.fileOut else: base / aj.fileOut),
                      fromCtl: aj.fromCtl)

proc finishFetch(app: var App; aj: AppJob) =
  ## Decode a fetch job's hex line and write the file locally.
  let outp = aj.job.output
  let at = outp.find(fetchTag & " ")
  var ok = false
  if at >= 0:
    let parts = outp[at + fetchTag.len + 1 .. ^1].splitWhitespace()
    if parts.len >= 2 and parts[0] != "missing":
      try:
        let n = parseInt(parts[0])
        let bytes = parseHexStr(parts[1 .. ^1].join(""))
        if bytes.len == n:
          createDir(aj.localPath.parentDir)
          writeFile(aj.localPath, bytes)
          ok = true
      except CatchableError: discard
  app.msg = (if ok: "fetched " else: "could not fetch ") & aj.localPath.extractFilename &
            (if ok: "" else: " from the session's host")

proc pollJobs*(app: var App): bool =
  ## Host loop, every frame: advance every session's runs without blocking and
  ## deliver finished ones. Returns true if anything finished (redraw).
  var done: seq[RunJob]
  for s in app.sessions.values:           # collect first: finishing runs hooks
    done.add pollSession(s)
  if done.len == 0: return maybeReturnTab(app)
  for j in done:
    for i in 0 ..< app.jobs.len:
      if app.jobs[i].job == j and not app.jobs[i].applied:
        if app.jobs[i].kind != jkFetch:       # (a fetch's hex isn't worth logging)
          app.sess.appendOutput("# " & app.jobs[i].label & " [job " & $j.id & "]\n" &
                                j.output & "\n")
        noteRan(app, app.jobs[i])
        if app.jobs[i].kind == jkBlock:
          var aj = app.jobs[i]
          finishBabelJob(app, aj)
          app.jobs[i] = aj
          queueFetch(app, aj)
        elif app.jobs[i].kind == jkFetch:
          app.jobs[i].applied = true
          finishFetch(app, app.jobs[i])
        else:
          app.jobs[i].applied = true
          if app.jobs[i].kind == jkCacheLoad:
            app.msg = "job " & $j.id & " (" & app.jobs[i].label & ") " &
                      (if hasErrorOutput(j.output): "failed" else: "restored cached objects")
        break
  # Keep a bounded history of finished jobs for `ctl status`.
  var keep: seq[AppJob]
  var finished = 0
  for i in countdown(app.jobs.high, 0):
    if app.jobs[i].applied:
      inc finished
      if finished > 200: continue
    keep.insert(app.jobs[i], 0)
  app.jobs = keep
  let cs = currentSession(app)
  if cs != nil and not cs.busy: refreshObjects(app)
  discard maybeReturnTab(app)
  true

proc findJob(app: var App; id: int): int =
  for i, aj in app.jobs:
    if aj.job.id == id: return i
  -1

proc submitEval*(app: var App; lang, name, code: string): int =
  ## Queue ad-hoc code in a session (ctl eval / Ctrl-Enter); returns the job id,
  ## or 0 if no session could be started.
  let s = getSession(app, lang, name)
  if s == nil: return 0
  let j = s.submit(code)
  app.jobs.add AppJob(kind: jkEval, job: j, sessKey: lang.toLowerAscii & "/" & name,
                      label: lang.toLowerAscii & " eval [" & name & "]",
                      fromCtl: app.ctlOrigin)
  noteCtlJob(app, lang.toLowerAscii & "/" & name)
  j.id

proc jobStateName(st: JobState): string =
  case st
  of jsQueued: "queued"
  of jsRunning: "running"
  of jsDone: "done"
  of jsInterrupted: "interrupted"

proc jobLine(aj: AppJob): string =
  let j = aj.job
  let t = if j.started == 0: 0.0
          elif j.finished > 0: j.finished - j.started
          else: epochTime() - j.started
  $j.id & "\t" & jobStateName(j.state) & "\t" & aj.label & "\t" &
    formatFloat(t, ffDecimal, 1) & "s"

proc jobStatus*(app: var App; id: int): string =
  ## `ctl status <id>`: "<id>\t<state>\t<label>\t<secs>", then the output once
  ## the job has finished.
  let i = findJob(app, id)
  if i < 0: return $id & "\tunknown"
  result = jobLine(app.jobs[i])
  if app.jobs[i].job.state in {jsDone, jsInterrupted}:
    result.add "\n" & app.jobs[i].job.output

proc jobsSummary*(app: App): string =
  ## `ctl jobs`: one line per tracked job, oldest first.
  for aj in app.jobs: result.add jobLine(aj) & "\n"
  if result.len == 0: result = "(no jobs)"

proc runningJobsLabel*(app: App): string =
  ## Short status-bar text while anything is queued or running, else "".
  var running, queued = 0
  for aj in app.jobs:
    case aj.job.state
    of jsRunning: inc running
    of jsQueued: inc queued
    else: discard
  if running + queued == 0: return ""
  $running & " running" & (if queued > 0: ", " & $queued & " queued" else: "")

proc jobStrip*(app: App): string =
  ## Session-panel tab-bar text: what is running (label, session, elapsed) and
  ## how many runs wait behind it -- so runs queued from anywhere (C-c C-c,
  ## `wkbctl`, an agent) are visible while they work, even when silent.
  var queued = 0
  var running: seq[string]
  for aj in app.jobs:
    case aj.job.state
    of jsQueued: inc queued
    of jsRunning:
      let secs = int(epochTime() - aj.job.started)
      let el = (if secs >= 3600: $(secs div 3600) & "h" & align($((secs mod 3600) div 60), 2, '0') & "m"
                else: $(secs div 60) & ":" & align($(secs mod 60), 2, '0'))
      let sess = aj.sessKey[aj.sessKey.find('/') + 1 .. ^1]
      let at = sess.find('@')
      let short = if at > 0: sess[0 ..< at] else: sess
      running.add "▶ " & aj.label & " [" & short & "] " & el
    else: discard
  if running.len == 0 and queued == 0: return ""
  result = running.join("  ")
  if queued > 0: result.add (if result.len > 0: "  ·  " else: "") & $queued & " queued"

proc interruptJob*(app: var App; id: int): string =
  ## Stop a queued or running job; a block's placeholder becomes the partial
  ## output plus "(interrupted)".
  let i = findJob(app, id)
  if i < 0: return "unknown job " & $id
  if app.jobs[i].job.state in {jsDone, jsInterrupted}: return "job " & $id & " already finished"
  let s = if app.sessions.hasKey(app.jobs[i].sessKey): app.sessions[app.jobs[i].sessKey] else: nil
  if s == nil or s.interrupt(id) == nil:
    # Orphaned (its session died or is gone): nothing to stop, just retire it so
    # it no longer blocks recompile or leaves its placeholder "running".
    app.jobs[i].job.state = jsInterrupted
    app.jobs[i].job.output = "(interrupted: its session had ended)"
    app.jobs[i].job.finished = epochTime()
  if app.jobs[i].kind == jkBlock:
    var aj = app.jobs[i]
    finishBabelJob(app, aj)
    app.jobs[i] = aj
  else: app.jobs[i].applied = true
  "ok: interrupted job " & $id

proc babelExecuteImpl(app: var App; force: bool) =
  ## C-c C-c: queue the src block at the cursor. `force` ignores `:cache yes`.
  let total = app.ed.getLineCount()
  let cur = app.ed.currentLine
  var b = -1
  var header = ""
  var isRmd = false
  for i in countdown(cur, 0):
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src"):
      b = i; header = strutils.strip(app.ed.getLineText(i)); break
    if low.startsWith("```"):
      # Rmd chunk opener: ```{r ...} (or a closing ``` that ends the chunk).
      # Match on the opener line itself too (cursor on the fence), but a plain
      # ``` above the cursor means we're not inside an R chunk.
      if "{r" in low or "{r," in low or low.startsWith("```{r"):
        b = i; header = strutils.strip(app.ed.getLineText(i)); isRmd = true; break
      elif i < cur:
        break   # a plain ``` fence above the cursor: not inside an R chunk
    if low.startsWith("#+end_src") and i < cur: break
  if b < 0: app.msg = "not in a src block"; return
  var e = -1
  for i in b + 1 ..< total:
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if (if isRmd: low.startsWith("```") else: low.startsWith("#+end_src")):
      e = i; break
  if e < 0 or cur > e: app.msg = "not in a src block"; return

  let hdr = strutils.splitWhitespace(header)
  var lang = if hdr.len >= 2: hdr[1] else: ""
  if isRmd:
    # Rmd chunk header is ```{r ...}; the language is the token after the brace.
    lang = "r"
  var sessName, host, dir, meth, fileOut = ""
  var gRes = 0
  var gW, gH, gType, gUnits = ""   # width/height kept as written: 9, 4.5, ...
  var rawResults, drawerResults = false
  # Parse :session / :ssh / :dir / :file / :width / :height / :res / :type from
  # a token list; only fill unset fields (so the BLOCK header wins over document
  # #+PROPERTY defaults, applied after).
  proc apply(toks: seq[string]) =
    var k = 0
    while k < toks.len:
      if toks[k] == ":session" and k + 1 < toks.len and sessName.len == 0:
        sessName = toks[k + 1]
      elif toks[k] == ":ssh" and k + 1 < toks.len and host.len == 0:
        host = toks[k + 1]
      elif toks[k] == ":dir" and k + 1 < toks.len and dir.len == 0 and host.len == 0:
        let (h, p, m) = parseSshDir(toks[k + 1])
        if h.len > 0:
          host = h
          meth = m
        dir = p
      elif toks[k] == ":file" and k + 1 < toks.len and fileOut.len == 0:
        fileOut = toks[k + 1]
      elif toks[k] == ":width" and k + 1 < toks.len and gW.len == 0:
        if (try: (discard parseFloat(toks[k + 1]); true) except: false): gW = toks[k + 1]
      elif toks[k] == ":height" and k + 1 < toks.len and gH.len == 0:
        if (try: (discard parseFloat(toks[k + 1]); true) except: false): gH = toks[k + 1]
      elif toks[k] == ":units" and k + 1 < toks.len and gUnits.len == 0:
        gUnits = toks[k + 1]
      elif toks[k] == ":res" and k + 1 < toks.len and gRes == 0:
        gRes = (try: parseInt(toks[k + 1]) except: 0)
      elif toks[k] == ":type" and k + 1 < toks.len and gType.len == 0:
        gType = toks[k + 1]
      elif toks[k] == ":results":
        # `:results output raw` (or `org`) means org splices the output verbatim
        # instead of `: `-prefixing it, so emitted org tables render as tables.
        var j = k + 1
        while j < toks.len and not toks[j].startsWith(":"):
          if toks[j] == "raw" or toks[j] == "org": rawResults = true
          if toks[j] == "drawer": rawResults = true; drawerResults = true
          inc j
      inc k
  # Per-block `#+header:` lines directly above `#+begin_src` carry args too --
  # org conventionally puts :width/:height/:res/:type there, not on the
  # begin_src line, so gather them (nearest line first) and apply them.
  var headerLineArgs: seq[string]
  if not isRmd:
    var h = b - 1
    while h >= 0:
      let hl = strutils.strip(app.ed.getLineText(h))
      if hl.toLowerAscii.startsWith("#+header:"):
        for t in strutils.splitWhitespace(hl)[1 .. ^1]: headerLineArgs.add t
        dec h
      else: break
  apply(strutils.splitWhitespace(header)[2 .. ^1])   # the block header first
  apply(headerLineArgs)                              # then #+header: lines
  apply(headerArgTokens(app, lang))                  # then document defaults
  if sessName.len == 0: sessName = "default"
  if host.len > 0 and '@' notin sessName:
    sessName = sessName & "@" & host
    if meth.len > 0:
      if not gRemoteMethods.hasKey(meth):
        app.msg = "no remote method '" & meth & "' (defineRemoteMethod in your config)"; return
      sessName.add "|" & meth
  if host.len > 0 and not ensureSshMaster(app, host): return   # authenticate first

  var bodyLines: seq[string]
  for i in b + 1 ..< e: bodyLines.add app.ed.getLineText(i)
  app.curLang = lang.toLowerAscii; app.curSession = sessName   # keys are lower-lang
  # A remote session starts in `dir` (the :dir path on the host); a local one
  # ignores it (getSession uses `dir` only for remote sessions, at creation).
  let s = getSession(app, lang, sessName, dir)
  if s == nil:
    app.msg = if host.len > 0:
                "could not start " & lang & " on " & host &
                  " -- check that `ssh " & host & "` gives a shell (password expired? qsub rejected?)"
              else: "no session for '" & lang & "'"
    return

  # A `:file <path>` header (with graphics results) means the block draws a
  # figure: wrap the body in a graphics device so R saves it, then insert a
  # [[file:...]] link below the block instead of the raw output.
  var body = dedentBody(bodyLines)
  if fileOut.len > 0:
    let ext = splitFile(fileOut).ext.toLowerAscii
    let dev = case ext
      of ".png": "png"
      of ".pdf": "pdf"
      of ".svg": "svg"
      of ".jpeg", ".jpg": "jpeg"
      of ".bmp": "bmp"
      of ".tiff", ".tif": "tiff"
      else: "png"
    var devArgs = "\"" & fileOut & "\""
    if gW.len > 0: devArgs.add ", width=" & gW
    if gH.len > 0: devArgs.add ", height=" & gH
    # Bitmap devices take `units` (default px: ":width 9 :units in" without it
    # made a 9-PIXEL-wide image); pdf/svg are always inches and reject it.
    if gUnits.len > 0 and dev notin ["pdf", "svg"]: devArgs.add ", units=\"" & gUnits & "\""
    if gRes > 0: devArgs.add ", res=" & $gRes
    if gType.len > 0: devArgs.add ", type=\"" & gType & "\""
    body = (if lang.toLowerAscii == "r": "dir.create(dirname(\"" & fileOut &
              "\"), recursive=TRUE, showWarnings=FALSE)\n" else: "") &
           dev & "(" & devArgs & ")\n" & body & "\ntry(dev.off(), silent=TRUE)\n"

  # A block whose previous run is still going keeps its placeholder: queuing it
  # again would overwrite that line and leave the first run nowhere to land.
  var p = e + 1
  while p < total and strutils.strip(app.ed.getLineText(p)).len == 0: inc p
  let hasResults = p < total and
    strutils.strip(app.ed.getLineText(p)).toLowerAscii.startsWith("#+results")   # also #+RESULTS[hash]:
  if hasResults and p + 1 < total and app.ed.getLineText(p + 1).startsWith(runningPrefix):
    app.msg = "block already running (" &
              strutils.strip(app.ed.getLineText(p + 1)).strip(chars = {':', ' ', '[', ']'}) & ")"
    return

  # Content hash (org blocks; Rmd chunks keep plain results): code + header args
  # + the hashes of its :depends/:var dependencies, stored in #+RESULTS[hash].
  let sessKey = lang.toLowerAscii & "/" & sessName
  var bi: BlockInfo
  var haveInfo = false
  if not isRmd:
    for x in blockTable(app):
      if x.header == b: bi = x; haveInfo = true; break
  let isR = lang.toLowerAscii == "r"
  let rdata = if haveInfo: cacheDir(app) / (bi.hash & ".RData") else: ""
  # `:cache yes` and unchanged since its results were made: don't re-run it.
  # If the session lacks its objects (restarted, crashed), an R block reloads
  # them from its cache file instead; one never saved there simply runs.
  if haveInfo and bi.cache and not force and hasResults and bi.storedHash == bi.hash:
    if bi.hash in app.ranIn.getOrDefault(sessKey) or not isR:
      app.msg = "cache hit: results up to date (babel-execute-force re-runs it)"
      return
    if fileExists(rdata):
      let lj = s.submit("load(" & rStr(rdata) & ", envir = globalenv())\n")
      app.jobs.add AppJob(kind: jkCacheLoad, job: lj, sessKey: sessKey,
                          label: "r cache load @line " & $(b + 1), hash: bi.hash,
                          filePath: app.filePath, fromCtl: app.ctlOrigin)
      app.lastJobIds.add lj.id
      noteCtlJob(app, sessKey)
      app.msg = "cache hit: restoring the block's objects (job " & $lj.id & ")"
      return
  if haveInfo and bi.cache and isR:
    # Keep the block's code next to its objects: the save snippet parses it to
    # find what the block assigns.
    try:
      createDir(cacheDir(app))
      let src = cacheDir(app) / (bi.hash & ".R")
      writeFile(src, dedentBody(bodyLines))
      body.add "\n" & rSaveSnippet(src, rdata)
    except CatchableError:
      app.msg = "cache: cannot write " & cacheDir(app)

  # Queue the run and return at once: the results land when the job finishes
  # (pollJobs, from the host loop), so long model fits no longer freeze the
  # editor and there is no silence timeout. Until then #+RESULTS holds a unique
  # placeholder line that finishBabelJob replaces.
  let job = s.submit(body)
  let placeholder = runningPrefix & $job.id & "]"
  var removeTo = e + 1
  if hasResults:
    inc p
    # Remove the whole previous results element, not just `:`-prefixed lines, so
    # `[[file:...]]` links and raw org tables are replaced instead of stacking.
    # Stop at a blank line, the next block/heading, or EOF.
    if p < total and strutils.strip(app.ed.getLineText(p)).toUpperAscii == ":RESULTS:":
      # a drawer: everything through its :END:, blank lines included
      var q = p + 1
      while q < total and strutils.strip(app.ed.getLineText(q)).toUpperAscii != ":END:": inc q
      if q < total: p = q + 1
    else:
      while p < total:
        let t = strutils.strip(app.ed.getLineText(p))
        if t.len == 0 or t.startsWith("#+") or t.startsWith("*"): break
        inc p
    removeTo = p

  var outLines: seq[string]
  for i in 0 .. e: outLines.add app.ed.getLineText(i)
  outLines.add ""
  outLines.add(if haveInfo: "#+RESULTS[" & bi.hash & "]:" else: "#+RESULTS:")
  outLines.add placeholder
  for i in removeTo ..< total: outLines.add app.ed.getLineText(i)

  app.ed.setText(outLines.join("\n"))
  app.ed.gotoLine(min(cur, app.ed.getLineCount() - 1) + 1, 0)   # gotoLine is 1-based
  app.jobs.add AppJob(kind: jkBlock, job: job,
                      sessKey: lang.toLowerAscii & "/" & sessName,
                      label: (if lang.len > 0: lang else: "?") & " block @line " & $(b + 1),
                      filePath: app.filePath, placeholder: placeholder,
                      fileOut: fileOut, rawResults: rawResults, drawerResults: drawerResults,
                      hash: (if haveInfo: bi.hash else: ""), fromCtl: app.ctlOrigin)
  app.lastJobIds.add job.id
  noteCtlJob(app, sessKey)
  if fileOut.len == 0:                  # textual output: show the live session pane,
    app.sessionHidden = false           # but keep typing in the editor while it runs
  app.msg = "babel: queued " & (if lang.len > 0: lang else: "?") & " block (job " &
            $job.id & ")"

proc babelExecute*(app: var App) = babelExecuteImpl(app, false)
proc babelExecuteForce*(app: var App) = babelExecuteImpl(app, true)

proc queueBlockAt(app: var App; idx: int; force: bool) =
  ## Queue block `idx` (re-located: earlier placeholders shift lines).
  let blocks = blockTable(app)
  if idx < 0 or idx >= blocks.len: return
  app.ed.gotoLine(blocks[idx].header + 2, 0)   # 1-based: the first body line
  babelExecuteImpl(app, force)

proc queuedReply(app: App): string = "queued: jobs " & app.lastJobIds.mapIt($it).join(" ")

proc babelExecuteDeps*(app: var App): string {.discardable.} =
  ## Run the block at the cursor after its transitive dependencies (`:depends`,
  ## `:var`), dependencies first; dependencies already fresh in the session are
  ## skipped (make-style). Returns the ctl reply.
  let cur = app.ed.currentLine
  let blocks = blockTable(app)
  let target = blockAtLine(blocks, cur)
  if target < 0:
    app.msg = "not in a src block"; return "error: not in a src block"
  var problems: seq[string]
  let order = dependencyOrder(blocks, target, problems)
  if problems.len > 0:
    app.msg = "deps: " & problems[0]; return "error: " & problems.join("; ")
  app.lastJobIds.setLen(0)
  var skipped = 0
  for idx in order:
    let bs = blockTable(app)
    if idx != target and isFresh(app, bs[idx]): inc skipped; continue
    queueBlockAt(app, idx, false)
  let bs = blockTable(app)
  app.ed.gotoLine(bs[target].header + 2, 0)
  app.msg = "deps: queued " & $app.lastJobIds.len & " job(s); " & $skipped &
            " dependenc" & (if skipped == 1: "y" else: "ies") & " already up to date"
  queuedReply(app)

proc babelExecuteDepsCmd(app: var App) = discard babelExecuteDeps(app)

proc runStale*(app: var App): string {.discardable.} =
  ## Queue every block that is not fresh -- its code or a dependency changed
  ## since its results were made, or it has not run in the live session (e.g.
  ## after a restart) -- top to bottom. Cached R blocks restore from disk.
  let cur = app.ed.currentLine
  app.lastJobIds.setLen(0)
  let n = blockTable(app).len
  var stale = 0
  for idx in 0 ..< n:
    let bs = blockTable(app)
    if idx >= bs.len: break
    if not gRepls.hasKey(bs[idx].lang) or isFresh(app, bs[idx]): continue
    inc stale
    queueBlockAt(app, idx, false)
  app.ed.gotoLine(min(cur, app.ed.getLineCount() - 1) + 1, 0)
  app.msg = "run-stale: " & $stale & " of " & $n & " blocks stale, " &
            $app.lastJobIds.len & " job(s) queued"
  queuedReply(app)

proc runStaleCmd(app: var App) = discard runStale(app)

proc inferBlockDeps*(app: var App): string {.discardable.} =
  ## Infer each R block's dependencies from what it reads and what earlier
  ## blocks (same session) assign, then rewrite the `:depends` header args --
  ## naming the blocks that are depended on (`#+name:`) where needed. The change
  ## is shown in the diff pane; undo by editing (or reverting) as usual.
  let blocks = blockTable(app)
  var rIdx: seq[int]
  var bodies: seq[string]
  for b in blocks:
    if b.lang == "r":
      rIdx.add b.idx; bodies.add b.body
  if rIdx.len == 0:
    app.msg = "infer-block-deps: no R blocks"; return app.msg
  var err = ""
  let found = rSymbols(bodies, err)
  if err.len > 0:
    app.msg = "infer-block-deps: " & err; return app.msg
  var syms = newSeq[SymInfo](blocks.len)
  for k, i in rIdx: syms[i] = found[k]
  let inferred = inferDepends(blocks, syms, ["r"])
  var names = newSeq[string](blocks.len)
  var taken: HashSet[string]
  for b in blocks:
    names[b.idx] = b.name
    if b.name.len > 0: taken.incl b.name
  for deps in inferred:
    for j in deps:
      if names[j].len == 0:
        names[j] = suggestName(blocks[j], syms[j], taken)
        taken.incl names[j]
  var lines: seq[string]
  for i in 0 ..< app.ed.getLineCount(): lines.add app.ed.getLineText(i)
  let old = lines.join("\n")
  var headers, named = 0
  for i in countdown(blocks.high, 0):           # bottom-up: insertions keep indices valid
    let b = blocks[i]
    if b.lang != "r" or not syms[i].ok: continue
    let ln = lines[b.header]
    let indent = ln[0 ..< ln.len - ln.strip(trailing = false).len]
    let toks = strutils.splitWhitespace(ln)
    var keep: seq[string]
    var k = 0
    while k < toks.len:
      if toks[k] == ":depends":
        inc k
        while k < toks.len and not toks[k].startsWith(":"): inc k
      else:
        keep.add toks[k]; inc k
    if inferred[i].len > 0:
      keep.add ":depends"
      for j in inferred[i]: keep.add refName(names[j])
    let newLn = indent & keep.join(" ")
    if newLn != ln:
      lines[b.header] = newLn; inc headers
    if b.name.len == 0 and names[i].len > 0:
      lines.insert(indent & "#+name: " & names[i], b.header); inc named
  let newText = lines.join("\n")
  if newText == old:
    app.msg = "infer-block-deps: headers already match (" & $rIdx.len & " R blocks)"
    return app.msg
  let curLine = app.ed.currentLine
  app.ed.setText(newText)
  app.ed.markChanged()
  app.ed.gotoLine(min(curLine, app.ed.getLineCount() - 1) + 1, 0)
  showDiff(app, old, newText, "infer-block-deps", app.filePath)
  app.msg = "infer-block-deps: " & $headers & " header(s) updated, " & $named &
            " block(s) named (" & $rIdx.len & " R blocks)"
  app.msg

proc inferBlockDepsCmd(app: var App) = discard inferBlockDeps(app)

proc srcBlockHeaderLines(app: App): seq[int] =
  ## 0-based line indices of every `#+begin_src` / ```{r} header in the buffer.
  let total = app.ed.getLineCount()
  for i in 0 ..< total:
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src") or low.startsWith("```{r"):
      result.add i

proc babelExecuteBuffer*(app: var App): string {.discardable.} =
  ## Queue every src block in the buffer, top to bottom, each in its own
  ## `:session` -- the buffer-wide `C-c C-c`. Blocks are re-scanned each
  ## iteration because each block's `#+RESULTS` placeholder shifts the lines
  ## below it. Runs in the same session execute in buffer order (the session
  ## queue is FIFO); different sessions run in parallel. Returns
  ## "queued: jobs <id> <id> ..." (the ctl `run-all` reply: the client waits on
  ## those ids and reports errors per block).
  let n = srcBlockHeaderLines(app).len
  var ids: seq[string]
  for idx in 0 ..< n:
    let headers = srcBlockHeaderLines(app)   # re-scan: placeholders shifted lines
    if idx >= headers.len: break
    app.ed.gotoLine(min(headers[idx] + 2, app.ed.getLineCount()), 0)  # a body line
    app.lastJobIds.setLen(0)
    babelExecute(app)
    for id in app.lastJobIds: ids.add $id
  app.msg = "run-all: queued " & $ids.len & " of " & $n & " blocks"
  "queued: jobs " & ids.join(" ")

proc babelExecuteBufferCmd*(app: var App) =
  ## Command wrapper (M-x run-all / keybinding): run all blocks, leave the
  ## summary in the status line.
  discard babelExecuteBuffer(app)

proc detectRebuildCmd*(): string =
  ## The command C-c r runs to rebuild wkbenchless. Prefer a toolchain bundled under
  ## <appdir>/toolchain so hot-reload needs no system compiler: a Nim under
  ## toolchain/nim/bin (it finds its own stdlib beside it) and, if present, zig
  ## as the hermetic C backend (single binary, ships its own libc, cross-
  ## compiles -- the user's pick over tcc). Falls back to the system `nim`.
  let base = "c --hints:off -o:wkbenchless src/wkbenchless.nim"
  let dir = getAppDir()
  let bnim = dir / "toolchain" / "nim" / "bin" / "nim"
  let bzig = dir / "toolchain" / "zig" / "zig"
  let nimExe = if fileExists(bnim): bnim.quoteShell else: "nim"
  if fileExists(bzig):
    let cc = (bzig & " cc").quoteShell     # Nim drives zig as a clang-alike
    result = nimExe & " " & "--cc:clang --clang.exe:" & cc &
             " --clang.linkerexe:" & cc & " " & base
  else:
    result = nimExe & " " & base

proc writeHandoff(app: var App): string =
  ## Preserve live REPL sessions and the terminal across the re-exec: clear
  ## FD_CLOEXEC on each pty master so it survives execv (the child processes stay
  ## alive on the slave side), and record fd+pid+identity in a temp file the new
  ## image adopts. Returns the file path ("" if nothing to hand off).
  when defined(posix):
    var blob = ""
    for key, s in app.sessions:
      # Only ready sessions: the new image adopts them AS ready. One still
      # logging in is dropped (a tmux one is just reattached on the next run).
      if s != nil and s.pty.alive and s.phase == spReady:
        discard fcntl(s.pty.master, F_SETFD, 0.cint)     # clear CLOEXEC
        let parts = key.split('/')
        blob.add "S\t" & $s.pty.master & "\t" & $s.pty.pid & "\t" &
                 parts[0] & "\t" & (if parts.len > 1: parts[1] else: "default") & "\n"
        for h in app.ranIn.getOrDefault(key):   # what already ran there stays fresh
          blob.add "H\t" & key & "\t" & h & "\n"
    for i, t in app.terminals:
      if t.pty.alive:
        discard fcntl(t.pty.master, F_SETFD, 0.cint)
        blob.add "T\t" & $t.pty.master & "\t" & $t.pty.pid & "\t" &
                 t.label & "\t" & $i & "\t" & $app.termActive & "\t" &
                 t.cmd & "\n"
    if blob.len == 0: return ""
    let path = getTempDir() / ("wkbenchless-handoff." & $getpid())
    writeFile(path, blob)
    path
  else: ""

proc adoptHandoff*(app: var App): tuple[terminals: seq[Terminal]; active: int] =
  ## If a hot reload handed off sessions/terminals (WKB_HANDOFF), rebuild the REPL
  ## sessions here and return the inherited terminals (fd/pid/label/cmd) for the
  ## host to adopt, plus the index that was active. Called once at startup after
  ## configure() (so gRepls is populated).
  result = (terminals: @[], active: -1)
  when defined(posix):
    let path = getEnv("WKB_HANDOFF")
    if path.len == 0 or not fileExists(path): return
    let blob = readFile(path)
    removeFile(path); delEnv("WKB_HANDOFF")
    for line in blob.splitLines():
      let f = line.split('\t')
      if f.len == 3 and f[0] == "H":
        app.ranIn.mgetOrPut(f[1], initHashSet[string]()).incl f[2]
        continue
      if f.len < 5: continue
      let fd = cint(parseInt(f[1]))
      discard fcntl(fd, F_SETFL, O_NONBLOCK)
      discard fcntl(fd, F_SETFD, FD_CLOEXEC)             # re-arm for the next reload
      if f[0] == "S" and gRepls.hasKey(f[3]):
        let sess = Session(pty: Pty(master: fd, pid: Pid(parseInt(f[2]))),
                           spec: specFor(gRepls[f[3]], f[4]))   # remote: keeps its stager
        if sess.spec.tmuxName.len > 0:
          # The child is `tmux -CC`, already in control mode: without the
          # adapter, the prime below would be sent to tmux AS commands.
          sess.pty.tmuxTarget = sess.spec.tmuxName
          sess.pty.ctlActive = true
        # Re-define the run driver so a reload also upgrades it in live sessions
        # (the REPL reads it once it is idle; its echo is filtered from the pane).
        sess.pty.feed(sess.spec.prime)
        app.sessions[f[3] & "/" & f[4]] = sess
      elif f[0] == "T":
        let idx = (if f.len > 4: (try: parseInt(f[4]) except: -1) else: -1)
        result.terminals.add Terminal(
          pty: Pty(master: fd, pid: Pid(parseInt(f[2]))),
          label: f[3], cmd: (if f.len > 6: f[6] else: f[3]), started: true)
        if f.len > 5 and f[5] == $idx: result.active = idx

proc nimblePkgSourceDir(): string =
  ## For a binary put on PATH by `nimble install <github-url>` (which lands in
  ## ~/.nimble/bin while the sources live under ~/.nimble/pkgs2/<pkg>-<hash>/):
  ## the newest wkbenchless-* package dir that actually carries the source.
  for base in [getHomeDir() / ".nimble" / "pkgs2",
               getHomeDir() / ".nimble" / "pkgs"]:
    if not dirExists(base): continue
    var best = ""
    var bestT: times.Time
    for kind, path in walkDir(base):
      if kind == pcDir and lastPathPart(path).startsWith("wkbenchless-") and
         fileExists(path / "src" / "wkbenchless.nim"):
        let t = getLastModificationTime(path / "src" / "wkbenchless.nim")
        if best.len == 0 or t > bestT: best = path; bestT = t
    if best.len > 0: return best

proc resolveBuildDir(): string =
  ## Directory to run the reload rebuild in -- one that actually has src/.
  ## In order: alongside the binary (working tree, or an install that kept its
  ## source); the git checkout this binary was compiled from; else the nimble
  ## package source dir (installed via a github URL). Falls back to getAppDir()
  ## so the caller's existing "no src -> fail" message still fires if all miss.
  if dirExists(getAppDir() / "src"): return getAppDir()
  const SourceRoot = currentSourcePath().parentDir.parentDir  # <repo>/src/.. = <repo>
  if dirExists(SourceRoot / ".git") and dirExists(SourceRoot / "src"):
    return SourceRoot
  let nimbleSrc = nimblePkgSourceDir()
  if nimbleSrc.len > 0: return nimbleSrc
  if dirExists(SourceRoot / "src"): return SourceRoot   # last resort: no .git, still there
  return getAppDir()

proc recompileConfig*(app: var App) =
  ## Hot-reload the config the honest way for compiled Nim (the xmonad model):
  ## rebuild the binary -- which recompiles wkbconfig.nim with it -- and, on
  ## success, re-exec ourselves, handing off the current file and cursor line.
  ## A compile error is shown in the session pane and nothing is replaced.
  when not defined(posix):
    app.msg = "recompile: only implemented on POSIX so far"
    return
  else:
    let busy = runningJobsLabel(app)
    if busy.len > 0:              # jobs are not handed off: their results would be lost
      app.msg = "recompile: jobs in progress (" & busy & ") -- wait, or interrupt them first"
      return
    app.msg = "recompiling..."
    # Rebuild from a directory that actually has the source (see resolveBuildDir).
    # When the binary was `nimble install`ed, getAppDir() can be a binary-only
    # dir with no src/, where rebuilding fails silently. This self-heals: a
    # successful reload re-execs the freshly built binary from the resolved dir.
    let dir = resolveBuildDir()
    if gRebuildCmd.len == 0: gRebuildCmd = detectRebuildCmd()
    let (outp, code) = execCmdEx(gRebuildCmd, workingDir = dir)
    if code != 0:
      stderr.write("-- recompile FAILED --\n$ " & gRebuildCmd & "\n" & outp & "\n")
      # surface the first real error line in the status bar
      var firstErr = ""
      for ln in outp.splitLines():
        if "Error:" in ln or " error:" in ln: firstErr = strutils.strip(ln); break
      app.msg = "recompile failed" & (if firstErr.len > 0: " -- " & firstErr else: " (see launch terminal)")
      return
    # persist the buffer so edits survive the exec
    var fileArg = app.filePath
    if fileArg.len == 0:
      fileArg = getTempDir() / "wkbenchless-scratch.org"
      writeFile(fileArg, app.ed.fullText())
    elif app.ed.changed:
      app.ed.saveToFile(app.filePath); app.ed.markSaved()
    let line = app.ed.currentLine
    # Hand the live sessions + terminal off to the new image instead of killing
    # them: their pty masters survive execv (CLOEXEC cleared) and, because execv
    # keeps our PID, we stay the parent of those child processes.
    let handoff = writeHandoff(app)
    # Exec the freshly built binary by its known path, NOT getAppFilename():
    # the rebuild replaced our on-disk file, so /proc/self/exe now reads
    # ".../wkbenchless (deleted)", which would make execv fail with ENOENT. `dir` was
    # captured before the build, and the rebuild writes `-o:wkbenchless` into it.
    let bin = dir / "wkbenchless"
    if not fileExists(bin):
      app.msg = "recompile: built binary not found at " & bin; return
    if handoff.len > 0: putEnv("WKB_HANDOFF", handoff)
    # Defer the execv to the host: it owns the terminal's screen grid, which it
    # snapshots (so a TUI looks identical after reload) just before re-exec.
    app.reloadBin = bin; app.reloadFile = fileArg; app.reloadLine = line
    app.reloadPending = true

proc execReload*(app: var App) =
  ## Re-exec the freshly built binary, restoring the file + cursor. Called by the
  ## host after it has stashed the terminal grid (WKB_TERMGRID) and sessions.
  when defined(posix):
    let argv = allocCStringArray(@[app.reloadBin, app.reloadFile, "--goto", $app.reloadLine])
    discard execv(app.reloadBin.cstring, argv)
    app.msg = "recompile: exec failed (" & app.reloadBin & ")"   # only if execv failed
    app.reloadPending = false

const defaultConfigSrc = staticRead("wkbconfig.nim")   ## seeds the user config

proc userConfigPath*(): string =
  ## The user's config, compiled in place of src/wkbconfig.nim when it exists
  ## (config.nims): ~/.config/wkbenchless/wkbconfig.nim, or WKB_USER_CONFIG.
  let env = getEnv("WKB_USER_CONFIG")
  if env.len > 0: expandTilde(env)
  else: getConfigDir() / "wkbenchless" / "wkbconfig.nim"

proc editConfig*(app: var App) =
  ## Open the config in the editor (edit, then reload-config / C-c r). Looks in
  ## ~/.config/wkbenchless first, seeding it on first use from the source tree's
  ## src/wkbconfig.nim (else the default built into this binary); falls back to
  ## the source tree's own file if the config dir can't be written.
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  var p = userConfigPath()
  var note = ""
  if not fileExists(p):
    let srcCfg = resolveBuildDir() / "src" / "wkbconfig.nim"
    try:
      createDir(p.parentDir)
      writeFile(p, if fileExists(srcCfg): readFile(srcCfg) else: defaultConfigSrc)
      note = "created " & p & " -- "
    except OSError, IOError:
      p = srcCfg
  if not fileExists(p): app.msg = "config not found: " & userConfigPath(); return
  app.filePath = p
  app.ed.lang = fileExtToLanguage(".nim")
  app.ed.loadFromFile(p)
  app.docLang = "nim"
  app.msg = note & "editing config -- reload with C-c r (or M-x reload-config)"

proc reloadConfig*(app: var App) =
  ## Rebuild (recompiling wkbconfig.nim into the binary) and restart.
  recompileConfig(app)

# -- terminal / panel ------------------------------------------------------
var gTerminalDir*: string   ## config override for the terminal cwd ("" = auto)

proc projectRoot*(app: App): string =
  ## The nearest ancestor of the current file that contains .git (else the
  ## file's dir, else the cwd).
  var cur = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  let startDir = cur
  while cur.len > 1:
    if dirExists(cur / ".git"): return cur
    let up = parentDir(cur)
    if up == cur: break
    cur = up
  startDir

proc terminalDir*(app: App): string =
  ## Where a new terminal starts: config gTerminalDir if set, else project root.
  if gTerminalDir.len > 0: expandTilde(gTerminalDir) else: projectRoot(app)

proc openTerminal*(app: var App; cmd: string) =
  ## Open `cmd` in its own bottom-panel terminal tab. Reuses an existing tab
  ## running the same command (so M-t twice doesn't stack bash tabs); otherwise
  ## adds a new one. Each terminal keeps its own PTY, so opening claude after a
  ## bash terminal no longer kills the bash session.
  let label = cmd.splitWhitespace()[0]   # "claude", "bash", ...
  for i, t in app.terminals:
    if t.cmd == cmd:
      # The earlier run of this exact command already ended (an ssh drop,
      # say) -- respawn it instead of just focusing a dead pane. The auto-
      # retire below only drops a dead tab once the user has moved off it, so
      # reattaching (e.g. `ssh host tmux attach -t name` after the connection
      # comes back) needs this: reopening the SAME command is how it retries.
      if t.started and not t.pty.alive:
        closePty(app.terminals[i].pty)
        app.terminals[i].pty = notRunningPty()
        app.terminals[i].started = false
      app.termActive = i
      app.sessionHidden = false
      app.focus = "session"
      app.msg = "terminal: " & label
      return
  app.terminals.add Terminal(pty: notRunningPty(), label: label, cmd: cmd)
  app.termActive = app.terminals.len - 1
  app.sessionHidden = false
  app.focus = "session"
  app.msg = "terminal: " & label

proc claudeSettingsPath*(): string = getCacheDir() / "wkbenchless" / "claude-settings.json"

proc writeClaudeSettings*(): bool =
  ## Write a `--settings` JSON whose Pre/PostToolUse hooks pop Claude's file
  ## edits into THIS editor's diff pane by shelling `<self> edit-diff pre|post`.
  ## Targeting is via the WKB_CTL_* env this instance exports, so the diff lands
  ## in the launching editor. The self path is single-quoted for the shell and
  ## JSON-escaped for the file (posix-focused).
  let selfEsc = getAppFilename().multiReplace(("\\", "\\\\"), ("\"", "\\\""))
  let pre  = "'" & selfEsc & "' edit-diff pre"
  let post = "'" & selfEsc & "' edit-diff post"
  let js =
    "{\"hooks\":{" &
    "\"PreToolUse\":[{\"matcher\":\"Edit|Write|MultiEdit\",\"hooks\":[" &
      "{\"type\":\"command\",\"command\":\"" & pre & "\",\"timeout\":8}]}]," &
    "\"PostToolUse\":[{\"matcher\":\"Edit|Write|MultiEdit\",\"hooks\":[" &
      "{\"type\":\"command\",\"command\":\"" & post & "\",\"async\":true,\"timeout\":12}]}]" &
    "}}"
  try:
    createDir(claudeSettingsPath().parentDir)
    writeFile(claudeSettingsPath(), js)
    result = true
  except CatchableError: result = false

proc withClaudeSettings*(cmd, settingsPath: string): string =
  ## Insert `--settings <path>` after each leading `claude` in the (possibly
  ## `||`-joined) launch command, leaving the rest of each segment intact.
  var parts: seq[string]
  for seg in cmd.split("||"):
    var s = seg.strip()
    if s.startsWith("claude"):
      s = "claude --settings " & quoteShell(settingsPath) & s[len("claude") .. ^1]
    parts.add s
  parts.join(" || ")

proc showPanel*(app: var App) =
  app.sessionHidden = false; app.focus = "session"; app.msg = "panel shown"

proc togglePanel*(app: var App) =
  app.sessionHidden = not app.sessionHidden
  if not app.sessionHidden: app.focus = "session"
  app.msg = "panel " & (if app.sessionHidden: "hidden" else: "shown")

# -- vim mode --------------------------------------------------------------
proc vimGoto(app: var App; line, col: int) =
  let ln = clamp(line, 0, max(0, app.ed.getLineCount() - 1))
  let ll = app.ed.getLineText(ln).len
  app.ed.gotoLine(ln, clamp(col, 0, ll))

proc vimMove(app: var App; dLine, dCol: int) =
  vimGoto(app, app.ed.currentLine + dLine, app.ed.currentCol + dCol)

proc vimFirstNonBlank(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  vimGoto(app, app.ed.currentLine, i)

proc vimToEol(app: var App; append = false) =
  let ll = app.ed.getLineText(app.ed.currentLine).len
  vimGoto(app, app.ed.currentLine, if append: ll else: max(0, ll - 1))

proc isVimWord(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc vimWordForward(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = app.ed.currentCol
  if i < line.len and isVimWord(line[i]):
    while i < line.len and isVimWord(line[i]): inc i
  while i < line.len and line[i] in {' ', '\t'}: inc i
  if i >= line.len and app.ed.currentLine < app.ed.getLineCount() - 1:
    vimGoto(app, app.ed.currentLine + 1, 0)
  else:
    vimGoto(app, app.ed.currentLine, i)

proc vimWordBackward(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = app.ed.currentCol - 1
  while i > 0 and line[i] in {' ', '\t'}: dec i
  while i > 0 and isVimWord(line[i - 1]): dec i
  vimGoto(app, app.ed.currentLine, max(0, i))

proc vimDeleteN(app: var App; n: int) =
  for _ in 0 ..< max(0, n): app.ed.deleteKey()

proc vimDeleteToEol(app: var App) =
  vimDeleteN(app, app.ed.getLineText(app.ed.currentLine).len - app.ed.currentCol)

proc vimDeleteWord(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = app.ed.currentCol
  if i < line.len and isVimWord(line[i]):
    while i < line.len and isVimWord(line[i]): inc i
  while i < line.len and line[i] in {' ', '\t'}: inc i
  vimDeleteN(app, i - app.ed.currentCol)

proc vimYankLine(app: var App) =
  putClipboardText(app.ed.getLineText(app.ed.currentLine) & "\n")

proc vimNormalChar(app: var App; c: char) =
  case app.vimPending
  of "d":
    app.vimPending = ""
    case c
    of 'd': vimYankLine(app); app.ed.deleteLine()
    of 'w': vimDeleteWord(app)
    of '$': vimDeleteToEol(app)
    else: discard
    return
  of "g":
    app.vimPending = ""
    if c == 'g': vimGoto(app, 0, 0)
    return
  of "y":
    app.vimPending = ""
    if c == 'y': vimYankLine(app)
    return
  else: discard
  case c
  of 'h': vimMove(app, 0, -1)
  of 'l': vimMove(app, 0, 1)
  of 'j': vimMove(app, 1, 0)
  of 'k': vimMove(app, -1, 0)
  of 'w': vimWordForward(app)
  of 'b': vimWordBackward(app)
  of '0': vimGoto(app, app.ed.currentLine, 0)
  of '$': vimToEol(app)
  of '^': vimFirstNonBlank(app)
  of 'G': vimGoto(app, app.ed.getLineCount() - 1, 0)
  of 'g': app.vimPending = "g"
  of 'd': app.vimPending = "d"
  of 'y': app.vimPending = "y"
  of 'D': vimDeleteToEol(app)
  of 'x': app.ed.deleteKey()
  of 'i': app.vimMode = vmInsert
  of 'I': vimFirstNonBlank(app); app.vimMode = vmInsert
  of 'a': vimMove(app, 0, 1); app.vimMode = vmInsert
  of 'A': vimToEol(app, append = true); app.vimMode = vmInsert
  of 'o': app.ed.insertLineBelow(); app.vimMode = vmInsert
  of 'O': app.ed.insertLineAbove(); app.vimMode = vmInsert
  of 'u': app.ed.undo()
  of 'p': app.ed.insertText(getClipboardText())
  else: discard

proc vimHandle*(app: var App; e: Event): bool =
  ## True if consumed. Insert mode consumes only Esc (typing flows to the
  ## editor); normal mode consumes everything.
  if app.vimMode == vmInsert:
    if e.kind == KeyDownEvent and e.key == KeyEsc:
      app.vimMode = vmNormal
      vimGoto(app, app.ed.currentLine, max(0, app.ed.currentCol - 1))
      return true
    return false
  case e.kind
  of TextInputEvent:
    var c = '\0'
    for ch in e.text:
      if ch != '\0': c = ch; break
    if c != '\0': vimNormalChar(app, c)
    return true
  of KeyDownEvent:
    case e.key
    of KeyEsc: app.vimPending = ""
    of KeyLeft: vimMove(app, 0, -1)
    of KeyRight: vimMove(app, 0, 1)
    of KeyUp: vimMove(app, -1, 0)
    of KeyDown, KeyEnter: vimMove(app, 1, 0)
    of KeyBackspace: vimMove(app, 0, -1)
    of KeyR:
      if CtrlPressed in e.mods: app.ed.redo()
    else: discard
    return true
  else: return false

proc toggleVim*(app: var App) =
  app.vimEnabled = not app.vimEnabled
  app.vimMode = vmNormal
  app.vimPending = ""
  app.msg = "vim mode " & (if app.vimEnabled: "on (NORMAL)" else: "off")

proc registerBuiltins*() =
  gRepls["r"] = rSpec
  gRepls["python"] = pySpec
  gRepls["bash"] = bashSpec
  gRebuildCmd = detectRebuildCmd()   # config may override before first C-c r

  gLspServers["nim"] = "nimlangserver"
  gLspServers["python"] = "pylsp"
  gLspServers["r"] = "R --no-echo -e languageserver::run()"
  gObjectsQuery["bash"] = "compgen -v | sort | head -60\n"

  gObjectsQuery["r"] =
    "local({ ns <- ls(envir=.GlobalEnv); " &
    "if (length(ns)==0) cat('(none)\\n') else " &
    "for (n in ns) cat(n, '  <', paste(class(get(n, envir=.GlobalEnv)), collapse=','), '>\\n', sep='') })\n"
  gObjectsQuery["python"] =
    "print('\\n'.join(f'{k}  <{type(v).__name__}>' " &
    "for k,v in list(globals().items()) if not k.startswith('_')) or '(none)')\n"

  gHelpQuery["r"] =
    "local({ h <- tryCatch(utils:::.getHelpFile(as.character(help('{word}'))), " &
    "error=function(e) NULL); if (is.null(h)) cat('no help for {word}\\n') else tools::Rd2txt(h) })\n"
  gHelpQuery["python"] =
    "import pydoc as _pd\n" &
    "try:\n    print(_pd.render_doc('{word}', renderer=_pd.plaintext))\n" &
    "except Exception as _e:\n    print('no help for {word}:', _e)\n"

  defcommand("save", "Save", saveCmd)
  defcommand("export", "Export this buffer (choose target: docx, html, ...)", openExportPalette)
  defcommand("save-as", "Save the buffer to a new path", saveAsCmd)
  defcommand("quit", "Quit", quitCmd)
  defcommand("next-buffer", "Buffers: cycle to the next buffer", nextBuffer)
  defcommand("prev-buffer", "Buffers: cycle to the previous buffer", prevBuffer)
  defcommand("history", "History: browse this file's time-versioned snapshots", historyCmd)
  defcommand("cite-history", "References: what we wrote about this citation, over time", citeHistory)
  defcommand("run-line", "Run current line in R (default session), skip to next", runLine)
  defcommand("babel-execute", "Org-babel: run this src block", babelExecute)
  defcommand("babel-execute-force", "Org-babel: run this src block, ignoring :cache", babelExecuteForce)
  defcommand("babel-execute-deps", "Org-babel: run this block after its (stale) dependencies", babelExecuteDepsCmd)
  defcommand("run-stale", "Org-babel: run every stale block (code/deps changed, or not run in this session)", runStaleCmd)
  defcommand("infer-block-deps", "Org-babel: infer R block dependencies, update :depends / #+name headers", inferBlockDepsCmd)
  defcommand("run-all", "Org-babel: run every src block in the buffer, top to bottom", babelExecuteBufferCmd)
  defcommand("toggle-line-numbers", "Show/hide line numbers", proc(a: var App) =
    a.ed.showLineNumbers = not a.ed.showLineNumbers
    a.msg = (if a.ed.showLineNumbers: "line numbers on" else: "line numbers off"))
  defcommand("comment-toggle", "Comment: toggle line", proc(app: var App) = app.ed.toggleComment())
  defcommand("undo", "Undo", proc(app: var App) = app.ed.undo())
  defcommand("redo", "Redo", proc(app: var App) = app.ed.redo())
  defcommand("palette", "Command palette", paletteCmd)
  defcommand("theme", "Theme: pick a base16 / sixteen color theme", themeCmd)
  defcommand("list-buffers", "List / switch buffers", listBuffers)
  defcommand("open-file", "Open file (browse)", openFileCmd)
  defcommand("find", "Find in buffer", openFind)
  defcommand("replace", "Find & replace in buffer", openReplace)
  defcommand("org-nav", "Org: navigate headings / named blocks / captions", orgNavCmd)
  defcommand("recent-files", "Open a recent file", openRecentCmd)
  defcommand("toggle-fold", "Org: fold / unfold this src block", toggleFold)
  defcommand("fold-all", "Org: fold all src blocks", foldAllSrc)
  defcommand("unfold-all", "Org: unfold all src blocks", unfoldAllSrc)
  defcommand("scroll-right", "Scroll the view right (wide tables)", scrollRight)
  defcommand("scroll-left", "Scroll the view left", scrollLeft)
  defcommand("kill-buffer", "Kill the current buffer", killBuffer)
  defcommand("revert-buffer", "Revert buffer to file on disk (discard unsaved edits)", revertBuffer)
  defcommand("zoom-in", "Increase font size", zoomIn)
  defcommand("zoom-out", "Decrease font size", zoomOut)
  defcommand("zoom-reset", "Reset font size", zoomReset)
  defcommand("open-link", "Open org link at cursor", openLink)
  defcommand("toggle-inline-images", "Images: toggle inline [[file:x.png]] rendering", toggleInlineImages)
  defcommand("latex-preview", "LaTeX: toggle inline previews of display math", latexPreview)
  defcommand("cancel", "Cancel / dismiss the palette or find overlay (C-g)", cancelOverlays)
  defcommand("next-landmark", "Go to next section / src block / comment (org or Rmd)", nextLandmark)
  defcommand("prev-landmark", "Go to previous section / src block / comment (org or Rmd)", prevLandmark)
  defcommand("next-chunk", "Go to the next src block", nextChunk)
  defcommand("prev-chunk", "Go to the previous src block", prevChunk)
  defcommand("criticmarkup-accept-all", "CriticMarkup: accept all tracked changes", criticAcceptAll)
  defcommand("criticmarkup-reject-all", "CriticMarkup: reject all tracked changes", criticRejectAll)
  defcommand("criticmarkup-accept", "CriticMarkup: accept change at point", criticAcceptOne)
  defcommand("criticmarkup-reject", "CriticMarkup: reject change at point", criticRejectOne)
  defcommand("criticmarkup-mark-done", "CriticMarkup: mark comment at point [DONE]", criticMarkDone)
  defcommand("criticmarkup-clean-done", "CriticMarkup: remove all [DONE] comments", criticCleanDone)
  defcommand("next-comment", "Go to the next comment", nextComment)
  defcommand("prev-comment", "Go to the previous comment", prevComment)
  defcommand("diff-buffer", "Diff: buffer vs saved file (two panes)", diffBuffer)
  defcommand("close-diff", "Diff: close the diff view", closeDiff)
  defcommand("toggle-vim", "Toggle vim (modal) editing", toggleVim)
  defcommand("terminal", "Open a bash terminal in the bottom panel",
             proc(app: var App) = openTerminal(app, "bash --norc"))
  defcommand("claude", "Open claude in the bottom panel (continues last chat)",
             proc(app: var App) =
               var cmd = gClaudeCmd
               # Only inject --settings if the hooks file was actually written,
               # so a failed write can never break the claude launch.
               if gClaudeDiffHooks and writeClaudeSettings():
                 cmd = withClaudeSettings(gClaudeCmd, claudeSettingsPath())
               openTerminal(app, cmd))
  defcommand("show-panel", "Show the bottom panel", showPanel)
  defcommand("toggle-panel", "Show/hide the bottom panel", togglePanel)
  defcommand("recompile", "Recompile config & restart", recompileConfig)
  defcommand("refresh-objects", "Objects: refresh from session", refreshObjects)
  defcommand("show-help", "Help: for word at cursor", showHelp)
  defcommand("complete", "LSP: complete at cursor", lspComplete)
  defcommand("ghost-accept", "Copilot: accept the ghost-text completion", ghostAccept)
  defcommand("ghost-dismiss", "Copilot: dismiss the ghost-text completion", ghostDismiss)
  defcommand("toggle-src-edit", "Toggle objects/help (src-edit)", toggleSrcEdit)
  defcommand("toggle-buffer-tabs", "Show/hide buffer tabs in the toolbar", toggleBufferTabs)
  defcommand("src-edit-block", "Src-edit: this block (org-edit-special)", srcEditBlock)
  defcommand("src-edit-session", "Src-edit: tangle this session's blocks", srcEditSession)
  defcommand("focus-next", "Focus next pane", focusNext)
  defcommand("switch-session", "Switch to next session", switchSession)
  defcommand("edit-config", "Edit config file", editConfig)
  defcommand("reload-config", "Reload config (recompile & restart)", reloadConfig)
  # The full keymap lives in wkbconfig.nim so every binding is visible and
  # editable in one place (M-x edit-config, then C-c r). These two are a
  # recovery net kept here: a config that removes its binds can still open the
  # palette (and from there reload-config/edit-config) and quit.
  bindkey("M-x", "palette")
  bindkey("C-q", "quit")
