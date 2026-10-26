#!/usr/bin/env bash
# Runs the regression tests: Claude Code settings, the openclaw server agent,
# the app's openclaw status client, the OAuth token path, the GitHub PR
# region, the usage response parser, then server/install.sh's option rules.
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

echo "▶ compiling settings tests"
swiftc -o "$OUT/tests" \
  "$ROOT/Sources/mongshell-menubar/Services/ClaudeSettingsStore.swift" \
  "$ROOT/Sources/mongshell-menubar/Models/ClaudeSettingsModel.swift" \
  "$ROOT/Tests/ClaudeSettingsTests/main.swift"

echo "▶ running settings tests"
# MONGSHELL_CLAUDE_SETTINGS is set per-case inside the tests; unset it here so a
# value inherited from the shell can never point them at the real settings file.
env -u MONGSHELL_CLAUDE_SETTINGS "$OUT/tests"

# The agent's main.swift is its entry point, so it's left out — the test file
# supplies the top-level code instead.
AGENT="$ROOT/Sources/mongshell-openclaw-agent"
echo "▶ compiling openclaw agent tests"
swiftc -o "$OUT/agent-tests" \
  "$AGENT/Probe.swift" \
  "$AGENT/Heal.swift" \
  "$AGENT/HostProbe.swift" \
  "$AGENT/StatusFile.swift" \
  "$ROOT/Tests/OpenClawAgentTests/main.swift"

echo "▶ running openclaw agent tests"
"$OUT/agent-tests"

# The app client is compiled together with the agent's encoder so the
# round-trip case catches any key-name drift between the two targets. The
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
  "$APP/Services/OpenClawStatusClient.swift" \
  "$APP/Services/TimeText.swift" \
  "$AGENT/Probe.swift" \
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
  "$APP/Services/OAuthTokenClient.swift" \
  "$ROOT/Tests/AuthTests/main.swift"

echo "▶ running auth tests"
"$OUT/auth-tests"

# The GitHub region (Decision #45): the pure judgements and the GraphQL
# client's decoding, with the constants and formatter they read. The
# @MainActor model is left out, as above. `GitHubCredentials` is compiled for
# its pure gh-value decoding; nothing here touches the Keychain. The click
# split between the two status-item regions (#58) rides along here.
echo "▶ compiling github tests"
swiftc -o "$OUT/github-tests" \
  "$APP/App/RegionClickRouting.swift" \
  "$APP/Design/Palette.swift" \
  "$APP/Models/GitHubState.swift" \
  "$APP/Models/GitHubPullRequest.swift" \
  "$APP/Services/BoundedHTTP.swift" \
  "$APP/Services/Config.swift" \
  "$APP/Services/GitHubAPIClient.swift" \
  "$APP/Services/GitHubCredentials.swift" \
  "$APP/Services/TimeText.swift" \
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
# `UsageRefreshPolicy`. `BoundedHTTP` rides along because the client's
# transport names it.
echo "▶ compiling usage tests"
swiftc -o "$OUT/usage-tests" \
  "$APP/Design/Palette.swift" \
  "$APP/Models/UsageRefreshPolicy.swift" \
  "$APP/Models/UsageState.swift" \
  "$APP/Services/AuthDebugLog.swift" \
  "$APP/Services/BoundedHTTP.swift" \
  "$APP/Services/Config.swift" \
  "$APP/Services/Credentials.swift" \
  "$APP/Services/DisplayText.swift" \
  "$APP/Services/TimeText.swift" \
  "$APP/Services/UsageAPIClient.swift" \
  "$ROOT/Tests/UsageTests/main.swift"

echo "▶ running usage tests"
"$OUT/usage-tests"

# Plain bash: sources the real server/lib.sh, exits non-zero on any failure.
echo "▶ running server install option tests"
bash "$ROOT/Tests/ServerOptionsTests/main.sh"
