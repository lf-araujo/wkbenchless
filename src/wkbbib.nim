## wkbbib.nim -- a minimal BibTeX parser: enough to extract entries,
## fields, and DAG IDs from .bib files. Not a full BibTeX implementation --
## just the pieces the citation-graph DAG needs.
##
## The key insight: if a paper's DAG ID lives in a `dagid` field inside
## its BibTeX entry, the citation graph extracts itself from the .bib
## file. Authors write papers in LaTeX as usual; the DAG parses their
## bibliography and builds the edges automatically.

import std/[tables, strutils]

type
  BibEntry* = object
    typ*: string                    ## "article", "inproceedings", "book", ...
    key*: string                    ## the cite key (e.g., "smith2024")
    fields*: Table[string, string]  ## field name (lowercase) -> value

  BibFile* = seq[BibEntry]

proc skipWs(s: string; i: var int) =
  while i < s.len and s[i] in {' ', '\t', '\n', '\r'}: inc i

proc parseValue(s: string; i: var int): string =
  ## Parse a field value: {braced}, "quoted", or bare (until comma/close).
  if i < s.len and s[i] == '{':
    inc i
    var depth = 1
    while i < s.len and depth > 0:
      if s[i] == '{': inc depth
      elif s[i] == '}': dec depth
      if depth > 0: result.add s[i]
      inc i
  elif i < s.len and s[i] == '"':
    inc i
    while i < s.len and s[i] != '"':
      result.add s[i]; inc i
    if i < s.len: inc i  # skip closing quote
  else:
    while i < s.len and s[i] != ',' and s[i] != '}':
      result.add s[i]; inc i
  result = result.strip

proc parseBib*(text: string): BibFile =
  ## Parse a .bib file into entries. Handles @type{key, field = {value}, ...}
  ## with braced values (the common case). Unknown syntax is skipped.
  var i = 0
  while i < text.len:
    # find the next @
    let at = text.find('@', i)
    if at < 0: break
    i = at + 1
    # skip @comment / @preamble / @string
    let wordEnd = text.find({'{', '('}, i)
    if wordEnd < 0: break
    let typ = text[i ..< wordEnd].toLowerAscii.strip
    if typ in ["comment", "preamble", "string"]:
      i = wordEnd
      # skip to matching close
      var depth = 0
      while i < text.len:
        if text[i] == '{' or text[i] == '(': inc depth
        elif text[i] == '}' or text[i] == ')':
          dec depth
          if depth == 0: inc i; break
        inc i
      continue
    # regular entry: @type{key, ...}
    i = wordEnd + 1
    skipWs(text, i)
    # extract the cite key
    let keyStart = i
    while i < text.len and text[i] != ',' and text[i] != '}': inc i
    let key = text[keyStart ..< i].strip
    var entry = BibEntry(typ: typ, key: key)
    # parse fields
    while i < text.len and text[i] != '}':
      if text[i] == ',': inc i; continue
      skipWs(text, i)
      if i >= text.len or text[i] == '}': break
      # field name
      let nameStart = i
      while i < text.len and text[i] != '=' and text[i] != ',' and text[i] != '}':
        inc i
      let name = text[nameStart ..< i].toLowerAscii.strip
      skipWs(text, i)
      if i < text.len and text[i] == '=':
        inc i
        skipWs(text, i)
        let value = parseValue(text, i)
        if name.len > 0: entry.fields[name] = value
      else:
        break  # malformed; skip to next entry
    # skip past the closing }
    while i < text.len and text[i] != '}': inc i
    if i < text.len: inc i
    if entry.key.len > 0:
      result.add entry

# -- field accessors -----------------------------------------------------------
proc bibDagId*(e: BibEntry): string = e.fields.getOrDefault("dagid", "")
proc bibDoi*(e: BibEntry): string = e.fields.getOrDefault("doi", "")
proc bibTitle*(e: BibEntry): string = e.fields.getOrDefault("title", "")
proc bibRetracts*(e: BibEntry): string = e.fields.getOrDefault("retracts", "")
proc bibYear*(e: BibEntry): string = e.fields.getOrDefault("year", "")

proc bibAuthors*(e: BibEntry): seq[string] =
  ## Parse the author field: "Smith, John and Doe, Jane" -> ["Smith, John", "Doe, Jane"]
  let raw = e.fields.getOrDefault("author", "")
  for a in raw.split(" and "):
    let clean = a.strip
    if clean.len > 0: result.add clean

proc toBib*(e: BibEntry): string =
  ## Render an entry back to BibTeX format (for export/distribution).
  result = "@" & e.typ & "{" & e.key & ",\n"
  for name, value in e.fields:
    result.add "  " & name & " = {" & value & "},\n"
  result.add "}\n\n"
