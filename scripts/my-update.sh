#!/bin/bash
# Installs the newest personal build of Coucou (offivlad/coucou "my-*" prerelease):
# downloads Coucou.zip, checks its SHA-256 against the release notes, replaces
# /Applications/Coucou.app and opens it.
#   bash <(curl -fsSL https://raw.githubusercontent.com/offivlad/coucou/main/scripts/my-update.sh)
set -euo pipefail
REPO="offivlad/coucou"
JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=10")
TAG=$(printf '%s' "$JSON" | /usr/bin/python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin) if x["tag_name"].startswith("my-")]; print(r[0]["tag_name"])')
SHA=$(printf '%s' "$JSON" | /usr/bin/python3 -c 'import json,sys,re; r=[x for x in json.load(sys.stdin) if x["tag_name"]=="'"$TAG"'"][0]; print(re.search(r"SHA-256: ([0-9a-f]{64})", r["body"]).group(1))')
echo "Newest build: $TAG"
TMP=$(mktemp -d)
curl -fL --progress-bar -o "$TMP/Coucou.zip" "https://github.com/$REPO/releases/download/$TAG/Coucou.zip"
GOT=$(shasum -a 256 "$TMP/Coucou.zip" | cut -d' ' -f1)
if [ "$GOT" != "$SHA" ]; then echo "SHA-256 mismatch: $GOT (expected $SHA). Nothing installed."; exit 1; fi
echo "SHA-256 OK"
osascript -e 'quit app "Coucou"' >/dev/null 2>&1 || true
sleep 2
rm -rf /Applications/Coucou.app
ditto -x -k "$TMP/Coucou.zip" /Applications
xattr -dr com.apple.quarantine /Applications/Coucou.app
rm -rf "$TMP"
open /Applications/Coucou.app
echo "Installed $TAG. Allow Coucou again in System Settings → Privacy & Security → Accessibility (− then +)."
