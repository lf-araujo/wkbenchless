## wkbmatter -- Matter (TextMate grammars, pure Nim) as SynEdit's code styler.
##
## Optional: build with `-d:wkbMatter` and `matter` on the path. It only adds an
## entry to an editor's `markdownLangs`, so languages without a grammar here, and
## every build without the flag, keep SynEdit's own tokenizers.
##
## The grammar is VS Code's extensions/r/syntaxes/r.tmLanguage.json (MIT).

import std/[strutils, tables]
import matter/[engine, rawgrammar]
import widgets/synedit
import widgets/theme

const
  rGrammarJson = staticRead("vendor/grammars/r.tmLanguage.json")
  MaxCachedLines = 100_000

type
  CachedLine = object
    before, after: StateStack
    runs: seq[StyleRun]

var
  rGrammar: Grammar
  cache: Table[string, seq[CachedLine]]

proc grammarR(): Grammar =
  if rGrammar == nil:
    let registry = newRegistry()
    registry.addGrammar(parseRawGrammar(rGrammarJson, "r.tmLanguage.json"))
    rGrammar = registry.loadGrammar("source.r")
  rGrammar

proc classOf(scopes: seq[string]): TokenClass =
  ## The innermost scope that means something to the theme. Comments and strings
  ## win from any depth: the `#` and the quotes are punctuation inside them.
  for s in scopes:
    if s.startsWith("comment"): return TokenClass.Comment
    if s.startsWith("string"): return TokenClass.StringLit
  for i in countdown(scopes.high, 0):
    let s = scopes[i]
    if s.startsWith("constant.numeric"): return TokenClass.DecNumber
    if s.startsWith("keyword.operator"): return TokenClass.Operator
    if s.startsWith("keyword") or s.startsWith("storage.type.function") or
       s.startsWith("constant.language"): return TokenClass.Keyword
    if s.startsWith("entity.name.function") or s.startsWith("support.function"):
      return TokenClass.Command
    if s.startsWith("punctuation"): return TokenClass.Punctuation
  TokenClass.None

proc tokenized(g: Grammar; line: string; state: StateStack): CachedLine =
  let r = g.tokenizeLine(line, state)
  result = CachedLine(before: state, after: r.ruleStack)
  for t in r.tokens:
    if t.endIndex > t.startIndex:
      result.runs.add StyleRun(first: t.startIndex, last: t.endIndex - 1,
                              tc: classOf(t.scopes))

proc lookup(g: Grammar; line: string; state: StateStack): CachedLine =
  ## A line's tokens depend only on its text and the state it starts in, so a
  ## document re-styled after one keystroke tokenizes only what really changed.
  let hits = addr cache.mgetOrPut(line, @[])
  for c in hits[]:
    if c.before == state: return c
  result = tokenized(g, line, state)
  hits[].add result

proc styleR(code: string; runs: var seq[StyleRun]) =
  if cache.len > MaxCachedLines: cache.clear()
  let g = grammarR()
  var state: StateStack = nil
  var offset = 0
  for line in code.split('\n'):
    try:
      let c = lookup(g, line, state)
      state = c.after
      for r in c.runs:
        runs.add StyleRun(first: r.first + offset, last: r.last + offset, tc: r.tc)
    except MatterError:
      discard                            # this line stays unstyled
    offset += line.len + 1

proc install*(s: var SynEdit) =
  s.markdownLangs["r"] = styleR
