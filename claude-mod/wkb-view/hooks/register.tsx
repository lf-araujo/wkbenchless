import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { EditDiff } from '../types'

// wkb-view: pictures where text falls short, and diffs where they belong.
//
// - Display math in a reply ($$…$$, \[…\]; not inside code fences) is compiled
//   with the local latex + dvipng and drawn as an Image: white, or the dvipng
//   colour in $WKB_MATH_FG (e.g. "rgb 0 0 0" for a light terminal). Until it
//   is ready, or where it cannot be, the source stays text.
// - A PNG a reply references on a line of its own (![alt](path)), or a PNG a
//   standalone Read row shows, is drawn as an Image.
// - Every Edit / Write / MultiEdit lands in a "Diffs" pane (one hunk per edit,
//   older edits a press away). Inside wkbenchless (WKB_CTL_PORT set) the pane
//   stays shut and the transcript's diff collapses to one line: the editor's
//   own diff pane shows it (wkbenchless's edit-diff hooks send it there).

const PANE = 'wkb-diffs'
const EDIT_TOOLS = ['Edit', 'Write'] as const

// Change a tag when the stored value's fields change: an older value is then
// read as the initial one rather than mis-read.
const edits = atom({ plugin: 'wkb-view', key: 'edits' } as const, [] as EditDiff[], {
  shape: 'edits-1',
})
const shown = atom({ plugin: 'wkb-view', key: 'shown' } as const, -1, { shape: 'shown-1' })

// Module state: rebuilt by session.start on every (re)load.
let inWkb = false
let cacheDir = ''
let cwd = ''
let fg = 'rgb 1 1 1'
let paneOpened = false
const queue: { tex: string; png: string }[] = []
const queued = new Set<string>()
const failed = new Set<string>()
const ready = new Set<string>()
const pngSize = new Map<string, { w: number; h: number }>()
const readPngs = new Map<string, string>()      // tool_use_id -> PNG a Read showed

// -- small helpers -------------------------------------------------------------

function hashOf(s: string): string {
  let h = 5381
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0
  return h.toString(16)
}

function baseName(p: string): string {
  return p.slice(p.lastIndexOf('/') + 1)
}

/** One hunk spanning everything that changed, with 3 lines of context. */
function unifiedDiff(before: string | null, after: string | null): string {
  const a = before ?? ''
  const b = after ?? ''
  if (a === b) return ''
  const A = a.length ? a.split('\n') : []
  const B = b.length ? b.split('\n') : []
  let p = 0
  while (p < A.length && p < B.length && A[p] === B[p]) p++
  let s = 0
  while (s < A.length - p && s < B.length - p && A[A.length - 1 - s] === B[B.length - 1 - s]) s++
  const C = 3
  const start = Math.max(0, p - C)
  const endA = Math.min(A.length, A.length - s + C)
  const endB = Math.min(B.length, B.length - s + C)
  const out: string[] = []
  for (let i = start; i < p; i++) out.push(' ' + A[i])
  for (let i = p; i < A.length - s; i++) out.push('-' + A[i])
  for (let i = p; i < B.length - s; i++) out.push('+' + B[i])
  for (let i = A.length - s; i < endA; i++) out.push(' ' + A[i])
  const lenA = endA - start
  const lenB = endB - start
  const at = (len: number) => (len > 0 ? start + 1 : start)
  return `@@ -${at(lenA)},${lenA} +${at(lenB)},${lenB} @@\n` + out.join('\n')
}

type Part =
  | { kind: 'md'; text: string }
  | { kind: 'math'; tex: string; raw: string }
  | { kind: 'img'; path: string; alt: string; raw: string }

const MATH_OR_IMG = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|^[ \t]*!\[([^\]]*)\]\(([^)\s]+\.png)\)[ \t]*$/gim

/** Splits a reply into markdown, display math and PNG lines; fences stay markdown. */
function splitReply(text: string): Part[] {
  const parts: Part[] = []
  const pushMd = (t: string) => {
    if (!t) return
    const last = parts[parts.length - 1]
    if (last?.kind === 'md') last.text += t
    else parts.push({ kind: 'md', text: t })
  }
  const chunks = text.split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/)
  for (const chunk of chunks) {
    if (chunk.startsWith('```') || chunk.startsWith('~~~')) {
      pushMd(chunk)
      continue
    }
    let last = 0
    for (const m of chunk.matchAll(MATH_OR_IMG)) {
      pushMd(chunk.slice(last, m.index))
      if (m[4] !== undefined) parts.push({ kind: 'img', alt: m[3] ?? '', path: m[4], raw: m[0] })
      else parts.push({ kind: 'math', tex: (m[1] ?? m[2] ?? '').trim(), raw: m[0] })
      last = (m.index ?? 0) + m[0].length
    }
    pushMd(chunk.slice(last))
  }
  return parts
}

function texDocument(tex: string): string {
  const body = /\\begin\{(align|gather|multline|equation|flalign)\*?\}/.test(tex)
    ? tex
    : `\\[\n${tex}\n\\]`
  return (
    '\\documentclass[12pt]{article}\n\\usepackage{amsmath,amssymb,amsfonts,bm}\n' +
    '\\pagestyle{empty}\n\\begin{document}\n' + body + '\n\\end{document}\n'
  )
}

async function readTextFile($: EngineInterface, path: string): Promise<string | null> {
  try { return String(await $.fs.read(path)) } catch { return null }
}

/** Runs an Edit / Write, then records its diff for the pane (and opens it). */
async function recordEdit<R extends { deny?: unknown; isError?: unknown }>(
  $: EngineInterface,
  file: string,
  id: string,
  run: () => Promise<R>,
): Promise<R> {
  const before = file ? await readTextFile($, file) : null
  const ran = await run()
  if (!file || ran.deny !== undefined || ran.isError === true) return ran
  const diff = unifiedDiff(before, await readTextFile($, file))
  const at = await $.clock.now()
  await update($, edits, list => [...(list ?? []), { id, file, diff, at }].slice(-50))
  await update($, shown, () => -1)
  if (!inWkb && !paneOpened) {
    paneOpened = true
    void $.ui.open({ id: PANE, title: 'Diffs' })
  }
  return ran
}

// -- the hooks -----------------------------------------------------------------

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    inWkb = !!(await $.env.get('WKB_CTL_PORT'))
    const home = (await $.env.get('HOME')) ?? ''
    const xdg = await $.env.get('XDG_CACHE_HOME')
    cacheDir = (xdg || home + '/.cache') + '/claude-wkb-view'
    cwd = (await $.env.get('PWD')) ?? home
    // White by default: Claude Code's own theme does not say what the
    // terminal's background is. $WKB_MATH_FG takes any dvipng colour.
    fg = (await $.env.get('WKB_MATH_FG')) || 'rgb 1 1 1'
    await $.process.run(['mkdir', '-p', cacheDir + '/math'])
    await $.command.register({ name: 'diffs', description: 'Show the edits of this session in a pane' })

    // The formula compiler: renders queued formulas one at a time, then
    // redraws so the replies holding them pick up their pictures.
    let busy = false
    $.clock.every(250, async () => {
      if (busy || queue.length === 0) return
      busy = true
      try {
        const job = queue.shift()!
        const dir = `${cacheDir}/build-${hashOf(job.png)}`
        await $.process.run(['mkdir', '-p', dir])
        await $.fs.write(dir + '/f.tex', texDocument(job.tex))
        const tex = await $.process.run(
          ['latex', '-interaction=nonstopmode', '-halt-on-error', 'f.tex'],
          { cwd: dir, timeoutMs: 30_000 },
        )
        const png = tex.exitCode === 0
          ? await $.process.run(
              // --truecolor: an RGBA PNG whose edges fade in alpha (the default
              // 4-bit palette blends them to grey); MATH_DPI keeps them sharp
              // on dense screens once the terminal scales the picture down.
              ['dvipng', '-q', '--truecolor', '-T', 'tight', '-D', String(MATH_DPI),
               '-bg', 'Transparent',
               '-fg', fg, '-o', job.png, 'f.dvi'],
              { cwd: dir, timeoutMs: 30_000 },
            )
          : tex
        if (png.exitCode === 0) ready.add(job.png)
        else failed.add(job.png)
        await $.process.run(['rm', '-rf', dir])
      } catch {
        // no latex / dvipng: the formula stays text
      } finally {
        busy = false
        $.ui.invalidate('ui.render')
      }
    })

    return next(e)
  })

  on('command.run', { command: 'diffs' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Diffs' })
    return { text: inWkb ? 'Diffs pane opened (wkbenchless also shows each diff).' : 'Diffs pane opened.' }
  })

  // -- edits: record each one's diff for the pane --------------------------------
  // A failure here must never block the edit itself: the .catch runs the tool
  // (or hands back its result, if it already ran) without the pane's record.
  on('tool.call', { tool: 'Edit' }, ($, e, next) =>
    recordEdit($, e.file_path, e.tool_use_id, () => next(e)),
  ).catch(($, e, next) => next(e))
  on('tool.call', { tool: 'Write' }, ($, e, next) =>
    recordEdit($, e.file_path, e.tool_use_id, () => next(e)),
  ).catch(($, e, next) => next(e))

  // Remember which PNG a Read showed, for its result row.
  on('tool.call', { tool: 'Read' }, async ($, e, next) => {
    const file = String((e as { file_path?: unknown }).file_path ?? '')
    if (/\.png$/i.test(file)) readPngs.set(e.tool_use_id, file)
    return next(e)
  }).catch(($, e, next) => next(e))

  // -- the Diffs pane -------------------------------------------------------------
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Code, Button } = $.ui.resolve(e)
    const list = (await read($, edits)) ?? []
    const want = (await read($, shown)) ?? -1
    if (list.length === 0) return <Text dimColor>No edits yet in this session.</Text>
    const i = want < 0 || want >= list.length ? list.length - 1 : want
    const d = list[i]!
    const step = async (delta: number) => {
      const all = (await read($, edits)) ?? []
      await update($, shown, n => {
        const cur = n === undefined || n < 0 || n >= all.length ? all.length - 1 : n
        const to = Math.min(all.length - 1, Math.max(0, cur + delta))
        return to === all.length - 1 ? -1 : to
      })
    }
    return (
      <Box flexDirection="column">
        <Box flexDirection="row" gap={1}>
          <Button key="older" label="‹ older" onPress={() => step(-1)} />
          <Text>{i + 1}/{list.length}</Text>
          <Button key="newer" label="newer ›" onPress={() => step(1)} />
          <Button key="latest" label="latest" onPress={() => update($, shown, () => -1)} />
        </Box>
        <Text bold>{baseName(d.file)} <Text dimColor>{d.file}</Text></Text>
        {d.diff
          ? <Code source={d.diff} format="diff" path={d.file} />
          : <Text dimColor>No change to the file.</Text>}
      </Box>
    )
  })

  // -- inside wkbenchless: an edit's diff is the editor's to show -----------------
  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const isEdit = (EDIT_TOOLS as readonly string[]).includes(e.props.tool)
    if (isEdit && inWkb && !e.props.isErrored && !e.props.isExpanded) {
      const { Text } = $.ui.resolve(e)
      return <Text dimColor>  ⎿  diff shown in wkbenchless (ctrl+o shows it here)</Text>
    }
    const png = e.props.tool === 'Read' ? readPngs.get(e.props.tool_use_id) : undefined
    if (png && e.surface === 'terminal' && !e.props.isErrored) {
      const cells = await sizeFor($, png, Math.max(10, (e.viewport?.columns ?? 80) - 8), 40)
      if (cells) {
        const { Box, Image } = $.ui.resolve(e)
        return (
          <Box flexDirection="column" paddingLeft={5}>
            <Image source={{ file: png, format: 'png' }} {...cells} alt={baseName(png)} />
          </Box>
        )
      }
    }
    return next(e)
  })

  // -- replies: display math and PNG lines as pictures ----------------------------
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const parts = splitReply(e.props.text)
    if (!parts.some(p => p.kind !== 'md')) return next(e)
    const { Box, Text, Markdown, Image } = $.ui.resolve(e)
    const width = Math.max(20, (e.viewport?.columns ?? 80) - 4)
    const children = []
    for (const part of parts) {
      if (part.kind === 'md') {
        if (part.text.trim()) children.push(<Markdown text={part.text.replace(/^\n+|\n+$/g, '')} />)
        continue
      }
      if (part.kind === 'math') {
        const png = `${cacheDir}/math/${hashOf(`v2:${MATH_DPI}:${fg}\u0000${part.tex}`)}.png`
        if (!ready.has(png) && !failed.has(png) && (await $.fs.exists(png))) ready.add(png)
        if (ready.has(png)) {
          const cells = await sizeFor($, png, width, 12, 'math')
          if (cells) {
            children.push(<Image source={{ file: png, format: 'png' }} {...cells} alt={part.tex} />)
            continue
          }
        } else if (!failed.has(png) && !queued.has(png)) {
          queued.add(png)
          queue.push({ tex: part.tex, png })
        }
        children.push(<Markdown text={part.raw} />)
        continue
      }
      const path = part.path.startsWith('/') ? part.path
        : part.path.startsWith('~/') ? ((await $.env.get('HOME')) ?? '') + part.path.slice(1)
        : `${cwd}/${part.path}`
      const cells = (await $.fs.exists(path)) ? await sizeFor($, path, Math.min(width, 100), 40) : undefined
      children.push(cells
        ? <Image source={{ file: path, format: 'png' }} {...cells} alt={part.alt || baseName(path)} />
        : <Markdown text={part.raw} />)
    }
    if (children.length === 0) return next(e)
    return (
      <Box flexDirection="row">
        <Text>{e.props.isFirstOfReply ? '● ' : '  '}</Text>
        <Box flexDirection="column" flexShrink={1}>{children}</Box>
      </Box>
    )
  })
}

// Terminal cells in pixels, roughly: a formula rendered at 150 dpi / 12 pt has
// glyphs about 1.5x a 1x terminal font, so it is laid out on larger cells.
const CELL = { w: 9, h: 19 }
const MATH_SCALE = 1.55
// Formulas render at MATH_DPI for sharpness; their cells are sized as at
// 150 dpi, so the extra pixels go into density, not size.
const MATH_DPI = 600

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

/** The first bytes of a base64 text (whole 4-char groups only). */
function decodeHead(b64: string, n: number): number[] {
  const out: number[] = []
  for (let i = 0; i + 3 < b64.length && out.length < n; i += 4) {
    const v = [0, 1, 2, 3].map(k => Math.max(0, B64.indexOf(b64[i + k] ?? 'A')))
    const x = (v[0]! << 18) | (v[1]! << 12) | (v[2]! << 6) | v[3]!
    out.push((x >> 16) & 255, (x >> 8) & 255, x & 255)
  }
  return out
}

/** The cells a PNG file takes, sized to its pixels; undefined if unreadable. */
async function sizeFor(
  $: EngineInterface,
  path: string,
  maxColumns: number,
  maxRows: number,
  kind: 'math' | 'picture' = 'picture',
): Promise<{ columns: number; rows: number } | undefined> {
  let size = pngSize.get(path)
  if (!size) {
    try {
      const { base64 } = await $.fs.read(path, { as: 'bytes' })
      const b = decodeHead(base64.slice(0, 32), 24)
      const u32 = (o: number) => ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0
      size = { w: u32(16), h: u32(20) }
      if (!size.w || !size.h) return undefined
      pngSize.set(path, size)
    } catch {
      return undefined
    }
  }
  let columns: number
  let rows: number
  if (kind === 'math') {
    const k = MATH_DPI / 150
    columns = Math.ceil(size.w / (CELL.w * MATH_SCALE * k))
    rows = Math.ceil(size.h / (CELL.h * MATH_SCALE * k))
  } else {
    columns = Math.min(maxColumns, Math.ceil(size.w / CELL.w))
    rows = Math.round((columns * CELL.w * size.h) / size.w / CELL.h)
  }
  if (columns > maxColumns) { rows = Math.ceil((rows * maxColumns) / columns); columns = maxColumns }
  if (rows > maxRows) { columns = Math.ceil((columns * maxRows) / rows); rows = maxRows }
  return { columns: Math.max(1, Math.min(255, columns)), rows: Math.max(1, Math.min(255, rows)) }
}
