#!/usr/bin/env bash
# Runs the regression tests: Claude Code settings, the openclaw server agent,
# the app's openclaw status client, the OAuth token path, the GitHub PR
# region, the usage response parser, the usage model's await order, then
# server/install.sh's option rules.
#
# Not `swift test`: that needs XCTest or swift-testing, and neither ships with
# the Command Line Tools this project builds against (no Xcode required is a
# stated goal — see README § 설치). So the tests are compiled directly against
# the real source files instead, which keeps them honest — they exercise the
# shipping code, not a copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Every test binary that compiles `AuthDebugLog` writes its lines here, not to
# the real diagnostic log: `Config.authDebugLogURL` ignores $TMPDIR (#150).
export MONGSHELL_AUTH_LOG="$OUT/auth.log"

# Every async Keychain entry point must be nonisolated(nonsending) so a call
# reaches the serial queue in the order the caller made it (#141). The order
# test in UsageTests only covers KeychainQueue.run; the stores touch the real
# Keychain, so their modifier is checked here instead. The model's Keychain
# boundaries stand for those entry points (#150); the order tests run their
# fakes on the main actor either way, so they cannot see the modifier go
# missing.
#
# Each file must hold exactly the expected number of modified declarations,
# not just none without the modifier: a declaration split over several lines
# or renamed out of the pattern would otherwise drop out of the check
# silently. A new entry point means raising its count here.
check_nonsending() { # <expected count> <extended regex> <file>
  local expected="$1" pattern="$2" file="$3" missing found
  missing="$(grep -nE "$pattern" "$file" | grep -v 'nonisolated(nonsending)' || true)"
  if [[ -n "$missing" ]]; then
    echo "✗ Keychain entry point without nonisolated(nonsending) in ${file#"$ROOT"/}:" >&2
    echo "$missing" >&2
    exit 1
  fi
  found="$(grep -E "$pattern" "$file" | grep -c 'nonisolated(nonsending)' || true)"
  if [[ "$found" -ne "$expected" ]]; then
    echo "✗ ${file#"$ROOT"/}: expected $expected nonisolated(nonsending) Keychain declarations, found $found" >&2
    echo "  (split over lines, renamed, or a new one — update the count in scripts/test.sh)" >&2
    exit 1
  fi
}

echo "▶ checking Keychain entry points are nonisolated(nonsending)"
SERVICES="$ROOT/Sources/mongshell-menubar/Services"
ENTRY_POINT='func [A-Za-z]+.*\) async'
check_nonsending 1 "$ENTRY_POINT" "$SERVICES/KeychainQueue.swift"
check_nonsending 4 "$ENTRY_POINT" "$SERVICES/Credentials.swift"
check_nonsending 4 "$ENTRY_POINT" "$SERVICES/GitHubCredentials.swift"
check_nonsending 4 'var (lookupOwnToken|saveOwnToken|clearOwnToken|loadClaudeCodeToken):' \
  "$ROOT/Sources/mongshell-menubar/Models/UsageModel.swift"

echo "▶ compiling settings tests"
swiftc -o "$OUT/tests" \
  "$ROOT/Sources/mongshell-menubar/Services/ClaudeSettingsStore.swift" \
  "$ROOT/Sources/mongshell-menubar/Models/ClaudeSettingsModel.swift" \
  "$ROOT/Tests/ClaudeSettingsTests/main.swift"

echo "▶ running settings tests"
# MONGSHELL_CLAUDE_SETTINGS is set per-case inside the tests; unset it here so a
# value inherited from the shell can never point them at the real settings file.
env -u MONGSHELL_CLAUDE_SETTINGS "$OUT/tests"

# Every agent source but main.swift, the entry point — the test file supplies
# the top-level code instead. Globbed: the agent has no AppKit, Keychain or
# @main to leave out, so a new file needs no list entry here (#107).
AGENT="$ROOT/Sources/mongshell-openclaw-agent"
AGENT_SOURCES=()
while IFS= read -r f; do AGENT_SOURCES+=("$f"); done \
  < <(find "$AGENT" -name '*.swift' ! -name main.swift | LC_ALL=C sort)
echo "▶ compiling openclaw agent tests"
swiftc -o "$OUT/agent-tests" \
  "${AGENT_SOURCES[@]}" \
  "$ROOT/Tests/OpenClawAgentTests/main.swift"

echo "▶ running openclaw agent tests"
"$OUT/agent-tests"

# The app client is compiled together with the agent's encoder so the
# round-trip case catches any key-name drift between the two targets. Both
# land in one module here, so the app and the agent must not share a
# top-level type name — each target builds alone, but this bundle would not. The
# @MainActor model (polling, notifications) is left out — its rules live in
# the pure types listed here, plus the TimeText clock it displays.
APP="$ROOT/Sources/mongshell-menubar"
echo "▶ compiling openclaw client tests"
swiftc -o "$OUT/client-tests" \
  "$APP/Design/Palette.swift" \
  "$APP/Models/OpenClawHealth.swift" \
  "$APP/Models/OpenClawStatus.swift" \
  "$APP/Models/ServerHost.swift" \
  "$APP/Models/ServerHostAlertWatch.swift" \
  "$APP/Services/BoundedHTTP.swift" \
  "$APP/Services/DisplayText.swift" \
  "$APP/Services/JSONNumber.swift" \
  "$APP/Services/OpenClawStatusClient.swift" \
  "$APP/Services/ResponseDate.swift" \
  "$APP/Services/TimeText.swift" \
  "$AGENT/Probe.swift" \
  "$AGENT/ProcessRunner.swift" \
  "$AGENT/HostProbe.swift" \
  "$AGENT/StatusFile.swift" \
  "$ROOT/Tests/OpenClawClientTests/main.swift"

echo "▶ running openclaw client tests"
"$OUT/client-tests"

# AuthService itself pulls in AppKit, the loopback server and the Keychain, so
# the token-endpoint request and its classification live in their own files
# and are compiled here with just the token type and the constants they
# need. `UsageState` rides along only because `AuthDebugLog` names
# `UsageSnapshot` for its usage line, `BoundedHTTP` because the token
# client's transport names it.
echo "▶ compiling auth tests"
swiftc -o "$OUT/auth-tests" \
  "$APP/Models/UsageState.swift" \
  "$APP/Services/AuthDebugLog.swift" \
  "$APP/Services/AuthError.swift" \
  "$APP/Services/BoundedHTTP.swift" \
  "$APP/Services/Config.swift" \
  "$APP/Services/Credentials.swift" \
  "$APP/Services/JSONNumber.swift" \
  "$APP/Services/KeychainQueue.swift" \
  "$APP/Services/OAuthTokenClient.swift" \
  "$ROOT/Tests/AuthTests/main.swift"

echo "▶ running auth tests"
"$OUT/auth-tests"

# The GitHub region (Decision #45): the pure judgements and the GraphQL
# client's decoding, with the constants and formatter they read. The
# @MainActor model is left out, as above. `GitHubCredentials` is compiled for
# its pure gh-value decoding; nothing here touches the Keychain. The click
# split between the two status-item regions (#58) rides along here, and so
# does `GitHubPresentation` — the connection badge, banner and token row the
# popover and settings read (#117). `PopoverHeader` rides along for the
# header clock both popovers run on (#153).
echo "▶ compiling github tests"
swiftc -o "$OUT/github-tests" \
  "$APP/App/RegionClickRouting.swift" \
  "$APP/Design/Palette.swift" \
  "$APP/Models/GitHubState.swift" \
  "$APP/Models/GitHubPresentation.swift" \
  "$APP/Models/GitHubPullRequest.swift" \
  "$APP/Models/GitHubMergePolicy.swift" \
  "$APP/Services/BoundedHTTP.swift" \
  "$APP/Services/Config.swift" \
  "$APP/Services/DisplayText.swift" \
  "$APP/Services/GitHubAPIClient.swift" \
  "$APP/Services/GitHubCredentials.swift" \
  "$APP/Services/JSONNumber.swift" \
  "$APP/Services/KeychainQueue.swift" \
  "$APP/Services/ResponseDate.swift" \
  "$APP/Services/TimeText.swift" \
  "$APP/Views/PopoverHeader.swift" \
  "$ROOT/Tests/GitHubTests/main.swift"

echo "▶ running github tests"
"$OUT/github-tests"

# The usage response parser and the snapshot it fills: known limit kinds,
# unknown kinds kept as extra rows, the flat fallback, and the debug-log
# summary line, plus the usage `Meter` (display number and the risk color
# with its mono fallback). `AuthDebugLog` is compiled for its timestamp
# format, which pulls in the constants and the token type it names; nothing
# here touches the network or the Keychain. The @MainActor model is left out,
# as above, but the 401 → refresh → retry rules it applies are compiled from
# `UsageRefreshPolicy` and the state it ends in from `UsageSession`.
# `BoundedHTTP` rides along because the client's
# transport names it. `WakeRetry` — the retry after a wake that the usage,
# GitHub and openclaw poll loops share (#156) — is pinned here too.
echo "▶ compiling usage tests"
swiftc -o "$OUT/usage-tests" \
  "$APP/Design/Palette.swift" \
  "$APP/Models/UsagePresentation.swift" \
  "$APP/Models/UsageRefreshPolicy.swift" \
  "$APP/Models/UsageSession.swift" \
  "$APP/Models/UsageState.swift" \
  "$APP/Models/WakeRetry.swift" \
  "$APP/Services/AuthDebugLog.swift" \
  "$APP/Services/BoundedHTTP.swift" \
  "$APP/Services/Config.swift" \
  "$APP/Services/Credentials.swift" \
  "$APP/Services/DisplayText.swift" \
  "$APP/Services/JSONNumber.swift" \
  "$APP/Services/KeychainQueue.swift" \
  "$APP/Services/ResponseDate.swift" \
  "$APP/Services/TimeText.swift" \
  "$APP/Services/UsageAPIClient.swift" \
  "$ROOT/Tests/UsageTests/main.swift"

echo "▶ running usage tests"
"$OUT/usage-tests"

# The @MainActor model itself, on fake boundaries (#150): where it re-checks
# the login generation after each await. The live boundaries
# (`UsageModelLive.swift` — AuthService, Notifier, Preferences) stay out; the
# rest is the usage bundle above. Its `AuthDebugLog` lines go to
# MONGSHELL_AUTH_LOG, set above.
echo "▶ compiling usage model order tests"
swiftc -o "$OUT/usage-model-tests" \
  "$APP/Design/Palette.swift" \
  "$APP/Models/UsageModel.swift" \
  "$APP/Models/UsagePresentation.swift" \
  "$APP/Models/UsageRefreshPolicy.swift" \
  "$APP/Models/UsageSession.swift" \
  "$APP/Models/UsageState.swift" \
  "$APP/Models/WakeRetry.swift" \
  "$APP/Services/AuthDebugLog.swift" \
  "$APP/Services/AuthError.swift" \
  "$APP/Services/BoundedHTTP.swift" \
  "$APP/Services/Config.swift" \
  "$APP/Services/Credentials.swift" \
  "$APP/Services/DisplayText.swift" \
  "$APP/Services/JSONNumber.swift" \
  "$APP/Services/KeychainQueue.swift" \
  "$APP/Services/ResponseDate.swift" \
  "$APP/Services/TimeText.swift" \
  "$APP/Services/UsageAPIClient.swift" \
  "$ROOT/Tests/UsageModelTests/main.swift"

echo "▶ running usage model order tests"
"$OUT/usage-model-tests"

# The runs above do write diagnostic lines; finding them here, not in the real
# log, is what shows the override took (#150).
if [[ ! -s "$MONGSHELL_AUTH_LOG" ]]; then
  echo "✗ no AuthDebugLog lines in MONGSHELL_AUTH_LOG — did they go to the real log?" >&2
  exit 1
fi

# Plain bash: sources the real server/lib.sh, exits non-zero on any failure.
echo "▶ running server install option tests"
bash "$ROOT/Tests/ServerOptionsTests/main.sh"
