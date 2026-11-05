## Included by synedit.nim: big Org headings and captions. wkbenchless only; kept out of
## that file so a sync with focim stays small.

proc isBigOrgLine(s: SynEdit; i: int): bool =
  ## org #+title / #+author / top-level headings, and Markdown/Rmd # headings,
  ## render in bigFont.
  if s.lang notin {langOrg, langMarkdown}: return false
  var t = ""
  var j = i
  while j < s.len and s[j] != '\L' and t.len < 12:
    t.add s[j]; inc j
  let ls = t.strip(leading = true, trailing = false).toLowerAscii
  if s.lang == langMarkdown:
    # Markdown/Rmd ATX headings (# / ## / ###). Exclude '#' inside a code chunk
    # (```{r}), where R comments also start with '#'.
    return ls.len > 0 and ls[0] == '#' and not s.inSrcBlock(i)
  result = ls.startsWith("#+title") or ls.startsWith("#+author") or
           isOrgHeadlineText(t)                 # `*+ ` headline, not `*bold*`

proc isCaptionLine(s: SynEdit; i: int): bool =
  ## org #+caption: lines render a touch larger (captionFont).
  if s.lang != langOrg: return false
  var t = ""
  var j = i
  while j < s.len and s[j] != '\L' and t.len < 12:
    t.add s[j]; inc j
  t.strip(leading = true, trailing = false).toLowerAscii.startsWith("#+caption")
