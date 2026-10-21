#!/usr/bin/env bash
# Assembles mongshell-menubar.app from the SwiftPM build product.
# Usage: scripts/make_app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/mongshell-menubar.app"
BIN="$ROOT/.build/$CONFIG/mongshell-menubar"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/mongshell-menubar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Bundle version from the nearest release tag — the git tag is the version SSOT
# (Decision #47). Resources/Info.plist only holds a 0.0.0 placeholder, so a build
# that can't see a vX.Y.Z tag (no .git, tags not fetched) is recognizable instead
# of passing as a release. Must run before codesign: the signature covers it.
TAG="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [[ "${TAG#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "▶ version ${TAG#v} (from $TAG)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" "$APP/Contents/Info.plist"
else
  echo "  (no vX.Y.Z tag reachable — keeping placeholder version from Info.plist)"
fi

# Code signature so Keychain / UserNotifications / ASWebAuth work locally.
#
# A signature without a Team ID (ad-hoc, self-signed) makes the Keychain ask
# again after every rebuild; an Apple Development certificate doesn't. Why,
# and what that widens: Decision #68. Setup: README § 개발용.
#
# The first identity present wins (order below). An explicit SIGN_ID that
# fails to sign stops the build. An identity picked here that fails falls back
# straight to ad-hoc, with a warning on stderr. Certificate signatures get the
# hardened runtime, as release.sh does.
#
# Apple Development is picked by its SHA-1 rather than its name: after a
# renewal two identities can share the name, and codesign refuses an
# ambiguous one. The self-signed lookup stays without `-v`: a self-signed root
# is reported as CSSMERR_TP_NOT_TRUSTED, which `-v` filters out, yet codesign
# doesn't need a trust chain. Both listings are read into variables first, so
# no `grep` can close a pipe on `security` and trip pipefail.
sign_with() {  # $1 = identity (name or SHA-1), $2 = name for the log, $3 = stop|adhoc on failure
  echo "▶ codesign ($2)"
  codesign --force --deep --options runtime --sign "$1" "$APP" && return
  if [[ "$3" == stop ]]; then
    echo "✗ signing with SIGN_ID '$2' failed — fix SIGN_ID or unset it" >&2
    exit 1
  fi
  echo "  (signing with '$2' failed — falling back to ad-hoc; Keychain prompts will repeat per rebuild)" >&2
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
}

SELF_SIGNED_ID="mongshell-menubar Dev"
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
VALID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEV_LINES="$(grep '"Apple Development: ' <<<"$VALID_IDENTITIES" || true)"
if [[ -n "${SIGN_ID:-}" ]]; then
  sign_with "$SIGN_ID" "$SIGN_ID" stop
elif [[ -n "$DEV_LINES" ]]; then
  DEV_LINE="$(head -n 1 <<<"$DEV_LINES")"
  if (( $(wc -l <<<"$DEV_LINES") > 1 )); then
    echo "  (several Apple Development identities — using the first; pin one with SIGN_ID=<SHA-1>)" >&2
  fi
  sign_with "$(awk '{print $2}' <<<"$DEV_LINE")" "$(cut -d'"' -f2 <<<"$DEV_LINE")" adhoc
elif grep -qF "\"$SELF_SIGNED_ID\"" <<<"$IDENTITIES"; then
  echo "  (no Apple Development identity — '$SELF_SIGNED_ID' has no Team ID, so Keychain prompts repeat per rebuild)" >&2
  sign_with "$SELF_SIGNED_ID" "$SELF_SIGNED_ID" adhoc
else
  echo "▶ ad-hoc codesign (no signing identity — Keychain prompts will repeat per rebuild)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped/failed — app still runs unsigned for local dev)"
fi

echo "✓ built $APP"
