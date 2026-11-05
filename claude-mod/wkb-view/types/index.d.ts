/** One edit the Diffs pane can show: the file and its change as unified-diff hunks. */
export type EditDiff = {
  /** The tool_use_id of the Edit / Write / MultiEdit call. */
  id: string
  file: string
  /** Unified-diff hunks (`@@ -a,b +c,d @@` …); empty when nothing changed. */
  diff: string
  /** $.clock.now() when the edit finished. */
  at: number
}

declare module 'claude-code' {
  interface PluginState {
    'wkb-view': {
      /** The session's edits, newest last (at most 50). */
      edits: Shaped<EditDiff[]>
      /** Which edit the pane shows: an index into `edits`, -1 = the newest. */
      shown: Shaped<number>
    }
  }
}
