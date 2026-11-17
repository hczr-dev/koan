#!/bin/bash
# Usage: scripts/custom/move-to-koan.sh NEW_BUNDLE_ID
# Copies what yab Dev keeps under its bundle id to the new one, once: its
# settings, and its WebKit stores (cookies, sign-ins, site data). The folder
# in Application Support is shared already (Yab's code names it "Yab Dev" for
# any id ending in .dev). Nothing of yab Dev's is moved or deleted.
set -euo pipefail
OLD=dev.serafim.fast.dev
NEW="$1"
[ "$NEW" != "$OLD" ] || exit 0
if ! defaults read "$NEW" >/dev/null 2>&1 && defaults read "$OLD" >/dev/null 2>&1; then
  defaults export "$OLD" - | defaults import "$NEW" -
  echo "Koan: settings copied from yab Dev"
fi
STAMP="$HOME/Library/WebKit/$NEW/.from-yab-dev"
[ -f "$STAMP" ] && exit 0
if pgrep -f 'yab Dev.app/Contents/MacOS/yab$' >/dev/null; then
  echo "Koan: quit yab Dev, then run scripts/custom/move-to-koan.sh $NEW to bring its sign-ins" >&2
  exit 0
fi
for base in "$HOME/Library/WebKit" "$HOME/Library/HTTPStorages"; do
  [ -d "$base/$OLD" ] && [ ! -e "$base/$NEW" ] && ditto "$base/$OLD" "$base/$NEW"
  [ -f "$base/$OLD.binarycookies" ] && [ ! -e "$base/$NEW.binarycookies" ] && cp -p "$base/$OLD.binarycookies" "$base/$NEW.binarycookies"
done
mkdir -p "$(dirname "$STAMP")" && touch "$STAMP"
echo "Koan: sign-ins and site data copied from yab Dev"
