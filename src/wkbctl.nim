## wkbctl -- drive a running wkbenchless over its control socket.
## For scripts/agents (e.g. Claude in the terminal) to drive the editor.
##
##   wkbctl buffer                        # print the current buffer
##   wkbctl blocks                        # list #+begin_src blocks (line: header)
##   wkbctl command <name>                # run a registered command
##   echo 'mean(1:10)' | wkbctl eval r default   # run code in a live session
##   echo TEXT | wkbctl set-buffer        # replace the whole buffer
##   echo TEXT | wkbctl insert <line>     # insert before 1-based <line>
##   echo TEXT | wkbctl replace <from> <to>   # replace 1-based lines [from..to]
##   wkbctl goto <line>                   # move the cursor
##   wkbctl run-block [line]              # run the src block at <line> (writes #+RESULTS)
##   wkbctl run-block <line> --async      # queue it; print the job id at once
##   wkbctl jobs | status <id> | wait <id>... | interrupt <id>   # async job control
##   wkbctl run-block <line> --deps       # after its stale :depends (make-style)
##   wkbctl run-block <line> --force      # ignore :cache
##   wkbctl run-stale                     # every stale block, top to bottom
##   wkbctl infer-deps                    # infer R :depends headers from the code
##   wkbctl diff <oldfile> <newfile> [title]  # show a side-by-side diff
##
## This is optional: the editor binary embeds the same client, so
## `wkbenchless ctl <verb...>` does exactly the same thing (and a symlink named
## `wkbctl` pointing at `wkbenchless` also works).

import std/os
import wkbctlclient

quit(ctlClient(commandLineParams()))
