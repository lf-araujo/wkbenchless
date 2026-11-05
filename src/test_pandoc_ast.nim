## test_pandoc_ast -- the typed pandoc AST round-trips pandoc's JSON unchanged,
## and malformed input fails loudly instead of losing content. The live section
## needs `pandoc` on PATH and is skipped without it.
##   nim c -r --hints:off src/test_pandoc_ast.nim

import std/[json, os, osproc, strutils]
import wkbpandoc

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

proc raisesPandocError(text: string): bool =
  try:
    discard parsePandoc(text)
  except PandocError:
    result = true

proc wrap(blocks: string): string =
  """{"pandoc-api-version":[1,23,1,2],"meta":{},"blocks":""" & blocks & "}"

proc roundTrips(text: string): bool =
  ## Key order matters to a text diff, so compare serialized forms.
  $parseJson(text) == parsePandoc(text).toJsonString

block constructors:
  let para = mkPara(@[mkStr("a"), mkSpace(), mkEmph(@[mkStr("b")])])
  check "constructor sets the kind", para.kind == bkPara
  check "one field branch", para.paraInlines[0].strText == "a"
  check "no argument constructor has no c",
    not toJ(mkSpace()).hasKey("c")
  check "single argument is bare", toJ(mkStr("x"))["c"].kind == JString
  check "several arguments are an array",
    toJ(mkCode(Attr(), "x"))["c"].kind == JArray

block encodings:
  check "minimal document", roundTrips(wrap("[]"))
  check "metadata keeps its key order", roundTrips(
    """{"pandoc-api-version":[1,23,1,2],"meta":{"z":{"t":"MetaBool","c":true},""" &
    """"a":{"t":"MetaString","c":"s"}},"blocks":[]}""")
  check "citation uses named keys", roundTrips(wrap(
    """[{"t":"Para","c":[{"t":"Cite","c":[[{"citationId":"k","citationPrefix":[],""" &
    """"citationSuffix":[],"citationMode":{"t":"NormalCitation"},""" &
    """"citationNoteNum":1,"citationHash":0}],[{"t":"Str","c":"[@k]"}]]}]}]"""))
  check "short caption null and present", roundTrips(wrap(
    """[{"t":"Figure","c":[["",[],[]],[null,[]],[]]},""" &
    """{"t":"Figure","c":[["",[],[]],[[{"t":"Str","c":"s"}],[]],[]]}]"""))
  check "column widths", toJ(mkColWidth(0.25)) == %*{"t": "ColWidth", "c": 0.25} and
    toJ(mkColWidth(1.0)) == %*{"t": "ColWidth", "c": 1}

block errors:
  check "unknown block", raisesPandocError(wrap("""[{"t":"Mystery"}]"""))
  check "unknown inline", raisesPandocError(
    wrap("""[{"t":"Para","c":[{"t":"Mystery"}]}]"""))
  check "unknown enum value", raisesPandocError(
    wrap("""[{"t":"Para","c":[{"t":"Math","c":[{"t":"Mystery"},"x"]}]}]"""))
  check "wrong arity", raisesPandocError(wrap("""[{"t":"Header","c":[1]}]"""))
  check "wrong record arity", raisesPandocError(
    wrap("""[{"t":"CodeBlock","c":[["",[]],"x"]}]"""))
  check "wrong leaf type", raisesPandocError(wrap("""[{"t":"Header","c":["1",["",[],[]],[]]}]"""))
  check "missing content", raisesPandocError(wrap("""[{"t":"Para"}]"""))
  check "unsupported version", raisesPandocError(
    """{"pandoc-api-version":[1,22,0],"meta":{},"blocks":[]}""")
  check "not a document", raisesPandocError("[]")

const everything = """
---
title: T
number: 1
flag: true
list: [a, b]
nested: {k: v}
blocks: |
  para one

  para two
---

# Heading {#id .class key=value}

*e* **s** ~~x~~ ^u^ ~d~ [sc]{.smallcaps} [u]{.underline} "q" 'r' `c`{.py} $x$
$$y$$ [@k, p. 1] @k [-@k] [l](u "t") ![i](u "t")^[note] [sp]{.c} break\
next
soft `<b>`{=html}

term
: definition

2. a
3. b

(a) paren

i. roman
ii. two

I.  upper roman
II. two

A.  upper alpha
B.  two

1) one paren
2) two

#. default
#. two

(@) example

- bullet

> quote

| left | right | centre |
|:-----|------:|:------:|
| 1    | 2     | 3      |

: caption

  long  plain
------  ------
     1  2

---------- -------
wide       cells
---------- -------
a          b

---------- -------

***

| line
| block

```{.r}
code
```

<div class="d">x</div>

```{=html}
<b>raw</b>
```

![figure](a.png)
"""

block live:
  if findExe("pandoc").len == 0:
    echo "skip live pandoc checks: pandoc not on PATH"
  else:
    let dir = getTempDir() / "wkb-test-pandoc-ast"
    createDir(dir)
    writeFile(dir / "in.md", everything)
    let (original, code) = execCmdEx(
      "pandoc -f markdown+pipe_tables -M str=s -t json " & quoteShell(dir / "in.md"),
      options = {poUsePath})
    check "pandoc produced json", code == 0
    if code == 0:
      check "every constructor round-trips", roundTrips(original)
      let doc = parsePandoc(original)
      check "the document has content", doc.blocks.len > 10
      writeFile(dir / "out.json", doc.toJsonString)
      let (again, code2) = execCmdEx(
        "pandoc -f json -t json " & quoteShell(dir / "out.json"),
        options = {poUsePath})
      check "pandoc reads our output", code2 == 0
      check "pandoc sees the same document", $parseJson(again) == $parseJson(original)
      var missing: seq[string]
      template coverage(E: typedesc) =
        for value in E:
          if ("\"" & $value & "\"") notin original: missing.add $value
      coverage(InlineKind)
      coverage(BlockKind)
      coverage(MetaValueKind)
      coverage(ColWidthKind)
      coverage(QuoteType)
      coverage(MathType)
      coverage(CitationMode)
      coverage(Alignment)
      coverage(ListNumberStyle)
      coverage(ListNumberDelim)
      check "fixture covers every constructor " & $missing, missing.len == 0
    removeDir(dir)

if fails > 0:
  echo fails, " checks failed"
  quit(1)
echo "test_pandoc_ast: ok"
