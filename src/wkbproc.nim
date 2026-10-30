## Running external tools the same way on every platform. On POSIX,
## `execCmdEx` goes through /bin/sh, so a missing program is just exit code
## 127; on Windows it is CreateProcess, which raises instead -- so any optional
## tool (latex, Rscript, sqlite3, unzip, git, ...) absent from a Windows box
## took the editor down. `runCmd` gives the POSIX answer everywhere.

import std/osproc

proc runCmd*(cmd: string; workingDir = ""): tuple[output: string; exitCode: int] =
  ## `execCmdEx` (stderr merged into the output), but a program that cannot be
  ## started comes back as exit code 127 with the reason, never an exception.
  try: execCmdEx(cmd, workingDir = workingDir)
  except OSError as e: (e.msg, 127)
