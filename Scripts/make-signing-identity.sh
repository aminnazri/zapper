#!/bin/bash
# Creates "MiRemote Local Signing", a self-signed code-signing certificate in
# the login keychain, so every build carries the same signature and keeps its
# Screen Recording and Accessibility permissions. Run once per Mac.
# Remove with: security delete-identity -c "MiRemote Local Signing"
# The name predates the rename to Zapper and is kept: the existing
# certificate, and the permissions granted to builds signed with it, carry on.
set -euo pipefail
NAME="MiRemote Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
LEGACY=""; openssl version | grep -q "^OpenSSL 3" && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout pass:miremote
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P miremote -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with Scripts/make-app.sh."
echo "The first build shows a keychain prompt for codesign: enter your login"
echo "password and choose Always Allow, or every build will wait on it."
