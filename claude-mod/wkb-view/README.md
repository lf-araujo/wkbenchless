# wkb-view

A Claude Code mod that wkbenchless loads into the Claude it starts (`C-c a` /
`M-x claude`), so the conversation shows what text alone does badly:

- **Display math** in Claude's replies (`$$…$$`, `\[…\]`, outside code) is
  compiled with your local `latex` + `dvipng` (amsmath) and drawn as a crisp
  image, white by default (`WKB_MATH_FG` takes any dvipng colour, e.g.
  `rgb 0 0 0`). Until it is rendered, or without LaTeX, it stays text.
- **PNG images** Claude references on a line of their own (`![alt](plot.png)`)
  or reads standalone are drawn inline.
- **Diffs:** inside wkbenchless an edit's diff collapses to one line in the
  conversation and shows in the editor's own diff pane; elsewhere a **Diffs**
  pane (`/diffs`) follows every Edit and Write.

Pictures need a terminal with the kitty graphics protocol (Ghostty, kitty) or
iTerm2 3.5+ under fullscreen rendering; other terminals keep the text.

wkbenchless embeds these files, writes them to
`~/.cache/wkbenchless/claude-mod/wkb-view` and passes `--plugin-dir` to
`claude` (Claude Code 2.1.287 or newer). Turn it off with
`gClaudeMod = false` in the config. The plugin API is early access: a Claude
Code update may need the mod adjusted; when a hook fails, Claude Code draws its
own view instead.

Develop with `claude plugin validate claude-mod/wkb-view` and
`claude plugin test claude-mod/wkb-view`.
