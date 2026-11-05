## wkbpandoc -- pandoc's document AST as Nim types, with a JSON codec.
##
## `pandoc -t json` and `pandoc -f json` speak this format, so a document can
## leave pandoc, be transformed as typed data, and go back without any text
## round trip through Markdown:
##
##   let doc = parsePandoc(execProcess("pandoc", args = ["a.org", "-t", "json"]))
##   let json = doc.toJsonString
##
## The `pandocAst` table below is the single place constructors are declared.
## From each entry the macro generates the variant object, a `mk*` constructor,
## and both directions of the codec, so a new pandoc constructor is one line.
##
## pandoc's encoding: `{"t": tag}` with no arguments, `{"t": tag, "c": value}`
## with one, and `{"t": tag, "c": [values]}` with several. Records are
## positional arrays, except `Citation` (named keys) and `MetaMap` (a JSON
## object). Decoding is strict: an unknown constructor or wrong arity raises
## `PandocError`, because skipping one would silently lose document content.

import std/[json, macros, options, strutils]
export options

type
  PandocError* = object of ValueError
    ## The JSON is not a document this module understands.

const supportedApi* = [1, 23]
  ## The pandoc-types major version pair this schema was written against.

# --- Generic codec: leaves, sequences, positional records ---------------------

proc failJ(n: JsonNode; expected: string) {.noreturn.} =
  raise newException(PandocError, "expected " & expected & ", got " & $n.kind)

proc tagOf(n: JsonNode): string =
  if n.kind != JObject or not n.hasKey("t"): failJ(n, "a tagged object")
  n["t"].getStr

proc contentOf(n: JsonNode): JsonNode =
  if not n.hasKey("c"):
    raise newException(PandocError, tagOf(n) & " has no content")
  n["c"]

proc argsOf(n: JsonNode; count: int): JsonNode =
  result = contentOf(n)
  if result.kind != JArray or result.len != count:
    raise newException(PandocError,
      tagOf(n) & " expects " & $count & " arguments")

proc unknownTag(tag, typeName: string) {.noreturn.} =
  raise newException(PandocError, "unknown " & typeName & " constructor: " & tag)

proc toJ*(x: string): JsonNode = newJString(x)
proc toJ*(x: int): JsonNode = newJInt(x)
proc toJ*(x: bool): JsonNode = newJBool(x)

proc toJ*(x: float): JsonNode =
  ## aeson writes a whole number with no fraction, so 1.0 goes out as 1.
  if x == x.int.float: newJInt(x.int) else: newJFloat(x)

proc toJ*[T: enum](x: T): JsonNode =
  result = newJObject()
  result["t"] = newJString($x)

proc toJ*[T](x: seq[T]): JsonNode =
  mixin toJ
  result = newJArray()
  for item in x: result.add toJ(item)

proc toJ*[T](x: Option[T]): JsonNode =
  mixin toJ
  if x.isSome: toJ(x.get) else: newJNull()

proc toJ*[T: object | tuple](x: T): JsonNode =
  mixin toJ
  result = newJArray()
  for value in x.fields: result.add toJ(value)

proc fromJ*(n: JsonNode; x: var string) =
  if n.kind != JString: failJ(n, "a string")
  x = n.getStr

proc fromJ*(n: JsonNode; x: var int) =
  if n.kind != JInt: failJ(n, "an integer")
  x = n.getInt

proc fromJ*(n: JsonNode; x: var bool) =
  if n.kind != JBool: failJ(n, "a boolean")
  x = n.getBool

proc fromJ*(n: JsonNode; x: var float) =
  if n.kind notin {JInt, JFloat}: failJ(n, "a number")
  x = n.getFloat

proc fromJ*[T: enum](n: JsonNode; x: var T) =
  let tag = tagOf(n)
  try:
    x = parseEnum[T](tag)
  except ValueError:
    unknownTag(tag, $T)

proc fromJ*[T](n: JsonNode; x: var seq[T]) =
  mixin fromJ
  if n.kind != JArray: failJ(n, "an array")
  x = newSeq[T](n.len)
  for i in 0 ..< n.len: fromJ(n[i], x[i])

proc fromJ*[T](n: JsonNode; x: var Option[T]) =
  mixin fromJ
  if n.kind == JNull:
    x = none(T)
  else:
    var value: T
    fromJ(n, value)
    x = some(value)

proc fromJ*[T: object | tuple](n: JsonNode; x: var T) =
  mixin fromJ
  if n.kind != JArray: failJ(n, "a record array")
  var count = 0
  for value in x.fields: inc count
  if n.len != count:
    raise newException(PandocError,
      $T & " expects " & $count & " fields, got " & $n.len)
  var i = 0
  for value in x.fields:
    fromJ(n[i], value)
    inc i

# --- The macro ----------------------------------------------------------------

proc kindPrefix(typeName: string): string =
  ## Inline -> ik, MetaValue -> mvk: enum values stay unique across types.
  for c in typeName:
    if c.isUpperAscii: result.add c.toLowerAscii
  result.add 'k'

proc fieldName(ctor, field: string): string =
  ## Nim forbids one field name in two branches, so `Para.inlines` is
  ## `paraInlines` and `Plain.inlines` is `plainInlines`.
  ctor[0].toLowerAscii & ctor[1 .. ^1] & field[0].toUpperAscii & field[1 .. ^1]

type
  CtorSpec = object
    name: string
    fields: seq[tuple[name, typ: string]]

proc parseCtor(n: NimNode): CtorSpec =
  case n.kind
  of nnkIdent:
    result.name = n.strVal
  of nnkObjConstr:
    result.name = n[0].strVal
    for i in 1 ..< n.len:
      result.fields.add (n[i][0].strVal, n[i][1].repr)
  else:
    error("expected `Name` or `Name(field: Type)`", n)

proc variantCode(typeName: string; ctors: seq[CtorSpec]): string =
  ## The type definition, spliced into the shared `type` section.
  let p = kindPrefix(typeName)
  result = "type\n  " & typeName & "Kind* = enum\n"
  for c in ctors:
    result.add "    " & p & c.name & " = \"" & c.name & "\"\n"
  result.add "  " & typeName & "* = object\n    case kind*: " & typeName & "Kind\n"
  for c in ctors:
    result.add "    of " & p & c.name & ":\n"
    if c.fields.len == 0: result.add "      discard\n"
    for f in c.fields:
      result.add "      " & fieldName(c.name, f.name) & "*: " & f.typ & "\n"

proc procsCode(typeName: string; ctors: seq[CtorSpec]): string =
  ## Constructors and the two codec directions for one variant type.
  let p = kindPrefix(typeName)
  for c in ctors:
    var params, inits: seq[string]
    for f in c.fields:
      params.add f.name & ": " & f.typ
      inits.add ", " & fieldName(c.name, f.name) & ": " & f.name
    result.add "proc mk" & c.name & "*(" & params.join("; ") & "): " & typeName &
      " = " & typeName & "(kind: " & p & c.name & inits.join("") & ")\n"
  result.add "proc toJ*(x: " & typeName & "): JsonNode =\n"
  result.add "  result = newJObject()\n  result[\"t\"] = newJString($x.kind)\n"
  result.add "  case x.kind\n"
  for c in ctors:
    result.add "  of " & p & c.name & ":\n"
    case c.fields.len
    of 0:
      result.add "    discard\n"
    of 1:
      result.add "    result[\"c\"] = toJ(x." & fieldName(c.name, c.fields[0].name) & ")\n"
    else:
      result.add "    let args = newJArray()\n"
      for f in c.fields:
        result.add "    args.add toJ(x." & fieldName(c.name, f.name) & ")\n"
      result.add "    result[\"c\"] = args\n"
  result.add "proc fromJ*(n: JsonNode; x: var " & typeName & ") =\n"
  result.add "  let tag = tagOf(n)\n  case tag\n"
  for c in ctors:
    result.add "  of \"" & c.name & "\":\n"
    var inits: seq[string]
    for i, f in c.fields:
      result.add "    var a" & $i & ": " & f.typ & "\n"
      inits.add ", " & fieldName(c.name, f.name) & ": a" & $i
    if c.fields.len == 1:
      result.add "    fromJ(contentOf(n), a0)\n"
    elif c.fields.len > 1:
      result.add "    let args = argsOf(n, " & $c.fields.len & ")\n"
      for i in 0 ..< c.fields.len:
        result.add "    fromJ(args[" & $i & "], a" & $i & ")\n"
    result.add "    x = " & typeName & "(kind: " & p & c.name & inits.join("") & ")\n"
  result.add "  else:\n    unknownTag(tag, \"" & typeName & "\")\n"

macro pandocAst(body: untyped): untyped =
  ## `body` holds a `type` section of plain records, a `forward:` list, and one
  ## `TypeName:` entry per variant type. Everything lands in one type section
  ## because the records and the variants refer to each other.
  result = newStmtList()
  var section, forward: NimNode
  var code = ""
  for item in body:
    case item.kind
    of nnkTypeSection:
      section = item
    of nnkCall:
      let name = item[0].strVal
      if name == "forward":
        forward = item[1]
      else:
        var ctors: seq[CtorSpec]
        for entry in item[1]: ctors.add parseCtor(entry)
        for def in parseStmt(variantCode(name, ctors))[0]: section.add def
        code.add procsCode(name, ctors)
    else:
      error("unexpected entry in pandocAst", item)
  result.add section
  result.add forward
  for name in ["Inline", "Block", "MetaValue", "ColWidth"]:
    result.add parseStmt("proc toJ*(x: " & name & "): JsonNode\n" &
      "proc fromJ*(n: JsonNode; x: var " & name & ")")
  result.add parseStmt(code)

# --- The schema (pandoc-types 1.23) ---------------------------------------------

pandocAst:
  type
    QuoteType* {.pure.} = enum
      SingleQuote, DoubleQuote
    MathType* {.pure.} = enum
      DisplayMath, InlineMath
    CitationMode* {.pure.} = enum
      AuthorInText, SuppressAuthor, NormalCitation
    Alignment* {.pure.} = enum
      AlignLeft, AlignRight, AlignCenter, AlignDefault
    ListNumberStyle* {.pure.} = enum
      DefaultStyle, Example, Decimal, LowerRoman, UpperRoman, LowerAlpha, UpperAlpha
    ListNumberDelim* {.pure.} = enum
      DefaultDelim, Period, OneParen, TwoParens

    Attr* = object
      id*: string
      classes*: seq[string]
      attributes*: seq[tuple[key, value: string]]
    Target* = object
      url*, title*: string
    Citation* = object
      citationId*: string
      citationPrefix*, citationSuffix*: seq[Inline]
      citationMode*: CitationMode
      citationNoteNum*, citationHash*: int
    ListAttributes* = object
      start*: int
      style*: ListNumberStyle
      delim*: ListNumberDelim
    DefinitionItem* = object
      term*: seq[Inline]
      definitions*: seq[seq[Block]]
    Caption* = object
      short*: Option[seq[Inline]]
      long*: seq[Block]
    ColSpec* = object
      alignment*: Alignment
      width*: ColWidth
    Cell* = object
      attr*: Attr
      alignment*: Alignment
      rowSpan*, colSpan*: int
      blocks*: seq[Block]
    Row* = object
      attr*: Attr
      cells*: seq[Cell]
    TableHead* = object
      attr*: Attr
      rows*: seq[Row]
    TableBody* = object
      attr*: Attr
      rowHeadColumns*: int
      head*, body*: seq[Row]
    TableFoot* = object
      attr*: Attr
      rows*: seq[Row]
    MetaEntry* = object
      key*: string
      value*: MetaValue
    MetaMap* = object
      entries*: seq[MetaEntry]

  forward:
    proc toJ*(x: Citation): JsonNode
    proc fromJ*(n: JsonNode; x: var Citation)
    proc toJ*(x: MetaMap): JsonNode
    proc fromJ*(n: JsonNode; x: var MetaMap)

  ColWidth:
    ColWidth(width: float)
    ColWidthDefault

  Inline:
    Str(text: string)
    Emph(inlines: seq[Inline])
    Underline(inlines: seq[Inline])
    Strong(inlines: seq[Inline])
    Strikeout(inlines: seq[Inline])
    Superscript(inlines: seq[Inline])
    Subscript(inlines: seq[Inline])
    SmallCaps(inlines: seq[Inline])
    Quoted(quote: QuoteType, inlines: seq[Inline])
    Cite(citations: seq[Citation], inlines: seq[Inline])
    Code(attr: Attr, text: string)
    Space
    SoftBreak
    LineBreak
    Math(mathType: MathType, text: string)
    RawInline(format: string, text: string)
    Link(attr: Attr, inlines: seq[Inline], target: Target)
    Image(attr: Attr, inlines: seq[Inline], target: Target)
    Note(blocks: seq[Block])
    Span(attr: Attr, inlines: seq[Inline])

  Block:
    Plain(inlines: seq[Inline])
    Para(inlines: seq[Inline])
    LineBlock(lines: seq[seq[Inline]])
    CodeBlock(attr: Attr, text: string)
    RawBlock(format: string, text: string)
    BlockQuote(blocks: seq[Block])
    OrderedList(attributes: ListAttributes, items: seq[seq[Block]])
    BulletList(items: seq[seq[Block]])
    DefinitionList(items: seq[DefinitionItem])
    Header(level: int, attr: Attr, inlines: seq[Inline])
    HorizontalRule
    Table(attr: Attr, caption: Caption, colSpecs: seq[ColSpec], head: TableHead,
          bodies: seq[TableBody], foot: TableFoot)
    Figure(attr: Attr, caption: Caption, blocks: seq[Block])
    Div(attr: Attr, blocks: seq[Block])

  MetaValue:
    MetaMap(map: MetaMap)
    MetaList(items: seq[MetaValue])
    MetaBool(value: bool)
    MetaString(text: string)
    MetaInlines(inlines: seq[Inline])
    MetaBlocks(blocks: seq[Block])

# --- Records with their own JSON shape ------------------------------------------

proc toJ*(x: Citation): JsonNode =
  result = newJObject()
  for name, value in x.fieldPairs: result[name] = toJ(value)

proc fromJ*(n: JsonNode; x: var Citation) =
  if n.kind != JObject: failJ(n, "a citation object")
  for name, value in x.fieldPairs:
    if not n.hasKey(name):
      raise newException(PandocError, "citation is missing " & name)
    fromJ(n[name], value)

proc toJ*(x: MetaMap): JsonNode =
  result = newJObject()
  for entry in x.entries: result[entry.key] = toJ(entry.value)

proc fromJ*(n: JsonNode; x: var MetaMap) =
  if n.kind != JObject: failJ(n, "a metadata object")
  x.entries = @[]
  for key, node in n:
    var value: MetaValue
    fromJ(node, value)
    x.entries.add MetaEntry(key: key, value: value)

# --- Whole documents ------------------------------------------------------------

type
  Pandoc* = object
    apiVersion*: seq[int]
    meta*: MetaMap
    blocks*: seq[Block]

proc checkApi(version: seq[int]) =
  if version.len < 2 or version[0] != supportedApi[0] or version[1] != supportedApi[1]:
    raise newException(PandocError,
      "unsupported pandoc-api-version " & $version & ", expected " &
      $supportedApi[0] & "." & $supportedApi[1])

proc parsePandoc*(n: JsonNode): Pandoc =
  ## Decode a parsed `pandoc -t json` document.
  if n.kind != JObject or not n.hasKey("pandoc-api-version"):
    failJ(n, "a pandoc document")
  fromJ(n["pandoc-api-version"], result.apiVersion)
  checkApi(result.apiVersion)
  fromJ(n["meta"], result.meta)
  fromJ(n["blocks"], result.blocks)

proc parsePandoc*(text: string): Pandoc =
  ## Decode `pandoc -t json` output.
  parsePandoc(parseJson(text))

proc toJson*(doc: Pandoc): JsonNode =
  result = newJObject()
  result["pandoc-api-version"] = toJ(doc.apiVersion)
  result["meta"] = toJ(doc.meta)
  result["blocks"] = toJ(doc.blocks)

proc toJsonString*(doc: Pandoc): string =
  ## JSON ready for `pandoc -f json`.
  $doc.toJson
