## Offline checks for the tmux control-mode adapter (no tmux or host needed).
include wkbpty
import wkbsession

# -- input: text -> send-keys commands --------------------------------------
doAssert tmuxKeys("T", "a'b\n\x03") ==
  "send-keys -t T -l -- 'a'\"'\"'b'\nsend-keys -t T Enter\nsend-keys -t T C-c\n"
doAssert tmuxKeys("T", "x;y #z $HOME\tq") ==
  "send-keys -t T -l -- 'x;y #z $HOME\tq'\n"          # all literal inside '...'
# the session pane's keyboard speaks terminal bytes
doAssert tmuxKeys("T", "ab\b\x7fc\r") ==
  "send-keys -t T -l -- 'ab'\nsend-keys -t T BSpace\nsend-keys -t T BSpace\n" &
  "send-keys -t T -l -- 'c'\nsend-keys -t T Enter\n"
doAssert tmuxKeys("T", "x\r\ny\n").count("Enter") == 2          # \r\n is ONE Enter
doAssert tmuxKeys("T", "\e[A\e[B\e[C\e[D\e") ==
  "send-keys -t T Up\nsend-keys -t T Down\nsend-keys -t T Right\nsend-keys -t T Left\n" &
  "send-keys -t T Escape\n"
doAssert tmuxKeys("T", "\e[200~p(1)\e[201~") == "send-keys -t T -l -- 'p(1)'\n"
let long = tmuxKeys("T", "é" & repeat('a', 1100) & "\n")
for ln in long.splitLines():
  doAssert ln.len < 1100, "runs must be split"
doAssert long.count("Enter") == 1

# -- output: control-mode lines -> pane bytes, across arbitrary chunk splits --
let transcript = "noise\r\nWKBxTMUXNEW\r\n" & ctlDcs &
  "%begin 1 2 0\r\n%end 1 2 0\r\n%window-add @2\r\n" &
  "%output %2 hello\\015\\012wor\r\n%output %2 ld\\134x\\033[0m!\r\n%exit\r\n"
for cut in 1 ..< transcript.len:
  var p = notRunningPty()
  p.tmuxTarget = "T"
  ctlTranslate(p, transcript[0 ..< cut].toOpenArray(0, cut - 1))
  ctlTranslate(p, transcript[cut .. ^1].toOpenArray(0, transcript.len - cut - 1))
  doAssert p.ctlActive
  doAssert p.ctlOut == "noise\r\nWKBxTMUXNEW\r\nhello\r\nworld\\x\e[0m!", $cut & ": " & p.ctlOut

# -- feeds before control mode starts are queued, not lost --------------------
var q = notRunningPty()
q.tmuxTarget = "T"
q.feed("ls\n")
q.tmuxCommand("refresh-client -C 250,50")
doAssert not q.ctlActive and "send-keys -t T -l -- 'ls'" in q.ctlPreIn and
         "refresh-client" in q.ctlPreIn

# -- staging: every typed line fits R's 4096-byte console limit --------------
var bytes = newSeq[byte](5000)
for i in 0 ..< bytes.len: bytes[i] = byte(i mod 256)
for spec in [rSpec, pySpec, bashSpec]:
  let code = spec.writeBytesCode(bytes, ".wkbenchless-run/x.src", "WKBSTAGEN7")
  for ln in code.splitLines(): doAssert ln.len < 4000, $ln.len
  doAssert "WKBSTAGEN7" notin code, "marker must be split in the typed source"
echo "tmux adapter ok"
