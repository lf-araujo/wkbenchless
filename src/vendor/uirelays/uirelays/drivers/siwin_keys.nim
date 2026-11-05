## Shared key/modifier translation for Siwin window drivers.
import siwin
import ../input

proc translateMods*(mods: set[siwin.ModifierKey]): set[input.Modifier] =
  if siwin.ModifierKey.shift in mods:
    result.incl ShiftPressed
  if siwin.ModifierKey.control in mods:
    result.incl CtrlPressed
  if siwin.ModifierKey.alt in mods:
    result.incl AltPressed
  if siwin.ModifierKey.system in mods:
    result.incl GuiPressed

proc translateKey*(k: siwin.Key): input.KeyCode =
  case k
  of siwin.Key.a: KeyA
  of siwin.Key.b: KeyB
  of siwin.Key.c: KeyC
  of siwin.Key.d: KeyD
  of siwin.Key.e: KeyE
  of siwin.Key.f: KeyF
  of siwin.Key.g: KeyG
  of siwin.Key.h: KeyH
  of siwin.Key.i: KeyI
  of siwin.Key.j: KeyJ
  of siwin.Key.k: KeyK
  of siwin.Key.l: KeyL
  of siwin.Key.m: KeyM
  of siwin.Key.n: KeyN
  of siwin.Key.o: KeyO
  of siwin.Key.p: KeyP
  of siwin.Key.q: KeyQ
  of siwin.Key.r: KeyR
  of siwin.Key.s: KeyS
  of siwin.Key.t: KeyT
  of siwin.Key.u: KeyU
  of siwin.Key.v: KeyV
  of siwin.Key.w: KeyW
  of siwin.Key.x: KeyX
  of siwin.Key.y: KeyY
  of siwin.Key.z: KeyZ
  of siwin.Key.n0: Key0
  of siwin.Key.n1: Key1
  of siwin.Key.n2: Key2
  of siwin.Key.n3: Key3
  of siwin.Key.n4: Key4
  of siwin.Key.n5: Key5
  of siwin.Key.n6: Key6
  of siwin.Key.n7: Key7
  of siwin.Key.n8: Key8
  of siwin.Key.n9: Key9
  of siwin.Key.f1: KeyF1
  of siwin.Key.f2: KeyF2
  of siwin.Key.f3: KeyF3
  of siwin.Key.f4: KeyF4
  of siwin.Key.f5: KeyF5
  of siwin.Key.f6: KeyF6
  of siwin.Key.f7: KeyF7
  of siwin.Key.f8: KeyF8
  of siwin.Key.f9: KeyF9
  of siwin.Key.f10: KeyF10
  of siwin.Key.f11: KeyF11
  of siwin.Key.f12: KeyF12
  of siwin.Key.enter: KeyEnter
  of siwin.Key.space: KeySpace
  of siwin.Key.escape: KeyEsc
  of siwin.Key.tab: KeyTab
  of siwin.Key.backspace: KeyBackspace
  of siwin.Key.del: KeyDelete
  of siwin.Key.insert: KeyInsert
  of siwin.Key.left: KeyLeft
  of siwin.Key.right: KeyRight
  of siwin.Key.up: KeyUp
  of siwin.Key.down: KeyDown
  of siwin.Key.pageUp: KeyPageUp
  of siwin.Key.pageDown: KeyPageDown
  of siwin.Key.home: KeyHome
  of siwin.Key.End: KeyEnd
  of siwin.Key.capsLock: KeyCapslock
  of siwin.Key.comma: KeyComma
  of siwin.Key.dot: KeyPeriod
  else: KeyNone

proc translateButton*(btn: siwin.MouseButton): input.MouseButton =
  case btn
  of siwin.MouseButton.left: LeftButton
  of siwin.MouseButton.right: RightButton
  of siwin.MouseButton.middle: MiddleButton
  else: LeftButton
