#!/bin/bash
#
# Create a STABLE local self-signed code-signing identity named "HoverDict Dev" and
# import it into the login keychain.
#
# Why: without a real Apple cert, the default is ad-hoc signing, whose code identity is
# the binary's cdhash — it changes on every rebuild, so macOS keeps forgetting the
# Screen Recording permission. A stable cert makes the signature's *designated
# requirement* constant ("identifier ... and certificate root = ..."), so you grant
# Screen Recording ONCE and it survives every recompile.
#
# This is a local DEV cert only (free, no Apple Developer account). For public
# distribution you still need a Developer ID cert + notarization.
#
# Run ONCE:  ./Scripts/create_signing_cert.sh
# Then rebuild — Scripts/build_app.sh auto-detects and uses "HoverDict Dev".
#
set -euo pipefail

NAME="HoverDict Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "✅ Identity \"$NAME\" already exists in the keychain. Nothing to do."
    exit 0
fi

echo "==> Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME/O=HoverDict" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

# OpenSSL 3 defaults to a PKCS12 MAC the macOS keychain can't read; -legacy fixes it.
echo "==> Packaging as PKCS#12…"
openssl pkcs12 -export -legacy \
    -out "$TMP/identity.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout pass:hoverdict

echo "==> Importing into the login keychain…"
# -A: allow any tool (e.g. codesign) to use the key without a per-use keychain prompt.
security import "$TMP/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P hoverdict -A -T /usr/bin/codesign

echo ""
echo "✅ Created identity \"$NAME\"."
echo "   (find-identity may list it as 'invalid' because it's self-signed/untrusted —"
echo "    that's expected; codesign still uses it and TCC keys off its designated requirement.)"
echo "   Now run:  ./Scripts/build_app.sh   (it will pick up \"$NAME\" automatically)"
