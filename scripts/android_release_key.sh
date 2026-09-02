#!/usr/bin/env bash
# One-time release signing setup for the Android app.
#
# Generates a self-signed release keystore and the `key.properties` file the
# Gradle build reads (android/app/android/app/build.gradle.kts). Both live under
# android/app/android/ and are git-ignored: the keystore is the identity of
# every release you ship — lose it and existing installs can no longer be
# overwritten by new releases (Android requires the same signing key to update
# an app in place).
#
# Usage: scripts/android_release_key.sh [--alias NAME] [--org ORG]
#   --alias  key alias inside the keystore (default: comic-release)
#   --org    CN for the certificate subject (default: Comic)
#
# Requires a JDK `keytool` on PATH. Uses java.util.Random-sourced entropy from
# keytool itself (no passphrase prompts).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/android/app/android"
KEYSTORE_DIR="$ANDROID_DIR/keystore"
KEYSTORE="$KEYSTORE_DIR/comic-release.jks"
PROPS="$ANDROID_DIR/key.properties"
ALIAS="comic-release"
ORG="Comic"

while [ $# -gt 0 ]; do
  case "$1" in
    --alias) ALIAS="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v keytool >/dev/null 2>&1 || {
  echo "keytool not found — install a JDK (e.g. brew install openjdk@17) and retry" >&2
  exit 1
}

if [ -f "$KEYSTORE" ] || [ -f "$PROPS" ]; then
  echo "release signing already exists ($KEYSTORE / $PROPS)" >&2
  echo "refusing to overwrite — keep this keystore for the life of the applicationId" >&2
  exit 1
fi

mkdir -p "$KEYSTORE_DIR"
chmod 700 "$KEYSTORE_DIR"

# Random passwords, written only into key.properties (git-ignored). Validity 30
# years: an Android key must outlive every install it signs, and re-signing with
# a second key after expiry silently breaks upgrades of installed builds.
STORE_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)"
KEY_PASS="$STORE_PASS"

keytool -genkeypair \
  -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10950 \
  -storepass "$STORE_PASS" \
  -keypass "$KEY_PASS" \
  -dname "CN=$ORG, OU=Personal, O=$ORG, L=Unknown, ST=Unknown, C=XX" >/dev/null

cat > "$PROPS" <<EOF
# Release signing — git-ignored, never commit. Regenerate only by deleting this
# file AND the keystore, which invalidates upgrades of every installed build.
storeFile=keystore/comic-release.jks
storePassword=$STORE_PASS
keyAlias=$ALIAS
keyPassword=$KEY_PASS
EOF
chmod 600 "$PROPS"

echo "release keystore: $KEYSTORE"
echo "signing props:    $PROPS (git-ignored)"
echo
echo "next: flutter build apk --release --split-per-abi"
