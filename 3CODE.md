# Working in wkbenchless (3code instructions)

wkbenchless is a native Nim literate editor. When you (3code) run **inside its
embedded terminal**, drive the live editor over its control socket with
**`wkbctl`** instead of editing files blind or grep-and-piping code.

## Detect it
The socket is live when this responds:
```sh
wkbctl blocks    # lists #+begin_src blocks as "  <line>: <header>"
```
If `wkbctl` isn't found or errors, wkbenchless isn't running here — work with
files normally. (`wkbctl <verb>` is just `wkbenchless ctl <verb>` — the editor
binary embeds the same client; either works, on Linux/macOS/Windows.)

## Read the live buffer
- `wkbctl buffer` — the current buffer's full text (use this, not the file on
  disk; the buffer may have unsaved edits).
- `wkbctl blocks` — src blocks with their 1-based line numbers, one per line as
  `<line>: <header>`. Use the `<line>` as the argument to `run-block`.

## Run org src blocks — use the editor's babel, NOT eval
To run a specific block, position + run the editor's own `C-c C-c` so it
executes in the block's `:session`, respects its language, and **writes
`#+RESULTS:` back into the buffer**:
```sh
wkbctl run-block <line>     # <line> = the block's #+begin_src line (from `blocks`)
```
Do **not** grep code out of a block and pipe it to `wkbctl eval` — that ignores
the block's session/language and doesn't write results. Reserve `eval` for
ad-hoc, throwaway code:
```sh
echo 'summary(fit)' | wkbctl eval r default     # ad-hoc in the r/default session
```
`eval` takes `<lang> <session>` (defaults `r default`); the session's live
process is the same one shown in the bottom panel, so state carries over.

## Agent verbs (extensions/agent_tools.nim)
Run `wkbctl help` to list these from the running editor — it is the source of
truth. Symbol intelligence over a persistent nimsuggest (locate without
reading files):
```sh
wkbctl symbols [file]                        # outline: "line: kind name"
wkbctl find-symbol submitEval                # project-wide: "path:line: kind name"
wkbctl references src/wkbcore.nim 2278 submitEval   # definition + usages
wkbctl def src/wkbctrl.nim 155 submitEval    # definition of the symbol at a site
wkbctl type-def src/wkbcore.nim 2278 submitEval     # its type's definition
```
Positions are `file line [word|col]`; the word locates the column for you. First
use per project spawns nimsuggest (analysis warms in the background; queries
answer "still warming up" until then — `symbols` works immediately).

Check / build / run — queued in the bash session (visible in the panel, focus
returns to the terminal when done) with a crisp pass/fail last line:
```sh
wkbctl check [file]                          # nim check + "check: ok|FAILED"
wkbctl check-project                         # nim check on the project's main file
wkbctl build [nim c args...]                 # project build + "build: ok|FAILED"
echo 'ls -la' | wkbctl sh                    # bash in the session panel
echo 'echo 1+1' | wkbctl nim-run             # Nim via the warm nimteractive session
```
`nim-run` (and `eval nim`) use nimteractive when installed (warm nimcache,
incremental recompile); without it they fall back to `scratch.nim` + `nim r`
from the project root. Prefer these over raw shell-outs — the user sees the
run live in the panel.

## Edit the buffer
- `echo TEXT | wkbctl set-buffer` — replace the whole buffer.
- `echo TEXT | wkbctl insert <line>` — insert before 1-based `<line>`.
- `echo TEXT | wkbctl replace <from> <to>` — replace 1-based lines `[from..to]`.
- `wkbctl goto <line>` — move the cursor.

## Show the user changes — use the diff panel
When you change files, show them in the editor's diff pane (renders in the top
editor area; the terminal stays live):
```sh
git show HEAD:path/file > /tmp/old && wkbctl diff /tmp/old path/file "what changed"
```

## Run any editor command / reload
- `wkbctl command <name>` — run any `M-x` command; echoes `ok: <name> -- <status>`.
  Useful names: `save`, `babel-execute`, `run-line`, `undo`, `redo`,
  `list-buffers`, `open-file`, `find`, `replace`, `next-landmark`, `prev-landmark`,
  `diff-buffer`, `close-diff`, `toggle-vim`, `terminal`, `claude`,
  `show-panel`, `toggle-panel`, `recompile`, `refresh-objects`, `show-help`,
  `complete`, `src-edit-block`, `src-edit-session`, `focus-next`,
  `switch-session`, `edit-config`, `reload-config`.
- `wkbctl command recompile` — after editing wkbenchless's own source, rebuild &
  hot-reload the running instance (sessions and terminals are preserved).

## Building this project
```sh
nim c --hints:off -o:wkbenchless src/wkbenchless.nim   # the editor
nim c --hints:off -o:wkbctl src/wkbctl.nim             # the control CLI
```
Extensions live in `extensions/*.nim` (each `proc extend*(app: var App)`), are
compiled in on `C-c r`, and filenames must be valid Nim identifiers (use `_`).
Windows is cross-checked with mingw (see the harness memory).