import std/strutils
import widgets/synedit

proc main() =
  var s: SynEdit
  s.tabSize = 4
  s.lang = langMarkdown
  s.setText("""# Title

Some text.

```{r}
x <- 1:10
mean(x)
```

More text.
""")

  # Find the chunk opener offset
  let text = "# Title\n\nSome text.\n\n```{r}\nx <- 1:10\nmean(x)\n```\n\nMore text.\n"
  let chunkStart = text.find("```{r}")

  # Check blockRangeAt returns the chunk range
  let r = s.blockRangeAt(chunkStart)
  echo "blockRangeAt(chunkStart): ", r, " (expect the chunk range)"

  # Check isFolded before toggle
  echo "isFolded before: ", s.isFolded(chunkStart), " (expect false)"

  # Toggle fold
  s.toggleFold(chunkStart)
  echo "isFolded after toggle: ", s.isFolded(chunkStart), " (expect true)"

  # Toggle again
  s.toggleFold(chunkStart)
  echo "isFolded after toggle2: ", s.isFolded(chunkStart), " (expect false)"

main()