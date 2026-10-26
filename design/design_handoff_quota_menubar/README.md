# Handoff: Quota — macOS 메뉴바 Claude 사용량 표시 앱

## Overview
**Quota**는 macOS 메뉴바에 상주하며 Claude 사용량을 한눈에 보여주는 앱이다. 메뉴바에는 사용량 %에
따라 형태가 변하는 **작은 아이콘 + `NN%` 텍스트**가 표시되고, 아이콘을 클릭하면 애플 스타일의
**팝오버(popover)** 가 열려 5시간 한도·7일 한도·요금 상태를 자세히 보여준다.

## About the Design Files
이 번들의 파일들은 **HTML로 만든 디자인 레퍼런스(프로토타입)** 이다. 최종 룩앤필과 동작을 보여주는
목적이며, 프로덕션 코드로 그대로 복사해 쓰는 것이 아니다. 과제는 이 디자인을 **대상 앱의 실제 환경에서
재현**하는 것이다.
- 권장 환경: **SwiftUI + `MenuBarExtra`** (macOS 13+) 기반 메뉴바 앱. 아이콘은 SwiftUI `Shape`/`Path`
  또는 동적 생성 `NSImage`(template image)로, 팝오버 본문은 SwiftUI 뷰로 구현.
- 환경이 정해져 있지 않다면 위 스택을 채택하되, 이미 정해진 패턴/라이브러리가 있으면 그쪽을 따른다.
- 아이콘의 형태 계산식은 HTML 파일의 `makeStage(pct)` 함수에 모두 들어 있으니 그대로 이식하면 된다.

## Fidelity
**High-fidelity (hifi).** 색상·타이포·간격·상호작용이 확정된 픽셀 단위 목업이다. UI를 대상 코드베이스의
패턴으로 픽셀에 가깝게 재현할 것. 단, 팝오버의 **수치(리셋 시간, 모델별 %, 피크 시간 등)는 샘플값**이며
실제 데이터로 대체해야 한다(아래 "State / Data" 참고).

---

## Screens / Views

### 1) 메뉴바 아이콘 (Menu Bar Item)
- **Purpose**: 사용량을 항상 보이게. 아이콘 형태 + `NN%` 텍스트.
- **Layout**: 가로 배치 `[아이콘][4~5px gap][NN%]`. 아이콘은 약 16–18pt 정사각(레티나 대응).
  텍스트는 12.5px, weight 600, 등폭 숫자(`tabular-nums`).
- **동작**: 클릭 시 팝오버 토글. 열려 있을 때 아이콘 배경 하이라이트(`rgba(255,255,255,.16)`, radius 7).
- **아이콘 종류**: 설정에서 6종 중 택1 — `Donut / Ring / Eclipse / Battery / Liquid / Hamster`.
  각 형태의 상세 파라미터는 아래 "Icon Concepts" 참고.
- **색상**: `colorCoding` 설정이 켜져 있으면 사용량 3단계로 색이 바뀜.
  햄스터는 **예외 — 항상 단색**(형태만으로 구분).

### 2) 팝오버 (Popover) — 애플 스타일, 라이트 테마
- **Purpose**: 상세 사용량 확인.
- **컨테이너**: width **308px**. 배경 `rgba(251,251,253,.92)` + `backdrop-blur(24px) saturate(180%)`,
  테두리 `1px solid rgba(0,0,0,.08)`, radius **14px**, 그림자 `0 22px 50px -14px rgba(0,0,0,.32)`.
  상단에 아이콘을 가리키는 작은 45° 회전 사각형 화살표.
- **폰트**: `-apple-system, SF Pro Display/Text`.
- **섹션(위→아래, 각 섹션 사이 `1px solid rgba(0,0,0,.07)` 헤어라인)**:
  1. **헤더** (padding 15/18/13): 미니 링 아이콘(18px, 사용량 진행) + 앱명 **"Quota"**(15px/600, `#1d1d1f`)
     + 우측 상태 표시(초록점 `#34c759` 7px + "Off-peak" 12px `#86868b`).
  2. **주 게이지** (padding 22/18/18, 세로 중앙정렬): 지름 132px 활동 링
     — 트랙 `rgba(0,0,0,.07)` 8px, 진행 `pop.color` 8px `round` cap.
     중앙에 큰 숫자 `NN`(42px/600, `#1d1d1f`, letter-spacing -.03em) + `%`(17px/500, `#86868b`, baseline 하단 정렬).
     아래 캡션 "5시간 한도"(12px/600 `#86868b`) + "3시간 8분 후 초기화"(14px `#1d1d1f`).
  3. **7일 한도** (padding 15/18/18): 헤더행 "7일 한도"(12/600 `#86868b`) / "일요일 21:59 초기화"(12 `#a1a1a6`).
     행1 "전체 모델" + `NN%`, 진행바(높이 5px, radius 3, 트랙 `rgba(0,0,0,.08)`, 채움 `dayAll.color`).
     행2 "Fable 5" + "25%", 진행바 채움 `#af52de`(보라).
  4. **푸터** (padding 11/18): 좌 "표준 요금" / 우 "10시간 59분 후 피크", 둘 다 12px `#86868b`.

---

## Icon Concepts (형태 로직)
모든 아이콘은 사용량 `p = pct/100` (0.0–1.0) 로 계산. 채우는 방향은 **사용한 양** 기준(가득=거의 소진).
좌표는 HTML의 viewBox 기준값. `makeStage()`의 값을 그대로 사용.

- **Ring**: `viewBox 24`, cx/cy 12, r **8.5**, stroke-width 3, round cap. 둘레 C=53.4.
  진행 원의 `stroke-dashoffset = 53.4*(1-p)`, `transform rotate(-90 12 12)`. 트랙 `#eceae4`.
- **Donut**: Ring과 동일 구조지만 **두꺼움** — r **7**, stroke-width **6**. 둘레 43.98,
  `offset = 43.98*(1-p)`. 중앙에 `NN` 텍스트.
- **Eclipse(잠식 원반)**: r 9 원판을 `fill=color`. 오른쪽에서 그림자 원이 들어오며 잠식.
  마스크: 흰 배경 + 검은 원 `cx = 12 + 18*(1-p)`, cy 12, r 9.2. (`p=0` 원판 가득 → `p=1` 완전 잠식)
  최대 크기 표시용 얇은 트랙 원(stroke) 유지.
- **Battery**: 본체 rect x1.5 y7.5 w17 h9 rx2.2 (stroke), nib rect x19.4 y10 w1.7 h4.
  채움 rect x3 y9 h6, **width = 14*p**, fill=color.
- **Liquid(액체)**: 컨테이너 rounded rect x6.5 y2.5 w11 h19 rx3.5. 채움 rect,
  `y = 2.5 + 19*(1-p)`, `height = 19*p`, 컨테이너로 clip. 아래→위로 차오름.
- **Hamster(햄스터, 단색 고정)**: `viewBox 0 0 100 96`. **머리·귀는 고정**, **볼(양쪽 원)만 크기 변화**.
  - 실루엣(fill 단색 — 라이트 배경 `#2b2b30`, 다크 메뉴바 `#eceef2`):
    귀 `circle(31,24,r10)`,`(69,24,r10)` / 볼 `circle(28,60,r=cheekR)`,`(72,60,r=cheekR)` /
    머리 `circle(50,46,r27)`. **그리는 순서: 귀 → 볼 → 머리(맨 위)**.
  - **cheekR = 29 - 25*p** → `p=0`이면 29(빵빵), `p=1`이면 4(쪼그라듦). 사용량↑일수록 볼↓.
  - 이목구비(knock-out, 라이트=`#fbfbfd` / 다크=`#34343a`):
    눈 `ellipse(41,44,rx4.2,ry7)`,`(59,44,…)` / 코 삼각형 `M46 54 L54 54 L50 61 Z` /
    입 `circle(46.5,67,r3.8)`,`(53.5,67,r3.8)`.

### 색상 코딩 (Hamster 제외)
`colorCoding == true`일 때 사용량 3단계:
- `< 50%` → 초록 `#3f9e69`
- `< 80%` → 주황 `#d1962f`
- `>= 80%` → 빨강 `#cf3b2c`
`colorCoding == false` → 모든 아이콘 단색 `#2b2b30`(라이트) / 라이트톤(다크 배경).

---

## Interactions & Behavior
- **아이콘 클릭 → 팝오버 토글.** 외부 클릭 시 닫힘(표준 `NSPopover`/`MenuBarExtra(.window)` 동작).
- **애니메이션 (RunCat 스타일, 선택 구현)**:
  - *채움 전환*: 사용량 변경 시 링/도넛의 진행이 부드럽게 애니메이트(≈0.3s ease), 색도 단계 넘을 때 전환.
  - *소진 임박 알림*: 사용량 **≥ 90%** 이면 메뉴바 아이콘이 천천히 맥동
    (`scale 1 → 1.14 → 1`, 1.1s ease-in-out, 무한 반복).
    → 구현했다가 #120 에서 뺐다: 거의 보이지 않으면서 도는 동안 CPU 를 한 코어의 절반 넘게 썼고,
    같은 상황은 게이지의 빨강과 90% 시스템 알림이 이미 알린다.
- 팝오버 열림 시 아이콘 배경 하이라이트.

## State / Data
런타임 상태 및 연동 필요 지점(현재 모두 샘플값 → **TODO: 실제 API 연동**):
- `usage: Int` (0–100) — 5시간 한도 사용률. 메뉴바 %, 주 게이지, 아이콘 형태를 구동.
- `fiveHourResetIn: String` — "3시간 8분 후 초기화".
- `sevenDay.allModels: Int` (샘플: `round(usage*0.28)`) + `sevenDay.reset: "일요일 21:59"`.
- `sevenDay.models: [{name, pct}]` (샘플: Fable 5 = 25%).
- `rateState: {label: "표준 요금"/"피크", peakIn: "10시간 59분 후 피크"}`.
- 설정: `menubarConcept`(6종 enum, 기본 Hamster), `colorCoding: Bool`(기본 true), `showPopup: Bool`.

## Design Tokens
- **상태 색**: 초록 `#3f9e69` · 주황 `#d1962f` · 빨강 `#cf3b2c` · 단색 `#2b2b30`.
- **팝오버 텍스트**: primary `#1d1d1f` · secondary `#86868b` · tertiary `#a1a1a6`.
- **팝오버 면/선**: 배경 `rgba(251,251,253,.92)` · 헤어라인 `rgba(0,0,0,.07)` · 테두리 `rgba(0,0,0,.08)`
  · 트랙 `rgba(0,0,0,.07~.08)`.
- **강조**: 초록점 `#34c759` · Fable 보라 `#af52de`.
- **Radius**: 팝오버 14 · 진행바 3 · 아이콘 하이라이트 7.
- **Shadow**: 팝오버 `0 22px 50px -14px rgba(0,0,0,.32)`.
- **Typography**: `-apple-system / SF Pro`. 앱명 15/600, 큰 숫자 42/600(-.03em), 본문 14, 캡션 12,
  메뉴바 % 12.5/600 tabular-nums.

## Assets
- 아이콘은 전부 코드로 그린 벡터(SVG/Path) — 별도 이미지 에셋 없음.
- 참고용 레퍼런스 이미지(유사 앱 팝업 스크린샷, 햄스터 얼굴 스톡 이미지)는 저작권 문제로
  저장소에서 제외했습니다. 형태·색 로직은 아래 HTML 프로토타입만 보면 충분합니다.

## Files
- `Menubar Usage Icon.dc.html` — 전체 디자인 프로토타입. 아이콘 6종 × 단계별 미리보기, 메뉴바 목업,
  팝오버, 애니메이션 데모 포함. **형태·색 로직의 단일 출처는 `<script>` 안의 `makeStage()` / `renderVals()`**.
  (HTML을 브라우저로 바로 열어 확인 가능. 우측 Tweaks의 사용량 슬라이더로 전 상태를 미리볼 수 있음.)
