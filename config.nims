import std/os

## Put `src` on the module path so extensions (in ../extensions) can
## `import wkbcore` by name.
switch("path", "src")

## uirelays is vendored in-tree (src/vendor/uirelays) -- patched for inline
## images and so releases build with no external UI dependency. This path makes
## `import uirelays`, `import uirelays/…`, and `import widgets/…` resolve to it.
switch("path", "src/vendor/uirelays")

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
