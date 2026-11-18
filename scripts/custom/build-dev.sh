#!/bin/bash
# Usage: scripts/custom/build-dev.sh [build.sh's arguments]
# The custom Yab Dev with Chromium tabs inside, on the fullest Chromium this
# Mac has: Yab's own, taken from the installed Yab (/Applications/yab.app,
# with H.264, AAC, HEVC and Yab's CEF patches), or else the official CEF
# build with a YabCore built here, which has Chromium's open codecs only
# (no H.264 or AAC: those are licensed, and the official build leaves them out).
set -euo pipefail
cd "$(dirname "$0")/../.."
# Signing of your own, kept outside the repository: YAB_SIGN_IDENTITY (your
# "Apple Development: …" or "Developer ID Application: …"), YAB_PROVISION_PROFILE
# (the profile carrying the web browser entitlement) and YAB_DEV_BUNDLE_ID
# (the App ID it was made for). With them, Apple Passwords works natively.
SIGNING="${YAB_DEV_SIGNING:-$HOME/.config/yab-dev/signing.env}"
if [ -r "$SIGNING" ]; then
  set -a; . "$SIGNING"; set +a
  echo "Signing: ${YAB_SIGN_IDENTITY:-ad hoc}"
fi
# Koan: its own name, icon and bundle id (Yab's TRADEMARKS.md). build.sh
# marks it a development build in its Info.plist (YabDevelopmentBuild), so it
# keeps its own folder and no update feed, never the installed Yab's.
export YAB_BRAND_NAME="${YAB_BRAND_NAME:-Koan}"
export YAB_BUNDLE_ICON="${YAB_BUNDLE_ICON:-Icon/Koan.icon}"
export YAB_BRAND_MARK="${YAB_BRAND_MARK:-Icon/KoanMark.png}"
export YAB_DEV_BUNDLE_ID="${YAB_DEV_BUNDLE_ID:-com.hczr.koan}"
# yab Dev's settings and sign-ins come along once (scripts/custom/move-to-koan.sh).
bash scripts/custom/move-to-koan.sh "$YAB_DEV_BUNDLE_ID" || true
if [ "${KOAN_CHROMIUM:-1}" = 0 ]; then
# KOAN_CHROMIUM=0: WebKit only, no Chromium inside (a much smaller app).
export YAB_CEF=0 YAB_UNIVERSAL=0
echo "Chromium: none, WebKit only"
else
CACHE="$HOME/.local/state/yab-spike-cef"
OFFICIAL="$(bash scripts/cef/fetch.sh)"
OFFICIAL="${OFFICIAL%/}"
RELEASE="${YAB_RELEASE_APP:-/Applications/yab.app}"
FRAMEWORK="Chromium Embedded Framework.framework"
if [ -x "$RELEASE/Contents/MacOS/YabCore" ] && [ -d "$RELEASE/Contents/Frameworks/$FRAMEWORK" ]; then
  # A CEF folder holding Yab's own framework beside the official headers
  # and license that embed.sh checks; copied again only when Yab changed.
  OWN="$CACHE/yab-own"
  STAMP="$(defaults read "$RELEASE/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo unknown)"
  if [ "$(cat "$OWN/.from" 2>/dev/null || true)" != "$STAMP" ]; then
    rm -rf "$OWN"
    mkdir -p "$OWN/Release"
    ln -s "$OFFICIAL/include" "$OWN/include"
    cp "$OFFICIAL/LICENSE.txt" "$OWN/LICENSE.txt"
    ditto --noqtn "$RELEASE/Contents/Frameworks/$FRAMEWORK" "$OWN/Release/$FRAMEWORK"
    printf '%s' "$STAMP" > "$OWN/.from"
  fi
  CEF_DIR="$OWN"
  HELPER="$RELEASE/Contents/MacOS/YabCore"
  echo "Chromium: Yab's own, from $RELEASE ($(defaults read "$RELEASE/Contents/Info.plist" CFBundleShortVersionString), build $STAMP)"
else
  HELPER="$CACHE/yabcore-v2/Page core.app/Contents/MacOS/YabCore"
  [ -x "$HELPER" ] || YAB_CEF_DIR="$OFFICIAL" bash YabCore/build.sh >/dev/null
  CEF_DIR="$OFFICIAL"
  # Yab's helper now asks for Yab's own CEF patches (native tab groups), so
  # pages don't load on this one: kept for building where no Yab is installed.
  echo "Chromium: the official CEF build (no H.264 or AAC; Chromium pages need Yab's patched build)"
fi
export YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_DIR="$CEF_DIR" YAB_CEF_HELPER="$HELPER"
fi
# The app's own words say Koan: a branded copy of the sources (brand.py) is
# built in build/branded, so this repository stays Yab's code and merges
# from upstream never conflict over wording. The app lands in build/.
MIRROR="build/branded"
mkdir -p "$MIRROR"
rsync -a --checksum --delete --exclude '/build/' --exclude '/.build/' --exclude '/.git/' \
  --exclude '/Sources/' --exclude '/build.sh' --exclude '/Android/' --exclude '/Phone/' --exclude '/demos/' --exclude '/videos/' \
  ./ "$MIRROR/"
python3 -I scripts/custom/brand.py "$PWD" "$MIRROR" "$YAB_BRAND_NAME"
(cd "$MIRROR" && ./build.sh "$@")
# An open Koan keeps running from its bundle: Chromium starts its helpers
# from there, and a renderer from another build than its browser fails.
# So the new build waits beside it (build/.Koan.next.app) and goes in place
# once every process of the open one has ended.
# KOAN_OUT: another folder for the app (a release built beside your own).
OUT="${KOAN_OUT:-build}"
mkdir -p "$OUT"
TARGET="$(cd "$OUT" && pwd)/$YAB_BRAND_NAME.app"
NEXT="$(cd "$OUT" && pwd)/.$YAB_BRAND_NAME.next.app"
rm -rf "$NEXT"
ditto "$MIRROR/build/$YAB_BRAND_NAME.app" "$NEXT"
if pgrep -f "^$TARGET/Contents/" >/dev/null; then
  # Its own session, so launchd ending the sync job doesn't end the wait.
  python3 -I -c 'import subprocess, sys; subprocess.Popen(sys.argv[1:], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)' \
    /bin/bash -c 'while pgrep -f "^$1/Contents/" >/dev/null; do sleep 15; done; [ -d "$2" ] && rm -rf "$1" && mv "$2" "$1"' _ "$TARGET" "$NEXT"
  echo "built: $NEXT ($YAB_BRAND_NAME is open: it replaces build/$YAB_BRAND_NAME.app when it quits)"
else
  rm -rf "$TARGET"
  mv "$NEXT" "$TARGET"
  echo "built: $TARGET"
fi
