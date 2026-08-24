#!/bin/zsh
set -euo pipefail
umask 077
setopt null_glob

ROOT="${0:A:h:h}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-34T8V3NA4P}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
RELEASE_CREDENTIALS_REPO="${RELEASE_CREDENTIALS_REPO:?Set RELEASE_CREDENTIALS_REPO to the readonly credentials checkout}"
MATCH_REPO="${MATCH_REPO:?Set MATCH_REPO to the readonly Match checkout}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:?Set AGE_IDENTITY_FILE to the protected CI age identity}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect issuer ID}"
ISOLATED_KEYCHAIN_RUNNER="$RELEASE_CREDENTIALS_REPO/run-with-isolated-release-keychain.sh"
SECRETS_VALIDATOR="$RELEASE_CREDENTIALS_REPO/skills/remotemic-notary-secrets/scripts/validate-notary-secrets-repo.sh"
MATCH_VALIDATOR="$MATCH_REPO/skills/apple-signing-match/scripts/validate-signing-repo.sh"
P8_ENCRYPTED_FILES=("$RELEASE_CREDENTIALS_REPO"/AuthKey_*.p8.github-actions.age(N))
MATCH_PASSWORD_ENCRYPTED_FILE="$RELEASE_CREDENTIALS_REPO/match-password.github-actions.age"
SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE="$RELEASE_CREDENTIALS_REPO/sparkle-ed25519.github-actions.key.age"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  print -u2 "this credential bootstrap is restricted to GitHub Actions"
  exit 1
fi
if [[ "$EXPECTED_DEVELOPER_TEAM_ID" != "34T8V3NA4P" ]]; then
  print -u2 "refusing to release for an unexpected Apple Developer Team"
  exit 1
fi
if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
  print -u2 "RELEASE_TAG must match Resources/Info.plist"
  exit 1
fi
if [[ "${REMOTE_WEB_RELAY_URL:-}" != wss://?*/ws ]]; then
  print -u2 "REMOTE_WEB_RELAY_URL must be a production wss:// URL ending in /ws"
  exit 1
fi
if ! print -r -- "${EARLY_ACCESS_SERVICE_URL:-}" | rg -q '^https://[^/?#]+/?$'; then
  print -u2 "EARLY_ACCESS_SERVICE_URL must be a production root HTTPS URL"
  exit 1
fi
if (( ${#P8_ENCRYPTED_FILES} != 1 )); then
  print -u2 "release credentials repository must contain exactly one AuthKey_*.p8.github-actions.age file"
  exit 1
fi
P8_ENCRYPTED_FILE="${P8_ENCRYPTED_FILES[1]}"

for required_file in \
  "$AGE_IDENTITY_FILE" \
  "$ISOLATED_KEYCHAIN_RUNNER" \
  "$SECRETS_VALIDATOR" \
  "$MATCH_VALIDATOR" \
  "$P8_ENCRYPTED_FILE" \
  "$MATCH_PASSWORD_ENCRYPTED_FILE" \
  "$SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE"; do
  if [[ ! -r "$required_file" ]]; then
    print -u2 "required Actions release input is unavailable: $required_file"
    exit 1
  fi
done
if [[ "$(/usr/bin/stat -f '%Lp' "$AGE_IDENTITY_FILE")" != "600" ]]; then
  print -u2 "the protected Actions age identity must have mode 600"
  exit 1
fi

"$SECRETS_VALIDATOR" "$RELEASE_CREDENTIALS_REPO"
"$MATCH_VALIDATOR" "$MATCH_REPO"

ALLOW_ISOLATED_RELEASE_KEYCHAIN=1 \
AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" \
ASC_ISSUER_ID="$ASC_ISSUER_ID" \
MATCH_GIT_URL="file://$MATCH_REPO" \
P8_ENCRYPTED_FILE="$P8_ENCRYPTED_FILE" \
MATCH_PASSWORD_ENCRYPTED_FILE="$MATCH_PASSWORD_ENCRYPTED_FILE" \
SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE="$SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE" \
  "$ISOLATED_KEYCHAIN_RUNNER" -- "$ROOT/scripts/package-macos-release-variants.sh"

print "GITHUB ACTIONS MAC RELEASE PACKAGE PASS"
print "RELEASE TAG: $RELEASE_TAG"
print "APPLE SILICON OUTPUT: $ROOT/dist"
print "INTEL OUTPUT: $ROOT/dist/intel"
