Bundled fonts
=============

This folder is referenced from Minis.xcodeproj as a FOLDER REFERENCE
(`lastKnownFileType = folder`), mirroring how `Resources/KaTeX` is declared.
Xcode copies a folder reference RECURSIVELY, so every file in here lands in the
built app bundle under `Fonts/`, and the `UIAppFonts` entries in Info.plist must
therefore carry that prefix: `Fonts/Lora-Regular.ttf`, not `Lora-Regular.ttf`.
A bare file name there does NOT fail the build -- CoreText simply never
registers the face, and every request for it silently renders in the system
font instead. Dropping a new file into this folder needs NO project edit in
either tree; adding its `UIAppFonts` line does.

Files
-----

  CJK text faces (Chinese)
    FZSongSanJianTi.ttf      方正宋三简体 — the default Chinese face. ONE weight.
    NotoSerifSC-Regular.ttf  思源宋体 / Noto Serif SC — Regular
    NotoSerifSC-SemiBold.ttf                     SemiBold
    NotoSerifSC-Bold.ttf                         Bold      (subset, see below)

  Latin faces
    Lora-Regular.ttf         Lora — the default Latin face for body and titles
    Lora-Medium.ttf
    Lora-SemiBold.ttf
    Lora-Bold.ttf
    Literata-Regular.ttf     Literata — the long-form reading alternative
    Literata-Medium.ttf
    Literata-SemiBold.ttf
    Literata-Bold.ttf
    JetBrainsMono-Regular.ttf  JetBrains Mono — code blocks and inline code
    JetBrainsMono-Medium.ttf
    JetBrainsMono-SemiBold.ttf
    JetBrainsMono-Bold.ttf
    Inter-Regular.ttf        Inter 4.001 — kept selectable, NOT the default
    Inter-Medium.ttf
    Inter-SemiBold.ttf

  Licences (all four families are SIL Open Font License 1.1)
    Inter-OFL.txt  Lora-OFL.txt  Literata-OFL.txt  JetBrainsMono-OFL.txt
    NotoSerifSC-OFL.txt

PostScript names (this is what UIFont(name:) needs)
---------------------------------------------------

Read out of each file's `name` table (platformID 3 / encodingID 1, UTF-16BE)
with `_tools/ttf-name-table.js`. A wrong string here does NOT throw and does NOT
log -- CoreText silently substitutes the system font -- so these are measured
values, not guesses:

  FZSongSanJianTi.ttf
      nameID 6 (PostScript) = FZS3JW--GB1-0
      nameID 1 (family)     = 方正宋三简体   (langID 2052)
      one face only: OS/2.usWeightClass = 400, head.macStyle = 0, no fvar
      -> no bold, no italic; iOS does not synthesise either for a custom font.
         AppFont handles that; the settings screen says so in as many words.

  Lora-Regular.ttf      = Lora-Regular      family "Lora"
  Lora-Medium.ttf       = Lora-Medium
  Lora-SemiBold.ttf     = Lora-SemiBold
  Lora-Bold.ttf         = Lora-Bold
      All four buckets share nameID 1 = "Lora" with distinct nameID 2, so a
      trait-based bold lookup also lands on the right instance.

  Literata-Regular.ttf / -Medium / -SemiBold / -Bold  (nameID 1 = "Literata")
  JetBrainsMono-Regular.ttf / -Medium / -SemiBold / -Bold
  NotoSerifSC-Regular.ttf / -SemiBold / -Bold

  Inter-Regular.ttf     nameID 6 = Inter-Regular    (family "Inter")
  Inter-Medium.ttf      nameID 6 = Inter-Medium     (family "Inter Medium")
  Inter-SemiBold.ttf    nameID 6 = Inter-SemiBold   (family "Inter SemiBold")
      Inter 4.001, static instances (no fvar). Note that the three weights sit in
      three DIFFERENT families, so a UIFontDescriptor weight trait cannot move
      between them -- another reason AppFont rebuilds rather than adjusts.
      There is no Inter-Bold in the bundle, so a Bold request on Inter resolves
      to its nearest available instance (SemiBold) and the settings screen shows
      that resolved name.

Provenance
----------

  FZSongSanJianTi.ttf   operator-supplied file; copied verbatim, renamed to ASCII
                        because the path ends up in project.pbxproj and in CI.
      sha256 BF9B1BF49BBAF5B945FA48FC81A5C02DEC78AEBFF0982FCCE438BD1AF023B62C

  Inter-*.ttf           Inter 4.001 by Rasmus Andersson (rsms/inter), SIL OFL 1.1.
                        Taken from the Google Fonts distribution via the
                        @expo-google-fonts/inter 0.4.2 npm tarball, because
                        github.com / codeload.github.com were not reachable from
                        the build host at the time.
      Inter-Regular.ttf   sha256 A414B48AA577EF2C62EBB135341DDEEF33EE26A4F5DC9F787F93C1AAB08EBB50
      Inter-Medium.ttf    sha256 F1738576525E86DB1D5CF63A6C1B56E0A7E2A2898B499AC93DB95F2E7A9F9CD5
      Inter-SemiBold.ttf  sha256 F30E9D2574C3BEC5144347FF965F9841C8F06857F0B7383000F8C9489A161841

  Lora, Literata, JetBrains Mono, Noto Serif SC — all four are SIL OFL 1.1 and
  were taken from the upstream google/fonts repository through the local proxy,
  as VARIABLE fonts, and turned into the static instances in this folder by
  `_tools/build-font-instances.py` on this host:

      _tools/fetch-fonts-2026-10.ps1   downloads (proxy 127.0.0.1:12000)
        https://raw.githubusercontent.com/google/fonts/main/ofl/lora/Lora%5Bwght%5D.ttf
        https://raw.githubusercontent.com/google/fonts/main/ofl/literata/Literata%5Bopsz,wght%5D.ttf
        https://raw.githubusercontent.com/google/fonts/main/ofl/jetbrainsmono/JetBrainsMono%5Bwght%5D.ttf
        https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf
        and each family's OFL.txt from the same directory.
      _tools/build-font-instances.py   fontTools 4.63.0: pin the axes (wght, and
        opsz=20 for Literata), rewrite the name table so every instance has its
        own PostScript name, then subset the CJK ones.
      _tools/stage-fonts-2026-10.ps1   copies the results into BOTH trees and
        refuses to leave the two copies different.
      _tools/dump-font-metrics.py      prints the metrics/coverage table quoted
        below, so the numbers here can be re-derived rather than trusted.

      sha256 of the shipped instances
        Lora-Regular.ttf           DCBA749B9864605D9198A42B1990E93904C3D5BC027683C7A15308D757D0A125
        Lora-Medium.ttf            6ECB2F882EF37394FE02F591FFCCC85322F876EF8915661FF2215B089F7AB87F
        Lora-SemiBold.ttf          9DB8F22EFD903A882ADB9C58C71470BA20B36CC78A9DB136B0DF0392CDF151C5
        Lora-Bold.ttf              28F84FF1E8AC62E83DA929F2F5B622333A86E02251FF7DCC7EEFEC0EEB6B08C5
        Literata-Regular.ttf       F1E5535715516077332D1A68A8B0F042E08E3CD2203565D7641995F60153EA0E
        Literata-Medium.ttf        4B9F1AAE19EEB83144ACEF3E9DF5BCCE7912E7AC8A9A243B5DEC9398637B3DB0
        Literata-SemiBold.ttf      B05F56FC593C7E8CCEF29350C6B49CA58BF565B4A4B7261099C1061F0CF4ED0B
        Literata-Bold.ttf          BD21C1D8A2093F8174959E6679B0E8C7468F30E8849FF2D408550BFACFAEE1CD
        JetBrainsMono-Regular.ttf  A408B2105AE78927FAF74B62CDB3B4D4C3009B8BBD47609F47E6136C37E155F8
        JetBrainsMono-Medium.ttf   B0CC94E73D516CD2A3A498568AF7BBC682E91518CF3EADF9204F36467325066C
        JetBrainsMono-SemiBold.ttf 9DD5E68A440A5C1FC9369710E17F8A5C277B2A11417ADB4C30B72D40561237D8
        JetBrainsMono-Bold.ttf     651E7965F26157CED96EB206033D2E0EA215731D8037CC1C53EE42995F2F4F05
        NotoSerifSC-Regular.ttf    A30629A55B2F1A55226833DCA3B10CDA66B67E7E36F6D2AEE53BD1F0A1B8405C
        NotoSerifSC-SemiBold.ttf   CAF9AA241E2A9102389F3D09D72B077AAE26EC14259EDC3898C42F53290A3E55
        NotoSerifSC-Bold.ttf       F866037C7E4AC5454DE755580D5DF8E99A55A588F89A86F0DB75E6A355EB3F6E

Why static instances and not the variable fonts
-----------------------------------------------

Two reasons, both about silent failure:

  1. Reaching a `wght` axis needs a `kCTFontVariationAttribute` descriptor, a
     path with its own no-op failure mode on the iOS 15 tree, and it leaves
     `UIFontDescriptor.TraitKey.weight` with nothing to match. A static face per
     weight gives each bucket its own PostScript name, so `UIFont(name:)` either
     resolves or returns nil and the launch log says which.
  2. iOS does not synthesise bold or italic for a custom font. With a static
     instance per weight, "heavier" is a name swap, which is exactly what
     `AppFont.bold(_:)` does.

Cost: the twelve Latin instances total ~1.7 MB (Lora 0.54, Literata 1.09,
JetBrains Mono 0.46). Static faces are also why the weight picker offers four
buckets (Regular / Medium / SemiBold / Bold) rather than a slider.

The CJK face is SUBSET, on purpose
----------------------------------

Noto Serif SC ships as a 25 MB variable font. The three shipped instances are
subset to 方正宋三简体's OWN character coverage plus the Latin/symbol blocks, so
the bundle grows by ~10.4 MB instead of ~75 MB:

  target coverage                9,584 codepoints (方正宋三简体's 8,105 cmap
                                 entries + ASCII, Latin-1/Extended-A, general
                                 punctuation, super/subscripts, currency,
                                 letterlike, arrows, math operators, enclosed
                                 alphanumerics, box drawing, geometric shapes,
                                 misc symbols, dingbats)
  kept in the Noto subset        8,054 codepoints, 8,665 glyphs, 3.47 MB per face
  方正宋三简体 codepoints the Noto subset lacks: 528, and **0 of them are CJK
  unified ideographs** (they are control characters and the private-use range
  U+E234…). Every Chinese character 方正宋三简体 can draw is also in the subset.

Coverage is therefore never worse than before, because 方正宋三简体 stays
directly behind Noto Serif SC in the cascade list. Anything the subset dropped
still renders -- from 方正宋三简体, and behind that, PingFang SC.

The weight model, including the honest part
-------------------------------------------

  * Four buckets: Regular 400 / Medium 500 / SemiBold 600 / Bold 700.
  * A Latin face gets the exact instance for the bucket; if it has none, the
    nearest one it does have (Inter has no Bold, so Bold -> SemiBold).
  * 方正宋三简体 has ONE face. iOS will not synthesise a heavier one, so on its
    own a Chinese title stays Regular no matter what the weight picker says.
    With "Let a single-weight Chinese face borrow weight" ON (the default), a
    request above Regular is served by the matching Noto Serif SC instance, with
    方正宋三简体 kept directly behind it in the cascade for coverage. Both are
    Song faces, so what changes is weight, not voice. With the switch OFF,
    Chinese stays Regular at every weight and the settings screen says so.

Metrics, for anyone wondering why line height moved
--------------------------------------------------

  file                        upem   hAsc  hDesc  glyphs  cmap
  FZSongSanJianTi.ttf          256    221    -71    8106  8105
  NotoSerifSC-{Regular,SemiBold,Bold}  1000  1151  -286  8665  8054
  Lora-*                      1000   1006   -274    892   778
  Literata-*                  1000   1177   -308   1789  1163
  JetBrainsMono-*             1000   1020   -300   1179   976
  Inter-*                     2048   1984   -494   2926  2849

  方正宋三简体 的 hhea 行高是 1.14 em，Noto Serif SC 是 1.44 em：中文行会因此
  变松一些，这是思源宋体自己的度量，也是中文正文该有的行距（参考实现里
  `:lang(zh) body { line-height: 1.75 }` 同样是刻意放宽中文行高）。默认中文面
  仍是方正宋三简体，只有"中文加粗"和显式选了思源宋体的地方会用到它。

Advance widths, which is what keeps a code block's table alignment
------------------------------------------------------------------

Measured on the shipped files by `_tools/verify-font-instances.py`:

  JetBrains Mono    M = 600/1000 em (0.600)   space = 600/1000
  Noto Serif SC     中 = 1000/1000 em (1.000)
  方正宋三简体      中 = 1000/1000 em (1.000)   (its own Latin is 227/256 = 0.887)

  Old code block stack was Menlo + PingFang SC; the new one is JetBrains Mono +
  方正宋三简体 (→ PingFang SC last). Menlo is a ~0.602 em monospace and a PingFang
  ideograph is also 1.0 em, so the ratio a column of Chinese sits on — 1.0 / 0.6 —
  is the same as before. (The old comment in `SelectableMarkdownView` claiming
  "exactly 2x" was wrong in both stacks; nothing changes either way.)

  The same script also asserts, against the shipped bytes:
    * every nameID 6 equals the string `AppFontLibrary` hard-codes, and is unique
      across all 19 files;
    * no shipped file still carries an `fvar`/`gvar` axis, and OS/2.usWeightClass
      matches each file's name (400/500/600/700);
    * the Latin faces map no CJK at all, which is what makes the Latin-first
      cascade both necessary and sufficient;
    * 方正宋三简体 ∩ Noto subset = every CJK ideograph 方正宋三简体 has (0 missing;
      477 codepoints go the other way, so the Noto subset is strictly wider on
      its own plane).
  Run it with: python _tools\verify-font-instances.py

Not verified on a device yet
---------------------------

  * That `UIAppFonts` + the `Fonts/` prefix is honoured at all on the shipped
    build. The launch line `[AppFont] … UIAppFonts[n]: Fonts/…=present` reports
    both halves (resolvable face AND file present in the bundle), which is the
    only place a mismatch is visible. Earlier builds only proved the line could
    be written, never that a face resolved.
  * Mixed-script line height and baseline with the two-face stack.
  * Whether 中文 bold (the borrowed Noto instance) reads as intended at UI sizes.
  * Imported fonts (`CTFontManagerRegisterFontsForURL(.process)` at every launch,
    copy into Application Support) have never been exercised on a device.
