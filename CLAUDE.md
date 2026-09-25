# Working in wkbenchless (agent instructions)

wkbenchless is a native Nim literate editor. When you (Claude) run **inside its
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
- `wkbctl blocks` — src blocks with their 1-based line numbers.

## Run org src blocks — use the editor's babel, NOT eval
To run a specific block, position + run the editor's own `C-c C-c` so it
executes in the block's `:session`, respects its language, and **writes
`#+RESULTS:` back into the buffer**:
```sh
wkbctl run-block <line>     # <line> = the block's #+begin_src line (from `blocks`)
```
Runs are **asynchronous** in the editor: `C-c C-c` / `run-block` queue the block
in its session, `#+RESULTS:` shows `: [running: job N]` until it finishes, and
the editor (and this socket) stay responsive however long it takes — there is no
timeout. The CLI still *waits* for you by polling (`run-block`, `run-all` and
`eval` return when their jobs finish); add `--async` to get the job id(s) at once.
```sh
wkbctl run-block 120 --async        # -> queued: job 7
wkbctl jobs                         # id, state, label, elapsed for each job
wkbctl status 7                     # state line, then the output once done
wkbctl wait 7 8                     # block until those jobs finish, with a report
wkbctl interrupt 7                  # Ctrl-C a running job / drop a queued one
```
Runs in one session execute in order (FIFO); different sessions run in parallel.
While a run started over `wkbctl` is going, the bottom pane shows its session
tab (output streams there live); it switches back to the terminal tab when the
runs finish.

### Dependencies, staleness and caching
- Name blocks with `#+name:` and list what they need with `:depends a b` (org's
  `:var x=a` also counts). A name with spaces is referenced with `_` for spaces.
- Results carry a content hash, `#+RESULTS[<hash>]:`, over the code, header args
  and the dependencies' hashes: editing a block makes everything downstream stale.
- `wkbctl run-block <line> --deps` runs the block after its stale dependencies;
  `wkbctl run-stale` runs every stale block (changed, or not yet run in the live
  session -- e.g. after a restart); `--force` ignores `:cache`.
- `:cache yes`: an unchanged block is not re-run. For R, the objects it assigns
  are saved to `.wkb-cache/<hash>.RData` next to the file and restored when a
  new session needs them, instead of refitting.
- `wkbctl infer-deps` (palette: `infer-block-deps`) infers R dependencies from
  the code (names read vs. assigned by earlier blocks) and rewrites the
  `:depends` / `#+name:` headers; the change is shown in the diff pane. NSE
  column names can add a spurious edge -- edit the header if so.

Do **not** grep code out of a block and pipe it to `wkbctl eval` — that ignores
the block's session/language and doesn't write results. Reserve `eval` for
ad-hoc, throwaway code:
```sh
echo 'summary(fit)' | wkbctl eval r default     # ad-hoc in the r/default session
```

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
Prose files (.org/.md/.txt/.tex) open in a word-level view (removed words red,
added green, unchanged stretches collapsed); code opens side-by-side at the
first change (`t` toggles). An untouched diff closes itself after 20 s
(`gDiffAutoClose`, 0 = never); any key, scroll or click pins it until Esc/q.
Closing it puts the editor cursor on the change when the diff is about the
active buffer (the client sends the new file's path).

## Run any editor command / reload
- `wkbctl command <name>` — run any `M-x` command.
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
