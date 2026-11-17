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
# Koan: its own name, icon and bundle id (Yab's TRADEMARKS.md). The id ends
# in .dev so Yab's code keeps it a development build: no update feed, its
# own folder, never the installed Yab's.
export YAB_BRAND_NAME="${YAB_BRAND_NAME:-Koan}"
export YAB_BUNDLE_ICON="${YAB_BUNDLE_ICON:-Icon/Koan.icon}"
export YAB_BRAND_MARK="${YAB_BRAND_MARK:-Icon/KoanMark.png}"
export YAB_DEV_BUNDLE_ID="${YAB_DEV_BUNDLE_ID:-io.github.hczr-dev.koan.dev}"
case "$YAB_DEV_BUNDLE_ID" in *.dev) ;; *) echo "YAB_DEV_BUNDLE_ID must end in .dev, or Yab's code takes it for the shipping Yab and its data" >&2; exit 1 ;; esac
# yab Dev's settings and sign-ins come along once (scripts/custom/move-to-koan.sh).
bash scripts/custom/move-to-koan.sh "$YAB_DEV_BUNDLE_ID" || true
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
  echo "Chromium: the official CEF build (no H.264 or AAC)"
fi
export YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_DIR="$CEF_DIR" YAB_CEF_HELPER="$HELPER"
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
rm -rf "build/$YAB_BRAND_NAME.app"
ditto "$MIRROR/build/$YAB_BRAND_NAME.app" "build/$YAB_BRAND_NAME.app"
echo "built: build/$YAB_BRAND_NAME.app"
