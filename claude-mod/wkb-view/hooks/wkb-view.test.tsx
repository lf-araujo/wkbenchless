import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const PANE = {
  plugin: 'wkb-view',
  component: 'Pane',
  requestId: 'wkb-diffs',
  props: {
    title: 'Diffs',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

/** Stands in for the engine beneath the mod: no files, no processes. */
function engine(on: On, readFile?: (path: string) => string) {
  on('command.register', () => ({ value: { command: 'diffs' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', () => ({
    value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  on('fs.exists', () => ({ value: false }))
  on('fs.read', (_, e) => {
    const path = (e as { path: string }).path
    if (readFile) return { value: readFile(path) }
    throw new Error('no such file: ' + path)
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
}

test('the Diffs pane starts empty, then shows an edit as a hunk', async ($, on) => {
  mock.env(on, { HOME: '/home/u' })
  mock.clock(on)
  let content = 'a\nb\nc\n'
  engine(on, () => content)
  on('tool.call', () => {
    content = 'a\nB\nc\n'
    return { result: {} }
  })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  let ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /No edits yet/ }))?.text).toBe('No edits yet in this session.')
  await ui.unmount()

  await $.tool.call({ tool: 'Edit', file_path: '/w/x.org', old_string: 'b', new_string: 'B' })
  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /1\/1/ }))?.text).toBe('1/1')
  const code = await ui.find({ type: 'Code' })
  expect(String(code?.props?.source)).toContain('-b\n+B')
  await ui.unmount()
})

const EDIT_RESULT = {
  plugin: 'wkb-view',
  component: 'ToolResult',
  requestId: 'toolu_1',
  props: { tool_use_id: 'toolu_1', tool: 'Edit', output: {}, isErrored: false },
} as const

test('inside wkbenchless an edit result collapses to one line', async ($, on) => {
  mock.env(on, { HOME: '/home/u', WKB_CTL_PORT: '41234' })
  mock.clock(on)
  engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ ...EDIT_RESULT, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /wkbenchless/ }))?.text).toContain('diff shown in wkbenchless')
  await ui.unmount()
})

test('outside wkbenchless the edit result is the engine\'s', async ($, on) => {
  mock.env(on, { HOME: '/home/u' })
  mock.clock(on)
  engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ ...EDIT_RESULT, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /engine/ }))?.text).toBe('engine')
  await ui.unmount()
})

test('display math stays text until its picture is ready', async ($, on) => {
  mock.env(on, { HOME: '/home/u' })
  mock.clock(on)
  engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({
    plugin: 'wkb-view',
    component: 'AssistantMessage',
    requestId: 'msg_1',
    surface: 'terminal',
    props: { text: 'Heritability:\n\n$$h^2 = \\frac{A}{P}$$\n\nDone.', isFirstOfReply: true },
  })
  const md = await ui.find({ type: 'Markdown', text: /frac/ })
  expect(String(md?.text)).toContain('$$h^2')
  expect((await ui.find({ type: 'Markdown', text: /Heritability/ }))?.text).toBe('Heritability:')
  await ui.unmount()
})
