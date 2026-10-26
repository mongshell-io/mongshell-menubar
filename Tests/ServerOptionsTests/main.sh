#!/usr/bin/env bash
# Tests for server/install.sh's option rules (server/lib.sh): validation, the
# saved `options` file, and precedence (command line > saved > default); the
# constants bash shares with the agent; the funnel port check
# (`serve_handlers`) and the old-path removal (`unpublish_path`) against a
# stand-in tailscale CLI.
#
# Each case pins a rule whose mutation would silently change what a re-run
# installs — the trap being `git pull && server/install.sh` reverting options.
#
# Run with `./scripts/test.sh`, which sources the real lib.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

die()  { printf '오류: %s\n' "$*" >&2; exit 1; }
warn() { printf '경고: %s\n' "$*" >&2; }
# shellcheck source=../../server/lib.sh
source "$ROOT/server/lib.sh"

FAILURES=()
CASES=0
check() { # $1=label, $2=expected, $3=actual
  CASES=$((CASES + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf ' FAIL  %s  — expected [%s], got [%s]\n' "$1" "$2" "$3"
    FAILURES+=("$1")
  fi
}

OPTS="$WORK/options"
# $1=file contents ("" → no file), $2=ARG_INTERVAL, $3=ARG_AUTO_HEAL.
# Prints "<interval> <auto_heal> <warned 0|1>".
resolve() {
  rm -f "$OPTS"
  [[ -n "$1" ]] && printf '%b' "$1" >"$OPTS"
  ARG_INTERVAL="$2" ARG_AUTO_HEAL="$3"
  load_saved_options "$OPTS" 2>"$WORK/err"
  resolve_options
  printf '%s %s %s' "$INTERVAL" "$AUTO_HEAL" "$([[ -s "$WORK/err" ]] && echo 1 || echo 0)"
}

echo "▸ 우선순위 (명시 > 저장 > 기본)"
check "파일 없음 → 기본 60·켬"            "60 1 0" "$(resolve "" "" "")"
check "저장 30 + 명시 없음 → 30"          "30 1 0" "$(resolve 'interval=30\n' "" "")"
check "저장 30 + 명시 45 → 45" "45 1 0" "$(resolve 'interval=30\n' 45 "")"
check "auto_heal=0 저장 + 명시 없음 → 끔" "60 0 0" "$(resolve 'auto_heal=0\n' "" "")"
check "명시 켬(--auto-heal)이 저장 0 을 덮음" "60 1 0" "$(resolve 'auto_heal=0\n' "" 1)"
check "명시 끔(--no-auto-heal)이 저장 1 을 덮음" "30 0 0" "$(resolve 'interval=30\nauto_heal=1\n' "" 0)"

echo "▸ 깨진 저장값 → 경고 후 기본"
check "interval=abc → 60 + 경고"          "60 1 1" "$(resolve 'interval=abc\n' "" "")"
check "auto_heal=2 → 켬 + 경고"           "60 1 1" "$(resolve 'auto_heal=2\n' "" "")"
check "auto_heal=00 → 켬 + 경고"          "60 1 1" "$(resolve 'auto_heal=00\n' "" "")"
# 2^64 + 30: without the digit cap, bash arithmetic wraps it to an in-range 30.
check "20자리 숫자 무시 (오버플로로 30 이 되는 값)" "60 1 1" "$(resolve 'interval=18446744073709551646\n' "" "")"
check "범위 밖 29 무시"                   "60 1 1" "$(resolve 'interval=29\n' "" "")"
check "범위 밖 86401 무시"                "60 1 1" "$(resolve 'interval=86401\n' "" "")"
check "경계 30 허용"                "30 1 0" "$(resolve 'interval=30\n' "" "")"
check "경계 86400 허용"                   "86400 1 0" "$(resolve 'interval=86400\n' "" "")"
check "앞자리 0 은 10진수 (045 → 45)"     "45 1 0" "$(resolve 'interval=045\n' "" "")"
check "끝줄 개행 없어도 읽음"             "30 0 0" "$(resolve 'interval=30\nauto_heal=0' "" "")"
check "모르는 키 무시"                    "30 1 0" "$(resolve 'foo=bar\ninterval=30\n' "" "")"

printf 'interval=30\n' >"$OPTS"; chmod 000 "$OPTS"
ARG_INTERVAL="" ARG_AUTO_HEAL=""
load_saved_options "$OPTS" 2>"$WORK/err"; status=$?
resolve_options
check "읽을 수 없는 파일 → 기본값 + 경고, 중단 없음" "60 1 1 0" \
  "$INTERVAL $AUTO_HEAL $([[ -s "$WORK/err" ]] && echo 1 || echo 0) $status"
chmod 600 "$OPTS"

rm -f "$WORK/pwned"
resolve "interval=\$(touch $WORK/pwned)\n" "" "" >/dev/null
check "파일 내용을 실행하지 않음" "absent" "$([[ -e "$WORK/pwned" ]] && echo present || echo absent)"

echo "▸ 에이전트 버전 (git describe)"
# The developer's own git config (commit/tag signing, editors) must not reach
# these throwaway repos.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$WORK/repo"
git init -q "$REPO"
commit() { git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
commit first
check "tag 없음 → 빈 값" "" "$(agent_version "$REPO")"
git -C "$REPO" tag v1.2.0
check "tag 위 → v1.2.0" "v1.2.0" "$(agent_version "$REPO")"
commit second
check "tag 뒤 1커밋 → v1.2.0+1" "v1.2.0+1" "$(agent_version "$REPO")"
commit third
check "커밋이 늘면 값이 바뀜 → v1.2.0+2" "v1.2.0+2" "$(agent_version "$REPO")"
git -C "$REPO" tag build-marker
check "v* 가 아닌 tag 는 무시" "v1.2.0+2" "$(agent_version "$REPO")"
git -C "$REPO" tag v1.3.0-rc-1
check "하이픈 든 tag 이름" "v1.3.0-rc-1" "$(agent_version "$REPO")"
check "repo 아님 → 빈 값" "" "$(agent_version "$WORK/nowhere")"

echo "▸ 빌드 진행 표시"
check "45초" "45초" "$(format_duration 45)"
check "60초 → 1분 0초" "1분 0초" "$(format_duration 60)"
check "331초 → 5분 31초" "5분 31초" "$(format_duration 331)"
check "앞자리 0 은 10진수 (089 → 1분 29초)" "1분 29초" "$(format_duration 089)"

# pid ppid comm — 100 is the build; 300 is someone else's compiler.
PS_TREE="100 1 /usr/bin/swift
101 100 /Library/Developer/CommandLineTools/usr/bin/swift-build
102 101 /Library/Developer/CommandLineTools/usr/bin/clang-stat-cache
300 1 /Library/Developer/CommandLineTools/usr/bin/swift-frontend"
check "자손에 clang-stat-cache → SDK 캐시 생성" "SDK 캐시 생성" "$(process_tree 100 <<<"$PS_TREE" | build_phase)"
check "남의 swift-frontend 는 세지 않음" "SDK 캐시 생성" "$(process_tree 100 <<<"$PS_TREE" | build_phase)"
check "손자의 swift-frontend → 컴파일" "컴파일" \
  "$(process_tree 100 <<<"$PS_TREE
103 101 /Library/Developer/CommandLineTools/usr/bin/swift-frontend" | build_phase)"
check "ld 가 있으면 링크가 앞섬" "링크" \
  "$(process_tree 100 <<<"$PS_TREE
103 101 /Library/Developer/CommandLineTools/usr/bin/swift-frontend
104 102 /usr/bin/ld" | build_phase)"
check "도구 없음 → 준비" "준비" "$(process_tree 100 <<<"100 1 /usr/bin/swift" | build_phase)"
check "빌드가 이미 끝남 → 준비" "준비" "$(process_tree 999 <<<"$PS_TREE" | build_phase)"
check "프로세스 트리: 루트와 자손만, 경로 없이" "100 swift,101 swift-build,102 clang-stat-cache" \
  "$(process_tree 100 <<<"$PS_TREE" | paste -sd, -)"
check "프로세스 트리: 루트가 없으면 빈 값" "" "$(process_tree 999 <<<"$PS_TREE")"

echo "▸ 스크립트와 에이전트의 같은 값 (#106)"
# The same constant lives in bash and in Swift; a change to one side alone
# would install options the agent clamps differently, or kickstart a label the
# agent would not pick.
AGENT_SRC="$ROOT/Sources/mongshell-openclaw-agent"
swift_value() { # $1=file, $2=declaration name → a string literal unquoted, or a number with its _ dropped
  grep -E "static let $2 = " "$1" | head -1 | sed -E 's/.*= *//; /^"/{s/"//g;b
}; s/_//g'
}
check "기본 주기 = Options.defaultInterval" "$(swift_value "$AGENT_SRC/Options.swift" defaultInterval)" "$DEFAULT_INTERVAL"
check "주기 하한 = Options.minimumInterval" "$(swift_value "$AGENT_SRC/Options.swift" minimumInterval)" "$MIN_INTERVAL"
check "주기 상한 = Options.maximumInterval" "$(swift_value "$AGENT_SRC/Options.swift" maximumInterval)" "$MAX_INTERVAL"
INSTALL_SH="$ROOT/server/install.sh"
check "자기 레이블 = Options.defaultSelfLabel" "$(swift_value "$AGENT_SRC/Options.swift" defaultSelfLabel)" \
  "$(grep -E '^SELF_LABEL=' "$INSTALL_SH" | sed -E 's/^SELF_LABEL="(.*)"$/\1/')"
check "기본 게이트웨이 레이블 = Launchd.defaultGatewayLabel" "$(swift_value "$AGENT_SRC/Heal.swift" defaultGatewayLabel)" \
  "$(grep -E '^DEFAULT_GATEWAY_LABEL=' "$INSTALL_SH" | sed -E 's/^DEFAULT_GATEWAY_LABEL="(.*)"$/\1/')"

echo "▸ funnel 포트 점검 serve_handlers (#106)"
# A stand-in tailscale CLI: prints $FAKE_SERVE_JSON, or fails when
# FAKE_SERVE_FAIL is set. serve_handlers takes the CLI path as its first
# argument, so nothing real is touched.
FAKE_TS="$WORK/tailscale"
cat >"$FAKE_TS" <<'SH'
#!/bin/bash
[[ -n "${FAKE_SERVE_FAIL:-}" ]] && exit 1
printf '%s' "$FAKE_SERVE_JSON"
SH
chmod +x "$FAKE_TS"
HP="srv.example.ts.net:8443"
handlers() { # $1=JSON → "<rc>|<handlers joined by ,>"
  local out rc
  out="$(FAKE_SERVE_JSON="$1" serve_handlers "$FAKE_TS" "$HP" 2>/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$(paste -sd, - <<<"$out")"
}
check "빈 설정 {} → 핸들러 없음" "0|" "$(handlers '{}')"
check "빈 출력 → 핸들러 없음" "0|" "$(handlers '')"
check "'No serve config' 문구 → 핸들러 없음" "0|" "$(handlers 'No serve config')"
check "그 밖의 비-JSON → 실패 (설정을 숨길 수 있다)" "1|" "$(handlers 'error: something')"
check "CLI 실패 → 실패" "1|" "$(FAKE_SERVE_FAIL=1 handlers '{}')"
check "깨진 JSON → 실패 (빈 설정으로 강등하지 않는다)" "1|" "$(handlers '{"Web":')"
check "여러 줄 중 한 줄만 'No serve config' → 실패" "1|" "$(handlers $'warning: something\nNo serve config')"
check "우리 포트의 웹 경로" "0|/abc" \
  "$(handlers '{"Web":{"srv.example.ts.net:8443":{"Handlers":{"/abc":{"Path":"/x"}}}}}')"
check "다른 포트의 경로는 세지 않음" "0|" \
  "$(handlers '{"Web":{"srv.example.ts.net:443":{"Handlers":{"/dash":{}}}}}')"
check "우리 포트의 TCP 포워딩" "0|tcp:127.0.0.1:3000" \
  "$(handlers '{"TCP":{"8443":{"TCPForward":"127.0.0.1:3000"}}}')"
check "--bg 없이 띄운 포그라운드 세션도 센다" "0|/fg" \
  "$(handlers '{"Foreground":{"s1":{"Web":{"srv.example.ts.net:8443":{"Handlers":{"/fg":{}}}}}}}')"
check "배경·포그라운드 둘 다" "0|/abc,/fg" \
  "$(handlers '{"Web":{"srv.example.ts.net:8443":{"Handlers":{"/abc":{}}}},"Foreground":{"s1":{"Web":{"srv.example.ts.net:8443":{"Handlers":{"/fg":{}}}}}}}')"

echo "▸ 옛 공개 경로 해제 unpublish_path (#156)"
# install.sh 는 경로를 root 로 건다. A stand-in CLI keeps the serve config in
# $FAKE_STATE and refuses 'off' from a non-root caller when FAKE_DENY_USER is
# set (or from root too with FAKE_DENY_ROOT); a stand-in sudo marks the call as
# root. Every 'off' lands in $FAKE_LOG as "user" or "root".
FAKE_TS2="$WORK/tailscale2"
cat >"$FAKE_TS2" <<'SH'
#!/bin/bash
case "$1" in
  serve) cat "$FAKE_STATE" ;;
  funnel)
    who="${FAKE_ROOT:+root}"; who="${who:-user}"
    echo "$who" >>"$FAKE_LOG"
    [[ "$who" == user && -n "${FAKE_DENY_USER:-}" ]] && { echo "access denied" >&2; exit 1; }
    [[ "$who" == root && -n "${FAKE_DENY_ROOT:-}" ]] && exit 1
    echo '{}' >"$FAKE_STATE" ;;
esac
SH
FAKE_SUDO="$WORK/sudo"
cat >"$FAKE_SUDO" <<'SH'
#!/bin/bash
FAKE_ROOT=1 exec "$@"
SH
chmod +x "$FAKE_TS2" "$FAKE_SUDO"
SUDO="$FAKE_SUDO"
export FAKE_STATE="$WORK/serve.json" FAKE_LOG="$WORK/funnel.log"
unpublish() { # → "<rc>|<off callers joined by ,>"; stderr → $WORK/unpublish.err
  local rc
  printf '%s' '{"Web":{"srv.example.ts.net:8443":{"Handlers":{"/abc":{}}}}}' >"$FAKE_STATE"
  : >"$FAKE_LOG"
  ( unpublish_path "$FAKE_TS2" "$HP" "/abc" ) >/dev/null 2>"$WORK/unpublish.err"; rc=$?
  printf '%s|%s' "$rc" "$(paste -sd, - <"$FAKE_LOG")"
}
check "sudo 없이 해제되면 sudo 를 쓰지 않는다" "0|user" "$(unpublish)"
check "sudo 없이 거부되면 root 로 재시도해 해제" "0|user,root" "$(FAKE_DENY_USER=1 unpublish)"
check "둘 다 거부되면 중단" "1|user,root" "$(FAKE_DENY_USER=1 FAKE_DENY_ROOT=1 unpublish)"
check "중단 안내의 수동 명령에 sudo" "1" \
  "$(grep -c "'sudo tailscale funnel --https=8443 --set-path=<경로> off'" "$WORK/unpublish.err")"
printf '%s' '{}' >"$FAKE_STATE"; : >"$FAKE_LOG"
( unpublish_path "$FAKE_TS2" "$HP" "/abc" ) >/dev/null 2>&1
check "걸려 있지 않은 경로는 off 를 부르지 않는다" "0|" "$?|$(paste -sd, - <"$FAKE_LOG")"

echo ""
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  echo "✓ $CASES cases passed"
else
  echo "✗ ${#FAILURES[@]}/$CASES failed: $(IFS=,; echo "${FAILURES[*]}")"
  exit 1
fi
