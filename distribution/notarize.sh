#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ShortVersion' "$ROOT/Version.plist")"
APP="/private/tmp/DiskMap-signed.app"
PACKAGE_APP="$ROOT/dist/DiskMap.app"
ARCHIVE="$ROOT/dist/DiskMap-${VERSION}-macos.zip"

for required in SIGNING_IDENTITY NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  if [[ -z "${(P)required:-}" ]]; then
    print -u2 "Variabile richiesta: $required"
    exit 2
  fi
done

if [[ ! -f "$NOTARY_KEY_PATH" ]]; then
  print -u2 "Chiave API non trovata: $NOTARY_KEY_PATH"
  exit 2
fi

print "Firma Disk Map con Developer ID…"
make -C "$ROOT" sign SIGNING_IDENTITY="$SIGNING_IDENTITY"

print "Creo l'archivio da inviare ad Apple…"
rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

print "Invio a Apple Notary Service (l'operazione puo richiedere alcuni minuti)…"
xcrun notarytool submit "$ARCHIVE" --wait \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID"

print "Applico il ticket di notarizzazione…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vvv -t exec "$APP"

# Re-create the downloadable archive only after stapling, so it contains the
# offline validation ticket. Use the canonical product name inside the ZIP;
# the signing staging path must never leak into the release package.
rm -rf "$PACKAGE_APP"
ditto --norsrc "$APP" "$PACKAGE_APP"
ditto -c -k --keepParent "$PACKAGE_APP" "$ARCHIVE"
(cd "$ROOT/dist" && shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256")
print "Build notarizzata pronta: $ARCHIVE"
