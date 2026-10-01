import std/os

## Put `src` on the module path so extensions (in ../extensions) can
## `import wkbcore` by name.
switch("path", "src")

## uirelays is vendored in-tree (src/vendor/uirelays) -- patched for inline
## images and so releases build with no external UI dependency. This path makes
## `import uirelays`, `import uirelays/…`, and `import widgets/…` resolve to it.
switch("path", "src/vendor/uirelays")

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
## conformant OPC package (no python / shell `zip` needed). Also used by pixie
## (below) for PNG inflate, so there is a single zippy on the path.
switch("path", "src/vendor/zippy")

## pixie (pure-Nim 2D graphics) + its dependency tree, vendored in-tree so inline
## images (PNG/JPG/GIF/…) decode natively with NO ImageMagick shell-out -- the
## `convert`/`magick` approach failed on machines without ImageMagick. synedit's
## toLoadableBmp reads with pixie and writes a 24-bit BMP the drivers already
## decode. pixie reuses the vendored zippy above.
## NB: use a literal "/" here, not the `/` os-path operator -- under a cross
## target (`--os:windows`) that operator emits the target separator ("\"), which
## is not a valid path on the Linux build host, so pixie would fail to resolve.
for p in ["pixie", "chroma", "flatty", "nimsimd", "vmath", "bumpy", "crunchy"]:
  switch("path", "src/vendor/" & p)

## GTK4/libadwaita here come from a conda-forge env (this network's Zscaler
## proxy blocks gnu.org, which brew's from-source build of these needs --
## see DESIGN.md). Their dylibs use @rpath install names, so the binary
## needs this embedded or dyld can't find them at runtime.
let condaPrefix = getEnv("CONDA_PREFIX")
if condaPrefix.len > 0:
  switch("passL", "-Wl,-rpath," & condaPrefix / "lib")
