#!/bin/bash
# Stores the "Drevo Local Signing" identity in this repository's GitHub secrets, once, so
# the Release workflow signs the app in the DMG with the same certificate as `make app`.
# macOS then treats a downloaded release and a local build as the same app, and the
# privacy grants (Full Disk Access, folder access) survive updates.
#
# Usage: scripts/ci-signing-secret.sh        (or: make ci-signing-secret)
# Needs the GitHub CLI, logged in (`gh auth login`), and the repository pushed to GitHub.
# Creates the identity first if it doesn't exist (scripts/make-signing-identity.sh).
# Sets two secrets: SIGNING_CERT_P12 (certificate + private key as base64 PKCS#12) and
# SIGNING_CERT_PASSWORD (a random password that protects it). Run it again to replace them.
#
# macOS asks for your login password so export-identity may read the private key: allow it.
set -euo pipefail

NAME="${SIGN_NAME:-Drevo Local Signing}"
here="$(cd "$(dirname "$0")" && pwd)"

if ! command -v gh >/dev/null; then
    echo "Needs the GitHub CLI: brew install gh"
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "Log in to GitHub first: gh auth login"
    exit 1
fi
if ! repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
    echo "This folder has no GitHub repository yet: create it, add it as the remote, push."
    exit 1
fi

SIGN_NAME="$NAME" "$here/make-signing-identity.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Compiled rather than run with `swift`, so the keychain prompt names "export-identity".
swiftc -O -suppress-warnings -o "$work/export-identity" "$here/export-identity.swift"
pass="$(uuidgen)"
P12_PASSWORD="$pass" "$work/export-identity" "$NAME" "$work/identity.p12"

base64 -i "$work/identity.p12" | gh secret set SIGNING_CERT_P12 --repo "$repo"
printf '%s' "$pass" | gh secret set SIGNING_CERT_PASSWORD --repo "$repo"
echo "Set SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD on $repo."
echo "Releases are signed as $NAME from now on."
