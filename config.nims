import std/[os, strutils]

## Put `src` on the module path so extensions (in ../extensions) can
## `import wkbcore` by name.
switch("path", "src")

## uirelays is vendored in-tree (src/vendor/uirelays) -- patched for inline
## images and so releases build with no external UI dependency. This path makes
## `import uirelays`, `import uirelays/…`, and `import widgets/…` resolve to it.
switch("path", "src/vendor/uirelays")

## Linux renders on the GPU by default: FigDraw (OpenGL) drawing into a siwin
## window -- native Wayland on a Wayland session, X11 otherwise -- with text
## through pixie, so no HarfBuzz library is needed at runtime. Needs
## `nimble install figdraw siwin`, and Nim >= 2.4: 2.2.x rejects siwin's
## exception effects. With an older Nim, or `-d:wkbX11`, the build uses the CPU
## X11 + Xft driver instead (also the fallback if the GPU build misbehaves).
## macOS and Windows keep their native drivers.
when defined(linux) and not defined(wkbX11) and
     not defined(features.uirelays.figDrawWindy) and not defined(figDrawWindy):
  when (NimMajor, NimMinor) >= (2, 4):
    switch("define", "features.uirelays.figDrawSiwinGpu")
    switch("define", "figdrawTextBackend=pixie")
  else:
    echo "wkbenchless: Nim " & NimVersion & " < 2.4 -- building the CPU X11 " &
         "driver; use Nim >= 2.4 for GPU rendering (or -d:wkbX11 to silence this)"

## Matter (TextMate grammars, pure Nim) highlights R blocks; see src/wkbmatter.nim.
## `-d:wkbNoMatter` leaves SynEdit's own tokenizers.
when not defined(wkbNoMatter):
  switch("define", "wkbMatter")

## nim-tuntox (the sibling checkout of github.com/lf-araujo/nim-tuntox) is the
## in-process Tox tunnel behind extensions/tox_collab.nim. A released build
## would `requires "nim-tuntox"` instead of this path. Its toxcore binding
## asks pkg-config for c-toxcore at compile time, so make the usual installs
## visible even when the shell that launched the editor didn't export
## PKG_CONFIG_PATH (C-c r's rebuild re-execs the compiler in-process).
## The checkout is found at $WKB_TUNTOX_DIR, beside this one, or as an
## installed nimble package (`nimble install` in nim-tuntox -> ~/.nimble/pkgs2/
## tuntox-*). The last one is what keeps the tunnel in builds that run away from
## the source tree: `nimble install` (a copy under ~/.nimble/buildtemp) and C-c r
## rebuilding a nimble-installed editor in its pkgs2 dir.
proc tuntoxSrc(dir: string): string =
  ## The dir holding tuntox.nim for a checkout (src/) or an installed package.
  if fileExists(dir & "/src/tuntox.nim"): dir & "/src"
  elif fileExists(dir & "/tuntox.nim"): dir
  else: ""
let tuntoxDir = block:
  var found = ""
  if getEnv("WKB_TUNTOX_DIR").len > 0: found = getEnv("WKB_TUNTOX_DIR")
  elif tuntoxSrc(thisDir() & "/../nim-tuntox").len > 0:
    found = thisDir() & "/../nim-tuntox"
  else:
    let nimbleDir = if getEnv("NIMBLE_DIR").len > 0: getEnv("NIMBLE_DIR")
                    else: getHomeDir() & ".nimble"
    # several installs (each `nimble install` of a changed checkout adds a
    # new tuntox-<ver>-<hash> dir): take the most recently installed one
    var newest = ""
    for d in listDirs(nimbleDir & "/pkgs2"):
      if d.extractFilename.startsWith("tuntox-") and tuntoxSrc(d).len > 0:
        let stamp = gorge("stat -f %m " & quoteShell(d) & " 2>/dev/null || stat -c %Y " &
                          quoteShell(d))
        if newest.len == 0 or stamp.strip.parseInt > newest.parseInt:
          newest = stamp.strip; found = d
  if found.len == 0: found = thisDir() & "/../nim-tuntox"   # for the error text
  found
let tuntoxPath = tuntoxSrc(tuntoxDir)
if tuntoxPath.len > 0: switch("path", tuntoxPath)
block:
  if getEnv("PKG_CONFIG_PATH").len == 0:
    for pc in [getHomeDir() & ".local/lib64/pkgconfig",
               getHomeDir() & ".local/lib/pkgconfig",
               tuntoxDir & "/vendor/lib64/pkgconfig"]:
      # skip a .pc whose prefix is not on this machine (the vendored
      # toxcore is a Linux build; on macOS brew's pkg-config finds toxcore)
      let tox = pc & "/toxcore.pc"
      if fileExists(tox):
        var prefix = ""
        for line in readFile(tox).splitLines:
          if line.startsWith("prefix="): prefix = line[7 .. ^1]
        if prefix.len > 0 and not dirExists(prefix): continue
      if dirExists(pc):
        putEnv("PKG_CONFIG_PATH", pc)
        break
## The Tox tunnel is built (`wkbTox`) when nim-tuntox AND a pkg-config-visible
## toxcore are both here; without them collab is LAN / host:port only
## (src/wkbtox.nim). CI and release.yml provide both (scripts/build-toxcore.sh)
## and set WKB_REQUIRE_TOX=1, so a build that lost the tunnel fails instead of
## shipping without it. On macOS the tunnel is required by default (brew
## install toxcore pkg-config; nimble install in nim-tuntox). -d:wkbNoTox
## leaves it out on any platform.
when not defined(wkbNoTox):
  if tuntoxPath.len > 0 and
     gorgeEx("pkg-config --exists toxcore").exitCode == 0:
    switch("define", "wkbTox")
  elif defined(macosx) or getEnv("WKB_REQUIRE_TOX") == "1":
    raise newException(OSError, "the Tox tunnel is required on this build " &
      "but unavailable: need nim-tuntox (at " & tuntoxDir & ", $WKB_TUNTOX_DIR, " &
      "or `nimble install` it) and toxcore via pkg-config (PKG_CONFIG_PATH=" &
      getEnv("PKG_CONFIG_PATH") & "). Build with -d:wkbNoTox to leave it out.")

## User config: ~/.config/wkbenchless/wkbconfig.nim (XDG_CONFIG_HOME, or
## %APPDATA% on Windows) is compiled in place of src/wkbconfig.nim when it exists,
## so a nimble-installed build can be configured without touching its package
## dir. M-x edit-config (C-c f) seeds it from the default; C-c r rebuilds with it.
## WKB_USER_CONFIG=<file> overrides the location; WKB_NO_USER_CONFIG=1 skips it
## (`nimble release` sets that, so a shared binary carries the default config).
block:
  var userCfg = getEnv("WKB_USER_CONFIG")
  if userCfg.len == 0:
    let base =
      if defined(windows): getEnv("APPDATA")
      elif getEnv("XDG_CONFIG_HOME").len > 0: getEnv("XDG_CONFIG_HOME")
      else: getEnv("HOME") & "/.config"
    if base.len > 0: userCfg = base & "/wkbenchless/wkbconfig.nim"
  if getEnv("WKB_NO_USER_CONFIG").len == 0 and userCfg.len > 0 and fileExists(userCfg):
    switch("define", "wkbUserConfig=" & userCfg)

## zippy (pure-Nim zip, dependency-free) vendored in-tree -- the org-tracked
## extension uses it to embed the canonical .org into the exported .docx as a
## conformant OPC package (no python / shell `zip` needed). Carries one local
## patch (write a classic non-ZIP64 archive when it fits -- pandoc cannot
## re-import ZIP64 docx); offered upstream as treeform/zippy#3 -- drop the
## vendored copy once that merges and a release carries it.
switch("path", "src/vendor/zippy")

## pixie (pure-Nim 2D graphics) is a nimble dependency ("pixie == 6.1.0" in
## wkbenchless.nimble), fetched with `nimble install` -- it was vendored only
## to be self-contained and was never edited locally. synedit's toLoadableBmp
## reads with pixie and writes a 24-bit BMP the drivers already decode (no
## ImageMagick shell-out). Nimble's pkgs dir goes on the path so plain `nim c`
## (and C-c r's rebuild, which does not go through nimble) still resolve pixie
## after one `nimble install`; a toolchain bundled by `nimble bundle` carries
## its own copy under toolchain/nim-pkgs (scripts/bundle-toolchain.sh).
## NB: use a literal "/" here, not the `/` os-path operator -- under a cross
## target (`--os:windows`) that operator emits the target separator ("\"), which
## is not a valid path on the Linux build host, so pixie would fail to resolve.
for pkgsDir in [getHomeDir() & ".nimble/pkgs2", getHomeDir() & ".nimble/pkgs",
                getCurrentDir() & "/toolchain/nim-pkgs"]:
  if dirExists(pkgsDir): switch("path", pkgsDir)

## GTK4/libadwaita here come from a conda-forge env (this network's Zscaler
## proxy blocks gnu.org, which brew's from-source build of these needs --
## see DESIGN.md). Their dylibs use @rpath install names, so the binary
## needs this embedded or dyld can't find them at runtime.
let condaPrefix = getEnv("CONDA_PREFIX")
if condaPrefix.len > 0:
  switch("passL", "-Wl,-rpath," & condaPrefix / "lib")
