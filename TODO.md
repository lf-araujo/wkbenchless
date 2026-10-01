# TODO

## org-tracked docx round-trip (extensions/org_tracked.nim)

Surfaced doing a real co-author round by hand (Chandra's `083126_chandra.docx`
merged onto the canonical `083126.org`). The Emacs otd import + the current Nim
port both mishandled it; the corrected by-hand merge is the spec.

### Import / merge (`otdImport`, `mergeContent`)
- [ ] **Tables are structural** — treat a contiguous run of `|` lines as a
  passthrough block from the canonical; never align/replace table rows as body
  (current behaviour halved the table).
- [ ] **Don't drop comments on unchanged paragraphs** — canonical comments must
  survive; add only the *new* reviewer's comments, and never resurrect comments
  the canonical already resolved/cleaned.
- [ ] **Change detection must be citation-blind and exact** — strip `[cite:@…]`
  (canonical) and `^{N}` / `Figure N` / `Table N` (tracked) before comparing, and
  treat *any* real word difference as changed (a similarity threshold misses
  small edits).
- [ ] **Back-substitute keys in changed paragraphs** — `^{N}` → `[cite:@key]`
  via a citeproc-order cite-map; `Figure N` / `Table N` → `[cite:@fig:…]` /
  `[cite:@tbl:…]` via a pandoc-crossref map built from `#+name:` order.
- [ ] **Rebuild changed paragraphs by clean word-diff** of canonical (keys
  intact) vs the reviewer's citation-normalised text, emitting fresh
  `{++/--/~~}` — instead of splicing raw tracked text. Avoids the nested-CM
  mangling below and preserves keys with no back-sub guesswork.
- [ ] **Nested CriticMarkup** — an insertion later *deleted* while carrying
  comments currently imports as `{++{--…+--}.++}` / stray `{----}` / orphan
  `==}`. The clean-diff rebuild sidesteps this; otherwise handle nesting.
- [ ] **Safety net** — any new reviewer comment that can't be placed goes to a
  `* Reviewer comments not auto-placed` section with a "re:" context note, so
  nothing is ever lost.

### Export (`otdExport`)
- [ ] **Embed fallback via docProps custom property** — OneDrive/Word strip the
  `customXml/` part on save (Chandra's returned docx had no embedded org), so
  also write the org as a base64 `OrgTrackedSource` custom document property
  (port org-tracked-docx's `otd--embed-custom-property`), and read whichever
  survived on import.

## Session / babel execution (src/wkbsession.nim) — FIXED 2026-09-16

Surfaced running the whole `2026-05-05-no-pTau.org` OpenMx notebook via
`ctl run-block` (rerun with the new cog data). Two bugs, both fixed and verified
with a standalone R-session harness:

- [x] **Marker desync → `/tmp/wkbenchless-*.src: No such file` race.** `readUntil`
  defaulted to a 15 s *silence* timeout; a long/quiet model fit (Hessian, CIs)
  made it return before the block's `__NIMACS_END__`, so the temp file was deleted
  while the next run still needed it, and — because markers carried no per-run id —
  every later call locked onto the stale END, permanently poisoning the session.
  Fix: each run gets a unique `nonce`; BEGIN/END markers carry it and the reader
  keys on END+nonce, so stale markers are skipped. R reads the file at `parse()`
  time up front, so deletion is always safe. Applies to R/Python/Bash specs.
- [x] **Whole-block abort on first error.** The block was `source()`d as one unit,
  so any error (e.g. `umxModify(..., comparison=TRUE)` hitting umx's non-RAM
  `umxSummary`) aborted every statement after it — later `EpisodicMemory <- …`
  never ran, cascading into "object not found" in the table blocks. Fix: the R
  driver now `parse()`s and `eval()`s each top-level form in its own `tryCatch`
  (ESS-like), reporting the error but continuing.
- [x] **Silence timeout too short for model fits** — `babelExecute` now passes
  `timeoutMs = 600_000` to `runBlock`; the nonce makes even a timed-out run safe
  for the next one.

NB: applying the fix to a *running* instance needs a fresh R session (the live
process still has the old 1-arg `.nimacs_run` prime); relaunch wkbenchless (or
restart the session) so the new nonce-aware prime is installed.

## Run-all + palette UX (2026-09-16) — DONE

- [x] **`run-all` — run every src block top to bottom.** New `babelExecuteBuffer`
  (wkbcore) re-scans block headers each iteration (results insertion shifts
  lines), runs each in its `:session`, and returns a per-block `[ok]/[ERR]`
  report. Exposed as: command `run-all` (M-x), keybinding **`C-c C-b`**, and ctl
  verb **`wkbenchless ctl run-all`**. The ctl verb blocks until done and returns
  the report, so it doubles as its own watcher (no external driver/watcher loop).
- [x] **Wider palette** — cap raised 620→900 px (`drawPalette`).
- [x] **Best match on top while searching** — `paletteEntries` (pmCommands) now
  ranks by `matchScore` (exact < prefix < word-boundary < substring, earlier
  hits first); combined with the existing `paletteSel = 0` on keystroke, the top
  row is the best hit, no scrolling. `matchScore` is reusable for other modes.
- [x] **Recall last-used command** — already restored via `gLastCommand` in
  `openPalette`; unaffected by ranking (empty query keeps stable name order).

Possible follow-up: `babelExecute` should `setwd()` to the buffer's directory
(org-babel default-directory semantics) so relative data paths work regardless
of where wkbenchless was launched — currently the session inherits the launch
dir and a notebook must `setwd()` itself or be launched from the project root.

## Cut / selection over folds (src/vendor/uirelays/widgets/synedit.nim) — DONE 2026-09-17

Cut + selection were clunky around collapsed src blocks. Folds are display-only
(`foldedBlocks` = offsets of #+begin_src header lines; body text stays in the
buffer), but `up`/`down` had no fold awareness, so the cursor walked into hidden
rows one invisible line at a time.

- [x] **Fold-aware `up`/`down`** — new `lineStartOf` / `foldedRangeContaining` /
  `offsetAtColumn` helpers; `down` hops past a collapsed block to the next
  visible line, `up` hops to its header row. Fixes `selectUp`/`selectDown` for
  free (they call `up`/`down`), so a selection across a fold now grabs the whole
  block as one unit and cuts it cleanly.
- [x] **C-x with no selection cuts the current line** (CUA/Sublime reflex) —
  copies the line + `\n`, then `deleteLine()`.

Follow-ups (not done): horizontal `left`/`right` stepping *into* a fold
char-by-char; Ctrl+C copying the current line when nothing is selected (symmetry
with the cut change).

## Document history — infinite undo + time-versioned browsing (src/vendor/uirelays/widgets/synedit.nim)

Two questions, two interfaces: "undo the thing I just did" (sequential, muscle
memory — C-z) vs. "what did this look like this morning?" (wall-clock, browse +
compare — a palette verb). Keep them apart; C-z must never time-travel. Current
undo is a linear versioned stack (`actions: seq[Action]`, `undoIdx`, `version`)
that truncates the redo tail on a new edit, has no timestamps, and is lost when
the buffer closes. **Chosen model: linear + persist + timestamps** (not a
branching tree — deliberately the simpler path).

### Layer 1 — C-z (infinite, cross-session)
- [ ] **Timestamp each version group** — add a `time` to `Action` (or per
  `version`) so history can be time-indexed for Layer 2.
- [ ] **Persist `actions` to a sidecar** — serialize on save/idle, reload on
  open, so undo survives closing the buffer (keyed to the file; guard against
  the file changing on disk underneath the history).
- [ ] Keep the linear model (still truncates redo on new edit) — no tree.

### Layer 2 — palette verb: time-versioned browser
- [ ] **Timestamped buffer snapshots** on idle/save (a moment you stopped, not a
  dumb timer tick), stored per-file.
- [ ] **`M-x history` / palette verb** listing versions with **adaptive time
  density** (recent dense per-snapshot → hours coarser → one or two per day),
  Time-Machine style.
- [ ] **Diff preview before restore** — reuse the existing diff panel
  (`wkbctl diff`); a second action restores.
- [ ] **Restore seeds the undo stack** — after jumping to an old version, C-z
  still nudges forward/back from there, so a time-jump is just another edit in
  Layer 1 and never a trap.

## Org view: bold at line start rendered as a heading (src/vendor/uirelays/widgets/synedit.nim) — DONE 2026-09-30

- [x] **A line starting with a bold word is drawn as a section title.** E.g.
  `*Response.* We thank the reviewer…` or `*eTable 1. …* Fit indices…` gets
  heading styling (big font / heading colour) instead of body text with a bold
  span. Org only treats a line as a headline when the stars are followed by a
  space (`^\*+ `); `*word*` at column 0 is emphasis. Fixed: new
  `isOrgHeadlineText` (column 0, run of `*`, then a space) now gates the
  highlighter and the big-font check (`isBigOrgLine`); `orgOutline` applies the
  same rule; landmark nav (`isLandmark`) already did. `*bold*` lines render as
  body text with a bold span.
