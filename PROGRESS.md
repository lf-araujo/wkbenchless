# nimacs — progress / how to resume

Status as of this session: **working end-to-end**. Editor window opens,
typing works natively, `Ctrl+T`/`Ctrl+U` run hot-reloadable commands,
"Reload Config" swaps in edited `config.nim` behavior live without
restarting or losing buffer text, native Open/Save file dialogs, an
"org babel mode" toggle (proportional prose font vs. monospace
`#+begin_src`/`#+end_src` blocks, re-tagged live via the buffer's own
`"changed"` signal). All verified interactively by the user. Committed
and pushed: `github.com/lf-araujo/nimacs`.

## GTK4 varargs C calls appear broken on this GTK version (4.22.4) -- avoid them

Two independent confirmations now: owlkettle's `FileChooserDialog` (via
`gtk_file_chooser_dialog_new`, a varargs constructor) SIGSEGV'd, fixed by
switching to the modern non-varargs-adjacent `GtkFileDialog` API. Then
`gtk_text_buffer_create_tag` (also varargs -- owlkettle's own
`TextBuffer.registerTag` uses it internally, `widgets.nim:2358`) SIGSEGV'd
too, on the *simplest possible* varargs call (name + a single immediate
NULL, zero properties) -- called from `setupOrgTags` while building the
org-babel-mode feature. Fixed by switching to `gtk_text_tag_new` (a plain
fixed-arity constructor) + explicit `gtk_text_tag_table_add` instead,
avoiding the buffer's create_tag helper entirely.

**Working theory, not confirmed root cause:** something about how Nim's
`{.varargs.}` FFI pragma generates the call site is incompatible with
this specific GTK build's ABI expectations on arm64 macOS (could be a
clang/Nim codegen mismatch for variadic calls specifically, unrelated to
argument *count* -- the crashing call had the minimum possible one extra
arg). **Rule of thumb for any further owlkettle/GTK work in this
project: if a call is declared `{.varargs.}` in `owlkettle/bindings/gtk.nim`,
assume it may crash here and look for (or write) a fixed-arity
alternative first, rather than trusting that "owlkettle already uses this
successfully elsewhere" — the elsewhere may never have been exercised on
this GTK version until it crashed here.**

## How to run it

```sh
export PATH="$HOME/.local/bin:$PATH"
export MAMBA_ROOT_PREFIX="$HOME/micromamba"
eval "$(micromamba shell hook --shell zsh)"
micromamba activate nimacs
cd "/Users/silvacastrl/Library/CloudStorage/OneDrive-TheUniversityofMelbourne/Coding/Nim/Programs/nimacs"
nim c -o:nimacs src/nimacs.nim   # rebuild after editing nimacs.nim / src/nimacs/*
./nimacs [optional-file-path]     # C-s only saves if a path was given
```

`config.nim` needs no rebuild step — `Ctrl+Shift+R` / "Reload Config"
recompiles and hot-swaps it while the app keeps running.

## Environment setup (already done, for reference / a fresh machine)

GTK4/libadwaita couldn't be installed via brew: this network's Zscaler
proxy blocks `gnu.org` (even tunneled through it directly), and `gettext`
(a transitive build dep, since this custom brew prefix at `~/Documents/.brew`
can't use precompiled bottles) only has gnu.org as a source. Worked around
entirely via **conda-forge** instead (different CDN, unaffected):

```sh
# micromamba itself, fetched from GitHub releases (not the blocked micro.mamba.pm)
curl -Ls -o ~/.local/bin/micromamba \
  "https://github.com/mamba-org/micromamba-releases/releases/download/2.8.1-0/micromamba-osx-arm64"
chmod +x ~/.local/bin/micromamba

export MAMBA_ROOT_PREFIX="$HOME/micromamba"
micromamba create -y -n nimacs -c conda-forge gtk4 libadwaita pkg-config
micromamba install -y -n nimacs -c conda-forge zlib expat libxml2   # fill pkg-config gaps below
nimble install owlkettle
```

Three environment-specific gaps had to be patched manually after the conda
install (all one-time, already done in `~/micromamba/envs/nimacs/`):

1. **Missing `-lxml2`/`-lintl` symlinks** — conda-forge's osx-arm64 packages
   ship versioned dylibs only (`libxml2.16.dylib`, `libintl.8.dylib`), no
   unversioned symlink for the linker's plain `-lxml2`/`-lintl` to find:
   ```sh
   cd ~/micromamba/envs/nimacs/lib
   ln -sf libxml2.16.dylib libxml2.dylib
   ln -sf libintl.8.dylib libintl.dylib
   ```
2. **Missing `libxml-2.0.pc`** — `appstream.pc` (a `libadwaita.pc`
   `Requires.private`) needs it to exist for `pkg-config`'s dependency-graph
   validation, but conda-forge's `libxml2` package doesn't ship one. Hand-
   authored a minimal stub at `~/micromamba/envs/nimacs/lib/pkgconfig/libxml-2.0.pc`
   (`Libs: -lxml2`, no real headers needed since nothing in this project
   `#include`s libxml2 directly).
3. **Uncompiled GSettings schemas** — caused a silent failure: the app ran
   its GTK main loop fine but never actually presented a window (a
   `g_return_if_fail`-triggered early return inside GTK/Adwaita's own
   startup, easy to miss since the process looks perfectly healthy).
   Fixed with:
   ```sh
   glib-compile-schemas ~/micromamba/envs/nimacs/share/glib-2.0/schemas/
   ```

`config.nims` (project root) embeds the conda env's `-rpath` automatically
via `$CONDA_PREFIX` so the built binary can find these dylibs at runtime —
no manual `--passL` flag needed for normal builds.

## Architecture gotchas discovered while building (see DESIGN.md for the rest)

- owlkettle's per-widget `<Name>State` types (e.g. `TextViewState`) are
  generated fresh by the `renderable` macro at each call site and are
  **not reachable from outside owlkettle's own module** — subclassing an
  existing owlkettle widget (e.g. `TextView`) from application code doesn't
  work, confirmed empirically. Fix: `EditorTextView` in `src/nimacs.nim`
  is built from scratch `of BaseWidget`, using owlkettle's public raw GTK
  bindings (`gtk_text_view_new`, `gtk_text_buffer_*`) directly instead of
  owlkettle's own `TextView`/`TextBuffer` wrapper types.
- `viewable`/`renderable` constructor syntax (`App(field = value, ...)`)
  only works **wrapped in `gui(...)`** — `gui(...)` is what translates
  `field = value` into the widget's real `hasField`/`valField` pair. Calling
  `App(field = value)` directly (outside `gui(...)`) fails since the raw
  type has no such constructor proc.
- The installed owlkettle version (nimble pulled `3.0.0`, an older pinned
  commit) is missing a few raw GTK bindings present on owlkettle's current
  `main` branch (e.g. `gtk_event_controller_key_new`,
  `gtk_text_view_get_buffer`). Declared these ourselves in `nimacs.nim` via
  plain `{.importc, cdecl.}` — the underlying GTK4 C library has them
  regardless of what owlkettle's Nim bindings happen to expose.
- **Keyboard-triggered state changes don't auto-redraw.** owlkettle's own
  declarative event hooks (`Button.clicked()` etc.) are dispatched through
  its own callback machinery, which calls `app.redraw()` after your handler
  runs. `EditorTextView`'s key handling is wired directly to a raw
  `GtkEventControllerKey` via `g_signal_connect`, entirely outside that
  machinery — so mutating `app.status` (or anything else the view reads)
  from `handleKey` silently updates memory but never repaints, unless you
  call `discard app.redraw()` yourself. `handleKey` now does this once at
  the end for every handled chord. Symptom that surfaced this: a
  `k.status = "Hello"`-only test command appeared to do nothing over a
  keybinding, while the exact same status-setting pattern worked fine when
  triggered by the "Reload Config" *button*.
- **owlkettle's `FileChooserDialog`/`app.open(...)` SIGSEGVs on this GTK
  version.** Confirmed via stack trace (lldb itself is blocked on this
  managed Mac, so relied on Nim's own `--stacktrace:on` crash trace
  instead) and an isolated minimal repro with none of nimacs's own code
  involved: the crash is inside owlkettle's `beforeBuild` hook for
  `FileChooserDialog`, in its call to `gtk_file_chooser_dialog_new` —
  GTK's now-deprecated legacy file-dialog constructor. owlkettle 3.0.0 was
  written against an older GTK4; this environment's GTK is 4.22.4 (very
  recent), and something about that legacy path no longer tolerates
  whatever owlkettle passes it (likely the `nil` parent at construction
  time, fixed up only *after* construction via
  `gtk_window_set_transient_for`). Fix: bypass owlkettle's dialog machinery
  entirely and call GTK4's modern, actively-maintained `GtkFileDialog`
  API (`gtk_file_dialog_new`/`_set_title`/`_open`/`_open_finish`, GTK
  >=4.10) directly via raw `{.importc, cdecl.}` bindings in `nimacs.nim` —
  same pattern as `EditorTextView` bypassing owlkettle's `TextView`. This
  API is async (`GAsyncReadyCallback`), so like `handleKey`, the callback
  runs outside owlkettle's event-dispatch machinery and needs its own
  explicit `discard app.redraw()`.

## UI

- Header bar, left to right: **Open** (native GTK4 file-open dialog via
  `openFile`/`GtkFileDialog`), **Save** (also `Ctrl+S`), **Edit config.nim**
  (pencil icon — loads `config.nim`'s source into the buffer and repoints
  `filePath` at it, so `Ctrl+S` saves back to `config.nim` directly; then
  "Reload Config" picks up the edit), **Reload Config** (also
  `Ctrl+Shift+R`). All icon-only buttons with tooltips (Adwaita symbolic
  icons: `document-open-symbolic`, `document-save-symbolic`,
  `document-edit-symbolic`, `view-refresh-symbolic`) — installed via
  `micromamba install -y -n nimacs -c conda-forge adwaita-icon-theme`
  (not part of the original gtk4/libadwaita install, the icon theme
  package is separate). `main()` sets `XDG_DATA_DIRS` at startup so GTK's
  icon lookup finds the conda env's icon theme automatically — no need to
  export it manually before running `./nimacs`.
- Both **Open** and **Edit config.nim** load into the single buffer this
  editor has (replacing whatever was there, unsaved) — no multi-buffer
  support yet, same caveat as before.
- **Org babel mode** — rightmost header-bar `ToggleButton`
  (`format-text-rich-symbolic`). Off by default. On: prose renders in a
  proportional font (`"Sans"`, a generic Pango alias) while
  `#+begin_src ... #+end_src` blocks (including the delimiter lines
  themselves, matching real org-mode) stay monospace (`"Monospace"`).
  Re-tags automatically on every edit via the `GtkTextBuffer`'s own
  `"changed"` signal — covers native typing (which bypasses all of
  nimacs's Nim code) as well as command/Open/Save/Edit-config-triggered
  changes, all uniformly. No org parser: a plain line scanner
  (`isBeginSrc`/`isEndSrc`/`retagOrgBlocks` in `nimacs.nim`) — deliberately
  narrow scope (prose vs. code only, no headings/tables/emphasis).
  Looked at `~/Downloads/BabelHub` (a prior related project) first to see
  what was reusable: it's a browser app (TypeScript/CodeMirror +
  `uniorg`'s full org-AST parser, split source/rendered-HTML-preview
  panes) — none of its code ports to Nim or this single-buffer-GTK
  paradigm, but it confirmed a full parser is overkill for just this
  narrower prose/code split (its own src-block detection is a one-line
  regex, no AST) and its font choices (proportional prose / mono code)
  matched the intended aesthetic.

## Not yet done

- No further GTK-nimacs features requested. Everything above is committed
  and pushed. Active development is on **wkbenchless** (see the planned
  work below).

## Planned: reference management (wkbenchless)

Design settled in discussion (2026-09). Land on a `[cite:@key]` in an org
buffer (cites are already fontified) and surface everything *you* have ever
associated with that reference, in the help/objects pane. The whole feature
is an **offline reader over Zotero's SQLite + your filesystem** — three
sources, all reached by the same `citekey → …` shape, all returned as plain
text (so `wkbctl`/Claude-in-terminal can pull a reference dossier too).

Three sources, keyed on one `@key`:

| Source | Access (verified on this machine) | Unit | Section label |
|---|---|---|---|
| Your **notes** | `itemNotes` join in `zotero.sqlite` (read a copy — Zotero holds a lock); citekey via Better BibTeX `citekeys` table. **524 keys have notes.** Must **filter out Mktero snapshot notes** (see below) so this stays *your* thinking, not a paper dump. | note (HTML→text) | "Notes" |
| Your **prose** | walk `gCorpusRoots` for `.org`, split to body paragraphs (reuse `org_tracked` `parseUnits`/`bodyParas`), extract `[cite:@key]` + bare `@key`. Corpus measured: 114 files / 8.1 MB / **15 ms to scrape**. | paragraph | "You've written about this" |
| The **paper** | Mktero (the tool being adopted) saves a PDF snapshot as a Zotero **note** plus a **`source.md`** attachment → the `.md` resolves via `itemAttachments` → `~/Zotero/storage/<attachmentKey>/source.md`. Optional layer; empty when no such attachment exists. | full text | "From the paper" (kept visually distinct — source, not you) |

Verbs to add (control socket + `wkbctl`/`wkbenchless ctl`):

- [ ] `cite-context <key>` — all available sections for a key (the dossier).
- [ ] `cite-notes <key>` — Zotero notes only (SQLite join).
- [ ] `cite-prose <key>` — your manuscript paragraphs, each with `file:line`
      for a jump (reuse `cite-goto`'s jump mechanic).
- [ ] `cite-paper <key>` — path/preview of the attached Mktero `source.md`
      full text (optional; only when present).
- [ ] `zotero-search <query>` — general library search over Zotero's SQLite
      (titles / authors / notes, and Mktero `source.md` full text when
      indexed), returning `citekey — Author (year). Title` + flags for what
      each hit has (notes / paper-md / cited-in-my-prose). Broader than the
      existing `bib` verb, which only searches the `.bib` files; this finds a
      paper you read but have not cited yet. Reuses the same offline SQLite.
- [ ] (editor) `M-x cite-context` — fill the help pane for the cite at point;
      on-demand first, automatic-on-cursor as a later toggle.

Design decisions already made:

- **Unit is the paragraph** (not the section) — org_tracked already splits
  this way.
- **Corpus = configured roots** (`gCorpusRoots`, active + archive dirs), NOT
  Zotero-attached manuscripts: Zotero stores attachments as *copies* in its
  storage dir, which would drift from the working `.org`. The live files are
  the truth; one config line survives archiving.
- **Ownership stays split**: Zotero owns *notes*, the filesystem owns
  *manuscripts*. Don't cross them.
- **Subversion sprawl** (~30 `_v2`/`-tracked`/dated copies): group by
  manuscript family, collapse near-identical paragraphs with org_tracked's
  `wordSet`/`similarity`, newest wins. "Paragraph evolution across drafts" is
  a later opt-in, not the default.
- **Mktero writes to BOTH note and attachment** — the workflow being adopted
  saves a PDF snapshot as a Zotero *note* (lands in `itemNotes`, so it would
  otherwise pollute the "Notes" = your-thinking section) **and** a `source.md`
  attachment (the reflowed full text). So: **route Mktero notes to "From the
  paper", not "Notes".** Detection TBD at build time — match a Mktero marker
  in the note HTML, and/or treat a note as a paper-snapshot when the item also
  carries a `source.md` and the note is large/structured. Confirm the exact
  marker against a real Mktero note once one exists in the library.
- **Decoupled from the OCR stack**: wkbenchless only *reads* the note and the
  `source.md`; it never calls Estravon's `Zotero.Estravon.extract()` hook or
  Mktero's MinerU backend — conversion stays Zotero/Mktero's job.
- **Cost**: negligible (15 ms full scrape) — rebuild the index on demand; a
  persistent cache is a nicety, not a requirement.

First slice: the paragraph index + `cite-prose` / `M-x cite-context` for the
prose source (the novel half), against the real 36 citing `.org` files. Notes
and paper-text sections slot into the same pane afterward as further joins.
