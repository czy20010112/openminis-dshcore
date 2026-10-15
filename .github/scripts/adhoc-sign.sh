#!/usr/bin/env bash
#
# Ad-hoc sign an unsigned .app bundle so dyld will load it on a jailbroken
# device with AppSync Unified.
#
# The build runs with CODE_SIGNING_ALLOWED=NO, so nothing inside the bundle is
# signed and the entitlements files are not applied. Codesign has to be re-run
# here, and it has to be re-run per nested Mach-O: `codesign --deep` signs the
# outer bundle and leaves nested binaries carrying whatever they had.
#
# Order matters — deepest first:
#   1. frameworks / dylibs,
#   2. embedded app extensions (each with its own entitlements),
#   3. the app bundle itself.
#
# Usage: bash .github/scripts/adhoc-sign.sh <path/to/App.app> <path/to/src/ios>

set -euo pipefail

APP="${1:?usage: adhoc-sign.sh <App.app> <src/ios>}"
SRCIOS="${2:?usage: adhoc-sign.sh <App.app> <src/ios>}"

if [ ! -d "$APP" ]; then
  echo "ERROR: $APP is not a directory"
  exit 1
fi

# Sign every framework and loose dylib under a root, deepest first.
sign_nested() {
  local root="$1"
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' item; do
    echo "  ad-hoc sign $item"
    codesign --force --sign - --timestamp=none "$item" || {
      # Inside an .appex a failure is not necessarily fatal (a nested bundle the
      # OS never maps), so report and keep going there; outside it, stop.
      echo "ERROR: failed to sign $item"
      return 1
    }
  done < <(find "$root" -mindepth 1 -depth \
             \( -type d -name "*.framework" -o -type f -name "*.dylib" \) -print0)
}

# 1. Frameworks embedded in the app.
#
# The "Strip Third-Party VAD Framework Symbols" build phase runs `strip -x` on
# RealTimeCutVADCXXLibrary.framework and only re-signs when
# EXPANDED_CODE_SIGN_IDENTITY is set. This build sets CODE_SIGNING_ALLOWED=NO, so
# that re-sign is skipped and the framework ships with a signature its stripped
# binary no longer satisfies. dyld then refuses to load it and the app dies at
# launch with "Library not loaded ... (code signature invalid)".
sign_nested "$APP/Frameworks"

# 2. App extensions. Each is a bundle with its own entitlements; signing one
#    without its entitlements file strips the App Group access it relies on.
if [ -d "$APP/PlugIns" ]; then
  for appex in "$APP/PlugIns"/*.appex; do
    [ -d "$appex" ] || continue
    name="$(basename "$appex" .appex)"
    case "$name" in
      MinisShare)           ent="$SRCIOS/ShareExtension/ShareExtension.entitlements" ;;
      MinisFileProvider)    ent="$SRCIOS/FileProvider/FileProvider.entitlements" ;;
      AgentWidgetExtension) ent="$SRCIOS/AgentWidget/AgentWidget.entitlements" ;;
      *)                    ent="" ;;
    esac
    sign_nested "$appex"
    if [ -n "$ent" ] && [ -f "$ent" ]; then
      echo "  ad-hoc sign $appex (entitlements: $ent)"
      codesign --force --sign - --timestamp=none --entitlements "$ent" "$appex"
    else
      echo "  ad-hoc sign $appex (no entitlements file)"
      codesign --force --sign - --timestamp=none "$appex"
    fi
  done
fi

# 3. The app bundle. Signing with `-` and no entitlements file strips App Group
#    access, and the app then gets nil from containerURL at startup.
APP_ENT="$SRCIOS/Minis.entitlements"
if [ -f "$APP_ENT" ]; then
  echo "  ad-hoc sign $APP (entitlements: $APP_ENT)"
  codesign --force --sign - --timestamp=none --entitlements "$APP_ENT" "$APP"
else
  echo "::warning::$APP_ENT not found — signing without entitlements"
  codesign --force --sign - --timestamp=none "$APP"
fi

# 4. Gate. A nested binary dyld refuses to map kills the app at launch with no
#    visible error, so verify before producing the IPA.
while IFS= read -r -d '' fw; do
  codesign --verify "$fw" || { echo "ERROR: $fw failed verification"; exit 1; }
done < <(find "$APP" -mindepth 1 -depth -type d -name "*.framework" -print0)

codesign --verify --deep --strict "$APP" || {
  echo "ERROR: app bundle failed signature verification"
  exit 1
}
echo "app bundle signature verified"
