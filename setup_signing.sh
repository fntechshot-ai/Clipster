#!/usr/bin/env bash
# One-time setup of a stable local code-signing identity ("Clipster Dev").
#
# Why: ad-hoc signatures change on every build, and macOS ties Accessibility /
# Screen Recording grants to the signature — so each update silently breaks
# them even though System Settings still shows the toggles as ON. A stable
# self-signed identity keeps the grants valid across updates.
#
# The private key is generated locally and never leaves this Mac. macOS may ask
# for your login password once (to trust the certificate) and may show an
# "allow codesign to use the key" prompt on the first build — click Always Allow.
set -euo pipefail

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Clipster Dev"; then
  echo "A 'Clipster Dev' identity already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "==> Generating local certificate (key never leaves this Mac)"
openssl req -x509 -newkey rsa:2048 -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
  -days 3650 -nodes -subj "/CN=Clipster Dev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1
openssl pkcs12 -export -out "${WORK}/clipster.p12" -inkey "${WORK}/key.pem" \
  -in "${WORK}/cert.pem" -passout pass:clipster-local

echo "==> Importing into your login keychain"
security import "${WORK}/clipster.p12" -k "${KEYCHAIN}" -P clipster-local -T /usr/bin/codesign

echo "==> Trusting the certificate for code signing (may ask for your password)"
security add-trusted-cert -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

echo "==> Done. Verify:"
security find-identity -v -p codesigning | grep "Clipster Dev" || {
  echo "Identity not visible yet — try opening Keychain Access once, then re-run."; exit 1; }
echo
echo "Now rebuild and reinstall, then grant permissions one last time:"
echo "  ./build_noxcode.sh && cp -R dist/Clipster.app /Applications/"
