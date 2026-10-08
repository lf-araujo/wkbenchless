# wkbenchless.nimble

version       = "0.4.3"
author        = "Luis F. Araujo"
description   = "A native, deeply Nim-configurable literate editor: org-babel, LSP, interactive REPL sessions, org-src fontification -- a workbench-less alternative to heavier IDEs."
license       = "MIT"
srcDir        = "src"
bin           = @["wkbenchless"]   # `wkbenchless ctl <verb>` drives a running editor (no separate wkbctl)

requires "nim >= 2.0.0"
# uirelays is vendored in src/vendor/uirelays (patched for inline images), so
# there is no external UI dependency to fetch -- config.nims puts it on the path.

task run, "Build and run wkbenchless":
  exec "nim c -r -o:wkbenchless src/wkbenchless.nim"

task release, "Build an optimized, stripped single binary to share":
  # Runs standalone -- only needs system libX11/libXft at runtime, no compiler.
  putEnv("WKB_NO_USER_CONFIG", "1")   # ship the default config, not ~/.config's
  exec "nim c -d:release -d:danger --opt:size --passL:-s -o:wkbenchless src/wkbenchless.nim"

task bundle, "Bundle a self-contained toolchain (Nim + zig) so C-c r needs no system compiler":
  # Pass the zig path after `--`, e.g.  nimble bundle -- /opt/zig/zig
  let zig = if paramCount() >= 3: paramStr(paramCount()) else: ""
  exec "bash scripts/bundle-toolchain.sh " & zig

# -- "Text file busy" ----------------------------------------------------------
# Linux refuses to open a running executable for writing (ETXTBSY), and an
# editor is usually running while you reinstall it: from ~/.nimble/pkgs2 after
# `nimble install`, or from the repo's ./wkbenchless after C-c r. Before install,
# replace each such file by a fresh copy of itself (cp + rename): a running
# editor keeps its old inode, and the path now names a file nothing executes,
# which the build and nimble's copy can overwrite. Unlike moving the binary
# aside, nothing goes missing if nimble then skips the install as unchanged.
when hostOS == "linux":
  import std/os

  proc unbusy(f: string) =
    if fileExists(f):
      let tmp = f & ".unbusy"
      cpFile(f, tmp)
      exec "chmod +x \"" & tmp & "\""
      mvFile(tmp, f)

  before install:
    unbusy(thisDir() / "wkbenchless")
    let nimbleDir = if existsEnv("NIMBLE_DIR"): getEnv("NIMBLE_DIR")
                    else: getHomeDir() / ".nimble"
    let pkgs = nimbleDir / "pkgs2"
    if dirExists(pkgs):
      for d in listDirs(pkgs):
        if d.extractFilename.startsWith("wkbenchless-"):
          unbusy(d / "wkbenchless")

# The legacy GTK editor (src/nimacs.nim, owlkettle) is kept for history but is
# no longer built by default; wkbenchless supersedes it.

# -- macOS .app bundle -------------------------------------------------------
# A bare Mach-O has no bundle identity for macOS to attach a permission prompt
# to, so TCC silently denies access to File-Provider-backed folders (OneDrive,
# Dropbox, iCloud Drive) -- images and folder listings fail with no error.
# Wrapping the binary in a minimal .app fixes that: macOS can then show and
# remember the normal "wkbenchless would like to access files in..." prompt.
# Runs after every `nimble build`/`nimble install` (macOS only) so the bundle
# never goes stale; ad-hoc codesign is re-applied each time since any binary
# change invalidates the previous signature.
when hostOS == "macosx":
  import std/os

  proc macAppDir(): string = getHomeDir() / "Applications" / "wkbenchless.app"

  proc refreshMacApp() =
    let appDir = macAppDir()
    let macosDir = appDir / "Contents" / "MacOS"
    let built = thisDir() / "wkbenchless"
    if not fileExists(built):
      echo "wkbenchless binary not found at " & built & " -- skipping .app refresh"
      return
    mkDir(macosDir)
    mkDir(appDir / "Contents" / "Resources")
    writeFile(appDir / "Contents" / "Info.plist", """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>wkbenchless</string>
  <key>CFBundleDisplayName</key><string>wkbenchless</string>
  <key>CFBundleIdentifier</key><string>org.wkbenchless.editor</string>
  <key>CFBundleVersion</key><string>""" & version & """</string>
  <key>CFBundleShortVersionString</key><string>""" & version & """</string>
  <key>CFBundleExecutable</key><string>wkbenchless</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
</dict>
</plist>
""")
    cpFile(built, macosDir / "wkbenchless")
    exec "chmod +x \"" & (macosDir / "wkbenchless") & "\""
    exec "codesign --force -s - \"" & appDir & "\""
    echo "macOS app bundle refreshed: " & appDir

  after build:
    refreshMacApp()

  after install:
    refreshMacApp()
