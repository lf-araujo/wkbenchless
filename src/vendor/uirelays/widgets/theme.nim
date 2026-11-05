## Theme -- color theme for uirelays.
##
## Since everything is text (SynEdit), there is one theme type.

import uirelays/screen

type
  TokenClass* {.pure.} = enum
    None, Whitespace, DecNumber, BinNumber, HexNumber,
    OctNumber, FloatNumber, Identifier, Keyword,
    StringLit, LongStringLit, CharLit, Backticks,
    EscapeSequence,
    Operator, Punctuation, Comment, LongComment, RegularExpression,
    TagStart, TagStandalone, TagEnd, Key, Value, RawData, Assembler,
    Preprocessor, Directive, Command, Rule, Link, Label,
    Reference, Text, Other, Green, Yellow, Red,
    MarkdownFence,
    # The sixteen a terminal has. `Green`, `Yellow` and `Red` above are three
    # of them: the console highlighter already guesses those from the shape of
    # a line, and a program that asks for them by name must not come out in a
    # different shade than a `+` line does. The rest are new, and a theme is
    # expected to answer for all sixteen -- ANSI black is not black here, it
    # is whatever this theme's dimmest legible foreground is.
    Black, Blue, Magenta, Cyan, White,
    BrightBlack, BrightRed, BrightGreen, BrightYellow,
    BrightBlue, BrightMagenta, BrightCyan, BrightWhite

  Theme* = object
    fg*: array[TokenClass, Color]   ## per-token foreground colors
    style*: array[TokenClass, FontStyles]
      ## per-token bold and italics, `{}` for the upright regular face. A
      ## color says what a token *is*, a style how much it wants to be read:
      ## comments in italics step back, a keyword in bold steps forward. Both
      ## are wishes -- a font without the face draws upright, so nothing here
      ## can make text disappear, and none of it changes the layout: the faces
      ## of a monospaced family share its advance width.
    bg*: Color                      ## editor background
    panelBg*: Color                 ## background of the panels around it --
      ## tab list, explorer, terminal, status bar. A step away from `bg` is
      ## enough: it is what makes the window read as a text surface with tools
      ## around it rather than as one undivided field of color.
    selBg*: Color                   ## selection background
    bracketBg*: Color               ## bracket match background
    cursorColor*: Color             ## cursor bar color
    lineNumColor*: Color            ## line number foreground
    markerBg*: Color                ## default marker highlight background
    scrollBarColor*: Color          ## scrollbar grip
    scrollBarActiveColor*: Color    ## scrollbar grip while dragging
    scrollTrackColor*: Color        ## scrollbar track background
    activeLineBg*: Color            ## background of the current/active line
    actionColor*: Color             ## frame around a line that acts on click
    closeColor*: Color              ## the (x) button of such a line
    focusColor*: Color              ## frame around the panel that has the
                                    ## keyboard focus

# ---------------------------------------------------------------------------
# Readability. A theme is only worth having if its text can be seen, so the
# contrast between what is drawn and what it is drawn on can be measured.
# ---------------------------------------------------------------------------

const MinContrast* = 300
  ## The lowest contrast ratio -- times 100, so 3.0:1 -- that still counts as
  ## readable. WCAG asks 4.5:1 for body text, but `goldenDusk` draws its
  ## comments at 4.4:1 and `catppuccinMocha` at 3.8:1, so both would fail their
  ## own test; dim comments are a deliberate and widespread choice, not a
  ## mistake. 3.0 is WCAG's bar for large text and interface parts, and it
  ## still catches everything that genuinely cannot be read.

proc luminance(c: Color): int =
  ## Relative luminance, 0 .. 10000. Squaring the channels stands in for the
  ## sRGB transfer function: it needs no floating point and lands close enough
  ## -- black on white comes out at 21.00:1, which is the textbook value.
  ## Alpha is ignored; theme colors are opaque.
  let r = int(c.r)
  let g = int(c.g)
  let b = int(c.b)
  result = (2126 * r * r + 7152 * g * g + 722 * b * b) div 65025

proc contrast*(a, b: Color): int =
  ## The contrast ratio between two colors, times 100: 450 means 4.5:1.
  ## The order does not matter. 100 is the lowest possible value, 2100 the
  ## highest.
  let la = luminance(a)
  let lb = luminance(b)
  let hi = max(la, lb)
  let lo = min(la, lb)
  result = ((hi + 500) * 100) div (lo + 500)

proc ratioText*(contrast100: int): string =
  ## A contrast ratio as "3.8:1".
  result = $(contrast100 div 100) & "." & $((contrast100 mod 100) div 10) & ":1"

proc contrastProblem*(t: Theme): string =
  ## "" when everything this theme draws *on* its background can be told apart
  ## from it; otherwise the first color that cannot, phrased for a message.
  ##
  ## Only foregrounds are checked. `selBg`, `activeLineBg`, `markerBg` and
  ## `bracketBg` sit *behind* text and are meant to stay close to `bg`, and
  ## the scrollbar and `actionColor` are hints rather than text -- the default
  ## theme draws its action frame at 1.9:1 on purpose.
  for tc in low(TokenClass)..high(TokenClass):
    let c = contrast(t.fg[tc], t.bg)
    if c < MinContrast:
      return $tc & " text is " & ratioText(c) & " against the background"
  let named = [("the cursor", t.cursorColor),
               ("the line numbers", t.lineNumColor),
               ("the (x) button", t.closeColor)]
  for i in 0 ..< named.len:
    let c = contrast(named[i][1], t.bg)
    if c < MinContrast:
      return named[i][0] & " is " & ratioText(c) & " against the background"
  # The panels carry the same text on a background of their own, so `panelBg`
  # is checked the same way -- against the base color, which is what a panel
  # draws most of.
  let c = contrast(t.fg[TokenClass.None], t.panelBg)
  if c < MinContrast:
    return "panel text is " & ratioText(c) & " against the panel background"
  result = ""

proc catppuccinMocha*(): Theme =
  result = default(Theme)
  let fg = color(205, 214, 244)
  for tc in low(TokenClass)..high(TokenClass):
    result.fg[tc] = fg
  result.fg[TokenClass.Keyword] = color(203, 166, 247)     # mauve
  result.fg[TokenClass.StringLit] = color(166, 227, 161)   # green
  result.fg[TokenClass.LongStringLit] = color(166, 227, 161)
  result.fg[TokenClass.CharLit] = color(166, 227, 161)
  result.fg[TokenClass.RawData] = color(166, 227, 161)
  result.fg[TokenClass.Comment] = color(108, 112, 134)     # overlay0
  result.fg[TokenClass.LongComment] = color(108, 112, 134)
  result.fg[TokenClass.DecNumber] = color(250, 179, 135)   # peach
  result.fg[TokenClass.BinNumber] = color(250, 179, 135)
  result.fg[TokenClass.HexNumber] = color(250, 179, 135)
  result.fg[TokenClass.OctNumber] = color(250, 179, 135)
  result.fg[TokenClass.FloatNumber] = color(250, 179, 135)
  result.fg[TokenClass.Operator] = color(137, 180, 250)    # blue
  result.fg[TokenClass.Punctuation] = color(147, 153, 178) # subtext0
  result.fg[TokenClass.EscapeSequence] = color(245, 194, 231) # pink
  result.fg[TokenClass.Preprocessor] = color(203, 166, 247)
  result.fg[TokenClass.Identifier] = fg
  result.fg[TokenClass.Green] = color(166, 227, 161)
  result.fg[TokenClass.Yellow] = color(249, 226, 175)
  result.fg[TokenClass.Red] = color(243, 139, 168)
  result.fg[TokenClass.MarkdownFence] = color(128, 128, 128)
  result.fg[TokenClass.Link] = color(137, 180, 250)       # blue
  # The sixteen. Catppuccin names its own ANSI set; the two darkest of them
  # are lifted to `overlay1`/`overlay2` because a foreground has to be legible
  # against `base`, and surface grey is not.
  result.fg[TokenClass.Black] = color(127, 132, 156)       # overlay1
  result.fg[TokenClass.Blue] = color(137, 180, 250)
  result.fg[TokenClass.Magenta] = color(245, 194, 231)     # pink
  result.fg[TokenClass.Cyan] = color(148, 226, 213)        # teal
  result.fg[TokenClass.White] = color(186, 194, 222)       # subtext1
  result.fg[TokenClass.BrightBlack] = color(147, 153, 178) # overlay2
  result.fg[TokenClass.BrightRed] = color(235, 160, 172)   # maroon
  result.fg[TokenClass.BrightGreen] = color(183, 232, 179)
  result.fg[TokenClass.BrightYellow] = color(250, 234, 196)
  result.fg[TokenClass.BrightBlue] = color(160, 195, 251)
  result.fg[TokenClass.BrightMagenta] = color(248, 210, 238)
  result.fg[TokenClass.BrightCyan] = color(172, 233, 223)
  result.fg[TokenClass.BrightWhite] = color(230, 238, 255) # above the text
  result.bg = color(30, 30, 46)
  result.panelBg = color(24, 24, 37)             # crust, a step below the base
  result.selBg = color(88, 91, 112)
  result.bracketBg = color(69, 71, 90)
  result.cursorColor = color(205, 214, 244)
  result.lineNumColor = color(108, 112, 134)
  result.markerBg = color(62, 68, 43)            # muted olive for search hits
  result.scrollBarColor = color(69, 71, 90)
  result.scrollBarActiveColor = color(108, 112, 134)
  result.scrollTrackColor = color(36, 36, 54)
  result.activeLineBg = color(69, 71, 90)        # surface1
  result.actionColor = color(88, 91, 112)        # surface2
  result.closeColor = color(147, 153, 178)       # subtext0
  result.focusColor = color(203, 166, 247)       # mauve, as the keywords

proc goldenDusk*(): Theme =
  ## Dark, in gold, orange and turquoise. Written in hex, the way a config file
  ## spells a color, so values can be copied straight between the two.
  let
    text        = color(0xE6, 0xDF, 0xD1)  # warm off-white
    gold        = color(0xE5, 0xB9, 0x4E)
    deepGold    = color(0xC9, 0xA2, 0x27)
    orange      = color(0xE8, 0x83, 0x3A)
    lightOrange = color(0xF2, 0xA6, 0x5A)
    turquoise   = color(0x2E, 0xC4, 0xB6)
    deepTurq    = color(0x1F, 0xA3, 0x98)
    brightTurq  = color(0x4F, 0xD1, 0xC5)
    muted       = color(0x8C, 0x85, 0x78)  # warm grey, for punctuation
    dim         = color(0x7A, 0x73, 0x65)  # dimmer still, for comments

  result = default(Theme)
  for tc in low(TokenClass)..high(TokenClass):
    result.fg[tc] = text

  result.fg[TokenClass.Keyword] = gold
  result.fg[TokenClass.Identifier] = text
  # The two the shipped config has always asked for, here as well: the config
  # file is written *from* this theme, so anything the object does not say is
  # a thing the file cannot say either.
  result.style[TokenClass.Keyword] = {FontStyle.bold}
  result.style[TokenClass.Comment] = {FontStyle.italics}
  result.style[TokenClass.LongComment] = {FontStyle.italics}
  result.fg[TokenClass.Operator] = deepGold
  result.fg[TokenClass.Punctuation] = muted
  result.fg[TokenClass.Comment] = dim
  result.fg[TokenClass.LongComment] = dim
  result.fg[TokenClass.MarkdownFence] = dim
  # Strings and everything string-shaped: turquoise.
  result.fg[TokenClass.StringLit] = turquoise
  result.fg[TokenClass.LongStringLit] = turquoise
  result.fg[TokenClass.CharLit] = turquoise
  result.fg[TokenClass.RawData] = turquoise
  result.fg[TokenClass.Backticks] = turquoise
  result.fg[TokenClass.Key] = turquoise
  result.fg[TokenClass.Link] = brightTurq
  result.fg[TokenClass.Rule] = deepTurq
  result.fg[TokenClass.Preprocessor] = deepTurq
  result.fg[TokenClass.Directive] = deepTurq
  # Numbers and everything that stands out on its own: orange.
  result.fg[TokenClass.DecNumber] = orange
  result.fg[TokenClass.BinNumber] = orange
  result.fg[TokenClass.HexNumber] = orange
  result.fg[TokenClass.OctNumber] = orange
  result.fg[TokenClass.FloatNumber] = orange
  result.fg[TokenClass.RegularExpression] = orange
  result.fg[TokenClass.Value] = orange
  result.fg[TokenClass.Label] = orange
  result.fg[TokenClass.Reference] = orange
  result.fg[TokenClass.EscapeSequence] = lightOrange
  # Markup and assembler read as keywords.
  result.fg[TokenClass.TagStart] = gold
  result.fg[TokenClass.TagStandalone] = gold
  result.fg[TokenClass.TagEnd] = gold
  result.fg[TokenClass.Assembler] = gold
  result.fg[TokenClass.Command] = gold
  # The three named colors keep their meaning; only the shade is ours.
  result.fg[TokenClass.Green] = color(0x4F, 0xBF, 0x9F)
  result.fg[TokenClass.Yellow] = gold
  result.fg[TokenClass.Red] = color(0xE4, 0x63, 0x4A)
  # And the sixteen a terminal has, in this theme's own gold and turquoise
  # rather than in the primaries -- a program that asks for blue gets the cool
  # accent here, because that is what blue is on this background.
  result.fg[TokenClass.Black] = dim
  result.fg[TokenClass.Blue] = turquoise
  result.fg[TokenClass.Magenta] = color(0xD8, 0x8A, 0xA8)  # dusty rose
  result.fg[TokenClass.Cyan] = brightTurq
  result.fg[TokenClass.White] = text
  result.fg[TokenClass.BrightBlack] = muted
  result.fg[TokenClass.BrightRed] = color(0xF2, 0x86, 0x70)
  result.fg[TokenClass.BrightGreen] = color(0x6F, 0xD9, 0xBB)
  result.fg[TokenClass.BrightYellow] = color(0xF2, 0xCE, 0x7A)
  result.fg[TokenClass.BrightBlue] = brightTurq
  result.fg[TokenClass.BrightMagenta] = color(0xE8, 0xA6, 0xC0)
  result.fg[TokenClass.BrightCyan] = color(0x7A, 0xE0, 0xD6)
  result.fg[TokenClass.BrightWhite] = color(0xFF, 0xF8, 0xEA)

  result.bg = color(0x15, 0x17, 0x1B)
  result.panelBg = color(0x11, 0x13, 0x16)       # a step below the editor
  result.selBg = color(0x35, 0x47, 0x4B)         # turquoise-tinted slate
  result.bracketBg = color(0x3E, 0x3A, 0x2C)     # gold-tinted, to match
  result.cursorColor = gold
  result.lineNumColor = color(0x6E, 0x67, 0x58)
  result.markerBg = color(0x4A, 0x3B, 0x14)      # dark gold for search hits
  result.scrollBarColor = color(0x33, 0x38, 0x3C)
  result.scrollBarActiveColor = color(0x4A, 0x52, 0x57)
  result.scrollTrackColor = color(0x1B, 0x1E, 0x22)
  result.activeLineBg = color(0x24, 0x27, 0x2C)  # a step below the selection
  result.actionColor = color(0x3A, 0x41, 0x45)
  result.closeColor = color(0xC0, 0x8A, 0x4A)    # gold, dimmed
  result.focusColor = color(0xC0, 0x8A, 0x4A)    # the same gold as the caret

proc morningPaper*(): Theme =
  ## Light: ink on warm paper, with the same amber and teal the dark theme
  ## reads by. A light background inverts one rule and only one -- every
  ## accent has to be *darker* than the page rather than lighter -- and that
  ## goes for the sixteen a terminal asks for too: `White` here is ink, not
  ## white, because white on paper is nothing at all.
  let
    ink         = color(0x2A, 0x27, 0x20)  # warm near-black
    amber       = color(0x8A, 0x58, 0x00)
    deepAmber   = color(0xA1, 0x6C, 0x10)
    rust        = color(0xB0, 0x4A, 0x16)
    lightRust   = color(0xC2, 0x5E, 0x22)
    teal        = color(0x0E, 0x6B, 0x60)
    deepTeal    = color(0x0A, 0x55, 0x4C)
    brightTeal  = color(0x11, 0x7F, 0x72)
    muted       = color(0x6B, 0x66, 0x59)  # warm grey, for punctuation
    dim         = color(0x7C, 0x76, 0x69)  # dimmer still, for comments

  result = default(Theme)
  for tc in low(TokenClass)..high(TokenClass):
    result.fg[tc] = ink

  result.fg[TokenClass.Keyword] = amber
  result.fg[TokenClass.Identifier] = ink
  result.fg[TokenClass.Operator] = deepAmber
  result.fg[TokenClass.Punctuation] = muted
  result.fg[TokenClass.Comment] = dim
  result.fg[TokenClass.LongComment] = dim
  result.fg[TokenClass.MarkdownFence] = dim
  result.style[TokenClass.Keyword] = {FontStyle.bold}
  result.style[TokenClass.Comment] = {FontStyle.italics}
  result.style[TokenClass.LongComment] = {FontStyle.italics}
  # Strings and everything string-shaped: teal.
  result.fg[TokenClass.StringLit] = teal
  result.fg[TokenClass.LongStringLit] = teal
  result.fg[TokenClass.CharLit] = teal
  result.fg[TokenClass.RawData] = teal
  result.fg[TokenClass.Backticks] = teal
  result.fg[TokenClass.Key] = teal
  result.fg[TokenClass.Link] = deepTeal
  result.fg[TokenClass.Rule] = deepTeal
  result.fg[TokenClass.Preprocessor] = deepTeal
  result.fg[TokenClass.Directive] = deepTeal
  # Numbers and everything that stands out on its own: rust.
  result.fg[TokenClass.DecNumber] = rust
  result.fg[TokenClass.BinNumber] = rust
  result.fg[TokenClass.HexNumber] = rust
  result.fg[TokenClass.OctNumber] = rust
  result.fg[TokenClass.FloatNumber] = rust
  result.fg[TokenClass.RegularExpression] = rust
  result.fg[TokenClass.Value] = rust
  result.fg[TokenClass.Label] = rust
  result.fg[TokenClass.Reference] = rust
  result.fg[TokenClass.EscapeSequence] = lightRust
  # Markup and assembler read as keywords.
  result.fg[TokenClass.TagStart] = amber
  result.fg[TokenClass.TagStandalone] = amber
  result.fg[TokenClass.TagEnd] = amber
  result.fg[TokenClass.Assembler] = amber
  result.fg[TokenClass.Command] = amber
  # The three named colors keep their meaning; only the shade is ours.
  result.fg[TokenClass.Green] = color(0x1E, 0x6B, 0x38)
  result.fg[TokenClass.Yellow] = color(0x8A, 0x6A, 0x00)
  result.fg[TokenClass.Red] = color(0xB3, 0x2A, 0x1E)
  # And the sixteen. `bright` is what a program means by "louder", which on
  # paper is *more* ink and not less, so the bright half is the darker one.
  result.fg[TokenClass.Black] = muted
  result.fg[TokenClass.Blue] = color(0x1A, 0x5F, 0x9E)
  result.fg[TokenClass.Magenta] = color(0x93, 0x38, 0x7C)
  result.fg[TokenClass.Cyan] = brightTeal
  result.fg[TokenClass.White] = color(0x55, 0x50, 0x45)
  result.fg[TokenClass.BrightBlack] = dim
  result.fg[TokenClass.BrightRed] = color(0x96, 0x22, 0x18)
  result.fg[TokenClass.BrightGreen] = color(0x18, 0x57, 0x2D)
  result.fg[TokenClass.BrightYellow] = color(0x73, 0x58, 0x00)
  result.fg[TokenClass.BrightBlue] = color(0x14, 0x4C, 0x80)
  result.fg[TokenClass.BrightMagenta] = color(0x7A, 0x2D, 0x67)
  result.fg[TokenClass.BrightCyan] = deepTeal
  result.fg[TokenClass.BrightWhite] = ink

  result.bg = color(0xF8, 0xF4, 0xEA)
  result.panelBg = color(0xEC, 0xE6, 0xD7)       # a step below the page
  result.selBg = color(0xD3, 0xE2, 0xDC)         # teal-tinted
  result.bracketBg = color(0xEF, 0xE2, 0xBE)     # amber-tinted, to match
  result.cursorColor = rust
  result.lineNumColor = color(0x80, 0x7A, 0x6B)
  result.markerBg = color(0xF2, 0xE1, 0xA8)      # pale gold for search hits
  result.scrollBarColor = color(0xD2, 0xCB, 0xBA)
  result.scrollBarActiveColor = color(0xB6, 0xAE, 0x9A)
  result.scrollTrackColor = color(0xF0, 0xEB, 0xDF)
  result.activeLineBg = color(0xF0, 0xEA, 0xDC)  # a step below the selection
  result.actionColor = color(0xD9, 0xD2, 0xC0)
  result.closeColor = amber
  result.focusColor = rust                       # the same rust as the caret

proc defaultTheme*(): Theme =
  ## The theme a widget gets when nobody says otherwise, and the one a config
  ## file starts from. One place to change taste.
  result = goldenDusk()

# ---------------------------------------------------------------------------
# The shipped themes, by the name one selects them by. A theme is picked in a
# prompt, so the names are short and lower case; the blurb is what a listing
# of them says.
# ---------------------------------------------------------------------------

const ShippedThemes*: array[3, tuple[name, blurb: string]] = [
  ("dusk", "dark, gold and turquoise"),
  ("mocha", "dark, Catppuccin Mocha"),
  ("paper", "light, ink on paper")]

proc findTheme*(name: string; t: var Theme): bool =
  ## The theme that goes by `name`, or `false` and `t` untouched. Selecting one
  ## is the only thing that has to fail here, and a caller that gets `false`
  ## has `themeNames` to say what it could have asked for instead.
  result = true
  case name
  of "dusk": t = goldenDusk()
  of "mocha": t = catppuccinMocha()
  of "paper": t = morningPaper()
  else: result = false

proc themeNames*(): string =
  ## "dusk, mocha, paper" -- for a message that has one line to say it in.
  result = ""
  for i in 0 ..< ShippedThemes.len:
    if i > 0: result.add ", "
    result.add ShippedThemes[i].name
