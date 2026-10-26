---
role: "빌드·테스트·스냅샷·릴리스 등 로컬 개발 명령어의 단일 권위 — 각 명령이 검증하는 대상의 설계 배경은 다루지 않음."
kind: operational
non_goals:
  - "코드 작성 기준 (docs/code-standards.md)"
  - "명령이 검증하는 구조의 설계 배경 (docs/architecture.md, docs/architecture-decisions.md)"
  - "영역별 세부 규약 (영역별 CLAUDE.md — 영역별 명령이 다르면 그쪽이 우선 권위)"
---

# 개발 명령어

macOS 26+ 와 Xcode **또는** Command Line Tools 만 있으면 된다. 외부 패키지 의존성이 없어 `swift build` 가 네트워크를 타지 않는다.

CLT 27.0 이상에서 `plugin for module 'SwiftUIMacros' not found` 가 나면 누군가 `@State` 를 새로 적은 것이다 — 수동 펼침으로 바꾼다 (Decision #11-2, `Views/CLAUDE.md`).

## 명령 요약

| 목적 | 명령 |
|---|---|
| 빌드 / typecheck | `swift build` (앱 + 서버 에이전트 두 타깃 모두) |
| 테스트 | `./scripts/test.sh` |
| lint | 별도 도구 없음 — `swift build` 경고가 대신한다 (경고 0 유지) |
| DB 마이그레이션 | 해당 없음 (DB 없음 — 영속 상태는 UserDefaults + Keychain) |
| 로컬 실행 | `./scripts/make_app.sh debug && open mongshell-menubar.app` |
| 시각 검증 (스냅샷) | `swift build && MONGSHELL_SNAPSHOT=/tmp/mongshell_snaps ./.build/debug/mongshell-menubar` |
| 배포용 dmg | `DEV_ID=… NOTARY_PROFILE=… ./scripts/release.sh` |
| 서버 에이전트만 빌드 | `swift build --product mongshell-openclaw-agent` |
| 서버 스크립트 문법 검사 | `bash -n server/*.sh` |
| 서버 에이전트 설치 (서버 맥) | `server/install.sh` — [server/README.md](../server/README.md) |

## typecheck

Swift 는 컴파일이 곧 타입 검사라 별도 typecheck 명령이 없다. **`swift build` 가 typecheck 명령이다.**

## 테스트

```bash
./scripts/test.sh
```

`scripts/test.sh` 는 컴파일 전에 grep 게이트를 먼저 돈다 — Keychain 의 `async` 진입점(`KeychainQueue`·`Credentials`·`GitHubCredentials`)에 `nonisolated(nonsending)` 이 빠졌으면 실패한다(#141; 진입점이 실제 Keychain 을 건드려 순서 테스트로는 덮지 못해서다, 규약은 `Services/CLAUDE.md`) 그 진입점을 대신하는 `UsageModel.Boundaries` 의 Keychain 클로저 넷도 같은 게이트를 지난다(#150; 순서 테스트의 가짜는 메인에서 돌아 수식어가 빠져도 보지 못한다). 게이트는 파일별로 수식어 달린 선언 수(`KeychainQueue` 1 · `Credentials` 4 · `GitHubCredentials` 4 · `UsageModel` 4)도 맞춰 보아, 선언이 여러 줄로 갈리거나 이름이 바뀌어 패턴에서 빠지면 실패한다 — 진입점을 더하면 `scripts/test.sh` 의 개수를 올린다.

`swift test` 가 **아니다.** `swift test` 는 XCTest 나 swift-testing 을 요구하는데 둘 다 Command Line Tools 에 들어 있지 않고, "Xcode 없이 빌드 가능" 은 이 프로젝트가 유지하는 전제다 (Decision #11-1). 대신 `scripts/test.sh` 가 `swiftc` 로 **실제 소스 파일과 테스트 파일을 함께 컴파일**해 실행한다 — 사본이 아니라 배포되는 코드를 그대로 검증한다.

그래서 `Package.swift` 에 test 타깃이 없는 것이 정상이다. 없다고 추가하지 말 것 — CLT 환경에서 빌드가 깨진다.

### 테스트 배치 컨벤션

- 테스트는 소스 옆(co-located)이 아니라 **`Tests/<대상>Tests/main.swift`** 에 둔다. `swiftc` 로 직접 컴파일하는 실행 파일이라 `@main` 없는 top-level 코드가 진입점이고, 소스 트리에 섞이면 `swift build` 가 앱 타깃에 함께 넣어버린다.
- 앱 쪽 테스트 대상을 추가하면 `scripts/test.sh` 의 `swiftc` 인자에 **그 대상이 의존하는 소스 파일을 직접 나열**해야 한다. 자동 탐색이 없다 — AppKit·Keychain·`@main` 을 끌어오는 파일을 빼야 하기 때문이다. `agent-tests` 만은 `main.swift` 를 뺀 에이전트 소스 전부를 glob 으로 모으므로, 에이전트 소스 파일을 더해도 목록을 고치지 않는다.
- 현재 커버리지는 여덟 묶음이다.
  - `Tests/ClaudeSettingsTests` — `ClaudeSettingsStore` / `ClaudeSettingsModel`. 불변식: **보이지 않는 설정을 앱이 파괴하지 않는다.**
  - `Tests/AuthTests` (실행 파일 `auth-tests`) — OAuth 토큰 경로 (`OAuthTokenClient`·`AuthError`)와 Claude Code 자격증명 해석(`CredentialStore.parseClaudeCodeJSON`, 읽기 결과 `ClaudeCodeTokenRead`). 불변식: **200 + `access_token` 만 토큰이 되고, 토큰이 되지 못한 2xx 의 실패 상세에는 바디 대신 최상위 키 이름(또는 크기)만 남으며, 죽은 refresh 토큰(`invalid_grant`)만 버리고 일시 오류·거부된 3xx 에는 살아 있는 토큰을 지키며, 본문은 200·400·401 에서만 읽어 `invalid_grant` 판정이 살아 있고 큰 오류 페이지는 상태 코드로 드러나며, 실제 응답 모양은 응답 상한(`Config.oauthTokenMaxResponseBytes`) 아래에 넉넉히 들어가고, `signedInAt` 이전에 저장된 토큰도 읽힌다. JSON `true`/`false` 는 `expires_in`·`expiresAt` 으로 읽히지 않는다. Claude Code Keychain 항목의 대화상자 취소(`errSecUserCanceled` 만)는 "토큰 없음" 과 따로 돌려주되 파일은 그대로 읽는다.**
  - `Tests/OpenClawAgentTests` (실행 파일 `agent-tests`) — 서버 에이전트의 소스 전부(glob, `main.swift` 는 진입점이라 제외). 불변식: **판정 규칙·복구 시점·자기 레이블 제외·공개 JSON 형식과 detail 필터가 조용히 바뀌지 않는다. 한 사이클의 순서 — 못 들은 probe 는 게시도 복구 계산도 하지 않고, 복구한 뒤 재probe 를 못 들어도 복구 기록을 복구 전 판정으로 먼저 게시한다(다음 프로세스의 쿨다운) — 와 옵션 규칙(필수·값 누락·주기 하한/상한, `--print-gateway-label` 은 `--status-file` 없이 돌고 `--self-label` 을 따름)이 바뀌지 않는다. 호스트 판정의 임계 경계(20% · 20GB · 5GB · 러너 전부/일부/0)와 전원·디스크·CI 러너 읽기 해석이 바뀌지 않고(극단값에 트랩하지 않고, 알 수 없는 전원 공급원을 ok 로 읽지 않고, `launchctl print` 의 최상위 `state` 만 보며, launchctl 을 듣지 못한 러너를 동작·중단 어느 쪽으로도 세지 않는다), 호스트 로그의 비교 키는 신호별 레벨이며, `host` 아래 문자열 값은 세 레벨 이름뿐이다.**
  - `Tests/OpenClawClientTests` (실행 파일 `client-tests`) — 앱의 `OpenClawStatusClient` / `OpenClawStatus` / `OpenClawHealth` / `ServerHost` / `ServerHostAlertWatch` / `TimeText` (`Palette` 는 점 색 때문에, `BoundedHTTP`·`DisplayText`·`JSONNumber`·`ResponseDate` 는 클라이언트가 응답을 읽는 데 쓰므로 함께 컴파일). 에이전트의 `Probe.swift`·`ProcessRunner.swift`·`HostProbe.swift`·`StatusFile.swift` 를 함께 컴파일해 에이전트 인코더 → 앱 파서 왕복을 검증한다. 불변식: **두 타깃의 JSON 키가 어긋나지 않고, 연락 두절(회색)과 게이트웨이 다운(빨강)이 섞이지 않으며, 서버 복구 알림은 새 복구에만 뜨며, 원격 문자열과 응답 크기는 상한 안에서만 받는다. 깨진 `host` 는 서버 점만 잃고 openclaw 판정은 남으며, 읽을 수 없는 레벨(모르는 문자열·문자열이 아닌 값)은 초록이 되지 않고, 전원의 원인 문구는 `pluggedIn: false` 일 때만 나오고 러너의 중단 문구는 개수가 보여줄 때만 나오며, 있을 수 없는 러너 개수(`running > total`, `total` 0, 정수 아님)는 러너 신호를 버리며, 서버 호스트 알림은 신호별 상승에 뜨고 쿨다운을 지키되 쿨다운에 눌린 상승은 버리지 않고 미루며, 통지 게이트가 닫힌 동안에는 아무것도 알린 것으로 세지 않는다.**
  - **두 타깃의 타입 이름은 겹치면 안 된다.** `client-tests` 는 앱 소스와 에이전트 소스를 한 모듈로 컴파일하므로, 양쪽에 같은 이름의 타입이 있으면 재선언 오류로 테스트가 컴파일되지 않는다 (`swift build` 는 타깃이 달라 통과한다). 그래서 같은 개념이라도 에이전트는 `HostLevel` / `HostStatus`, 앱은 `ServerHostLevel` / `ServerHost` 다.
  - `Tests/GitHubTests` (실행 파일 `github-tests`) — GitHub PR 영역(Decision #45)의 순수 판정(`GitHubPullRequest` / `GitHubMergePolicy` / `GitHubState` / `GitHubPresentation`)과 `GitHubAPIClient` 의 `interpret` / `parse` / 쿼리 문자열, `GitHubCredentials` 의 go-keyring 값 디코딩, 상태바 두 영역의 클릭 분배 판정 `RegionClickRouting` (#58) (`@MainActor` 모델은 제외). 불변식: **배지 우선순위·메뉴바 숫자·점 색·칩 접기·hover CI 줄(진행중 > 실패 > 통과·없음, 이미 실패한 PR 은 진행중으로 세지 않음)·폴링 주기(백오프 중엔 30초 주기 없음, 빠른 주기는 loaded + 60분 이내 running 일 때만)가 바뀌지 않고, 모르는 검사 값은 통과가 되지 않으며(완료 + 모르는 conclusion 은 failed, 모르는 status 는 queued), 401/403·429/2xx 외의 코드와 `data` 없는 본문은 빈 목록이 아니라 오류이고, gh 의 세 가지 저장 형태가 모두 토큰으로 풀린다. 머지 가능 판정이 팝오버 머지 버튼과 같고 진행·완료된 머지는 세지 않는다. GitHub 에서 온 문자열(PR 제목·레포 이름·검사 이름·머지 메시지)은 한 줄·글자 상한 안에서만 화면에 닿되 검사 재실행을 묶는 키는 원문으로 만들어 서로 다른 검사가 합쳐지지 않고, 정규화 후 레포 이름이 빈 PR 은 버려진다. 상태바 클릭은 GitHub 영역의 왼쪽 경계 x 하나로 갈려 경계 위·오른쪽(영역 사각형 밖 여백 포함)은 GitHub, 왼쪽과 영역이 꺼졌거나 프레임이 없을 때는 Claude 로 간다. 연결 상태마다 배지·배너·배너 버튼·토큰 행이 하나로 정해지고, PAT 를 쓰는 동안은 연결 상태와 상관없이 지울 수 있으며, PAT 저장에 실패한 직후에는 이전 토큰 출처와 상관없이 토큰 행이 "PAT 저장 실패" 이고 지우기 버튼이 없다 — 다음 새로고침이 Keychain 을 다시 읽어 행을 정한다 (#124). PR 행의 보조 배지(`PRSecondaryBadge`)는 검사가 진행 중이면(롤업 PENDING, 또는 목록이 잘려도 도는·대기 칩이 있으면) "검사 진행중", 승인됐는데 판정이 승인·머지 가능이 아니면 "승인" 이고 둘 다면 검사 진행중이 먼저이며, 팝오버의 막힘 개수는 목록과 같은 숨김 기준의 glance 를 쓴다 (#138).**
  - `Tests/UsageTests` (실행 파일 `usage-tests`) — `UsageAPIClient.parse` 와 그것이 채우는 `UsageSnapshot`, `AuthDebugLog` 의 usage 로그 줄·dedupe 키, 사용량 `Meter`, 클라이언트의 상태 코드 매핑과 본문 읽기 규칙, 그리고 `UsageModel` 에서 떼어 낸 순수 판정 — `UsageRetryPolicy`(429 대기)·`UsageRefreshPolicy`(토큰 선택·보류 토큰·401 → 갱신 → 재요청)·`UsageSession`(표시 상태 전이)·`UsageThresholdWatch`(임계 알림)·`UsagePresentation`(배지·배너·계정 행) (`Palette`·`TimeText`·`DisplayText`·`JSONNumber`·`BoundedHTTP`·`Config`·`Credentials`·`KeychainQueue`·`ResponseDate` 를 함께 컴파일; `@MainActor` 모델 `UsageModel` 자체는 제외). 불변식: **실제 응답 모양에서 session / weekly_all / weekly_scoped 가 읽히고, 5시간·7일 한도를 응답에서 찾지 못하면(`kind` 누락·개명, 숫자 아닌 percent) 0% 가 아니라 값 없음(nil)이고 그 창의 초기화 시각도 비며, 그 창의 flat 객체(`five_hour`/`seven_day`)가 있으면 그것으로 대신 읽고, 값 없음은 연결된 상태에서 형식 배너로 드러나며(Claude Code 계정 배너보다 앞서고 오류·요청 제한 배너는 가리지 않는다), 모르는 `kind` 의 `limits` 항목은 버려지지 않고 `extraLimits` 에 이름·percent·resetAt 으로 실리며(스코프 모델명은 weekly_scoped 행과 같은 표기 뒤에 kind 를 붙인다), `limits` 가 없는 flat 폴백에서는 `extraLimits` 가 비고, `unknownTopLevel` 과 로그 줄은 [docs/architecture.md § 1](architecture.md#1-사용량-폴링-주-경로) 의 필터 규칙 셋을 따르며, dedupe 키는 percent·utilization 이 움직여도 같고 kind·resets_at·버킷 집합이 바뀌면 다르고, 범위 밖·비유한 숫자는 트랩 없이 100/0/nil 로 접히며, 응답 문자열은 한 줄·글자 상한 안에서만 라벨과 로그에 닿고 개수 상한을 넘는 행은 버려지며, `Meter` 의 색은 남은 양 모드에서도 사용량 기준이고 색상 코딩이 꺼지면 위험도 색이 아니라 모노크롬이며, 401/403 은 재인증·429 는 `Retry-After` 백오프·거부된 3xx 는 HTTP 오류로 갈리고, 본문은 200 일 때만 읽어 큰 오류 페이지도 상태 코드로 드러나며, 실제 응답 모양은 응답 상한(`Config.usageMaxResponseBytes`) 아래에 넉넉히 들어간다. JSON `true`/`false` 는 퍼센트·크레딧 금액·지수로 읽히지 않고, `limits` 가 있는데 flat 객체로 대신 읽은 창은 로그 줄과 dedupe 키에 남는다. 판정 쪽은 — 429 대기·수동 새로고침 차단이 같은 창을 쓰고, 401 뒤 갱신·재요청의 각 결과가 로그아웃·로그인 만료·오류·백오프 중 정해진 하나로 가며, Keychain 이 잠긴 동안 Claude Code 토큰으로 넘어가지 않고, 갱신한 토큰을 Keychain 이 받지 못하면 버리지 않고 보류해 그것으로 폴링하며(거부 중에는 폴링마다 다시 저장, 잠김·대화상자 취소 중에는 메모리에서만), 다른 로그인·로그아웃이 끼어들면 보류를 버린다. 자체 토큰의 읽기·저장 대화상자 취소(`errSecUserCanceled` 만 — `errSecAuthFailed` 는 아니다)는 기억되어, 그 뒤 폴링은 자체 토큰 항목을 읽지도 저장하지도 않고 거부된 읽기와 같은 토큰 선택을 하며, 로그인·로그아웃·수동 새로고침([다시 허용]) 때에만 다시 읽는다. 그 해제 이전에 나간 읽기·저장이 해제 뒤 취소 응답을 들고 돌아와도 기억을 되살리지 않는다(`UsageSession.declineLifts`). 로그인 직후 Keychain 이 받지 못한 새 토큰도 버리지 않고 보류해 그것으로 폴링하며, 그 보류는 항목에 무엇이 있든 대신한다(`replacesAny`, #151). Claude Code CLI 항목의 대화상자 취소도 따로 기억되어 그동안 그 항목은 묻지 않고 파일만 읽으며, 같은 사용자 행동에만 풀린다(#155). 기억하는 동안 팝오버 배너는 그 사실과 그 대신 보이는 것(Claude Code 계정·보류 토큰 — 실제로 보류 토큰이 있을 때만·샘플)을 말하고 [다시 허용] 버튼을 달며, CLI 항목 취소는 샘플이 보일 때만 같은 배너로 드러나고, 샘플·Claude Code 계정·형식 배너보다 앞서되(형식 문제는 그 배너에 덧붙는다) 로그인 만료·불러오는 중·요청 제한·오류 배너는 가리지 않고, 배지와 계정 행은 그대로다. 저장 결과는 대화상자 취소를 실패와 따로 돌려주되 우리 삭제 뒤의 실패는 취소보다 앞선다. 로그인 만료(`invalid_grant`)는 Keychain 이 확인해 주지 못해도(잠김·거부·대화상자 취소 기억) 안내로 드러나되 그때는 항목을 지우지 않고, 다른 로그인·로그아웃으로 바뀐 것이 확인되면 안내를 띄우지 않으며, 안내가 떠 있는 동안의 거듭된 만료는 다시 알리지 않고, 안내가 내려간 뒤에도 이미 알린 refresh token — 보류 토큰이 만료됐으면 그 전 Keychain 토큰도 — 의 재만료는 알리지 않는다. 그 사이 Keychain 이 잠겨 읽히지 않아도 만료 안내는 오류 배너로 덮이지 않는다(`ownTokenUnreadable`). 로그인 만료 안내는 사용량 요청이 성공하거나 사용자가 로그인·로그아웃할 때까지 남고, 401·로그아웃은 직전 실제 숫자 대신 샘플을 보이며, 샘플의 초기화 시각은 샘플로 돌아갈 때마다 그 시각부터 다시 잡히고, 남은 시간 문구는 그리는 시계를 따르며 초기화 시각이 없으면 비고, 임계 알림은 레벨이 오를 때 한 번이다. 같은 actor 에서 차례로 부른 Keychain 작업은 부른 순서대로 한 번에 하나씩 메인 밖에서 돌고, 종료 대기는 앞서 오른 작업을 기다리되 상한에서 끝나며, 그 완료 콜백은 메인 큐 블록 안에 중첩된 런루프에도 닿는다.**
  - `Tests/UsageModelTests` (실행 파일 `usage-model-tests`) — `@MainActor` 모델 `UsageModel` 자체를 가짜 경계(`UsageModel.Boundaries`)와 함께 컴파일해, await 사이에 로그아웃·로그인·[다시 허용]·다른 refresh 가 끼어들 때의 최종 상태(Keychain 저장·삭제, 표시, 만료 알림 횟수)를 고정한다 (#150, Decision #150). 실앱 경계 `UsageModelLive.swift`(`AuthService`·`Notifier`·`Preferences`)는 빼고 나머지는 `usage-tests` 와 같은 목록이며, `AuthDebugLog` 줄이 실제 진단 로그에 섞이지 않게 `TMPDIR` 을 임시 디렉토리로 돌려 실행한다. 가짜 Keychain 은 `KeychainQueue` 처럼 부른 순서대로 효과를 내고 답만 붙잡아 두며, 테스트가 그 답을 붙잡은 채 다른 동작을 끝까지 돌린 뒤 놓아 준다. 불변식: **await 뒤에는 로그인 세대를 다시 확인한다 — 읽기 중 로그아웃이면 Claude Code 항목을 더 읽지 않고, 읽기·요청 중 로그아웃이면 그 결과를 보이지 않으며, 갱신 토큰을 들이는 중(확인·저장) 로그인이면 갱신을 버리고 새 로그인이 남고, 만료 토큰을 지우는 중(확인·삭제) 로그인이면 새 로그인을 지우지도 만료 안내를 띄우지도 않는다. 해제([다시 허용]·로그인·로그아웃) 이전에 나간 읽기의 취소 응답은 기억을 되살리지 않는다 — 로그인 세대를 올리는 곳은 모두 `declineLifts` 도 올린다. 같은 죽은 토큰의 재만료는 그 사이 안내가 내려갔어도 다시 알리지 않는다. 진행 중 refresh 에 겹친 요청은 겹쳐 돌지 않고 후속 한 번으로 합쳐진다. 로그인 저장을 취소하면 새 토큰을 보류해 그것으로 폴링하고(Claude Code 토큰으로 떨어지지 않는다) [다시 허용] 이 그것을 저장하며, 그 저장 중 로그아웃·다른 로그인이 끼면 보류하지 않고, 앞서 시작한 갱신이 그 보류를 지우지 않는다. 로그아웃의 삭제 실패는 그 사이 로그인 위에 오류로 뜨지 않고, 보류 토큰을 저장하는 중 로그아웃하면 다음 폴링이 그 토큰을 되살리지 않는다. Claude Code 항목의 취소는 기억되어 다음 폴링이 그 항목을 다시 묻지 않고(파일은 읽는다) [다시 허용] 이 다시 물으며, 해제 이전에 나간 그 읽기의 취소 응답은 기억을 되살리지 않는다.**
  - `Tests/ServerOptionsTests` (`main.sh` — Swift 가 아니라 bash 라 컴파일 없이 `bash` 로 실행) — 실제 `server/lib.sh` 를 source 해 `server/install.sh` 의 설치 옵션 규칙(`valid_interval` / `load_saved_options` / `resolve_options`)을 검증한다. 불변식: **우선순위는 명령줄 > 저장값 > 기본값(60초 · 자동복구 켬)이고, 깨진 저장값(숫자가 아님 · 30–86400 범위 밖 · 자릿수 초과 · `auto_heal` 이 0/1 이 아님)과 읽을 수 없는 `options` 파일은 경고 후 기본값으로 가되 설치를 중단시키지 않으며, `options` 파일의 내용은 실행되지 않는다.** 같은 파일이 에이전트 버전(`agent_version` — tag 위 `v1.2.0`, 그 뒤 `v1.2.0+N`, `v*` 외 tag 무시)과 빌드 진행 표시(`format_duration`, 빌드 pid 의 자손만 모으는 `process_tree` 와 링크 > 컴파일 > SDK 캐시 생성 순으로 고르는 `build_phase`)도 검증한다. 또 bash 와 에이전트가 함께 쓰는 값(주기 기본·하한·상한, 자기 레이블, 기본 게이트웨이 레이블)이 Swift 소스와 같은지, 그리고 funnel 포트 점검 `serve_handlers` 가 가짜 tailscale CLI 출력에 대해 빈 설정·`No serve config` 는 없음, 그 밖의 비-JSON 과 CLI 실패는 실패(fail-closed), 우리 포트의 웹 경로·TCP 포워딩·포그라운드 세션은 세고 다른 포트는 세지 않는지 검증한다 (#106).
- 서버 스크립트(`server/*.sh`)에서 자동 테스트가 있는 것은 위 `lib.sh` 의 규칙들뿐이다. 나머지 — 실제 tailscale serve/funnel 설정 조회와 경로 해제(`server/lib.sh` 의 `unpublish_path`; `serve_handlers` 의 출력 해석은 위처럼 가짜 CLI 로 검증하지만 실제 출력 모양은 실기로만 확인된다), `install.sh` / `uninstall.sh` 의 빌드·LaunchAgent 등록·토큰·공개 절차 — 는 tailscale 실기가 필요해 자동 테스트가 없다. `bash -n` 문법 검사와, 서버 맥에서의 설치 후 [server/README.md](../server/README.md) § 동작 확인이 검증 경로다.

## 로컬 실행

```bash
./scripts/make_app.sh debug && open mongshell-menubar.app
```

`swift run` 이나 `.build/debug/mongshell-menubar` 직접 실행은 **크래시한다** — UserNotifications 가 앱 번들을 요구한다. 스냅샷 렌더 모드(아래)만 예외적으로 맨 바이너리로 돈다.

`make_app.sh` 는 인자 없이 부르면 release 빌드다.

## 시각 검증 (스냅샷)

```bash
swift build && MONGSHELL_SNAPSHOT=/tmp/mongshell_snaps ./.build/debug/mongshell-menubar
```

`MONGSHELL_SNAPSHOT` 이 설정되면 앱이 메뉴바에 붙는 대신 오프스크린으로 PNG 를 렌더하고 종료한다 (`App/SnapshotRenderer.swift`). 30초 안에 끝나지 않으면 stderr 메시지와 함께 exit 1 — 멈춤이 실패로 드러난다. 이 프로젝트는 웹 UI 가 아니라 `.claude/browser-scenarios.md` 대상이 아니며, **UI 변경의 시각 확인은 이 경로가 담당한다.**

`Form` 기반 화면(설정창)은 `ImageRenderer` 로 빈 이미지가 나와 오프스크린 윈도우 캡처 경로를 쓴다 — 새 설정 UI 를 추가하면 그쪽에 등록한다.

산출물 (`<이름>.png`):

| 파일 | 내용 |
|---|---|
| `menubar_strip_dark` / `menubar_strip_light` | 메뉴바 — 사용량 레벨 3쌍 × openclaw 점 (정상 / 두절 / 다운), 마지막에 5시간 한도를 읽지 못한 경우(점선 회색 링, #130) |
| `menubar_host_strip_dark` / `menubar_host_strip_light` | 메뉴바 두 줄 스택 — 서버 점 없음(단일 표시, 비교 기준) → 서버 점 ok / warning / critical / 두절. 실제 메뉴바 두께(22pt)로 잘라 그리므로 넘치는 스택은 잘려 보인다 |
| `popover` | 팝오버 — openclaw 정상, 서버 섹션 없음 |
| `popover_host_on_battery` | 팝오버 — 서버 섹션, 어댑터가 빠진 서버 (전원 warning) |
| `popover_host_disk_critical` | 팝오버 — 서버 섹션, 배터리 없는 서버의 디스크 critical (전원 줄 없음) |
| `popover_host_runners_partial` | 팝오버 — 서버 섹션, CI 러너 일부만 동작 (러너 warning) |
| `popover_host_unreachable` | 팝오버 — 두절, 서버 섹션에 마지막 값이 흐리게 남음 |
| `popover_openclaw_unreachable` / `popover_openclaw_down` | 팝오버 — openclaw 두절 / 게이트웨이 다운 |
| `popover_extra_limit` | 팝오버 — 로그인된 상태(샘플 배너 없음)에서 7일 한도 아래에 앱이 모르는 `kind` 의 한도(설정 화면의 제한 초기화/보너스) 한 줄이 위험도 색 막대와 초기화 캡션으로 붙은 상태. `popover` 에는 없다 |
| `popover_usage_rate_limited` / `popover_usage_session_expired` / `popover_usage_error` / `popover_usage_cli_account` | 팝오버 — 사용량 배너가 상태마다 다른 모습: 요청 제한(N분 후 자동 재시도, 버튼 없음) / 로그인 만료(로그인 버튼) / 오류(재시도 버튼) / Claude Code 계정 사용 중. 숫자는 샘플이다 |
| `popover_usage_keychain_declined_cli_account` / `popover_usage_keychain_declined_held_login` / `popover_usage_keychain_declined_sample` | 팝오버 — 자체 토큰 대화상자 취소를 기억하는 동안(#143)의 배너 (#146): "Keychain 접근을 취소했어요 — " 뒤에 그 대신 보이는 것(Claude Code 계정 사용 중 / 저장 못 한 로그인으로 사용 중 / 샘플 데이터 표시 중)과 [다시 허용] 버튼. 숫자는 샘플이다 |
| `popover_usage_cli_keychain_declined_sample` | 팝오버 — Claude Code CLI 항목의 대화상자 취소만 기억하는 동안(#155) 볼 토큰이 없어 샘플이 보이는 상태: `popover_usage_keychain_declined_sample` 과 같은 배너와 [다시 허용] 이다(픽셀이 같아야 한다). 숫자는 샘플이다 |
| `popover_usage_keychain_declined_unread_cli_account` / `popover_usage_keychain_declined_unread_held_login` | 팝오버 — 취소를 기억하는 동안 응답에서 5시간 한도를 읽지 못한 상태 (#146): 취소 배너가 형식 배너를 가리지 않고 "Keychain 접근 취소 — … · 한도 형식 오류" 로 줄여 덧붙인 두 줄로 보이며 [다시 허용] 버튼은 그대로다. 게이지는 `popover_usage_unread_limits` 처럼 점선 회색 링과 "—" |
| `popover_usage_no_values` | 팝오버 — 5시간·7일 한도를 모두 읽지 못하고 초기화 시각도 없는 상태 (#133): 회색 링·"—" 아래에 "곧 초기화" 같은 초기화 문구가 없다 |
| `hover` / `hover_no_values` | Claude 영역 hover 요약 — 5시간·7일 두 줄(퍼센트 · 초기화 문구) / 값도 초기화 시각도 없어 "—" 만 남은 상태 (#133). 5시간 초기화 문구는 그릴 때 만들어지며, 스냅샷은 샘플의 초기화 시각을 렌더 시계에 고정해 "3시간 8분" 으로 그린다 |
| `popover_usage_unread_limits` | 팝오버 — 응답에서 5시간 한도를 읽지 못한 상태 (#130): 머리말·본 게이지가 점선 회색 링과 "—", "사용량 형식을 읽지 못했습니다" 배너(버튼 없음). 읽힌 7일 한도는 그대로 보인다 |
| `settings` / `settings_claude` / `settings_openclaw` / `settings_openclaw_down` | 설정창 |
| `github_menubar_strip_dark` / `github_menubar_strip_light` / `github_menubar_strip_zero_dark` / `github_menubar_strip_ci_dark` | 메뉴바 두 영역 — Claude 영역 뒤에 헤어라인 · GitHub 글리프 · 점 · 숫자 (3건·빨강 / 0건·초록 / 0건·주황 = CI 진행중) |
| `github_menubar_strip_merge_dark` / `github_menubar_strip_merge_light` | 메뉴바 두 영역 — 머지 가능한 내 PR 이 있어 글리프가 초록 merge 로 바뀐 상태 (Decision #52). `_zero_dark` 와 글리프 칸 밖은 픽셀 단위로 같아야 한다 (폭 불변) |
| `github_hover` | GitHub 영역 hover 요약 — CI 줄 + 내 PR 줄 + 머지 가능 줄, CI 경과 시간은 `frozenNow` 로 고정 |
| `github_popover` / `github_popover_overflow` / `github_popover_no_token` / `github_popover_unauthorized` | GitHub 팝오버 — gh CLI 로 연결됨 / 섹션 상한 초과("외 N건")와 빈 섹션("없음") / 토큰 없음 배너 / 401 배너. 진행중 칩의 경과 시간은 `frozenNow` 로 고정 |
| `github_popover_rate_limited` | GitHub 팝오버 — API 한도 초과 배너("N분 후 자동 재시도", #133). 남은 분은 `frozenNow` 로 고정. 헤더 ⋯ 메뉴의 새로고침은 배너 시각이 아니라 서버가 준 시각(없으면 백오프 시각)까지만 비활성이다(#154) — 메뉴가 닫힌 이미지라 보이지 않는다 |
| `github_popover_merge_failed` | GitHub 팝오버 — 내 PR 의 머지 가능 행에서 GitHub 가 squash 머지를 거절해 행 아래 빨간 사유 한 줄이 붙은 상태 (Decision #49). `github_popover` 에는 같은 행에 평상시 버튼이 보인다 |
| `settings_github` | 설정창 GitHub 섹션 (켜진 상태) |

서버 섹션이 있는 스냅샷(`popover_host_*`)은 제목 `오픈클로 서버` 옆에 `v1.2.0+3` 을 그린다 (Decision #81). openclaw 팝오버 스냅샷은 openclaw 가 채우는 마지막 섹션(서버 섹션, 없으면 openclaw 섹션) 맨 아래에 `오픈클로 서버 확인 …` 과 새로고침을 그린다.

## Claude Code 설정 편집 테스트

앱이 `~/.claude/settings.json` 을 실제로 읽고 쓴다. 개발 중에는 사본을 가리키게 한다.

```bash
MONGSHELL_CLAUDE_SETTINGS=/tmp/settings.json open mongshell-menubar.app
```

`scripts/test.sh` 는 이 변수를 케이스별로 직접 설정하며, 셸에서 상속된 값이 실제 파일을 가리키지 못하도록 실행 직전 `env -u` 로 지운다.

## 배포용 dmg

```bash
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="mongshell-menubar-notary" ./scripts/release.sh
```

앱 번들의 `CFBundleShortVersionString` 은 `make_app.sh` 가 빌드 시 가장 가까운 `vX.Y.Z` 태그에서 찍는다 (Decision #47) — `Resources/Info.plist` 의 `0.0.0` 은 자리표시다. 릴리스 빌드 전에 `git fetch --tags` 로 태그를 받아 둔다 — `release.sh` 는 번들 버전이 `0.0.0` 자리표시로 남으면 서명 전에 멈춘다.

`make_app.sh` 의 서명은 로컬 전용이다 — 남에게 주면 Gatekeeper 가 막는다. 서명 신원은 Apple Development 인증서가 있으면 그것이고, 없으면 팀 ID 가 없는 서명이라 빌드마다 Keychain 재승인이 필요하다 (Decision #68, 고르는 순서와 인증서 발급은 [README § 로컬 코드 서명 인증서](../README.md#키체인-프롬프트가-재빌드마다-다시-뜰-때--로컬-코드-서명-인증서)). 배포 준비물과 절차는 [README](../README.md) § 배포 참조.
