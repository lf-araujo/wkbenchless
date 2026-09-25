## Notebook HTML export -- the Emacs "notebook" look (org-html + the Tufte
## tweaks in init.el + the file's style.theme), without Emacs.
##
##   M-x notebook-html-export   (or Export -> "html")   writes <file>.html
##
## Pipeline: the org buffer is pre-processed here (babel `:exports` applied the
## org way -- pandoc ignores `#+PROPERTY` defaults and never sees `#+RESULTS[hash]`
## as results), then pandoc renders it with a Lua filter that emits org-html's
## markup (#content, h1.title, div.org-src-container > pre.src, pre.example,
## div.figure + span.figure-number, table numbers) so the same CSS applies; code
## blocks are collapsed in <details> (summary = caption, else #+name, else
## "<Lang> code"), footnotes and citations become numbered sidenotes, and
## [[mn:][...]] / #+begin_marginnote become margin notes. The CSS comes from the
## file's #+HTML_HEAD lines, following #+SETUPFILE (as Emacs does). Nothing is
## evaluated: the stored results are exported. Images are embedded as base64 so
## the report is one self-contained file.

import std/[os, osproc, strutils, times, base64, re, sequtils, streams]
import wkbcore

var gNotebookHtmlEmbedMax* = 0   ## embed images up to this many bytes (0 = all)

const luaFilter = """
local sn, fig, tab = 0, 0, 0
local cite_sidenotes = false

local function esc(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end
local function inl_html(inlines)
  return (pandoc.write(pandoc.Pandoc({pandoc.Plain(inlines)}), 'html'):gsub('%s+$', ''))
end
local function blk_html(blocks)
  return (pandoc.write(pandoc.Pandoc(blocks), 'html'):gsub('%s+$', ''))
end
local function strip_p(s) return (s:gsub('</?p[^>]*>', '')) end

local function side(kind, id, marker_class, marker, content)
  return string.format('<label for="%s" class="%s">%s</label>' ..
    '<input type="checkbox" id="%s" class="margin-toggle"/><span class="%s">%s</span>',
    id, marker_class, marker, id, kind, content)
end

-- org-html src block, syntax-highlighted by pandoc, collapsed in <details>
local function src_block(cb, caption)
  local lang = cb.attributes['org-language'] or cb.classes[1] or 'source'
  local out = pandoc.write(pandoc.Pandoc({cb}), 'html')
  local code = out:match('<code[^>]*>(.-)</code>') or esc(cb.text)
  code = code:gsub('<a href="#cb[%d%-]+"[^>]*></a>', ''):gsub('<span id="cb[%d%-]+">', '<span>')
  local summary = caption
  if summary == nil or summary == '' then
    summary = (cb.identifier ~= '' and cb.identifier) or
              (lang:sub(1, 1):upper() .. lang:sub(2) .. ' code')
  end
  return pandoc.RawBlock('html',
    '<details class="src-collapsed"><summary>' .. summary .. '</summary>\n' ..
    '<div class="org-src-container">\n<pre class="src src-' .. lang:lower() .. '">' ..
    code .. '</pre>\n</div>\n</details>')
end

local function is_src(cb)
  return #cb.classes > 0 and not cb.classes:includes('example')
end

local function figure_html(img, caption)
  local h = '<div class="figure">\n<p>' .. inl_html({img}) .. '</p>\n'
  if caption and caption ~= '' then
    fig = fig + 1
    h = h .. '<p><span class="figure-number">Figure ' .. fig .. ': </span>' .. caption .. '</p>\n'
  end
  return pandoc.RawBlock('html', h .. '</div>')
end

return {
 { Meta = function(m) cite_sidenotes = m['citeproc-sidenotes'] ~= nil end },
 {
  traverse = 'topdown',

  Div = function(div)
    if div.classes:includes('captioned-content') then
      local caption, code
      for _, b in ipairs(div.content) do
        if b.t == 'Div' and b.classes:includes('caption') then
          caption = strip_p(blk_html(b.content))
        elseif b.t == 'CodeBlock' then code = b end
      end
      if code and is_src(code) then return src_block(code, caption), false end
    elseif div.classes:includes('marginnote') then
      sn = sn + 1
      return pandoc.RawBlock('html', '<p>' .. side('marginnote', 'mn-b' .. sn,
        'margin-toggle', '&#8853;', strip_p(blk_html(div.content))) .. '</p>'), false
    end
  end,

  CodeBlock = function(cb)
    if is_src(cb) then return src_block(cb, nil) end
    return pandoc.RawBlock('html', '<pre class="example">' .. esc(cb.text) .. '</pre>')
  end,

  Figure = function(f)
    local img
    pandoc.walk_block(pandoc.Div(f.content), { Image = function(i) img = img or i end })
    if not img then return nil end
    local cap = inl_html(pandoc.utils.blocks_to_inlines(f.caption.long))
    return figure_html(img, cap), false
  end,

  Para = function(p)             -- a standalone image is a figure in org-html
    if #p.content == 1 and p.content[1].t == 'Image' then
      return figure_html(p.content[1], nil), false
    end
  end,

  Table = function(t)
    local cap = t.caption.long
    if #cap > 0 then
      tab = tab + 1
      local inl = pandoc.utils.blocks_to_inlines(cap)
      table.insert(inl, 1, pandoc.RawInline('html',
        '<span class="table-number">Table ' .. tab .. ': </span>'))
      t.caption.long = { pandoc.Plain(inl) }
      return t
    end
  end,

  Note = function(n)             -- footnotes -> numbered sidenotes
    sn = sn + 1
    return pandoc.RawInline('html', side('sidenote', 'sn-' .. sn,
      'margin-toggle sidenote-number', '', strip_p(blk_html(n.content)))), false
  end,

  Cite = function(c)             -- (after citeproc) citations -> sidenotes
    if not cite_sidenotes then return nil end
    sn = sn + 1
    return pandoc.RawInline('html', side('sidenote', 'cn-' .. sn,
      'margin-toggle sidenote-number', '', inl_html(c.content))), false
  end,

  Link = function(l)             -- [[mn:][text]] -> margin note
    if l.target == 'mn:' or l.target:sub(1, 3) == 'mn:' then
      sn = sn + 1
      return pandoc.RawInline('html', side('marginnote', 'mn-' .. sn,
        'margin-toggle', '&#8853;', inl_html(l.content))), false
    end
  end,
 },
}
"""

const pageTemplate = """<!DOCTYPE html>
<html lang="$if(lang)$$lang$$else$en$endif$">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>$pagetitle$</title>
$if(author)$<meta name="author" content="$for(author)$$author$$sep$; $endfor$"/>
$endif$<meta name="generator" content="wkbenchless notebook-html"/>
$for(header-includes)$
$header-includes$
$endfor$
</head>
<body>
<div id="content" class="content">
$if(title)$<h1 class="title">$title$$if(subtitle)$<br/><span class="subtitle">$subtitle$</span>$endif$</h1>
$endif$$if(toc)$<div id="table-of-contents" role="doc-toc">
<h2>Table of Contents</h2>
<div id="text-table-of-contents" role="doc-toc">
$table-of-contents$
</div>
</div>
$endif$$if(abstract)$<div class="abstract">
$abstract$
</div>
$endif$$body$
</div>
<div id="postamble" class="status">
$if(author)$<p class="author">Author: $for(author)$$author$$sep$, $endfor$</p>
$endif$$if(date)$<p class="date">Date: $date$</p>
$endif$<p class="date">Created: $created$</p>
</div>
</body>
</html>
"""

# Token colours for the highlighted code (pandoc's classes, pygments palette);
# scoped to pre.src so they never touch the theme's own rules.
const tokenCss = """<style type="text/css">
pre.src, pre.example { overflow-x: auto; }   /* long lines scroll inside their box */
/* the theme's body line-height (1.3em = a fixed 20.8px) is inherited by the
   large headings, so a wrapped title overlapped itself: scale with the font */
h1, h2, h3, h4 { line-height: 1.25; }
h1.title { line-height: 1.2; }
pre.src span.kw, pre.src span.cf { color: #007020; font-weight: bold; }
pre.src span.dt { color: #902000; }
pre.src span.dv, pre.src span.bn, pre.src span.fl { color: #40a070; }
pre.src span.ch, pre.src span.st, pre.src span.vs, pre.src span.ss, pre.src span.sc { color: #4070a0; }
pre.src span.co, pre.src span.do, pre.src span.an, pre.src span.cv, pre.src span.in { color: #60a0b0; font-style: italic; }
pre.src span.ot, pre.src span.op { color: #666666; }
pre.src span.fu { color: #06287e; }
pre.src span.al, pre.src span.er { color: #ff0000; font-weight: bold; }
pre.src span.cn, pre.src span.va { color: #19177c; }
pre.src span.pp, pre.src span.at, pre.src span.im, pre.src span.bu, pre.src span.ex { color: #7d9029; }
pre.src span.wa { color: #60a0b0; font-weight: bold; font-style: italic; }
</style>"""

proc keywordValue(line, key: string): string =
  ## "#+KEY: value" -> "value" (case-insensitive key), else "".
  let s = line.strip()
  if s.toLowerAscii.startsWith(key): s[key.len .. ^1].strip() else: ""

proc collectSetup(path: string; lines: seq[string]; heads, options: var seq[string];
                  depth = 0) =
  ## #+HTML_HEAD / #+HTML_HEAD_EXTRA and #+OPTIONS lines, following #+SETUPFILE
  ## (relative to the including file), in document order -- as Emacs reads them.
  for ln in lines:
    let low = ln.strip().toLowerAscii
    if low.startsWith("#+setupfile:") and depth < 5:
      var f = keywordValue(ln, "#+setupfile:").strip(chars = {'"', ' '})
      if not f.isAbsolute: f = path.parentDir / f
      if fileExists(f):
        collectSetup(f, readFile(f).splitLines(), heads, options, depth + 1)
    elif low.startsWith("#+html_head:"):
      heads.add ln.strip()[len("#+html_head:") .. ^1].strip()
    elif low.startsWith("#+html_head_extra:"):
      heads.add ln.strip()[len("#+html_head_extra:") .. ^1].strip()
    elif low.startsWith("#+options:"):
      options.add ln.strip()[len("#+options:") .. ^1].splitWhitespace()

proc optionValue(options: seq[string]; key: string): string =
  ## The last `key:value` among #+OPTIONS tokens ("" if absent).
  for o in options:
    if o.startsWith(key & ":"): result = o[key.len + 1 .. ^1]

proc isAffiliatedKeyword(line: string): bool =
  ## org affiliated keywords that belong to the element below them.
  let low = line.strip().toLowerAscii
  for k in ["#+name:", "#+caption:", "#+header:", "#+attr_", "#+label:"]:
    if low.startsWith(k): return true

proc resultsEnd(lines: seq[string]; resultsLine: int): int =
  ## One past the last line of the results element starting at `resultsLine`
  ## (same rule babel uses: stop at a blank line, a new #+ keyword or a heading).
  var p = resultsLine + 1
  while p < lines.len:
    let t = lines[p].strip()
    if t.len == 0 or (t.startsWith("#+") and not t.toLowerAscii.startsWith("#+begin_") and
                      not t.toLowerAscii.startsWith("#+end_")) or t.startsWith("*"):
      break
    inc p
  p

proc applyExports(app: App; lines: seq[string]; running: var int): seq[string] =
  ## Babel's `:exports` done the org way (document defaults included):
  ## none -> drop code and results; code -> drop results; results -> drop code;
  ## both -> keep both. `#+RESULTS...:` keywords go, so pandoc exports what is
  ## left as plain results. Works bottom-up so earlier line numbers stay valid.
  result = lines
  let blocks = blockTable(app)
  for i in countdown(blocks.high, 0):
    let b = blocks[i]
    let ex = argValues(b.args, ":exports")
    let mode = if ex.len > 0: ex[0].toLowerAscii else: "code"   # org's default
    var codeStart = b.header
    while codeStart > 0 and isAffiliatedKeyword(result[codeStart - 1]):
      dec codeStart                                    # #+name / #+caption / #+header
    if b.resultsLine >= 0:
      let rEnd = resultsEnd(result, b.resultsLine)
      for k in b.resultsLine + 1 ..< rEnd:
        if result[k].contains(runningPrefix): inc running
      if mode in ["code", "none"]:
        result.delete(b.resultsLine .. rEnd - 1)
      else:
        result.delete(b.resultsLine)                   # keep the results, drop the keyword
    if mode in ["results", "none"]:
      result.delete(codeStart .. b.endLine)
    else:
      # pandoc applies its own :exports (code by default): hand it plain blocks
      var toks = result[b.header].strip().splitWhitespace()
      var keep: seq[string]
      var k = 0
      while k < toks.len:
        if toks[k] == ":exports":
          inc k
          while k < toks.len and not toks[k].startsWith(":"): inc k
        else:
          keep.add toks[k]; inc k
      result[b.header] = keep.join(" ")

proc mimeOf(path: string): string =
  case path.splitFile.ext.toLowerAscii
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".webp": "image/webp"
  of ".bmp": "image/bmp"
  else: ""

proc embedImages(html, baseDir: string; embedded, linked: var int): string =
  ## <img src="local path"> -> a base64 data URI, like the init.el advice (but
  ## by default for every size, so the report is one self-contained file).
  var pos = 0
  let pat = re("""<img\b[^>]*?\ssrc="([^"]+)"""")
  var m: array[1, string]
  while true:
    let (a, b) = findBounds(html, pat, m, pos)
    if a < 0:
      result.add html[pos .. ^1]; break
    result.add html[pos ..< a]
    var tag = html[a .. b]
    var src = m[0]
    if not src.startsWith("data:") and not src.startsWith("http"):
      if src.startsWith("file:"): src = src[5 .. ^1]
      let f = if src.isAbsolute: src else: baseDir / src
      let mime = mimeOf(f)
      if mime.len > 0 and fileExists(f) and
         (gNotebookHtmlEmbedMax == 0 or getFileSize(f) <= gNotebookHtmlEmbedMax):
        tag = tag.replace("src=\"" & m[0] & "\"",
                          "src=\"data:" & mime & ";base64," & encode(readFile(f)) & "\"")
        inc embedded
      else: inc linked
    result.add tag
    pos = b + 1

proc notebookHtmlExport*(app: var App) =
  if app.filePath.len == 0 or not app.filePath.toLowerAscii.endsWith(".org"):
    app.msg = "notebook-html: save the buffer as an .org file first"; return
  if findExe("pandoc").len == 0:
    app.msg = "notebook-html: pandoc not on PATH"; return
  let src = absolutePath(app.filePath)
  let dir = src.parentDir
  var lines: seq[string]
  for i in 0 ..< app.ed.getLineCount(): lines.add app.ed.getLineText(i)
  var heads, options: seq[string]
  collectSetup(src, lines, heads, options)
  var running = 0
  let body = applyExports(app, lines, running)

  let tmp = getTempDir() / "wkb-notebook-html"
  createDir(tmp)
  let orgTmp = dir / (".wkb-export-" & src.splitFile.name & ".org")   # same dir: relative paths hold
  writeFile(orgTmp, body.join("\n"))
  defer: removeFile(orgTmp)
  writeFile(tmp / "filter.lua", luaFilter)
  writeFile(tmp / "template.html", pageTemplate)
  writeFile(tmp / "head.html", heads.join("\n") & "\n" & tokenCss & "\n")

  var args = @["-f", "org", "-t", "html5", "--standalone", "--wrap=none",
               "--template=" & tmp / "template.html",
               "--include-in-header=" & tmp / "head.html",
               "--shift-heading-level-by=1",
               "-V", "created=" & now().format("yyyy-MM-dd ddd HH:mm")]
  # org defaults: toc and section numbers on, unless #+OPTIONS says otherwise
  let toc = optionValue(options, "toc")
  if toc != "nil":
    args.add "--toc"
    if toc.len > 0 and toc[0] in Digits: args.add "--toc-depth=" & toc
  if optionValue(options, "num") != "nil": args.add "--number-sections"
  var bib = ""
  for ln in lines:
    let v = keywordValue(ln, "#+bibliography:")
    if v.len > 0 and bib.len == 0: bib = if v.isAbsolute: v else: dir / v
  if bib.len > 0 and fileExists(bib):
    args.add @["--citeproc", "--bibliography=" & bib, "-M", "citeproc-sidenotes=true"]
  args.add @["--lua-filter=" & tmp / "filter.lua"]    # after citeproc: sees formatted cites
  let outFile = src.changeFileExt("html")
  args.add @[orgTmp, "-o", outFile & ".tmp"]
  let p = startProcess(findExe("pandoc"), workingDir = dir, args = args,
                       options = {poStdErrToStdOut})
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    app.msg = "notebook-html: pandoc failed: " & outp.strip().splitLines()[0 .. min(2, outp.strip().splitLines().high)].join(" | ")
    return
  var embedded, linked = 0
  let html = embedImages(readFile(outFile & ".tmp"), dir, embedded, linked)
  removeFile(outFile & ".tmp")
  writeFile(outFile, html)
  app.msg = "notebook-html: wrote " & extractFilename(outFile) & " (" &
            $(html.len div 1024) & " KB; " & $embedded & " image(s) embedded" &
            (if linked > 0: ", " & $linked & " linked" else: "") &
            (if running > 0: "; WARNING: " & $running & " block(s) still running" else: "") & ")"

proc extend*(app: var App) =
  defcommand("notebook-html-export", "Export: HTML notebook (Emacs notebook style, self-contained)",
             notebookHtmlExport)
  registerExport("html", "HTML notebook (Emacs notebook style, self-contained)",
                 "notebook-html-export")
