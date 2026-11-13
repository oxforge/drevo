#!/bin/bash
# Creates a self-signed code-signing identity in your login keychain, once.
#
# `make app` signs ad hoc by default, and an ad-hoc signature is different after every
# build, so macOS forgets the folder access (Desktop, Documents, Downloads…) it granted
# to Drevo. Signed with the same certificate every time, the app stays "the same app"
# to macOS and the grants stay. `make app` picks this identity up by itself.
#
# Usage: scripts/make-signing-identity.sh            (or: make signing-identity)
#        scripts/make-signing-identity.sh --trust    if codesign refuses the identity
# Remove: delete "Drevo Local Signing" (certificate and private key) in Keychain Access.
#
# The script signs a scratch file to check the identity; macOS then asks for your login
# password so codesign may use the key: choose "Always Allow".
set -euo pipefail

NAME="${SIGN_NAME:-Drevo Local Signing}"
# Tests pass a scratch keychain; normally the login keychain.
KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    if [ "${1:-}" != "--trust" ]; then
        echo "“$NAME” already exists in $KEYCHAIN — nothing to do."
        exit 0
    fi
    echo "Marking “$NAME” as trusted for code signing (macOS asks for your password)…"
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$work/cert.pem"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"
    echo "Done."
    exit 0
fi

cat > "$work/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# The key never leaves this machine; the password only wraps it between two commands.
pass="$(uuidgen)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$work/cert.conf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$NAME" -out "$work/identity.p12" -passout "pass:$pass"
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created “$NAME” in $KEYCHAIN."

# Sign a scratch binary to see that codesign accepts the identity (this is where macOS
# asks for the login password: choose "Always Allow").
cp /usr/bin/true "$work/probe"
if codesign --force --sign "$NAME" "$work/probe" 2>"$work/codesign.log"; then
    echo "codesign can sign with it. From now on \`make app\` uses it; grant Drevo its"
    echo "folder access once more and it stays."
    exit 0
fi

# Some macOS versions want a self-signed certificate trusted for code signing first.
echo "codesign refused the new identity: $(cat "$work/codesign.log")"
if [ "${1:-}" = "--trust" ]; then
    echo "Marking the certificate as trusted for code signing (macOS asks for your password)…"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"
    codesign --force --sign "$NAME" "$work/probe"
    echo "codesign can sign with it now. \`make app\` uses it from here on."
else
    echo "Run this script again with --trust to mark the certificate as trusted for code"
    echo "signing (for your user only), or do it in Keychain Access: open the certificate,"
    echo "Trust ▸ Code Signing ▸ Always Trust."
    exit 1
fi
