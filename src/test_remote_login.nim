## remote-login lists the hosts of open remote sessions and ~/.ssh/config's
## hosts, and still takes a typed address: the typed text is the last entry whenever it is not a candidate.
import wkbcore
import std/[os, tables]

let dir = getTempDir() / "wkb-test-remote-login"
createDir(dir)
let sshCfg = dir / "config"
writeFile(sshCfg, """Host group.vipbg.vcu.edu
  HostName group.vipbg.vcu.edu
  User ldearaujo
Host light *.wild !neg
Host=eq.example
""")
doAssert sshConfigHosts(sshCfg) == @["group.vipbg.vcu.edu", "light", "eq.example"]
doAssert sshConfigHosts(dir / "missing").len == 0

var app: App
app.termActive = -1
app.ed.setText("")
app.sessions["r/default@group.vipbg.vcu.edu|workq"] = nil   # an open remote session
let ch = remoteHostChoices(app)
doAssert ch.len >= 1 and ch[0].id == "group.vipbg.vcu.edu", $ch   # method stripped
for c in ch: doAssert '|' notin c.id

# The palette: every candidate with an empty query; filtering by label; the
# typed text appended unless it is a candidate id.
openPalette(app, pmPrompt)
doAssert gPromptChoices.len == 0                 # openPalette clears them
gPromptChoices = @[("group.vipbg.vcu.edu", "group.vipbg.vcu.edu"),
                   ("light.vipbg.vcu.edu", "light.vipbg.vcu.edu"),
                   ("light", "light")]
doAssert paletteEntries(app).len == 3
app.paletteQuery = "lig"
var e = paletteEntries(app)
doAssert e.len == 3 and e[0].id == "light.vipbg.vcu.edu" and e[2].id == "lig", $e
app.paletteQuery = "luis@other.host"
e = paletteEntries(app)
doAssert e.len == 1 and e[0].id == "luis@other.host"
app.paletteQuery = "light"
e = paletteEntries(app)
doAssert e.len == 2 and e[0].id == "light", $e   # exact match first, no typed duplicate
# A prompt without candidates (e.g. tox's) still lists nothing.
gPromptChoices = @[]
doAssert paletteEntries(app).len == 0

removeDir(dir)
echo "remote login ok"
