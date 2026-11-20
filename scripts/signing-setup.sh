#!/bin/zsh
# One time: make a self-signed code-signing identity in your login keychain.
#   scripts/signing-setup.sh ["Name"]        the default name is "Rumi Self-Signed"
# macOS ties Full Disk Access to how an app is signed. Signed with the same identity every time, Rumi keeps its access
# across rebuilds and updates. Gatekeeper doesn't trust a self-signed identity, so a downloaded copy still has to be
# allowed once in System Settings. The key never leaves your keychain; lose it and the next update asks for access again.
set -euo pipefail
NAME=${1:-Rumi Self-Signed}
KEYCHAIN=$HOME/Library/Keychains/login.keychain-db

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in your keychain"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# the file only exists for the import below, so its password doesn't matter. -legacy: `security` can't read OpenSSL 3's
# newer default; LibreSSL (the openssl that ships with macOS) writes the old form already and has no such flag
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout pass:rumi -out "$TMP/id.p12" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout pass:rumi -out "$TMP/id.p12"
# -A: codesign may use the key without asking each time
security import "$TMP/id.p12" -k "$KEYCHAIN" -P rumi -A >/dev/null
echo "✓ made \"$NAME\". Build with it: RUMI_SIGN_ID=\"$NAME\" scripts/build.sh"
echo "  The first build asks for your login password so codesign can use the key: choose Always Allow."
