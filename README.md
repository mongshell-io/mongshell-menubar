# mongshell-menubar — macOS 메뉴바 Claude 사용량 표시 앱

맥 메뉴바에 Claude 사용량을 Claude 마크 + 7일 링 게이지(숫자 없음)와 초기화 시각으로 상시 표시하고,
클릭하면 7일 한도의 정확한 %와 초기화 시각, 모델별 주간 사용량, 계정 상태를 보여주는
팝오버가 열리는 메뉴바 앱입니다.

<img width="136" height="50" alt="image" src="https://github.com/user-attachments/assets/d01dd02e-0eff-4366-93ae-cb75ac4850f1" />
<img width="626" height="984" alt="image" src="https://github.com/user-attachments/assets/e988ab74-489b-4530-9bf4-4559608c125f" />



## 메뉴바 표시
**Claude 마크(테라코타 스타버스트)** + 7일 사용률을 **작은 링 게이지**로 컴팩트하게
표시합니다. 링은 사용한 만큼 채워지고, 색상 코딩 켜짐 시 사용량
3단계(초록 <50 · 주황 <80 · 빨강 ≥80)로 색칠됩니다. 링 옆에는 **초기화 요일과 시각(예: `금 22:59`)을
함께** 보여줍니다. 정확한 %와 모델별 사용량은 클릭 시 뜨는 팝오버에서 봅니다.
응답에서 한도를 읽지 못하면 0%(초록) 대신 **점선 회색 링**과 "—" 로 그리고, 팝오버에 "사용량 형식을
읽지 못했습니다" 배너가 뜹니다 — 비공식 엔드포인트의 형식이 바뀌었다는 신호입니다.

## openclaw 게이트웨이 상태 (선택 기능 — 상태 URL 설정 시에만 활성화)
[openclaw](https://openclaw.ai) 게이트웨이가 도는 **서버 맥**에 감시 에이전트를 설치하면
([server/README.md](server/README.md)), 에이전트가 판정·자동복구를 하고 결과를 공개 HTTPS
주소(`https://<서버>.ts.net:8443/<토큰>`)로 내놓습니다. 설정의 **서버** 섹션에 그 주소를
붙여넣고 **`Claude + 서버`** 를 고르면 게이트웨이·채널 건강 상태가 **같은 메뉴바
아이템에 통합**됩니다 — 사용률 오른쪽에 발자국 + 신호등(🟢 정상 / 🟡 채널 이상 / 🔴
게이트웨이 다운 / ⚪️ 서버 연락 두절)이 붙고, 팝오버 아래에 상태·채널·서버 확인 시각이
표시됩니다. 회색은 서버 소식이 끊겼다는 뜻일 뿐 게이트웨이 고장이 아닙니다(맥북이
오프라인이어도 빨간 점이 뜨지 않게). 앱은 읽기만 하며, 서버가 자동 재시작하면 알림으로
알려줍니다. **URL 이 없거나 `Claude만`을 고르면 이 요소는 메뉴바·팝오버 어디에도 나타나지
않고 기존과 100% 동일하게 동작합니다.**

에이전트는 **서버 맥 자체의 신호(전원·디스크 여유·CI 러너)** 도 함께 판정해 보냅니다. 서버가 이
신호를 보내면 발자국 + 점 아래에 서버 글리프 + 점(🟢 정상 / 🟡 주의 / 🔴 위험 / ⚪️ 서버
연락 두절)이 한 줄 더 쌓이고 — 메뉴바 폭은 늘지 않습니다 — 팝오버에 배터리·디스크 여유·CI 러너
대수를 보여주는 서버 섹션이 생깁니다. 어댑터가 빠지거나 디스크가 차거나 CI 러너가 멈춰 상태가 나빠지면 알림으로
알려줍니다. 따로 켜는 설정은 없고, 서버가 보내지 않는 신호(구버전 에이전트, 배터리 없는
서버의 전원, 러너 없는 서버의 CI 러너)는 자리 없이 사라집니다. 점 색의 기준은
[server/README.md](server/README.md#서버-점-전원디스크ci-러너) 에 있습니다.

**설치 가이드: [server/README.md](server/README.md)** — 서버 맥 준비부터 맥북 연결·운영·문제 해결까지
따라 하는 런북입니다. 요약하면:
1. 서버 맥에 brew 판 Tailscale 을 준비하고 `server/install.sh` 실행 (Tailscale 은 서버 맥에만)
2. 마지막에 출력되는 상태 URL(`https://…:8443/<토큰>`)을 비밀번호 관리자 등에 보관
3. 각 맥북의 메뉴바 앱 **설정 → 서버** 에 붙여넣고 `Claude + 서버` 선택

## Claude Code 설정 (선택 기능 — `~/.claude` 가 있을 때만 활성화)
설정창의 **Claude Code** 섹션에서 `~/.claude/settings.json` 을 직접 편집합니다 — 기본 모델,
추론 강도, 대체 모델, 컨텍스트 자동 압축, 권한 기본 모드. 각 항목에 무엇을 바꾸는 값인지
한글 설명이 붙어 있고, 추론 강도·권한 모드 선택지에는 문서·CLI 와 대조할 수 있게 실제
값(`xhigh`, `auto` …)을 함께 표기합니다.

권한 기본 모드는 `ask`/`auto`/`deny` 만 제공합니다 — `allow`(전부 허용)는 오클릭 위험 때문에
GUI 에서 뺐습니다. 파일에 이미 `allow` 나 앱이 모르는 값(고정 모델 ID 등)이 들어 있으면
"직접 설정한 값"으로 그대로 보여주고 유지하므로, 설정창을 열었다는 이유로 값이 바뀌지는
않습니다.

Claude Code 는 설정 파일을 감시하므로 **대부분 실행 중인 세션에도 즉시 반영**되고, `model`
만 새 세션부터 적용됩니다. 반대로 CLI 쪽 변경(`/effort`, `/fast`)도 파일 감시로 설정창에
바로 반영됩니다.

저장은 **read-modify-write** 입니다 — 저장 직전 파일을 다시 읽어 위 5개 키만 교체하므로
권한 목록·플러그인 설정 등 앱이 모르는 키는 값이 그대로 보존됩니다(다만 파일 전체가 키
정렬된 형태로 다시 쓰이므로 손으로 잡아둔 키 순서·들여쓰기는 유지되지 않습니다). 직전
내용은 가능한 경우 `settings.json.bak` 로 한 부 남습니다. 기본값으로 되돌리면 값을 쓰는
대신 **키를 삭제**합니다. `hooks`·`env`·MCP 같은 자유형 키는 의도적으로 다루지 않습니다.

> 개발 중에는 `MONGSHELL_CLAUDE_SETTINGS=<경로>` 로 실제 설정 파일 대신 사본을 쓰게 할 수
> 있습니다.

## GitHub PR 진행 상황 (선택 기능 — 설정에서 켠 경우에만)
설정의 **GitHub 표시** 를 켜면 Claude 영역 오른쪽에 세로 헤어라인으로 나뉜 **두 번째 영역**이
생깁니다 — PR 글리프 + 신호등 점 + 내 PR 중 막힌 것의 수. 머지할 수 있는 내 PR 이 있으면 글리프가 초록 알약 배지로 바뀝니다. 점은 막힌 PR 이 있으면 🔴,
막힌 것 없이 검사가 도는 중이면 🟡, 할 일이 없으면 🟢(🟡·🟢 는 숫자 없이 점만), 토큰이
없거나 거부되면 ⚪️ 입니다. hover 하면 두 줄 요약(내 PR 의 CI 진행 — 가장 오래 돈 검사와
경과 시간 — 과 내 PR 의 막힘), 클릭하면 내 PR·최근 7일 머지 두 섹션과 PR 별 배지(충돌 /
검사 실패 / 변경 요청 / Draft / 리뷰 대기 / 승인 / 머지 가능), 검사별 칩과 소요시간이
보입니다. 쓰기 동작은 하나뿐입니다 — GitHub 가 머지
가능(`CLEAN`)으로 판정한 내 PR 행의 **#N 머지**(squash) 버튼으로, 누르면 확인 없이 바로
실행됩니다. 누른 순간 화면에 보인 커밋이 그대로일 때만 머지됩니다. 앱은 브랜치를 지우지
않으며, 저장소의 자동 삭제 설정을 따릅니다. 승인·코멘트·다른 머지 방식은 없습니다.

토큰은 설정에 붙여넣은 classic PAT(`repo` 권한)가 있으면 그것을 먼저 쓰고, 없으면 **gh CLI
로 로그인되어 있을 때 그 Keychain 항목을 재사용**합니다(첫 켤 때 "키체인 접근 허용"
프롬프트). 둘 다 각자
Keychain 에만 있고 `api.github.com` 외 어디에도 보내지 않습니다. 갱신은 GitHub 공식
GraphQL API 요청 1회(3분 주기, 설정 1~10분; 팝오버를 열면 즉시, 정상 상태에서 내 PR 에 막 시작한
(60분 이내) 실행중 검사가 있으면 팝오버를 열지 않아도 30초)이며 시간당 5,000 포인트 한도에서 요청당 1 포인트 안팎입니다. **기본값은 꺼짐이고,
꺼져 있으면 메뉴바·팝오버 어디에도 흔적이 없습니다** — 폭을 늘리는 유일한 예외라서,
켠 사람만 그 폭(약 52pt)을 치릅니다
([PHILOSOPHY § Admission Criteria 4 의 예외](docs/PHILOSOPHY.md#admission-criteria)).

## 설치 — 각자 빌드해서 쓰기 (Apple 계정 불필요)
직접 빌드한 앱은 Gatekeeper에 막히지 않습니다. 필요한 건 **macOS 26+ 와 Xcode
(또는 Command Line Tools)** 뿐.
```bash
git clone <이 저장소 URL> && cd mongshell-menubar
./scripts/make_app.sh          # release 빌드 → mongshell-menubar.app 생성(로컬 서명)
open mongshell-menubar.app                 # 메뉴바에 아이콘 등장
```
처음 실행하면:
- **Claude Code 사용자**: "키체인 접근 허용" 프롬프트 → *항상 허용* → 바로 실제 사용량 표시.
- 그 외: 팝오버의 **로그인** → 브라우저에서 Claude 로그인·승인 → 자동 복귀.
- **GitHub 표시** 를 켜면 gh CLI 의 Keychain 항목(`gh:github.com`)에도 같은 프롬프트가 한 번
  더 뜹니다 → *항상 허용*. 거부하면 그 세션 동안은 다시 묻지 않고 설정에서만 재시도합니다.

> `swift run`으로 맨 바이너리를 직접 실행하면 UserNotifications가 앱 번들을 요구해
> 크래시합니다. 항상 `.app` 번들(`make_app.sh`)로 실행하세요.

> 재빌드할 때마다 키체인 프롬프트(Claude Code 항목, GitHub 표시를 켰다면 gh 항목까지)가
> 다시 뜬다면 앱 서명에 팀 ID 가 없기 때문입니다. 무료 Apple ID 로 없앨 수 있습니다(선택) —
> [로컬 코드 서명 인증서](#키체인-프롬프트가-재빌드마다-다시-뜰-때--로컬-코드-서명-인증서) 참고.

### 개발용
```bash
./scripts/make_app.sh debug && open mongshell-menubar.app          # 디버그 빌드
./scripts/test.sh                                                  # 회귀 테스트 전체 (묶음 목록은 docs/development.md § 테스트)
swift build && MONGSHELL_SNAPSHOT=/tmp/mongshell_snaps ./.build/debug/mongshell-menubar   # 아이콘/팝오버·설정창 PNG 렌더
```

#### 키체인 프롬프트가 재빌드마다 다시 뜰 때 — 로컬 코드 서명 인증서
**팀 ID 가 없는 서명(ad-hoc, 자기 서명 인증서)은 재빌드할 때마다** 키체인 프롬프트가 다시
뜹니다. 키체인이 그런 앱을 빌드마다 바뀌는 바이너리 해시로 알아보기 때문입니다. 대상은
`Claude Code-credentials`, 앱 자체 로그인 토큰(`com.mongshell.menubar.tokens`), GitHub 표시를
켰다면 gh 의 `gh:github.com` 항목입니다. 여기서 거부하면 앱이 토큰을 못 읽어 로그인을 다시 하라고
보입니다. 키체인이 앱을 알아보는 방식과 이 선택이 넓히는 범위는
[Decision #68](docs/architecture-decisions.md#decision-68-로컬-빌드는-팀-id-가-있는-apple-development-인증서로-서명한다)
이 권위입니다.

`make_app.sh` 는 이 순서로 서명 신원을 고릅니다.

1. `SIGN_ID` 환경변수로 넘긴 신원
2. 키체인의 유효한 **Apple Development** 인증서 — 팀 ID 가 있어 *항상 허용* 이 재빌드 후에도 유지됩니다
3. 자기 서명 인증서 `mongshell-menubar Dev` — 팀 ID 가 없어 재빌드 프롬프트는 막지 못합니다
4. ad-hoc 서명(`--sign -`)

**Apple Development 인증서 만들기 (만료 시 같은 절차로 재발급).** 유료 Apple Developer 계정은
필요 없습니다. 무료 Apple ID 로 Xcode 가 개인 팀(Personal Team)의 Apple Development 인증서를
발급합니다. Xcode 는 이 발급과 만료 시 재발급에만 필요하고, 빌드는 계속 Command Line Tools 로
됩니다.

1. Xcode → Settings → Accounts 에서 Apple ID 를 추가합니다.
2. 그 계정을 고르고 **Manage Certificates…** → `+` → **Apple Development** 를 누릅니다.
3. 인증서가 보이는지 확인합니다.
   ```bash
   security find-identity -v -p codesigning   # "Apple Development: …" 가 보이면 됩니다
   ```
4. `./scripts/make_app.sh` 를 실행합니다. 로그에 `▶ codesign (Apple Development: …)` 가 찍힙니다.

서명이 바뀐 직후 처음 실행하면 키체인 프롬프트가 항목마다 한 번씩 더 뜹니다. 여기서 *항상 허용*
을 누르면 그 뒤로는 재빌드해도 묻지 않습니다. 팀 ID 가 찍혔는지는 이렇게 확인합니다 —
`TeamIdentifier=not set` 이 아니라 팀 ID 가 나와야 합니다.
```bash
codesign -dv mongshell-menubar.app 2>&1 | grep TeamIdentifier
```

**알고 쓰셔야 할 것.** Xcode 가 만든 개인 키는 접근 목록에 `codesign` 이 이미 들어 있어, 빌드할
때 묻지 않습니다. 그 말은 이 맥에서 같은 사용자로 도는 어떤 프로그램이든 묻지 않고 이 인증서로
서명할 수 있다는 뜻입니다. 그런 프로그램은 이 앱의 신원을 흉내 낸 바이너리를 만들어 앱이 저장한
로그인 토큰과 GitHub PAT 를 프롬프트 없이 읽을 수 있습니다. 이 설정으로 새로 열리는 범위와
수용한 근거는 Decision #68 에 있습니다.

재발급한 인증서의 이름이 같으면 키체인 허용도 그대로 유지됩니다. 다시 묻는다면 항목마다 한 번
*항상 허용* 하면 됩니다.

자기 서명 인증서 `mongshell-menubar Dev` 를 이미 만들어 두셨다면 지워도 됩니다. 팀 ID 가 없어
재빌드 프롬프트를 막지 못합니다. 다른 이름의 인증서를 쓰려면
`SIGN_ID="<인증서 이름>" ./scripts/make_app.sh` 로 넘기세요. 배포용 `release.sh` 는 Developer ID
로 다시 서명하므로 영향받지 않습니다.

테스트는 `swift test` 가 아니라 `scripts/test.sh` 입니다 — `swift test` 는 XCTest 나
swift-testing 을 요구하는데 둘 다 Command Line Tools 에 들어 있지 않아서, Xcode 없이 빌드
가능하다는 이 프로젝트의 전제와 맞지 않습니다. 대신 실제 소스 파일을 그대로 컴파일해
검증합니다. 테스트 묶음과 각 묶음이 지키는 불변식은
[docs/development.md § 테스트](docs/development.md#테스트) 가 권위입니다.

## 구조
```
Sources/mongshell-menubar/
  MongshellMenubarApp.swift            @main (Settings 씬은 비어 있음, ⌘, 는 실제 설정창으로 연결 — UI는 상태바+팝오버)
  App/AppDelegate.swift     NSStatusItem + NSPopover + 설정창 관리
  App/RegionClickRouting.swift 클릭을 Claude·GitHub 영역 중 어디로 보낼지 판정(순수 함수)
  App/SnapshotRenderer.swift 오프스크린 PNG QA 렌더러(MONGSHELL_SNAPSHOT)
  Views/ClaudeMarkView.swift Claude 스타버스트 마크 Canvas 렌더러
  Views/MenuBarIconView.swift 상태바 마크 + 7d 링 게이지(+초기화 요일·시각,
                            읽지 못한 한도는 점선 회색 링), openclaw 신호등
                            (+ 그 아래 서버 호스트 신호등), 다크/라이트 적응
  Views/HoverSummaryView.swift hover 즉시 요약(7d · 초기화 3열 Grid)
  Views/PopoverView.swift   라이트 팝오버 308px(주간/세부 한도 + openclaw 섹션
                            + 서버 섹션)
  Views/PopoverHeader.swift 두 팝오버가 함께 쓰는 머리말(제목·연결 배지·⋯ 메뉴)
  Views/PopoverBanner.swift 두 팝오버가 함께 쓰는 머리말 아래 한 줄 배너
  Views/SettingsView.swift  일반(자동 실행)·메뉴바·업데이트(폴링·알림)·Claude Code·서버·GitHub·계정
  Views/ClaudeSettingsSection.swift  settings.json 편집 섹션(한글 설명 캡션)
  Views/OpenClawSettingsSection.swift openclaw 상태 URL 입력·상태·확인 간격 섹션
  Views/GitHubMenuBarView.swift      두 번째 영역(헤어라인 · PR 글리프 · 점 · 숫자)
  Views/GitHubHoverSummaryView.swift GitHub 영역 hover 두 줄 요약(CI · 내 PR)
  Views/GitHubPopoverView.swift      GitHub 팝오버(배너 + 내 PR/최근 머지 섹션, 검사 칩)
  Views/GitHubSettingsSection.swift  GitHub 표시 토글·토큰·PAT·갱신 주기·레포 숨기기
  Design/Palette.swift      색 토큰 SSOT(사용량 3단계·팝오버 표면/텍스트)
  Models/…                  Preferences, UsageState(UsageSnapshot·LoadState·429 대기 규칙),
                            UsageModel(폴링 루프·토큰 갱신·보류 토큰 저장·로그인/로그아웃 조율),
                            UsageSession(사용량 표시 상태와 세션 플래그의 전이·임계 알림 판정),
                            UsageRefreshPolicy(토큰 선택·보류 토큰·401 → 갱신 → 재요청 판정),
                            UsagePresentation(사용량 배지·배너·버튼·계정 행 판정),
                            OpenClawHealth, OpenClawStatus(두절 판정·복구 알림 판정),
                            ServerHost(서버 호스트 신호 값 타입·표시 문구),
                            ServerHostAlertWatch(전원·디스크·CI 러너 알림 판정),
                            OpenClawModel(상태 URL 폴링/복구·서버 호스트 알림),
                            GitHubPullRequest(PR 배지·메뉴바 숫자·점·칩 접기 판정),
                            GitHubMergePolicy(머지 버튼 노출·요청·머지 상태 이월 판정),
                            GitHubState(연결 상태·스냅샷·폴링 주기 규칙),
                            GitHubPresentation(GitHub 연결 배지·배너·버튼·토큰 행 판정),
                            GitHubModel(토큰 결정·GraphQL 폴링·팝오버 열림 주기·머지),
                            ClaudeSettingsModel(settings.json ↔ 구조체),
                            LoginItemModel(로그인 항목 상태 캐시/안내)
  Services/…                Config, Credentials(Keychain), UsageAPIClient, AuthService(PKCE),
                            AuthError, AuthDebugLog(토큰 경로·응답 형식 변화 진단 로그),
                            LoopbackServer(OAuth 루프백 리다이렉트 수신),
                            OAuthTokenClient(토큰 교환·갱신 요청),
                            Notifier(알림 센터 단일 경계 — 보낼지는 모델이 정함),
                            BoundedHTTP(리다이렉트 거부·바이트 캡 전송 공용),
                            TimeText(시간 표기), DisplayText(외부 문자열 한 줄·길이 상한),
                            JSONNumber(JSON 숫자 읽기 — bool 은 숫자 아님), ResponseDate(ISO 8601 읽기),
                            OpenClawStatusClient(상태 URL HTTPS 읽기/관대한 디코딩),
                            GitHubAPIClient(GraphQL 1요청·응답 해석), GitHubCredentials(자체 PAT → gh Keychain),
                            ClaudeSettingsStore(settings.json 입출력/파일 감시),
                            LoginItemService(SMAppService 로그인 항목 등록)

Sources/mongshell-openclaw-agent/     서버 맥용 에이전트 (server/README.md)
  main.swift                진입점 — 옵션 결과 처리·로그·게시(호스트 판정 + 상태 파일 쓰기)·루프
  Options.swift             실행 인자 파싱 (순수 함수)
  AgentCycle.swift          한 사이클: probe → 복구 → 재probe → 게시 (바깥 세계는 주입)
  Probe.swift               `openclaw channels status --probe` 실행·판정
  ProcessRunner.swift       시간 제한 있는 외부 명령 실행 (새 프로세스 그룹, 정리)
  Heal.swift                자동복구 시점 판정, 게이트웨이 레이블 탐색·kickstart
  HostProbe.swift           전원(IOKit)·디스크 여유 읽기 + 호스트 판정 규칙(HostRules)
  StatusFile.swift          공개 상태 JSON 인코딩·원자적 쓰기
```

## 데이터 소스 & 인증
- **인증 우선순위**: 자체 OAuth 로그인 토큰(Keychain) → 없으면 Claude Code CLI 토큰
  (Keychain `Claude Code-credentials` 또는 `~/.claude/.credentials.json`) 자동 감지.
  - Claude Code 사용자는 **로그인 없이** 앱이 기존 토큰을 재사용합니다. 다른 앱이 그 항목을
    읽으므로 **첫 실행 시 "키체인 접근 허용" 프롬프트**가 뜹니다 → "항상 허용".
  - Claude Code가 없으면 **OAuth 로그인**: 브라우저가 열리고 로그인·승인하면 로컬 루프백
    리스너로 **자동 복귀**합니다. 루프백 리다이렉트가 거부되면 콘솔 콜백 페이지에 표시되는
    인증 코드를 앱에 붙여넣는 방식으로 폴백합니다.
- **엔드포인트**: `GET https://api.anthropic.com/api/oauth/usage`.
  - 헤더: `Authorization: Bearer …`, `anthropic-beta: oauth-2025-04-20`,
    **`User-Agent: claude-code/<version>` (필수 — 없으면 429 도배)**.
  - 응답: `limits` 배열의 `weekly_all`(7일)·`weekly_scoped`(모델별) 행의
    0–100 % + 초기화 시각. 행이 없으면 `seven_day` 객체로 대신 읽고, 둘 다 없으면
    그 한도는 비워 둡니다(0% 로 보이지 않음). 폐지된 5시간 한도(`session`·`five_hour`)가 남아 와도 무시합니다. 자세한 규칙은
    [docs/architecture.md](docs/architecture.md) § Data Flow 1.
- **폴링**: 기본이자 최소 180초(설정에서 3·5·10·15분). 429 시 지수 백오프.
- **토큰은 각자 Keychain에만 저장**, 외부 서버로 절대 전송하지 않습니다.
- **GitHub PR 영역(켠 경우)**: 토큰은 자체 PAT(Keychain) → gh CLI 의 Keychain 항목
  `gh:github.com` 순. 엔드포인트는 GitHub **공식** GraphQL API
  `POST https://api.github.com/graphql` 하나이며, 리다이렉트를 따르지 않아 토큰이 다른
  호스트로 가는 경로가 없습니다. 자세한 흐름은 [docs/architecture.md](docs/architecture.md)
  § Data Flow 4.

## ⚠️ 배포 전 반드시 알아둘 것 (비공식 도구)
- Claude **구독(Pro/Max) 한도에는 공식 API가 없습니다.** 위 엔드포인트는 **비공개**이며
  예고 없이 변경·차단될 수 있습니다.
- 자체 OAuth는 Claude Code의 client_id/User-Agent를 사용 → **공식 클라이언트 사칭 성격의
  ToS 회색지대**입니다. 공개 배포·사용은 본인 책임입니다.
- 엔드포인트/스키마/헤더와 OAuth 파라미터는 커뮤니티 리버스엔지니어링으로 확인된 실제 값을
  사용합니다. 로그인·토큰이 없으면 UI는 샘플 데이터로 렌더됩니다.

## 배포 (지인에게 서명된 dmg 공유)
`scripts/make_app.sh`는 로컬 개발용 서명(Apple Development 인증서가 없으면 팀 ID 없는 서명)
까지만 하므로, 남에게 주면 Gatekeeper가 차단합니다. 서명·공증된 `.dmg`는 `scripts/release.sh`로 만듭니다.

**준비물(1회):** Apple Developer 계정($99/년) + **Developer ID Application** 인증서.
```bash
# 인증서 확인
security find-identity -v -p codesigning
# 공증 자격증명 저장(앱 암호는 appleid.apple.com에서 발급)
xcrun notarytool store-credentials mongshell-menubar-notary \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
```
**릴리스:**
```bash
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="mongshell-menubar-notary" scripts/release.sh
# → mongshell-menubar.dmg 생성. 받는 사람은 Applications로 드래그 후 실행.
```
정식 Developer ID로 서명하면 **로그인 토큰이 업데이트 후에도 유지**됩니다(팀 ID 가 없는
서명은 빌드마다 키체인 재승인이 필요). 각 사용자는 자기 Claude 계정으로 로그인하며, 토큰은 각자
Keychain에만 저장됩니다.

> **주의:** 이 앱은 Claude Code의 client_id/User-Agent와 비공개 엔드포인트를 사용하는
> 비공식 도구입니다(ToS 회색지대). 공유·사용은 본인 책임이며, 위 README의 경고를 함께
> 전달하세요.
