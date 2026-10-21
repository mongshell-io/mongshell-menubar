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
# The Keychain recognizes the app twice. An item's ACL matches the app's
# designated requirement, and the item's partition list matches a partition
# ID derived from the signature: `teamid:<TEAMID>` when the signature carries
# a Team ID, `cdhash:<hash>` when it doesn't. The cdhash changes on every
# rebuild, so any signature without a Team ID — ad-hoc, or a self-signed
# certificate — brings the "allow" prompt back after each rebuild, even while
# the ACL still matches (a self-signed leaf keeps the ACL, not the partition).
# An Apple Development certificate (free with an Apple ID, issued by Xcode)
# carries a Team ID, so one "Always Allow" survives rebuilds. README § 개발용.
#
# Identity order: an explicit SIGN_ID → the first valid Apple Development
# identity → the self-signed "mongshell-menubar Dev" → ad-hoc.
#
# Apple Development is picked by its SHA-1 rather than its name: after a
# renewal two identities share the name and codesign refuses an ambiguous one.
# The self-signed lookup stays without `-v`: a self-signed root is reported as
# CSSMERR_TP_NOT_TRUSTED, which `-v` filters out, yet codesign doesn't need a
# trust chain.
sign_with() {  # $1 = identity (name or SHA-1), $2 = what to call it in the log
  echo "▶ codesign ($2)"
  codesign --force --deep --sign "$1" "$APP" || {
    echo "  (signing with '$2' failed — falling back to ad-hoc)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  }
}

SELF_SIGNED_ID="mongshell-menubar Dev"
if [[ -n "${SIGN_ID:-}" ]]; then
  sign_with "$SIGN_ID" "$SIGN_ID"
elif DEV_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development: ')"; then
  sign_with "$(awk '{print $2}' <<<"$DEV_LINE")" "$(cut -d'"' -f2 <<<"$DEV_LINE")"
elif security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SELF_SIGNED_ID\""; then
  echo "  (no Apple Development identity — '$SELF_SIGNED_ID' has no Team ID, so Keychain prompts repeat per rebuild)"
  sign_with "$SELF_SIGNED_ID" "$SELF_SIGNED_ID"
else
  echo "▶ ad-hoc codesign (no signing identity — Keychain prompts will repeat per rebuild)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped/failed — app still runs unsigned for local dev)"
fi

echo "✓ built $APP"
