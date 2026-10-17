## `wkbenchless install-desktop`: install the app icon (hicolor theme, every
## size + scalable SVG) and a .desktop launcher for the current user, so app
## menus and docks show wkbenchless with its icon. The icon files and the
## .desktop template are embedded at compile time from assets/, so this works
## however the binary was installed (nimble, a release download, a copy).
## `StartupWMClass=wkbenchless` matches the WM_CLASS the X11 driver sets from
## the program name, which is how a dock ties the running window to the entry.

import std/[os, osproc, strutils]

const
  assetsDir = currentSourcePath().parentDir / ".." / "assets"
  iconSizes = [16, 24, 32, 48, 64, 128, 256, 512]
  iconPngs = (proc (): seq[(int, string)] =
    for s in iconSizes:
      result.add (s, staticRead(assetsDir / "icon" / "png" / ("wkbenchless-" & $s & ".png"))))()
  iconSvg = staticRead(assetsDir / "icon" / "wkbenchless.svg")
  iconIcns = staticRead(assetsDir / "icon" / "wkbenchless.icns")
  desktopTemplate = """[Desktop Entry]
Type=Application
Name=wkbenchless
GenericName=Scientific Workbench
Comment=Literate scientific editor: org-babel, REPL sessions, inline figures, manuscript round-tripping
Exec=wkbenchless %F
Icon=wkbenchless
Terminal=false
Categories=Development;TextEditor;
MimeType=text/plain;text/x-org;
Keywords=org;babel;notebook;literate;editor;nim;
StartupWMClass=wkbenchless
"""

proc launcherExe(): string =
  ## A stable path for Exec=: the nimble shim when present (the real binary
  ## lives in a pkgs2 dir whose name changes with every version), else the
  ## first wkbenchless on PATH, else this binary.
  let shim = getHomeDir() / ".nimble" / "bin" / "wkbenchless"
  if fileExists(shim): return shim
  let onPath = findExe("wkbenchless")
  if onPath.len > 0: return onPath
  getAppFilename()

proc installDesktop*(): int =
  when defined(macosx):
    # The .app wrapper (built by the nimble hooks) takes its icon from
    # Contents/Resources/wkbenchless.icns. Run this BEFORE the bundle is
    # codesigned: changing a resource afterwards invalidates the signature.
    let res = getHomeDir() / "Applications" / "wkbenchless.app" / "Contents" / "Resources"
    try:
      createDir(res)
      writeFile(res / "wkbenchless.icns", iconIcns)
      echo "installed icon -> ", res / "wkbenchless.icns"
      return 0
    except CatchableError as e:
      echo "install-desktop failed: ", e.msg
      return 1
  elif not defined(linux):
    echo "install-desktop: nothing to install on this platform"
    return 1
  else:
    let share = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")
    let hicolor = share / "icons" / "hicolor"
    try:
      for (s, data) in iconPngs:
        let dir = hicolor / ($s & "x" & $s) / "apps"
        createDir(dir)
        writeFile(dir / "wkbenchless.png", data)
      createDir(hicolor / "scalable" / "apps")
      writeFile(hicolor / "scalable" / "apps" / "wkbenchless.svg", iconSvg)
      let apps = share / "applications"
      createDir(apps)
      let entry = apps / "wkbenchless.desktop"
      writeFile(entry, desktopTemplate.replace("Exec=wkbenchless %F",
                                               "Exec=" & launcherExe() & " %F"))
      # refresh the caches when the tools exist (harmless if they don't)
      if findExe("gtk-update-icon-cache").len > 0:
        discard execCmdEx("gtk-update-icon-cache -q -t " & quoteShell(hicolor))
      if findExe("update-desktop-database").len > 0:
        discard execCmdEx("update-desktop-database -q " & quoteShell(apps))
      echo "installed icon -> ", hicolor, "\ninstalled launcher -> ", entry
      0
    except CatchableError as e:
      echo "install-desktop failed: ", e.msg
      1
