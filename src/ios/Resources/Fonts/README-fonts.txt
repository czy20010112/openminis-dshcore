Bundled fonts
=============

This folder is referenced from Minis.xcodeproj as a FOLDER REFERENCE
(`lastKnownFileType = folder`), mirroring how `Resources/KaTeX` is declared.
Xcode copies a folder reference RECURSIVELY, so every file in here lands in the
built app bundle under `Fonts/`, and the `UIAppFonts` entries in Info.plist must
therefore carry that prefix: `Fonts/Inter-Regular.ttf`, not `Inter-Regular.ttf`.

Files
-----

  FZSongSanJianTi.ttf   CJK text face (方正宋三简体)
  Inter-Regular.ttf     Latin text face
  Inter-Medium.ttf      Latin, one step up (composer context-usage emphasis)
  Inter-SemiBold.ttf    Latin, headings and `**strong**`
  Inter-OFL.txt         SIL Open Font License 1.1 for Inter

PostScript names (this is what UIFont(name:) needs)
---------------------------------------------------

Read out of each file's `name` table (platformID 3 / encodingID 1, UTF-16BE)
with `_tools/ttf-name-table.js`. A wrong string here does NOT throw and does NOT
log -- CoreText silently substitutes the system font -- so these are measured
values, not guesses:

  FZSongSanJianTi.ttf
      nameID 6 (PostScript) = FZS3JW--GB1-0
      nameID 1 (family)     = 方正宋三简体   (langID 2052)
                              FZSong III-Z05S (langID 1033)
      one face only: OS/2.usWeightClass = 400, head.macStyle = 0, no fvar
      -> no bold, no italic; iOS does not synthesise either for a custom font.
         AppFont.bold()/AppFont.italic() handle that (see src/ios/DSH/AppFont.swift).

  Inter-Regular.ttf     nameID 6 = Inter-Regular    (family "Inter")
  Inter-Medium.ttf      nameID 6 = Inter-Medium     (family "Inter Medium")
  Inter-SemiBold.ttf    nameID 6 = Inter-SemiBold   (family "Inter SemiBold")
      Inter 4.001, static instances (no fvar). Note that the three weights sit in
      three DIFFERENT families, so a UIFontDescriptor weight trait cannot move
      between them -- another reason AppFont rebuilds rather than adjusts.

Provenance
----------

  FZSongSanJianTi.ttf   operator-supplied file; copied verbatim, renamed to ASCII
                        because the path ends up in project.pbxproj and in CI.
      sha256 BF9B1BF49BBAF5B945FA48FC81A5C02DEC78AEBFF0982FCCE438BD1AF023B62C

  Inter-*.ttf           Inter 4.001 by Rasmus Andersson (rsms/inter), SIL OFL 1.1.
                        Taken from the Google Fonts distribution via the
                        @expo-google-fonts/inter 0.4.2 npm tarball, because
                        github.com / codeload.github.com were not reachable from
                        the build host (objects.githubusercontent.com and
                        registry.npmjs.org were).
      Inter-Regular.ttf   sha256 A414B48AA577EF2C62EBB135341DDEEF33EE26A4F5DC9F787F93C1AAB08EBB50
      Inter-Medium.ttf    sha256 F1738576525E86DB1D5CF63A6C1B56E0A7E2A2898B499AC93DB95F2E7A9F9CD5
      Inter-SemiBold.ttf  sha256 F30E9D2574C3BEC5144347FF965F9841C8F06857F0B7383000F8C9489A161841

Why static Inter faces and not InterVariable.ttf
------------------------------------------------

Inter is used here only for Latin, at three specific weights that the existing
code already asks for by name (`.regular`, `.medium`, `.semibold`). Static
instances give each of those a real PostScript name, so `UIFont(name:)` either
resolves or returns nil and the launch log says so. The variable font exposes one
PostScript name and selects weight through `fvar` axes, which UIKit reaches only
through a `kCTFontVariationAttribute` descriptor -- on the iOS 15 tree that path
is exactly the kind of silent no-op described above, and it also leaves
`UIFontDescriptor.TraitKey.weight` with nothing to match. Static faces cost about
1 MB in total and remove that whole class of failure.
