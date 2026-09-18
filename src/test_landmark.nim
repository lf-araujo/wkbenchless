import std/[strutils, tables]
import wkbcore

var app: App
app.ed.lang = langOrg
app.ed.setText("""Intro text.

* Section one

some prose
{>> fix this <<}

#+begin_src r
x <- 1
#+end_src

** Sub one

more prose
""")

var visited: seq[string]
for _ in 1 .. 5:
  nextLandmark(app)
  visited.add $app.ed.currentLine & ":" & app.msg
echo visited.join(" | ")
nextLandmark(app)

# expectations (0-based lines): 2=heading, 5=comment, 7=src, 11=sub-heading
doAssert app.msg == "no next section / block / comment"
app.ed.gotoLine(6, 0)          # inside first src block
prevLandmark(app)
doAssert app.ed.currentLine == 2 and app.msg == "previous section: Section one", app.msg
nextLandmark(app)
doAssert app.ed.currentLine == 5 and app.msg == "next comment", app.msg

# -- Rmd ------------------------------------------------------------------
app = App()
app.ed.lang = langMarkdown
app.ed.setText("""# Title

```{r}
x <- 1
```

{>> a comment <<}

## Sub heading
""")

visited.setLen 0
for _ in 1 .. 3:
  nextLandmark(app)
  visited.add $app.ed.currentLine & ":" & app.msg
echo visited.join(" | ")

# 2=chunk, 6=comment, 8=## heading (line 0 `# Title` is the cursor start)
doAssert app.ed.currentLine == 8, $app.ed.currentLine
doAssert app.msg == "next section: Sub heading"
prevLandmark(app)
doAssert app.ed.currentLine == 6 and app.msg == "previous comment", app.msg
prevLandmark(app)
doAssert app.ed.currentLine == 2 and app.msg == "previous src block", app.msg
prevLandmark(app)
doAssert app.ed.currentLine == 0 and app.msg == "previous section: Title", app.msg

# -- non-landmark noise must not match ------------------------------------
app = App()
app.ed.lang = langOrg
app.ed.setText("""*bold start* is not a heading
#+RESULTS:
: session value
- list item with {>> comment <<} on same line

* Real heading
""")
app.ed.gotoLine(1, 0)              # 0-based line 0
nextLandmark(app)
doAssert app.ed.currentLine == 3, "line 3 has the comment: " & app.msg
nextLandmark(app)
doAssert app.ed.currentLine == 5 and app.msg == "next section: Real heading", app.msg

# -- scratch / plain-text buffers: BOTH heading syntaxes -------------------
app = App()
app.ed.lang = langNone
app.ed.setText("""* Org-style heading in a .txt
plain prose
# Hash-style heading in same txt
""")
nextLandmark(app)
doAssert app.ed.currentLine == 2 and app.msg == "next section: Hash-style heading in same txt", app.msg
prevLandmark(app)
doAssert app.ed.currentLine == 0 and app.msg == "previous section: Org-style heading in a .txt", app.msg

# -- code buffers: headings OFF (an R `# comment` is not a section) --------
app = App()
app.ed.lang = langR
app.ed.setText("""# just a comment
x <- 1
""")
nextLandmark(app)
doAssert app.msg == "no next section / block / comment", app.msg

# -- chunk bodies are skipped (code is not structure) ----------------------
app = App()
app.ed.lang = langOrg
app.ed.setText("""* Top

#+begin_src r
# a hash comment in the body
* a bullet in the body
#+end_src

* After
""")
nextLandmark(app)                     # cursor 0 -> the src block, NOT body lines
doAssert app.ed.currentLine == 2 and app.msg == "next src block", $app.ed.currentLine & " " & app.msg
nextLandmark(app)
doAssert app.ed.currentLine == 7 and app.msg == "next section: After", $app.ed.currentLine & " " & app.msg
prevLandmark(app)                     # backward must land on the FENCE, not the body
doAssert app.ed.currentLine == 2 and app.msg == "previous src block", $app.ed.currentLine & " " & app.msg
prevLandmark(app)
doAssert app.ed.currentLine == 0 and app.msg == "previous section: Top", $app.ed.currentLine & " " & app.msg

# Rmd: a `# comment` inside a ```{r} body must not read as a heading
app = App()
app.ed.lang = langMarkdown
app.ed.setText("""# Title

```{r}
# not a heading
x <- 1
```
""")
nextLandmark(app)
doAssert app.ed.currentLine == 2 and app.msg == "next src block", $app.ed.currentLine & " " & app.msg
nextLandmark(app)
doAssert app.msg == "no next section / block / comment", app.msg

# -- unterminated last line: gotoLine must reach it ----------------------
# A buffer whose text does NOT end in \L has numberOfLines == index of its
# final line. gotoLine must be able to land on it (e.g. jump to the last
# heading); the old clamp (numberOfLines - 1) always landed one short.
app = App()
app.ed.lang = langOrg
app.ed.setText("* First\n\n* Last (no trailing newline)")
echo "count=", app.ed.getLineCount()
nextLandmark(app)
doAssert app.ed.currentLine == 2, $app.ed.currentLine & " " & app.msg
doAssert app.msg == "next section: Last (no trailing newline)", app.msg
nextLandmark(app)
doAssert app.msg == "no next section / block / comment", app.msg
prevLandmark(app)
doAssert app.ed.currentLine == 0 and app.msg == "previous section: First", app.msg

# commands registered
registerBuiltins()
doAssert gCommands.hasKey("next-landmark")
doAssert gCommands.hasKey("prev-landmark")
echo "all landmark tests passed"
