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
