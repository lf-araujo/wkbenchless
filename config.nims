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
     not defined(feature.uirelays.figDrawWindy) and not defined(figDrawWindy):
  when (NimMajor, NimMinor) >= (2, 4):
    switch("define", "feature.uirelays.figDrawSiwin")
    switch("define", "figdrawTextBackend=pixie")
  else:
    echo "wkbenchless: Nim " & NimVersion & " < 2.4 -- building the CPU X11 " &
         "driver; use Nim >= 2.4 for GPU rendering (or -d:wkbX11 to silence this)"

## nim-tuntox (the sibling checkout of github.com/lf-araujo/nim-tuntox) is the
## in-process Tox tunnel behind extensions/tox_collab.nim. A released build
## would `requires "nim-tuntox"` instead of this path. Its toxcore binding
## asks pkg-config for c-toxcore at compile time, so make the usual installs
## visible even when the shell that launched the editor didn't export
## PKG_CONFIG_PATH (C-c r's rebuild re-execs the compiler in-process).
## The checkout is found beside this one, or at $WKB_TUNTOX_DIR -- set that for
## `nimble install`, which builds in a copy under ~/.nimble/buildtemp where the
## sibling path does not exist.
let tuntoxDir =
  if getEnv("WKB_TUNTOX_DIR").len > 0: getEnv("WKB_TUNTOX_DIR")
  else: thisDir() & "/../nim-tuntox"
switch("path", tuntoxDir & "/src")
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
