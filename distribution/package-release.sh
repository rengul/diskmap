#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ShortVersion' "$ROOT/Version.plist")"
DIST="$ROOT/dist"
ARCHIVE="$DIST/DiskMap-${VERSION}-macos.zip"
CHECKSUM="$DIST/DiskMap-${VERSION}-macos.zip.sha256"

if [[ ! -d "$ROOT/DiskMap.app" ]]; then
  print -u2 'DiskMap.app non trovato. Esegui prima: make ui'
  exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --keepParent "$ROOT/DiskMap.app" "$ARCHIVE"
(cd "$DIST" && shasum -a 256 "${ARCHIVE:t}" > "${CHECKSUM:t}")

print "Creato: $ARCHIVE"
print "Checksum: $CHECKSUM"
