## test_claude_mod -- the wkb-view Claude Code mod wkbenchless ships: the
## embedded files are written out whole (and left alone when unchanged, since
## Claude Code reloads a --plugin-dir mod on every change), and the claude
## command gets --plugin-dir (beside --settings) in every `||` segment.
##   nim c -r --hints:off src/test_claude_mod.nim
import std/[os, strutils, times]
import wkbcore

let tmp = getTempDir() / "wkb_test_claude_mod"
removeDir(tmp)
putEnv("XDG_CACHE_HOME", tmp)                 # getCacheDir() honours it on Linux
when defined(windows): putEnv("LOCALAPPDATA", tmp)

# -- the files are written out, identical to the repo's ------------------------
let dir = writeClaudeMod()
doAssert dir.len > 0 and dir == claudeModDir(), "mod not written: " & dir
const repo = currentSourcePath().parentDir & "/../claude-mod/wkb-view/"
for rel in [".claude-plugin/plugin.json", "hooks/hooks.json", "hooks/register.tsx",
            "types/index.d.ts", "README.md"]:
  doAssert fileExists(dir / rel), "missing " & rel
  doAssert readFile(dir / rel) == readFile(repo & rel), rel & " differs from the repo"
doAssert not fileExists(dir / "hooks" / "wkb-view.test.tsx"), "tests are not shipped"
echo "mod files written ok"

# -- an unchanged mod is not rewritten (no needless hot reload) ----------------
let before = getLastModificationTime(dir / "hooks" / "register.tsx")
os.sleep(1100)
doAssert writeClaudeMod() == dir
doAssert getLastModificationTime(dir / "hooks" / "register.tsx") == before,
  "an unchanged file was rewritten"
echo "unchanged mod left alone ok"

# -- the launch command ---------------------------------------------------------
let cmd = withClaudeFlag(withClaudeSettings("claude --continue || claude", "/s.json"),
                         "--plugin-dir " & quoteShell(dir))
doAssert cmd.count("--plugin-dir") == 2 and cmd.count("--settings") == 2, cmd
doAssert cmd.startsWith("claude --plugin-dir ") and " --continue || claude --plugin-dir " in cmd, cmd
echo "command ok: ", cmd

# -- the version gate ------------------------------------------------------------
if findExe("claude").len > 0:
  echo "claude supports mods: ", claudeSupportsMods()
removeDir(tmp)
echo "ALL OK"
