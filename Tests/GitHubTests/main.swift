import Foundation

// Tests for the GitHub PR region (Decision #45): the pure judgements the
// menu bar, hover and popover are made of — badge priority, the menu-bar
// count and dot, hover wording, check-chip folding, the duration format, the
// poll cadence — plus the GraphQL client's tolerant decoding, its
// status-code / header reading, the query it sends, and the gh CLI
// Keychain value decoding.
//
// Each case pins a rule whose mutation would change what a user sees.
// Run with `./scripts/test.sh`, which compiles this against the real sources
// (the @MainActor model is left out, as for the other bundles).

var failures: [String] = []
var caseCount = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    caseCount += 1
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

let now = Date(timeIntervalSince1970: 1_790_000_000)

func pr(_ repo: String = "mongshell/bookdam", _ number: Int = 45,
        draft: Bool = false,
        review: PRReviewDecision = .none,
        mergeable: PRMergeable = .mergeable,
        merge: PRMergeState = .unknown,
        rollup: PRChecksRollup = .success,
        checks: [PRCheck] = [],
        complete: Bool = false,
        nodeID: String? = nil, headSHA: String? = nil,
        linked: Bool = true) -> GitHubPullRequest {
    GitHubPullRequest(repository: repo, number: number, title: "t",
                      url: linked ? URL(string: "https://github.com/\(repo)/pull/\(number)") : nil,
                      isDraft: draft,
                      reviewDecision: review, mergeable: mergeable, mergeState: merge, checksRollup: rollup,
                      checks: checks, checksListComplete: complete, updatedAt: now, mergedAt: nil,
                      nodeID: nodeID, headSHA: headSHA)
}

func chk(_ name: String, _ outcome: PRCheckOutcome, start: TimeInterval? = 0, end: TimeInterval? = 60) -> PRCheck {
    PRCheck(name: name, outcome: outcome,
            startedAt: start.map { now.addingTimeInterval($0) },
            completedAt: end.map { now.addingTimeInterval($0) }, url: nil)
}

func snap(mine: [GitHubPullRequest] = [], merged: [GitHubPullRequest] = []) -> GitHubSnapshot {
    GitHubSnapshot(mine: mine, recentlyMerged: merged,
                   rateLimit: nil, fetchedAt: now, tokenScopesLackRepo: nil)
}

func verdict(_ p: GitHubPullRequest) -> PRVerdict {
    PRVerdict.of(p)
}

// MARK: - 1. 배지 우선순위

print("▸ 배지 우선순위")
do {
    check("충돌 + 검사 실패 → 충돌",
          verdict(pr(mergeable: .conflicting, rollup: .failure)) == .conflict)
    check("검사 실패 + 변경 요청 → 검사 실패",
          verdict(pr(review: .changesRequested, rollup: .failure)) == .checksFailed)
    check("변경 요청 + Draft → 변경 요청",
          verdict(pr(draft: true, review: .changesRequested)) == .changesRequested)
    check("검사 실패 + Draft → 검사 실패",
          verdict(pr(draft: true, rollup: .failure)) == .checksFailed)
    check("mergeable unknown → 충돌 아님 (리뷰 대기)",
          verdict(pr(mergeable: .unknown)) == .awaitingReview)
    check("리뷰 판정 없음·검사 통과 → 리뷰 대기",
          verdict(pr(review: .none)) == .awaitingReview)
    check("reviewRequired → 리뷰 대기",
          verdict(pr(review: .reviewRequired)) == .awaitingReview)
    check("우선순위 = 선언 순서 (min 이 이김)",
          [PRVerdict.draft, .conflict, .approved].min() == .conflict
              && PRVerdict.conflict < .checksFailed && PRVerdict.checksFailed < .changesRequested
              && PRVerdict.changesRequested < .draft
              && PRVerdict.draft < .awaitingReview && PRVerdict.awaitingReview < .approved
              && PRVerdict.approved < .mergeable)
}

// MARK: - 2. 머지 가능 / 승인

print("▸ 머지 가능과 승인")
do {
    check("승인 + rollup success + mergeable → 머지 가능",
          verdict(pr(review: .approved, mergeable: .mergeable, rollup: .success)) == .mergeable)
    check("승인 + 검사 없음(none) + mergeable → 머지 가능",
          verdict(pr(review: .approved, mergeable: .mergeable, rollup: .none)) == .mergeable)
    check("승인인데 검사 진행중 → 승인",
          verdict(pr(review: .approved, rollup: .pending)) == .approved)
    check("승인인데 mergeable unknown → 승인",
          verdict(pr(review: .approved, mergeable: .unknown)) == .approved)
    check("승인 아님 + 검사 통과 + mergeable → 머지 가능 아님",
          verdict(pr(review: .reviewRequired)) != .mergeable)
}

print("▸ mergeStateStatus")
do {
    check("리뷰 규칙 없음 + CLEAN + 검사 없음 → 머지 가능 (혼자 쓰는 저장소)",
          verdict(pr(review: .none, merge: .clean, rollup: .none)) == .mergeable)
    check("리뷰 규칙 없음 + CLEAN + 검사 통과 → 머지 가능",
          verdict(pr(review: .none, merge: .clean, rollup: .success)) == .mergeable)
    check("리뷰 규칙 없음 + CLEAN + 검사 진행중 → 리뷰 대기",
          verdict(pr(review: .none, merge: .clean, rollup: .pending)) == .awaitingReview)
    check("승인 + CLEAN + 검사 진행중 → 승인",
          verdict(pr(review: .approved, merge: .clean, rollup: .pending)) == .approved)
    check("리뷰 규칙 없음 + BLOCKED → 리뷰 대기",
          verdict(pr(review: .none, merge: .blocked)) == .awaitingReview)
    check("승인 + BLOCKED → 승인 (MERGEABLE·검사 통과여도)",
          verdict(pr(review: .approved, mergeable: .mergeable, merge: .blocked, rollup: .success)) == .approved)
    check("승인 + mergeState unknown + success + MERGEABLE → 머지 가능 (기존 경로)",
          verdict(pr(review: .approved, mergeable: .mergeable, merge: .unknown, rollup: .success)) == .mergeable)
    check("mergeState unknown + 칩 전부 통과인데 rollup pending(보고 전 필수 검사) → 승인, 머지 가능 아님",
          verdict(pr(review: .approved, mergeable: .mergeable, merge: .unknown, rollup: .pending,
                     checks: [chk("build", .passed)], complete: true)) == .approved)
    check("mergeState unknown + 리뷰 규칙 없음 → 리뷰 대기 (CLEAN 을 추정하지 않음)",
          verdict(pr(review: .none, merge: .unknown)) == .awaitingReview)
    check("reviewRequired 인데 CLEAN → GitHub 의 종합 판정을 믿어 머지 가능",
          verdict(pr(review: .reviewRequired, merge: .clean)) == .mergeable)
    check("Draft + CLEAN → Draft", verdict(pr(draft: true, merge: .clean)) == .draft)
    check("충돌 + CLEAN → 충돌 (우선순위 불변)",
          verdict(pr(mergeable: .conflicting, merge: .clean)) == .conflict)
    check("CLEAN 이어도 검사 실패 → 검사 실패",
          verdict(pr(merge: .clean, rollup: .failure)) == .checksFailed)
    check("CLEAN 이어도 변경 요청 → 변경 요청",
          verdict(pr(review: .changesRequested, merge: .clean)) == .changesRequested)
}

// MARK: - 3. 막힘 판정

print("▸ 막힘(blocking)")
do {
    check("Draft 인데 검사 실패 → 검사 실패 (블로킹)",
          verdict(pr(draft: true, rollup: .failure)) == .checksFailed
              && verdict(pr(draft: true, rollup: .failure)).isBlocking)
    check("충돌·검사 실패·변경 요청만 블로킹",
          PRVerdict.conflict.isBlocking && PRVerdict.checksFailed.isBlocking
              && PRVerdict.changesRequested.isBlocking
              && !PRVerdict.draft.isBlocking && !PRVerdict.awaitingReview.isBlocking
              && !PRVerdict.approved.isBlocking && !PRVerdict.mergeable.isBlocking)
    check("목록이 잘렸으면 검사 판정은 rollup — 칩에 실패가 있어도 rollup success 면 아님",
          verdict(pr(rollup: .success, checks: [chk("build", .failed)])) == .awaitingReview)
}

// MARK: - 3b. 끝까지 받은 칩 목록으로 검사 판정

print("▸ effectiveChecks")
do {
    let allPassed = [chk("test", .passed), chk("automerge", .skipped)]
    check("끝까지 받은 칩이 전부 통과면 rollup FAILURE 여도 검사 실패 아님",
          verdict(pr(rollup: .failure, checks: allPassed, complete: true)) != .checksFailed
              && pr(rollup: .failure, checks: allPassed, complete: true).effectiveChecks == .success)
    check("목록이 잘렸으면 rollup FAILURE → 검사 실패",
          verdict(pr(rollup: .failure, checks: allPassed, complete: false)) == .checksFailed)
    check("contexts 가 비고 rollup FAILURE → 검사 실패",
          verdict(pr(rollup: .failure, checks: [], complete: true)) == .checksFailed)
    check("끝까지 받은 칩에 실패 하나 → 검사 실패 (rollup success 여도)",
          verdict(pr(rollup: .success, checks: [chk("a", .passed), chk("b", .failed)], complete: true)) == .checksFailed)
    check("끝까지 받은 칩에 진행중 → pending (CLEAN 이어도 머지 가능 아님)",
          pr(rollup: .failure, checks: [chk("a", .running, end: nil)], complete: true).effectiveChecks == .pending
              && verdict(pr(merge: .clean, rollup: .success,
                            checks: [chk("a", .queued, start: nil, end: nil)], complete: true)) == .awaitingReview)
    check("검사 없음(rollup none) → none 그대로", pr(rollup: .none, complete: true).effectiveChecks == PRChecksRollup.none)
}

// MARK: - 3c. 재실행 검사 정리

print("▸ latestRuns")
do {
    func dedupe(_ checks: [PRCheck]) -> [PRCheck] {
        GitHubAPIClient.latestRuns(checks.map { (.checkRun(suite: "verify", name: $0.name), $0) })
    }
    let early = chk("test", .failed, start: 0, end: 60)
    let late = chk("test", .passed, start: 120, end: 180)
    check("test CANCELLED(이른) + test SUCCESS(늦은) → test 하나, passed",
          dedupe([early, late]) == [late] && dedupe([late, early]) == [late])
    let a = chk("ci", .failed, start: nil, end: nil), b = chk("ci", .passed, start: nil, end: nil)
    check("시각 없는 중복 → 응답에서 뒤에 온 것", dedupe([a, b]) == [b] && dedupe([b, a]) == [a])
    let byEnd1 = chk("e", .failed, start: nil, end: 10), byEnd2 = chk("e", .passed, start: nil, end: 20)
    check("startedAt 없으면 completedAt 으로 비교", dedupe([byEnd2, byEnd1]) == [byEnd2])
    let x = chk("lint", .passed), y = chk("build", .passed), z = chk("static", .passed)
    check("서로 다른 이름은 유지·순서 유지", dedupe([x, y, z]) == [x, y, z])
    check("남은 것은 원래 자리 순서", dedupe([early, x, late, y]) == [x, late, y],
          "\(dedupe([early, x, late, y]).map(\.name))")

    // A run with no time yet is a re-run that hasn't started: it is the
    // newest whichever side of the timed run GitHub lists it on.
    let queued = chk("test", .queued, start: nil, end: nil)
    let cancelled3 = chk("test", .failed, start: 3, end: 4)
    let passed5 = chk("test", .passed, start: 5, end: 6)
    check("[시각 없음, t=3] → 시각 없는 쪽", dedupe([queued, cancelled3]) == [queued])
    check("[t=3, 시각 없음] → 시각 없는 쪽", dedupe([cancelled3, queued]) == [queued])
    check("[t=5, 시각 없음, t=3] → 시각 없는 쪽", dedupe([passed5, queued, cancelled3]) == [queued],
          "\(dedupe([passed5, queued, cancelled3]).map(\.outcome))")
    check("시각 없는 재실행이 남으면 검사 실패가 아니라 진행중",
          pr(rollup: .failure, checks: dedupe([queued, cancelled3]), complete: true).effectiveChecks == .pending)

    check("키 없는 CheckRun 은 같은 이름끼리도 합치지 않음",
          GitHubAPIClient.latestRuns([(nil, early), (nil, late)]) == [early, late])
    check("CheckRun 과 같은 이름의 StatusContext 는 다른 검사",
          GitHubAPIClient.latestRuns([(.checkRun(suite: "ci", name: "test"), early),
                                      (.status(context: "test"), late)]) == [early, late])
}

// MARK: - 3d. 밀려난 실행 버리기 (#60)

print("▸ withoutSupersededRuns")
do {
    typealias Context = GitHubAPIClient.ParsedContext
    func ctx(_ name: String, _ outcome: PRCheckOutcome, run number: Int?,
             workflow: String = "verify", workflowID: Int = 335_587_108, event: String = "pull_request",
             start: TimeInterval? = 0, end: TimeInterval? = 60) -> Context {
        let run = number.map {
            GitHubAPIClient.WorkflowRun(series: .init(workflowID: workflowID, event: event), number: $0)
        }
        return (run, (.checkRun(suite: workflow, name: name), chk(name, outcome, start: start, end: end)))
    }
    func current(_ contexts: [Context]) -> [PRCheck] {
        GitHubAPIClient.latestRuns(GitHubAPIClient.withoutSupersededRuns(contexts))
    }

    // gambau#2014: run 874 cancelled by the labeled run 875, whose
    // automerge waits on `needs` and doesn't exist yet.
    let superseded = current([
        ctx("test", .failed, run: 874), ctx("static", .failed, run: 874), ctx("automerge", .failed, run: 874),
        ctx("static", .passed, run: 875, start: 30, end: 90), ctx("test", .running, run: 875, start: 30, end: nil),
    ])
    check("이전 실행에만 있는 CANCELLED job 은 버림 — automerge 칩 없음",
          superseded.map(\.name) == ["static", "test"], "\(superseded.map(\.name))")
    check("밀려난 취소가 빠지면 검사 실패가 아니라 진행중",
          pr(rollup: .failure, checks: superseded, complete: true).effectiveChecks == .pending)

    let attempts = current([ctx("test", .failed, run: 875, start: 0, end: 60),
                            ctx("test", .passed, run: 875, start: 120, end: 180)])
    check("같은 실행 번호의 재시도끼리는 최신 하나", attempts.map(\.outcome) == [.passed])

    let events = GitHubAPIClient.withoutSupersededRuns([ctx("deploy", .failed, run: 10, event: "push"),
                                                        ctx("test", .passed, run: 11)])
    check("event 가 다르면 번호가 작아도 지우지 않음",
          events.map(\.check.name) == ["deploy", "test"], "\(events.map(\.check.name))")
    let workflows = GitHubAPIClient.withoutSupersededRuns([ctx("build", .failed, run: 3, workflow: "CI", workflowID: 7),
                                                           ctx("test", .passed, run: 875)])
    check("다른 워크플로의 실행 번호와는 비교하지 않음", workflows.count == 2)

    let unknown = GitHubAPIClient.withoutSupersededRuns([ctx("automerge", .failed, run: nil),
                                                         ctx("test", .passed, run: 875)])
    check("실행 번호 없는 CheckRun 은 남음", unknown.map(\.check.name) == ["automerge", "test"])
}

// MARK: - 4. Glance (메뉴바 숫자·점)

print("▸ Glance")
do {
    let blocked = pr("mongshell/bookdam", 45, rollup: .failure, checks: [chk("build", .failed)])
    let conflict = pr("mongshell/menubar", 12, mergeable: .conflicting)
    let fine = pr("mongshell/bookdam", 46)

    let g = GitHubGlance.of(snap(mine: [blocked, fine, conflict]), state: .loaded(.pat), hidden: [], mergeActivity: [:])
    check("막힘 2 → count 2·빨강 (막히지 않은 PR 은 세지 않음)", g.count == 2 && g.dot == .red, "\(g)")

    let green = GitHubGlance.of(snap(mine: [fine]), state: .loaded(.pat), hidden: [], mergeActivity: [:])
    check("처리할 것 없음 → 초록·0", green.count == 0 && green.dot == .green, "\(green)")

    let hidden = GitHubGlance.of(snap(mine: [blocked, fine, conflict]),
                                 state: .loaded(.pat), hidden: ["mongshell/bookdam"], mergeActivity: [:])
    check("숨긴 레포 → count·점·hover 어디에도 없음",
          hidden.count == 1 && hidden.dot == .red
              && !hidden.hoverMineLine.contains("#45")
              && hidden.hoverMineLine == "내 PR 1 · 막힘 1 · #12 충돌", "\(hidden)")
    let hiddenUpper = GitHubGlance.of(snap(mine: [blocked]), state: .loaded(.pat), hidden: ["mongshell/bookdam"], mergeActivity: [:])
    check("숨김 비교는 소문자 기준", hiddenUpper.count == 0 && hiddenUpper.dot == .green)
    check("hiding 은 머지 목록도 거른다",
          snap(merged: [fine]).hiding(["mongshell/bookdam"]).recentlyMerged.isEmpty)

    let noToken = GitHubGlance.of(snap(mine: [blocked]), state: .noToken, hidden: [], mergeActivity: [:])
    check("noToken → 회색·0 (스냅샷이 있어도)", noToken.count == 0 && noToken.dot == .grey
              && noToken.hoverCILine(now: now) == "GitHub 토큰 없음" && noToken.hoverMineLine == "", "\(noToken)")
    for state: GitHubLoadState in [.off, .keychainDenied, .unauthorized, .patSaveFailed(-25299), .error("x")] {
        let g = GitHubGlance.of(snap(mine: [blocked]), state: state, hidden: [], mergeActivity: [:])
        check("\(state) → 회색·0", g.count == 0 && g.dot == .grey)
    }
    let loading = GitHubGlance.of(snap(mine: [blocked]), state: .loading, hidden: [], mergeActivity: [:])
    check("loading + 마지막 스냅샷 → 값 유지", loading.count == 1 && loading.dot == .red)
    let limited = GitHubGlance.of(snap(mine: [blocked]), state: .rateLimited(retryAt: now), hidden: [], mergeActivity: [:])
    check("rateLimited + 마지막 스냅샷 → 값 유지", limited.count == 1 && limited.dot == .red)
    let loadingEmpty = GitHubGlance.of(nil, state: .loading, hidden: [], mergeActivity: [:])
    check("loading + 스냅샷 없음 → 회색·0", loadingEmpty.count == 0 && loadingEmpty.dot == .grey)
    check("draft 는 막힘이 아니다",
          GitHubGlance.of(snap(mine: [pr(draft: true)]), state: .loaded(.pat), hidden: [], mergeActivity: [:]).dot == .green)

    // #51: amber now means a check is still going on one of my PRs.
    let running = pr("mongshell/bookdam", 50, rollup: .pending,
                     checks: [chk("test", .running, start: -60, end: nil)], complete: true)
    let queued = pr("mongshell/bookdam", 51, rollup: .pending,
                    checks: [chk("lint", .queued, start: nil, end: nil)], complete: true)
    let ci = GitHubGlance.of(snap(mine: [fine, running]), state: .loaded(.pat), hidden: [], mergeActivity: [:])
    check("막힘 없음 + 진행중 → 주황·숫자 없음", ci.count == 0 && ci.dot == .amber, "\(ci)")
    let ciQueued = GitHubGlance.of(snap(mine: [queued]), state: .loaded(.pat), hidden: [], mergeActivity: [:])
    check("막힘 없음 + 대기(queued)만 → 주황", ciQueued.count == 0 && ciQueued.dot == .amber)
    let ciBlocked = GitHubGlance.of(snap(mine: [running, blocked]), state: .loaded(.pat), hidden: [], mergeActivity: [:])
    check("막힘 + 진행중 → 빨강·막힘만 셈", ciBlocked.count == 1 && ciBlocked.dot == .red, "\(ciBlocked)")
    let ciHidden = GitHubGlance.of(snap(mine: [fine, running]), state: .loaded(.pat),
                                   hidden: ["mongshell/bookdam"], mergeActivity: [:])
    check("진행중이 숨긴 레포에만 → 주황 아님", ciHidden.dot == .green)
    // A chip still running on a PR whose checks already failed is read as
    // the badge reads it: failed, not running.
    let failedButRunning = pr("mongshell/bookdam", 52, rollup: .pending,
                              checks: [chk("build", .failed), chk("test", .running, start: -30, end: nil)],
                              complete: true)
    check("실패한 PR 의 남은 진행중 칩은 주황이 아니다 (빨강)",
          GitHubGlance.of(snap(mine: [failedButRunning]), state: .loaded(.pat), hidden: [], mergeActivity: [:]).dot == .red)
}

// MARK: - 5. hover 문구

print("▸ hover 문구")
do {
    let fail = pr("mongshell/bookdam", 45, rollup: .failure, checks: [chk("lint", .passed), chk("build", .failed)])
    let conflict = pr("mongshell/bookdam", 47, mergeable: .conflicting)
    let changes = pr("mongshell/bookdam", 48, review: .changesRequested)

    func mineLine(_ mine: [GitHubPullRequest]) -> String {
        GitHubGlance.of(snap(mine: mine), state: .loaded(.pat), hidden: [], mergeActivity: [:]).hoverMineLine
    }
    check("검사 실패 → \"#45 build 실패\" (첫 실패 검사 이름)",
          mineLine([pr("mongshell/bookdam", 1), fail]) == "내 PR 2 · 막힘 1 · #45 build 실패", mineLine([fail]))
    check("충돌 → \"#47 충돌\"", mineLine([conflict]) == "내 PR 1 · 막힘 1 · #47 충돌", mineLine([conflict]))
    check("변경 요청 → \"#48 변경 요청\"", mineLine([changes]) == "내 PR 1 · 막힘 1 · #48 변경 요청")
    check("막힘 0 → 뒤에 아무것도 없음", mineLine([pr()]) == "내 PR 1 · 막힘 0", mineLine([pr()]))
    check("막힘 여럿 → 첫 번째만", mineLine([conflict, fail]) == "내 PR 2 · 막힘 2 · #47 충돌")
    let noChip = pr("mongshell/bookdam", 49, rollup: .failure, checks: [])
    check("rollup 실패인데 실패 칩 없음 → 배지 이름", mineLine([noChip]) == "내 PR 1 · 막힘 1 · #49 검사 실패")

    // The hover view draws the parts, not the joined strings: the numbers
    // get a color and the rest is greyed.
    let parts = GitHubGlance.of(snap(mine: [pr("mongshell/bookdam", 1), fail]),
                                state: .loaded(.pat), hidden: [], mergeActivity: [:]).lines
    check("lines 는 숫자와 나머지를 따로 든다",
          parts == GitHubGlance.Lines(ci: .failed(prs: 1, rest: "#45 build 실패"),
                                      mine: 2, blocked: 1, mineRest: "막힘 1 · #45 build 실패",
                                      mergeable: 0, mergeableRest: ""),
          "\(String(describing: parts))")
    let noLines = GitHubGlance.of(snap(mine: [fail]), state: .unauthorized, hidden: [], mergeActivity: [:])
    check("스냅샷을 읽지 않는 상태 → lines 없음·stateLabel 만",
          noLines.lines == nil && noLines.stateLabel == "토큰이 거부되었어요 (401)")
    let saveFailed = GitHubGlance.of(snap(mine: [fail]), state: .patSaveFailed(-25299), hidden: [], mergeActivity: [:])
    check("PAT 저장 실패 → stateLabel 에 상태 코드, 토큰 값 없음",
          saveFailed.stateLabel == "PAT 를 Keychain 에 저장하지 못했어요 (-25299)", saveFailed.stateLabel)
}

// MARK: - 5b. hover CI 줄 (#51)

print("▸ hover CI 줄")
do {
    func ciLine(_ mine: [GitHubPullRequest], hidden: Set<String> = [], at: Date = now) -> String {
        GitHubGlance.of(snap(mine: mine), state: .loaded(.pat), hidden: hidden, mergeActivity: [:]).hoverCILine(now: at)
    }
    func going(_ repo: String, _ number: Int, _ checks: [PRCheck]) -> GitHubPullRequest {
        pr(repo, number, rollup: .pending, checks: checks, complete: true)
    }
    let passed = pr("mongshell/bookdam", 40, checks: [chk("build", .passed)], complete: true)
    let failed = pr("mongshell/bookdam", 45, rollup: .failure,
                    checks: [chk("lint", .passed), chk("build", .failed)], complete: true)
    // Started 100s ago on the first PR, 300s ago on the second: the second
    // has run longest, whatever the list order.
    let young = going("mongshell/bookdam", 46, [chk("test", .running, start: -100, end: nil)])
    let old = going("mongshell/growdle", 121, [chk("lint", .passed),
                                               chk("Vercel", .running, start: -300, end: nil)])

    check("진행중 → \"CI 2 · growdle #121 Vercel 5m 00s…\" (가장 먼저 시작한 running, PR 을 넘어)",
          ciLine([young, old]) == "CI 2 · growdle #121 Vercel 5m 00s…", ciLine([young, old]))
    check("경과 시간은 넘긴 시각으로 흐른다",
          ciLine([young, old], at: now.addingTimeInterval(5)) == "CI 2 · growdle #121 Vercel 5m 05s…")
    let untimed = going("mongshell/bookdam", 47, [chk("ci", .running, start: nil, end: nil)])
    check("시각 없는 running 은 시각 있는 running 을 이기지 못한다",
          ciLine([untimed, young]) == "CI 2 · bookdam #46 test 1m 40s…", ciLine([untimed, young]))
    check("running 이 전부 시각 없음 → 목록 순서 첫 것, \"진행중\"",
          ciLine([untimed]) == "CI 1 · bookdam #47 ci 진행중", ciLine([untimed]))

    let queuedA = going("mongshell/bookdam", 48, [chk("lint", .queued, start: nil, end: nil),
                                                  chk("build", .queued, start: nil, end: nil)])
    let queuedB = going("mongshell/growdle", 9, [chk("x", .queued, start: nil, end: nil)])
    check("queued 만 → 목록 순서 첫 PR 의 첫 queued, 경과 없이 \"대기\"",
          ciLine([queuedA, queuedB]) == "CI 2 · bookdam #48 lint 대기", ciLine([queuedA, queuedB]))
    check("queued 가 앞에 있어도 running 이 있으면 running",
          ciLine([queuedA, young]) == "CI 2 · bookdam #46 test 1m 40s…", ciLine([queuedA, young]))
    let rollupOnly = pr("mongshell/bookdam", 49, rollup: .pending, checks: [], complete: false)
    check("rollup 만 진행중(칩 없음) → \"검사 진행중\"",
          ciLine([rollupOnly]) == "CI 1 · bookdam #49 검사 진행중", ciLine([rollupOnly]))

    check("진행중이 실패보다 앞 — 숫자는 진행중 PR 수",
          ciLine([failed, old]) == "CI 1 · growdle #121 Vercel 5m 00s…", ciLine([failed, old]))
    check("실패만 → \"CI 1 · #45 build 실패\" (첫 실패 검사 이름)",
          ciLine([passed, failed]) == "CI 1 · #45 build 실패", ciLine([passed, failed]))
    let failed2 = pr("mongshell/growdle", 3, rollup: .failure, checks: [], complete: false)
    check("실패 여럿 → 숫자는 실패 PR 수, 문구는 목록 순서 첫 PR",
          ciLine([failed2, failed]) == "CI 2 · #3 검사 실패", ciLine([failed2, failed]))
    check("모두 통과 → 숫자 없이 \"CI 모두 통과\"", ciLine([passed]) == "CI 모두 통과", ciLine([passed]))
    check("검사 있는 PR 이 없음 → \"CI 없음\"",
          ciLine([pr(rollup: .none)]) == "CI 없음" && ciLine([]) == "CI 없음", ciLine([pr(rollup: .none)]))
    check("검사 없는 PR 이 섞여도 통과한 PR 이 있으면 모두 통과",
          ciLine([pr(rollup: .none), passed]) == "CI 모두 통과")

    check("숨긴 레포의 진행중·실패는 CI 줄에서도 빠진다",
          ciLine([old, failed, passed], hidden: ["mongshell/growdle"]) == "CI 1 · #45 build 실패"
              && ciLine([old, failed], hidden: ["mongshell/growdle", "mongshell/bookdam"]) == "CI 없음")

    // The parts the view draws: a number only when there is a count, and
    // its color telling running from failed.
    let runningLine = GitHubCILine.of([young, old])
    check("진행중 → 숫자·주황·경과 기준 시각",
          runningLine.number == 2 && runningLine.tone == .amber
              && runningLine.runningSince == now.addingTimeInterval(-300), "\(runningLine)")
    let queuedLine = GitHubCILine.of([queuedA])
    check("대기 → 숫자·주황·흐르는 시간 없음",
          queuedLine.number == 1 && queuedLine.tone == .amber && queuedLine.runningSince == nil)
    let failedLine = GitHubCILine.of([failed])
    check("실패 → 숫자·빨강", failedLine.number == 1 && failedLine.tone == .red && failedLine.runningSince == nil)
    check("모두 통과·없음 → 숫자·색 없음",
          GitHubCILine.of([passed]).number == nil && GitHubCILine.of([passed]).tone == nil
              && GitHubCILine.of([]).number == nil && GitHubCILine.of([]).tone == nil)
}

// MARK: - 5c. 머지 가능 (Decision #52)

print("▸ 머지 가능")
do {
    func clean(_ repo: String = "mongshell/bookdam", _ number: Int = 57, draft: Bool = false,
               merge: PRMergeState = .clean, nodeID: String? = "PR_n", linked: Bool = true) -> GitHubPullRequest {
        pr(repo, number, draft: draft, merge: merge, nodeID: nodeID, headSHA: "abc", linked: linked)
    }
    func glance(mine: [GitHubPullRequest],
                state: GitHubLoadState = .loaded(.pat), hidden: Set<String> = [],
                activity: [String: PRMergeActivity] = [:]) -> GitHubGlance {
        GitHubGlance.of(snap(mine: mine), state: state, hidden: hidden, mergeActivity: activity)
    }
    func count(_ g: GitHubGlance) -> Int? { g.lines?.mergeable }

    let one = glance(mine: [clean()])
    check("CLEAN 내 PR 1개 → 머지 가능 1·글리프 켬",
          count(one) == 1 && one.hasMergeable, "\(one)")
    // Mixed fixtures: the count is exactly the rows canOffer draws a button on.
    let mixed = [clean("mongshell/bookdam", 1), clean("mongshell/bookdam", 2, draft: true),
                 clean("mongshell/bookdam", 3, merge: .blocked), clean("mongshell/bookdam", 4, nodeID: nil),
                 clean("mongshell/growdle", 5), pr("mongshell/bookdam", 6)]
    let mixedGlance = glance(mine: mixed)
    let offered = mixed.filter { GitHubMergePolicy.canOffer($0, section: .mine) }.count
    check("머지 가능 수 = 팝오버 머지 버튼이 그려지는 행 수 (canOffer)",
          offered == 2 && count(mixedGlance) == offered, "\(String(describing: count(mixedGlance)))")

    // Only the rows the popover draws (section cap), not the "외 N건" past it.
    let cap = Config.githubSectionCaps.mine
    func capped(cleanAt index: Int) -> [GitHubPullRequest] {
        (1...(cap + 1)).map { $0 == index ? clean("mongshell/bookdam", $0) : pr("mongshell/bookdam", $0) }
    }
    let past = glance(mine: capped(cleanAt: cap + 1))
    check("상한 밖(\(cap + 1)번째)의 CLEAN PR 은 세지 않음 (팝오버에 버튼 없음)",
          count(past) == 0 && !past.hasMergeable && past.hoverMergeableLine == "머지 가능 0", past.hoverMergeableLine)
    let last = glance(mine: capped(cleanAt: cap))
    check("상한 안 마지막(\(cap)번째) CLEAN PR 은 센다",
          count(last) == 1 && last.hoverMergeableLine == "머지 가능 1 · bookdam #\(cap)", last.hoverMergeableLine)
    let spill = glance(mine: (1...(cap + 2)).map { clean("mongshell/bookdam", $0) })
    check("mergeableRest 의 외 K 도 상한 안에서 센다",
          count(spill) == cap && spill.hoverMergeableLine == "머지 가능 \(cap) · bookdam #1 외 \(cap - 1)", spill.hoverMergeableLine)
    for (label, p) in [("Draft", clean(draft: true)), ("BLOCKED", clean(merge: .blocked)),
                       ("UNKNOWN", clean(merge: .unknown)),
                       ("nodeID 없음", clean(nodeID: nil)), ("url 없음", clean(linked: false))] {
        let g = glance(mine: [p])
        check("\(label) → 머지 가능 0", count(g) == 0 && !g.hasMergeable, "\(g)")
    }
    let noHead = pr("mongshell/bookdam", 57, merge: .clean, nodeID: "PR_n", headSHA: nil)
    check("headSHA 없음 → 머지 가능 0", count(glance(mine: [noHead])) == 0)

    let hidden = glance(mine: [clean("mongshell/bookdam", 57)], hidden: ["mongshell/bookdam"])
    check("숨긴 레포의 CLEAN PR → 0·hover 에 없음",
          count(hidden) == 0 && !hidden.hasMergeable && hidden.hoverMergeableLine == "머지 가능 0", hidden.hoverMergeableLine)

    let a = clean("mongshell/bookdam", 57), b = clean("mongshell/growdle", 9)
    let merging = glance(mine: [a, b], activity: [a.id: .merging])
    check(".merging 인 PR 은 세지 않음", count(merging) == 1 && merging.hoverMergeableLine == "머지 가능 1 · growdle #9",
          merging.hoverMergeableLine)
    let merged = glance(mine: [a], activity: [a.id: .merged])
    check(".merged 인 PR 은 세지 않음 (색인 지연 동안 거짓 있음 방지)",
          count(merged) == 0 && !merged.hasMergeable)
    let failed = glance(mine: [a], activity: [a.id: .failed("x")])
    check(".failed 인 PR 은 센다 (버튼이 다시 나온다)", count(failed) == 1 && failed.hasMergeable)
    let otherID = glance(mine: [a], activity: [b.id: .merged])
    check("다른 PR 의 활동은 영향 없음", count(otherID) == 1)
    let loadingKept = GitHubGlance.of(snap(mine: [a]), state: .loading, hidden: [], mergeActivity: [a.id: .merging])
    check("loading + 마지막 스냅샷에도 활동 반영", loadingKept.lines?.mergeable == 0)

    check("머지 가능은 메뉴바 숫자에 더하지 않음", one.count == 0 && one.dot == .green, "\(one)")

    check("hoverMergeableLine 0 → \"머지 가능 0\"", glance(mine: [pr()]).hoverMergeableLine == "머지 가능 0")
    check("hoverMergeableLine 1 → \"머지 가능 1 · bookdam #57\"", one.hoverMergeableLine == "머지 가능 1 · bookdam #57",
          one.hoverMergeableLine)
    let three = glance(mine: [a, pr(), b, clean("mongshell/menubar", 3)])
    check("hoverMergeableLine 여럿 → 첫 번째 · 외 K",
          three.hoverMergeableLine == "머지 가능 3 · bookdam #57 외 2" && three.lines?.mergeableRest == "bookdam #57 외 2",
          three.hoverMergeableLine)

    for state: GitHubLoadState in [.off, .noToken, .keychainDenied, .unauthorized, .patSaveFailed(-25299), .error("x")] {
        let g = glance(mine: [clean()], state: state)
        check("\(state) → 머지 가능 표시 없음", g.lines == nil && !g.hasMergeable && g.hoverMergeableLine == "")
    }
    check("loading + 스냅샷 없음 → 표시 없음",
          !GitHubGlance.of(nil, state: .loading, hidden: [], mergeActivity: [:]).hasMergeable)
}

// MARK: - 6. 검사 칩 접기

print("▸ 검사 칩 접기")
do {
    let skip = chk("automerge", .skipped, start: 5, end: 6)
    switch ChecksLine.fold([chk("lint", .passed, start: 0, end: 30), chk("build", .passed, start: 10, end: 90), skip]) {
    case .collapsed(let n, let total, let skipped):
        check("전부 통과(+skip) → collapsed(2, skipped:[automerge])", n == 2 && skipped == [skip])
        check("total = max(completedAt) − min(startedAt) = 90s", total == 90, "\(String(describing: total))")
    default:
        check("전부 통과 → collapsed", false)
    }
    if case .expanded(let all) = ChecksLine.fold([chk("lint", .passed), chk("build", .failed)]) {
        check("실패 하나 → expanded(전체)", all.count == 2)
    } else { check("실패 하나 → expanded", false) }
    if case .expanded = ChecksLine.fold([chk("lint", .passed), chk("build", .running, end: nil)]) {
        check("running 하나 → expanded", true)
    } else { check("running 하나 → expanded", false) }
    if case .expanded = ChecksLine.fold([chk("build", .queued, start: nil, end: nil)]) {
        check("queued → expanded", true)
    } else { check("queued → expanded", false) }
    check("빈 배열 → none", ChecksLine.fold([]) == .none)
    if case .collapsed(_, let total, _) = ChecksLine.fold([chk("lint", .passed), chk("ci", .passed, start: nil, end: nil)]) {
        check("시각 없는 검사(StatusContext)가 하나라도 → total nil", total == nil)
    } else { check("시각 없는 검사 → collapsed", false) }
    if case .collapsed(let n, _, let skipped) = ChecksLine.fold([skip]) {
        check("skip 만 → collapsed(0, skipped 1)", n == 0 && skipped.count == 1)
    } else { check("skip 만 → collapsed", false) }
    check("isPending 은 running·queued 만",
          PRCheckOutcome.running.isPending && PRCheckOutcome.queued.isPending
              && !PRCheckOutcome.passed.isPending && !PRCheckOutcome.failed.isPending
              && !PRCheckOutcome.skipped.isPending)
}

// MARK: - 7. 소요시간 표기

print("▸ TimeText.duration")
do {
    check("0 → 0s", TimeText.duration(0) == "0s")
    check("59 → 59s", TimeText.duration(59) == "59s")
    check("60 → 1m 00s", TimeText.duration(60) == "1m 00s", TimeText.duration(60))
    check("3599 → 59m 59s", TimeText.duration(3599) == "59m 59s")
    check("3600 → 1h 00m", TimeText.duration(3600) == "1h 00m", TimeText.duration(3600))
    check("3900 → 1h 05m", TimeText.duration(3900) == "1h 05m")
    check("음수 → 0s", TimeText.duration(-5) == "0s")
    check("ago 공개: 23분 전", TimeText.ago(now.addingTimeInterval(-23 * 60), now: now) == "23분 전")
}

// MARK: - 8. 폴링 주기

print("▸ GitHubSnapshot.hasFreshRunningChecks")
do {
    func fresh(_ mine: [GitHubPullRequest], merged: [GitHubPullRequest] = [],
               hidden: Set<String> = []) -> Bool {
        snap(mine: mine, merged: merged).hiding(hidden).hasFreshRunningChecks(now: now)
    }
    func running(minutesAgo: Double) -> PRCheck {
        chk("build", .running, start: -minutesAgo * 60, end: nil)
    }
    check("10분 전 시작한 running → 빠른 주기",
          fresh([pr(checks: [running(minutesAgo: 10)], complete: true)]))
    check("정확히 60분 전 시작한 running → 빠른 주기 (상한 포함)",
          fresh([pr(checks: [running(minutesAgo: 60)], complete: true)]))
    check("61분 전 시작한 running → 아님 (끝나지 않는 실행이 붙잡지 않음)",
          !fresh([pr(checks: [running(minutesAgo: 61)], complete: true)]))
    check("1분 뒤 시작으로 보고된 running (시계 오차 안) → 빠른 주기",
          fresh([pr(checks: [running(minutesAgo: -1)], complete: true)]))
    check("정확히 5분 뒤 시작 (오차 경계) → 빠른 주기",
          fresh([pr(checks: [running(minutesAgo: -5)], complete: true)]))
    check("10분 뒤 시작으로 보고된 running → 아님 (미래 시각이 60분 상한을 넘지 못함)",
          !fresh([pr(checks: [running(minutesAgo: -10)], complete: true)]))
    check("오래된 running 옆에 막 시작한 running 이 있으면 → 빠른 주기",
          fresh([pr(checks: [running(minutesAgo: 90), chk("lint", .running, start: -30, end: nil)],
                    complete: true)]))
    check("queued 만 → 아님 (꺼진 러너·승인 대기)",
          !fresh([pr(checks: [chk("build", .queued, start: nil, end: nil)], complete: true)]))
    check("rollup 만 pending (칩 잘림·보고 안 된 필수 검사) → 아님",
          !fresh([pr(rollup: .pending, checks: [chk("a", .passed)], complete: false)])
              && !fresh([pr(rollup: .pending, checks: [], complete: true)]))
    check("startedAt 없는 running (StatusContext PENDING) → 아님",
          !fresh([pr(checks: [chk("ci", .running, start: nil, end: nil)], complete: true)]))
    check("칩이 이미 실패한 PR 의 남은 running → 아님",
          !fresh([pr(rollup: .pending, checks: [chk("a", .failed), running(minutesAgo: 1)],
                     complete: true)]))
    check("숨긴 레포의 running → 아님",
          !fresh([pr("mongshell/bookdam", 1, checks: [running(minutesAgo: 1)], complete: true)],
                 hidden: ["mongshell/bookdam"]))
    check("최근 머지 목록의 running → 아님 (내 PR 만)",
          !fresh([pr(checks: [chk("a", .passed)], complete: true)],
                 merged: [pr(checks: [running(minutesAgo: 1)], complete: true)]))
}

print("▸ GitHubPollPolicy.nextWait")
do {
    func wait(base: Int = 180, backoff: Int = 0) -> Int {
        GitHubPollPolicy.nextWait(base: base, backoff: backoff)
    }
    check("백오프 없음 → base", wait() == 180)
    check("백오프 → base·2^backoff", wait(backoff: 1) == 360)
    check("백오프 상한 3600", wait(base: 600, backoff: 4) == 3600)
    check("base 하한 60", wait(base: 5) == 60)
    check("base 상한 600", wait(base: 10_000) == 600)
}

print("▸ GitHubPollPolicy.nextAutoWait")
do {
    func auto(_ state: GitHubLoadState, base: Int = 180, backoff: Int = 0, running: Bool = false) -> Int? {
        GitHubPollPolicy.nextAutoWait(after: state, base: base, backoff: backoff,
                                      hasFreshRunningChecks: running)
    }
    check("401 이후 자동 대기 없음 (무효 토큰 재전송 정지)", auto(.unauthorized) == nil)
    check("401 이후엔 진행중이어도 자동 대기 없음", auto(.unauthorized, running: true) == nil)
    check("401 이후엔 백오프 중이어도 자동 대기 없음", auto(.unauthorized, backoff: 2) == nil)
    check("성공 후 → base", auto(.loaded(.pat)) == 180)
    check("PAT 저장 실패 후 자동 대기 없음 (다른 토큰으로 나가지 않음)", auto(.patSaveFailed(-25299)) == nil)
    check("PAT 저장 실패 후엔 진행중이어도 자동 대기 없음",
          auto(.patSaveFailed(-25299), running: true) == nil)
    check("다른 오류 후 → base (정지는 401·PAT 저장 실패만)", auto(.error("x")) == 180)
    check("한도 초과 후 → 백오프 대기", auto(.rateLimited(retryAt: now), backoff: 1) == 360)
    check("성공 후 진행중 → 30 (팝오버가 닫혀 있어도)", auto(.loaded(.pat), running: true) == 30)
    check("성공 후 진행중이면 긴 base 설정도 30", auto(.loaded(.ghCLI(account: "a")), base: 600, running: true) == 30)
    check("백오프 중엔 성공 상태·진행중이어도 30 아님", auto(.loaded(.pat), backoff: 1, running: true) == 360)
    check("한도 초과 백오프 중엔 진행중이어도 30 아님", auto(.rateLimited(retryAt: now), backoff: 1, running: true) == 360)
    // #51 C1: a snapshot left from before the state went grey must not hold
    // the fast cadence.
    check("토큰 없음 + 지난 스냅샷 진행중 → base", auto(.noToken, running: true) == 180)
    check("Keychain 거부 + 지난 스냅샷 진행중 → base", auto(.keychainDenied, running: true) == 180)
    check("오류 + 지난 스냅샷 진행중 → base", auto(.error("x"), running: true) == 180)
    check("확인 중 + 지난 스냅샷 진행중 → base", auto(.loading, running: true) == 180)
}

print("▸ GitHubPollPolicy.backsOff")
do {
    check("헤더 없는 403 → 물러남 (보조 한도일 수 있음)", GitHubPollPolicy.backsOff(after: .http(403)))
    check("헤더 없는 429 → 물러남", GitHubPollPolicy.backsOff(after: .http(429)))
    check("500 → 물러나지 않음", !GitHubPollPolicy.backsOff(after: .http(500)))
    check("네트워크 오류 → 물러나지 않음",
          !GitHubPollPolicy.backsOff(after: .timedOut) && !GitHubPollPolicy.backsOff(after: .offline))
    // What the model does with it: one step of backoff, the plain error.
    let after403 = GitHubPollPolicy.backsOff(after: .http(403)) ? 1 : 0
    let state403 = GitHubLoadState.error(GitHubAPIError.http(403).detail)
    check("헤더 없는 403 뒤 → base·2 대기 (최소 1분 넘김, 진행중이어도 30 아님)",
          GitHubPollPolicy.nextAutoWait(after: state403, base: 60, backoff: after403,
                                        hasFreshRunningChecks: true) == 120)
    check("헤더 없는 403 뒤 → 팝오버를 열어도 요청 안 함 (머지 성공 뒤 갱신도 같은 판정)",
          !GitHubPollPolicy.refreshesOnOpen(after: state403, backoff: after403))
}

print("▸ GitHubPollPolicy.refreshesOnOpen")
do {
    func opens(_ state: GitHubLoadState, backoff: Int = 0) -> Bool {
        GitHubPollPolicy.refreshesOnOpen(after: state, backoff: backoff)
    }
    check("백오프 없음 → 열면 즉시 갱신", opens(.loaded(.pat)))
    check("오류 후 → 열면 즉시 갱신", opens(.error("x")))
    check("백오프 중 → 열어도 요청 안 함", !opens(.loaded(.pat), backoff: 1))
    check("401 상태 → 열어도 요청 안 함", !opens(.unauthorized))
    check("백오프 + 401 → 열어도 요청 안 함", !opens(.unauthorized, backoff: 1))
    check("PAT 저장 실패 → 열어도 요청 안 함", !opens(.patSaveFailed(-25299)))
}

// MARK: - 9. parse 관대함

func node(_ repo: String = "mongshell/bookdam", _ number: Int = 45, typename: String = "PullRequest",
          mergeable: String = "MERGEABLE", mergeState: String? = nil, review: Any = "APPROVED",
          rollup: String? = #"{"state":"SUCCESS","contexts":{"nodes":[]}}"#,
          url: String? = nil, id: String? = nil, headRefOid: String? = nil) -> String {
    let reviewJSON = review is NSNull ? "null" : "\"\(review)\""
    let rollupJSON = rollup ?? "null"
    let urlText = url ?? "https://github.com/\(repo)/pull/\(number)"
    let mergeStateJSON = mergeState.map { "\"mergeStateStatus\":\"\($0)\"," } ?? ""
    let idJSON = id.map { "\"id\":\"\($0)\"," } ?? ""
    let headJSON = headRefOid.map { "\"headRefOid\":\"\($0)\"," } ?? ""
    return """
    {"__typename":"\(typename)",\(idJSON)\(headJSON)"number":\(number),"title":"t","url":"\(urlText)",
     "isDraft":false,"reviewDecision":\(reviewJSON),"mergeable":"\(mergeable)",\(mergeStateJSON)
     "updatedAt":"2026-09-29T03:12:45Z","mergedAt":null,
     "repository":{"nameWithOwner":"\(repo)"},
     "commits":{"nodes":[{"commit":{"statusCheckRollup":\(rollupJSON)}}]}}
    """
}

func body(mine: [String] = [], merged: [String]? = [],
          rateLimit: String? = #"{"cost":12,"remaining":4812,"limit":5000,"resetAt":"2026-09-29T04:00:00Z"}"#,
          errors: String? = nil) -> Data {
    var data = ["\"mine\":{\"nodes\":[\(mine.joined(separator: ","))]}"]
    if let merged { data.append("\"merged\":{\"nodes\":[\(merged.joined(separator: ","))]}") }
    if let rateLimit { data.append("\"rateLimit\":\(rateLimit)") }
    var root = ["\"data\":{\(data.joined(separator: ","))}"]
    if let errors { root.append("\"errors\":\(errors)") }
    return Data("{\(root.joined(separator: ","))}".utf8)
}

func parsed(_ data: Data) -> GitHubSnapshot? { try? GitHubAPIClient.parse(data, now: now) }

print("▸ parse 관대함")
do {
    let s = parsed(body(mine: [node()], merged: nil))
    check("alias 누락(merged) → 그 목록만 빈 배열, 나머지는 채움",
          s?.mine.count == 1 && s?.recentlyMerged.isEmpty == true,
          "\(String(describing: s))")
    check("rateLimit 읽음", s?.rateLimit == GitHubRateLimit(cost: 12, remaining: 4812, limit: 5000,
                                                        resetAt: ISO8601DateFormatter().date(from: "2026-09-29T04:00:00Z")))
    check("URL·repository·number 읽음",
          s?.mine.first?.url?.absoluteString == "https://github.com/mongshell/bookdam/pull/45"
              && s?.mine.first?.repository == "mongshell/bookdam"
              && s?.mine.first?.number == 45)

    let typed = parsed(body(mine: [node(typename: "Issue"), node("mongshell/menubar", 8)]))
    check("__typename 이 PullRequest 가 아닌 노드는 건너뜀",
          typed?.mine.map(\.number) == [8], "\(String(describing: typed?.mine.map(\.number)))")

    check("rateLimit 누락 → nil", parsed(body(rateLimit: nil))?.rateLimit == nil)
    check("rateLimit 있어도 목록은 독립", parsed(body(rateLimit: nil))?.mine.isEmpty == true)

    let odd = parsed(body(mine: [node(mergeable: "SOMETHING_NEW")]))
    check("mergeable 모르는 문자열 → unknown (충돌도 머지 가능도 아님)",
          odd?.mine.first?.mergeable == .unknown)
    check("mergeable UNKNOWN → unknown", parsed(body(mine: [node(mergeable: "UNKNOWN")]))?.mine.first?.mergeable == .unknown)
    check("mergeable CONFLICTING → conflicting",
          parsed(body(mine: [node(mergeable: "CONFLICTING")]))?.mine.first?.mergeable == .conflicting)

    let noRollup = parsed(body(mine: [node(rollup: nil)]))?.mine.first
    check("statusCheckRollup null → rollup none + 빈 checks",
          noRollup?.checksRollup == PRChecksRollup.none && noRollup?.checks.isEmpty == true)
    let newState = parsed(body(mine: [node(rollup: #"{"state":"WEIRD","contexts":{"nodes":[]}}"#)]))?.mine.first
    check("rollup 모르는 state → pending (success 아님)", newState?.checksRollup == .pending)
    check("rollup FAILURE·ERROR → failure",
          parsed(body(mine: [node(rollup: #"{"state":"ERROR"}"#)]))?.mine.first?.checksRollup == .failure
              && parsed(body(mine: [node(rollup: #"{"state":"FAILURE"}"#)]))?.mine.first?.checksRollup == .failure)

    let states: [(String, PRMergeState)] = [("CLEAN", .clean), ("BLOCKED", .blocked), ("BEHIND", .behind),
                                            ("DIRTY", .dirty), ("DRAFT", .draft), ("HAS_HOOKS", .hasHooks),
                                            ("UNSTABLE", .unstable), ("UNKNOWN", .unknown), ("SHINY_NEW", .unknown)]
    for (raw, expected) in states {
        check("mergeStateStatus \(raw) → \(expected)",
              parsed(body(mine: [node(mergeState: raw)]))?.mine.first?.mergeState == expected)
    }
    check("mergeStateStatus 누락 → unknown", parsed(body(mine: [node()]))?.mine.first?.mergeState == .unknown)

    check("reviewDecision null → none", parsed(body(mine: [node(review: NSNull())]))?.mine.first?.reviewDecision == PRReviewDecision.none)
    check("reviewDecision 모르는 값 → none (approved 아님)",
          parsed(body(mine: [node(review: "BLESSED")]))?.mine.first?.reviewDecision == PRReviewDecision.none)

    let contexts = #"""
    {"state":"PENDING","contexts":{"nodes":[
      {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS",
       "startedAt":"2026-09-29T03:00:00Z","completedAt":"2026-09-29T03:01:30Z","detailsUrl":"https://x/1"},
      {"__typename":"StatusContext","context":"ci/legacy","state":"PENDING","createdAt":"2026-09-29T03:00:00Z","targetUrl":"https://x/2"},
      {"__typename":"Mystery","name":"?"}]}}
    """#
    let chips = parsed(body(mine: [node(rollup: contexts)]))?.mine.first?.checks ?? []
    check("CheckRun·StatusContext 를 한 어휘로, 모르는 typename 은 건너뜀",
          chips.map(\.name) == ["build", "ci/legacy"] && chips.map(\.outcome) == [.passed, .queued],
          "\(chips.map(\.name))")
    check("CheckRun 은 시각 둘 다, StatusContext 는 둘 다 nil",
          chips.first?.startedAt != nil && chips.first?.completedAt != nil
              && chips.last?.startedAt == nil && chips.last?.completedAt == nil)
    check("CheckRun 소요 90s", chips.first.flatMap { c in c.completedAt.flatMap { e in c.startedAt.map { e.timeIntervalSince($0) } } } == 90)

    // Links reach NSWorkspace.open from a click, so the parse boundary is
    // the only place a hostile or careless value can be stopped.
    func prURL(_ url: String) -> URL? { parsed(body(mine: [node(url: url)]))?.mine.first?.url }
    check("PR url https://github.com → 그대로",
          prURL("https://github.com/mongshell/bookdam/pull/45")?.absoluteString
              == "https://github.com/mongshell/bookdam/pull/45")
    check("PR url 호스트 대소문자 무시", prURL("https://GitHub.com/a/b/pull/1") != nil)
    check("PR url javascript: → nil", prURL("javascript:alert(1)") == nil)
    check("PR url vscode:// → nil", prURL("vscode://file/etc/passwd") == nil)
    check("PR url http://github.com → nil", prURL("http://github.com/a/b/pull/1") == nil)
    check("PR url 다른 호스트 → nil", prURL("https://evil.example/a/b/pull/1") == nil)
    check("PR url userinfo 로 github.com 흉내 → nil", prURL("https://github.com@evil.example/a") == nil)
    check("PR url 하위 도메인 → nil", prURL("https://gist.github.com/a") == nil)
    check("PR 은 url 이 걸러져도 행은 남음", parsed(body(mine: [node(url: "javascript:x")]))?.mine.count == 1)

    func checkURLs(_ detailsUrl: String, _ targetUrl: String) -> [URL?] {
        let rollup = """
        {"state":"SUCCESS","contexts":{"nodes":[
          {"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"\(detailsUrl)"},
          {"__typename":"StatusContext","context":"b","state":"SUCCESS","targetUrl":"\(targetUrl)"}]}}
        """
        return parsed(body(mine: [node(rollup: rollup)]))?.mine.first?.checks.map(\.url) ?? []
    }
    let thirdParty = checkURLs("https://ci.example/run/1", "https://status.example/2")
    check("검사 url 은 https 면 제3자 호스트도 받음",
          thirdParty.map { $0?.host } == ["ci.example", "status.example"], "\(thirdParty)")
    check("검사 url javascript:·vscode:// → nil",
          checkURLs("javascript:alert(1)", "vscode://x") == [nil, nil])
    check("검사 url http:// → nil",
          checkURLs("http://ci.example/1", "http://status.example/2") == [nil, nil])

    check("data 없음 → badResponse (빈 목록으로 가장하지 않음)",
          parsed(Data(#"{"errors":[{"message":"bad query"}]}"#.utf8)) == nil)
    check("JSON 아님 → badResponse", parsed(Data("<html>".utf8)) == nil)
    check("숫자가 아닌 number 는 건너뜀",
          parsed(Data(#"{"data":{"mine":{"nodes":[{"__typename":"PullRequest","number":true,"repository":{"nameWithOwner":"a/b"}}]}}}"#.utf8))?.mine.isEmpty == true)
}

// MARK: - 9b. 재실행된 검사 (gambau#1982 모양, 2026-10-20 실측)

print("▸ 재실행 검사 끝에서 끝까지")
do {
    // The re-runs all came from the one `verify` workflow; the Vercel app's
    // run has no workflow, only the app.
    func run(_ name: String, _ conclusion: String, _ start: String, _ end: String,
             workflow: String? = "verify", app: String? = "github-actions") -> String {
        let workflowRun = workflow.map { #"{"workflow":{"name":"\#($0)"}}"# } ?? "null"
        let appJSON = app.map { #"{"slug":"\#($0)"}"# } ?? "null"
        return #"{"__typename":"CheckRun","name":"\#(name)","status":"COMPLETED","conclusion":"\#(conclusion)","startedAt":"2026-10-20T\#(start)Z","completedAt":"2026-10-20T\#(end)Z","detailsUrl":"https://x/\#(name)","checkSuite":{"workflowRun":\#(workflowRun),"app":\#(appJSON)}}"#
    }
    let contexts = [
        run("static", "SUCCESS", "05:23:35", "05:25:07"),
        run("static", "SUCCESS", "05:25:54", "05:27:15"),
        run("test", "CANCELLED", "05:23:35", "05:25:51"),
        run("test", "SUCCESS", "05:25:54", "05:28:09"),
        run("automerge", "CANCELLED", "05:25:52", "05:25:51"),
        run("automerge", "SUCCESS", "05:28:12", "05:28:21"),
        #"{"__typename":"StatusContext","context":"Vercel","state":"SUCCESS","createdAt":"2026-10-20T05:26:53Z","targetUrl":"https://x/v"}"#,
        run("Vercel Preview Comments", "SUCCESS", "05:23:18", "05:23:18", workflow: nil, app: "vercel"),
    ]
    func rollup(totalCount: Int?) -> String {
        let count = totalCount.map { "\"totalCount\":\($0)," } ?? ""
        return #"{"state":"FAILURE","contexts":{"# + count + #""nodes":["# + contexts.joined(separator: ",") + "]}}"
    }
    let full = parsed(body(mine: [node("mongshellio/gambau", 1982, mergeState: "UNKNOWN", review: NSNull(),
                                       rollup: rollup(totalCount: 8))]))
    let pr1982 = full?.mine.first
    check("워크플로·job 별 최신 실행 하나씩, 원래 순서",
          pr1982?.checks.map(\.name) == ["static", "test", "automerge", "Vercel", "Vercel Preview Comments"],
          "\(String(describing: pr1982?.checks.map(\.name)))")
    check("남은 칩은 전부 passed", pr1982?.checks.allSatisfy { $0.outcome == .passed } == true)
    check("totalCount 8 == 받은 8 → 목록 끝까지", pr1982?.checksListComplete == true)
    check("rollup FAILURE 인데 verdict 는 검사 실패 아님",
          pr1982.map { verdict($0) } == .awaitingReview, "\(String(describing: pr1982.map { verdict($0) }))")
    let g = full.map { GitHubGlance.of($0, state: .loaded(.pat), hidden: [], mergeActivity: [:]) }
    check("Glance 도 정리된 판정 — 막힘 0·초록·\"막힘 0\"",
          g?.count == 0 && g?.dot == .green && g?.hoverMineLine == "내 PR 1 · 막힘 0", "\(String(describing: g))")

    let cut = parsed(body(mine: [node(rollup: rollup(totalCount: 40))]))?.mine.first
    check("totalCount > 받은 수(잘림) → rollup FAILURE 로 검사 실패",
          cut?.checksListComplete == false && cut.map { verdict($0) } == .checksFailed)
    let noCount = parsed(body(mine: [node(rollup: rollup(totalCount: nil))]))?.mine.first
    check("totalCount 누락 → 끝까지 받았다고 보지 않음 (rollup)",
          noCount?.checksListComplete == false && noCount.map { verdict($0) } == .checksFailed)
    let mystery = #"{"state":"FAILURE","contexts":{"totalCount":2,"nodes":[\#(run("a", "SUCCESS", "05:00:00", "05:01:00")),{"__typename":"Mystery"}]}}"#
    check("건너뛴 모르는 노드가 있으면 끝까지 받은 게 아님 (rollup)",
          parsed(body(mine: [node(rollup: mystery)]))?.mine.first.map { verdict($0) } == .checksFailed)
    let empty = parsed(body(mine: [node(rollup: #"{"state":"FAILURE","contexts":{"totalCount":0,"nodes":[]}}"#)]))?.mine.first
    check("contexts 비고 rollup FAILURE → 검사 실패", empty.map { verdict($0) } == .checksFailed)

    // `name` is the job's only: CI's `build` and Release's `build` are two
    // checks, and one passing must not hide the other failing.
    func suites(_ nodes: [String]) -> GitHubPullRequest? {
        let rollup = #"{"state":"FAILURE","contexts":{"totalCount":\#(nodes.count),"nodes":["# + nodes.joined(separator: ",") + "]}}"
        return parsed(body(mine: [node(rollup: rollup)]))?.mine.first
    }
    let twoWorkflows = suites([run("build", "FAILURE", "05:00:00", "05:01:00", workflow: "CI"),
                               run("build", "SUCCESS", "05:10:00", "05:11:00", workflow: "Release")])
    check("같은 이름·다른 워크플로 둘(실패·성공) → 둘 다 남고 검사 실패",
          twoWorkflows?.checks.map(\.outcome) == [.failed, .passed] && twoWorkflows.map { verdict($0) } == .checksFailed,
          "\(String(describing: twoWorkflows?.checks.map(\.outcome)))")
    let rerun = suites([run("build", "FAILURE", "05:00:00", "05:01:00", workflow: "CI"),
                        run("build", "SUCCESS", "05:10:00", "05:11:00", workflow: "CI")])
    check("같은 워크플로의 재실행 → 하나만 남음",
          rerun?.checks.map(\.outcome) == [.passed] && rerun.map { verdict($0) } != .checksFailed)
    let byApp = suites([run("deploy", "FAILURE", "05:00:00", "05:01:00", workflow: nil, app: "vercel"),
                        run("deploy", "SUCCESS", "05:10:00", "05:11:00", workflow: nil, app: "vercel")])
    check("워크플로 없으면 앱 slug 로 묶음", byApp?.checks.map(\.outcome) == [.passed])
    let anonymous = suites([run("build", "FAILURE", "05:00:00", "05:01:00", workflow: nil, app: nil),
                            run("build", "SUCCESS", "05:10:00", "05:11:00", workflow: nil, app: nil)])
    check("suite 식별자 없는 같은 이름 둘 → 둘 다 남음",
          anonymous?.checks.count == 2 && anonymous.map { verdict($0) } == .checksFailed)

    // A failure that survives the dedupe still names the check in the hover.
    let stillFailing = [run("test", "SUCCESS", "05:00:00", "05:01:00"), run("test", "FAILURE", "05:10:00", "05:11:00")]
    let failing = #"{"state":"FAILURE","contexts":{"totalCount":2,"nodes":["# + stillFailing.joined(separator: ",") + "]}}"
    let fs = parsed(body(mine: [node("mongshell/bookdam", 45, rollup: failing)]))
    check("최신 실행이 실패면 칩 하나·hover \"#45 test 실패\"",
          fs?.mine.first?.checks.count == 1
              && fs.map { GitHubGlance.of($0, state: .loaded(.pat), hidden: [], mergeActivity: [:]).hoverMineLine } == "내 PR 1 · 막힘 1 · #45 test 실패")
}

// MARK: - 9c. 밀려난 실행 (gambau#2014 모양, 2026-10-20 실측)

print("▸ 밀려난 실행 끝에서 끝까지")
do {
    func run(_ name: String, _ status: String, _ conclusion: String?, _ start: String, _ end: String?,
             runNumber: Int?, event: String? = "pull_request",
             workflow: String = "verify", workflowID: Int? = 335_587_108) -> String {
        func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        let number = runNumber.map(String.init) ?? "null"
        let id = workflowID.map(String.init) ?? "null"
        return #"{"__typename":"CheckRun","name":"\#(name)","status":"\#(status)","conclusion":\#(json(conclusion)),"startedAt":"2026-10-20T\#(start)Z","completedAt":\#(json(end.map { "2026-10-20T\($0)Z" })),"detailsUrl":"https://x/\#(name)","checkSuite":{"workflowRun":{"runNumber":\#(number),"event":\#(json(event)),"workflow":{"databaseId":\#(id),"name":"\#(workflow)"}},"app":{"slug":"github-actions"}}}"#
    }
    let vercel = #"{"__typename":"CheckRun","name":"Vercel Preview Comments","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-20T15:14:10Z","completedAt":"2026-10-20T15:14:10Z","detailsUrl":"https://x/v","checkSuite":{"workflowRun":null,"app":{"slug":"vercel"}}}"#
    func pullRequest(_ contexts: [String]) -> GitHubPullRequest? {
        let rollup = #"{"state":"FAILURE","contexts":{"totalCount":\#(contexts.count),"nodes":["# + contexts.joined(separator: ",") + "]}}"
        return parsed(body(mine: [node("mongshellio/gambau", 2014, mergeState: "UNKNOWN", review: NSNull(),
                                       rollup: rollup)]))?.mine.first
    }
    let pr2014 = pullRequest([
        run("test", "COMPLETED", "CANCELLED", "15:14:05", "15:14:20", runNumber: 874),
        run("static", "COMPLETED", "CANCELLED", "15:14:27", "15:14:42", runNumber: 874),
        run("test", "COMPLETED", "CANCELLED", "15:14:27", "15:14:42", runNumber: 874),
        run("automerge", "COMPLETED", "CANCELLED", "15:14:42", "15:14:42", runNumber: 874),
        run("static", "COMPLETED", "SUCCESS", "15:14:45", "15:16:10", runNumber: 875),
        run("test", "IN_PROGRESS", nil, "15:14:45", nil, runNumber: 875),
        vercel,
    ])
    check("최신 실행(875)과 다른 앱 검사만 남음 — 874 의 automerge 없음",
          pr2014?.checks.map(\.name) == ["static", "test", "Vercel Preview Comments"]
              && pr2014?.checks.map(\.outcome) == [.passed, .running, .passed],
          "\(String(describing: pr2014?.checks.map(\.name)))")
    check("버린 것도 읽은 것 — totalCount 7 == 받은 7 → 목록 끝까지", pr2014?.checksListComplete == true)
    check("rollup FAILURE 인데 검사 실패가 아니라 진행중",
          pr2014?.effectiveChecks == .pending && pr2014.map { verdict($0) } != .checksFailed,
          "\(String(describing: pr2014.map { verdict($0) }))")

    let otherEvent = pullRequest([run("deploy", "COMPLETED", "FAILURE", "15:10:00", "15:11:00",
                                      runNumber: 870, event: "push"),
                                  run("test", "IN_PROGRESS", nil, "15:14:45", nil, runNumber: 875)])
    check("push 실행은 pull_request 실행에 밀리지 않음 (파싱 경로)",
          otherEvent?.checks.map(\.name) == ["deploy", "test"] && otherEvent.map { verdict($0) } == .checksFailed,
          "\(String(describing: otherEvent?.checks.map(\.name)))")
    // Two workflow files both named `verify`: each counts its own runs, so
    // the other file's bigger number says nothing about this one.
    let sameName = pullRequest([run("lint", "COMPLETED", "FAILURE", "15:10:00", "15:11:00",
                                    runNumber: 12, workflowID: 999),
                                run("test", "IN_PROGRESS", nil, "15:14:45", nil, runNumber: 875)])
    check("이름은 같고 워크플로 id 가 다르면 작은 runNumber 쪽 FAILURE 가 남음 (파싱 경로)",
          sameName?.checks.map(\.name) == ["lint", "test"] && sameName.map { verdict($0) } == .checksFailed,
          "\(String(describing: sameName?.checks.map(\.name)))")
    let noWorkflowID = pullRequest([run("automerge", "COMPLETED", "CANCELLED", "15:14:42", "15:14:42",
                                        runNumber: 874, workflowID: nil),
                                    run("test", "IN_PROGRESS", nil, "15:14:45", nil, runNumber: 875)])
    check("워크플로 id 를 못 읽은 실행은 밀려났다고 보지 않음",
          noWorkflowID?.checks.map(\.name) == ["automerge", "test"],
          "\(String(describing: noWorkflowID?.checks.map(\.name)))")
    let noEvent = pullRequest([run("automerge", "COMPLETED", "CANCELLED", "15:14:42", "15:14:42",
                                   runNumber: 874, event: nil),
                               run("test", "IN_PROGRESS", nil, "15:14:45", nil, runNumber: 875)])
    check("event 를 못 읽은 실행은 밀려났다고 보지 않음",
          noEvent?.checks.map(\.name) == ["automerge", "test"], "\(String(describing: noEvent?.checks.map(\.name)))")
    let noNumber = pullRequest([run("automerge", "COMPLETED", "CANCELLED", "15:14:42", "15:14:42", runNumber: nil),
                                run("test", "IN_PROGRESS", nil, "15:14:45", nil, runNumber: 875)])
    check("runNumber 를 못 읽은 CheckRun 은 남음 (파싱 경로)",
          noNumber?.checks.map(\.name) == ["automerge", "test"] && noNumber.map { verdict($0) } == .checksFailed)
}

// MARK: - 10. interpret

print("▸ interpret (상태 코드·헤더)")
do {
    func interpret(_ code: Int, _ headers: [String: String] = [:], _ data: Data = Data()) -> Result<GitHubFetchResult, GitHubAPIError> {
        do { return .success(try GitHubAPIClient.interpret(statusCode: code, headers: headers, data: data, now: now)) }
        catch { return .failure(error) }
    }
    check("401 → unauthorized", interpret(401) == .success(.unauthorized))
    check("403 + retry-after → rateLimited(now + 30)",
          interpret(403, ["retry-after": "30"]) == .success(.rateLimited(retryAt: now.addingTimeInterval(30))))
    check("429 + retry-after → rateLimited",
          interpret(429, ["Retry-After": "7"]) == .success(.rateLimited(retryAt: now.addingTimeInterval(7))))
    check("403 + remaining 0 → rateLimited(reset epoch)",
          interpret(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790003600"])
              == .success(.rateLimited(retryAt: Date(timeIntervalSince1970: 1_790_003_600))))
    check("403 맨몸 → http(403)", interpret(403) == .failure(.http(403)))
    check("200 + remaining 0 → rateLimited (데이터보다 우선)",
          interpret(200, ["x-ratelimit-remaining": "0"], body(mine: [node()]))
              == .success(.rateLimited(retryAt: nil)))
    check("errors RATE_LIMITED + data 동반 → rateLimited 가 데이터보다 우선",
          interpret(200, ["x-ratelimit-reset": "1790003600"], body(mine: [node()], errors: #"[{"type":"RATE_LIMITED","message":"slow down"}]"#))
              == .success(.rateLimited(retryAt: Date(timeIntervalSince1970: 1_790_003_600))))
    check("다른 errors + data → 데이터는 읽음",
          { if case .success(.snapshot(let s)) = interpret(200, [:], body(mine: [node()], errors: #"[{"type":"NOT_FOUND"}]"#)) { return s.mine.count == 1 }; return false }())

    func scopes(_ headers: [String: String]) -> Bool?? {
        if case .success(.snapshot(let s)) = interpret(200, headers, body()) { return .some(s.tokenScopesLackRepo) }
        return nil
    }
    check("x-oauth-scopes 에 repo 있음 → false", scopes(["x-oauth-scopes": "repo, read:org"]) == .some(false))
    check("x-oauth-scopes 에 repo 없음 → true", scopes(["X-OAuth-Scopes": "public_repo, gist"]) == .some(true))
    check("x-oauth-scopes 헤더 없음 → nil", scopes([:]) == .some(nil))
    check("500 → http(500)", interpret(500) == .failure(.http(500)))
    check("302(리다이렉트 거부 결과) → http(302)", interpret(302) == .failure(.http(302)))
    check("200 + JSON 아님 → badResponse", interpret(200, [:], Data("nope".utf8)) == .failure(.badResponse))
    check("2xx 만 본문 읽음", GitHubAPIClient.readsBody(statusCode: 200)
              && !GitHubAPIClient.readsBody(statusCode: 401) && !GitHubAPIClient.readsBody(statusCode: 403))
    check("URLError.cancelled → cancelled", GitHubAPIError.transport(.cancelled) == .cancelled)
    check("오프라인 → offline", GitHubAPIError.transport(.notConnectedToInternet) == .offline)
}

// MARK: - 11. query

print("▸ query")
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    let since = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))!
    let q = GitHubAPIClient.query(mergedSince: since, calendar: cal)
    check("merged:>=YYYY-MM-DD (로컬 달력)", q.contains("merged:>=2026-10-13"), q)
    check("alias 2개 (mine·merged)", q.contains("mine: search(") && q.contains("merged: search(")
              && q.components(separatedBy: ": search(").count == 3)
    check("리뷰 요청 검색 없음", !q.contains("review-requested") && !q.contains("reviewRequested"))
    check("검색어", q.contains("is:pr is:open author:@me") && q.contains("is:pr is:merged author:@me"))
    check("rateLimit 포함", q.contains("rateLimit { cost remaining limit resetAt }"))
    check("statusCheckRollup 과 두 컨텍스트 타입",
          q.contains("statusCheckRollup { state") && q.contains("... on CheckRun {") && q.contains("... on StatusContext {"))
    check("mergeStateStatus 요청", q.contains(" mergeStateStatus "))
    check("first: 20 / contexts first: 30", q.contains("first: 20)") && q.contains("contexts(first: 30)"))
    check("contexts 의 totalCount 요청", q.contains("contexts(first: 30) { totalCount nodes"))
    check("CheckRun 의 실행 번호·event·워크플로 id·이름·앱 slug 요청",
          q.contains("checkSuite { workflowRun { runNumber event workflow { databaseId name } } app { slug } }"))
    check("mutation 아님", !q.contains("mutation"))
    // The day boundary follows the calendar handed in, not UTC.
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    check("같은 순간이 UTC 로는 전날", GitHubAPIClient.query(mergedSince: since, calendar: utc).contains("merged:>=2026-10-13"))
    let lateNight = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 1))!
    check("서울 01시 = UTC 전날 → 달력이 결정", GitHubAPIClient.query(mergedSince: lateNight, calendar: utc).contains("merged:>=2026-10-12"))
}

// MARK: - 11b. 머지 mutation (Decision #49)

print("▸ PR 노드 id · head SHA")
do {
    let full = parsed(body(mine: [node(id: "PR_kwDOabc", headRefOid: "0123abcd")]))?.mine.first
    check("id → nodeID", full?.nodeID == "PR_kwDOabc", "\(String(describing: full?.nodeID))")
    check("headRefOid → headSHA", full?.headSHA == "0123abcd")
    let bare = parsed(body(mine: [node()]))?.mine.first
    check("id·headRefOid 없음 → nil (행은 남음)", bare != nil && bare?.nodeID == nil && bare?.headSHA == nil)
    let empty = parsed(body(mine: [node(id: "", headRefOid: "")]))?.mine.first
    check("빈 문자열 → nil", empty?.nodeID == nil && empty?.headSHA == nil)
    let q = GitHubAPIClient.query(mergedSince: now)
    check("query 가 id·headRefOid 를 요청", q.contains(" id number ") && q.contains(" headRefOid "))
}

print("▸ 머지 mutation")
do {
    let m = GitHubAPIClient.mergeMutation
    check("mutation 이다", m.hasPrefix("mutation"))
    check("mergeMethod: SQUASH", m.contains("mergeMethod: SQUASH"))
    check("expectedHeadOid 를 변수로 넘김", m.contains("expectedHeadOid: $expectedHeadOid")
              && m.contains("$expectedHeadOid: GitObjectID!"))
    check("pullRequestId 를 변수로 넘김", m.contains("pullRequestId: $pullRequestId") && m.contains("$pullRequestId: ID!"))
    check("브랜치 삭제·커밋 문구 인자 없음",
          !m.contains("deleteBranch") && !m.contains("commitHeadline") && !m.contains("commitBody"))
    check("결과로 state 를 받음", m.contains("pullRequest { number state mergedAt }"))
    let b = GitHubAPIClient.mergeRequestBody(pullRequestId: "PR_x", expectedHeadOid: "abc")
    let vars = b["variables"] as? [String: String]
    check("본문 variables 에 두 id", vars == ["pullRequestId": "PR_x", "expectedHeadOid": "abc"])
    check("본문 query 는 mutation 원문", b["query"] as? String == m)
}

print("▸ 머지 응답 해석")
do {
    func merge(_ code: Int, _ json: String = "", _ headers: [String: String] = [:]) -> GitHubMergeResult {
        GitHubAPIClient.interpretMerge(statusCode: code, headers: headers, data: Data(json.utf8))
    }
    let merged = #"{"data":{"mergePullRequest":{"pullRequest":{"number":57,"state":"MERGED","mergedAt":"2026-10-20T03:00:00Z"}}}}"#
    check("state MERGED → merged", merge(200, merged) == .merged)
    check("성공은 실패 사유 없음", GitHubMergeResult.merged.failureReason == nil)
    let moved = #"{"data":{"mergePullRequest":null},"errors":[{"type":"UNPROCESSABLE","path":["mergePullRequest"],"message":"Head branch was modified. Review and try the merge again."}]}"#
    check("head 바뀜 메시지 → headChanged", merge(200, moved) == .headChanged, "\(merge(200, moved))")
    let refused = #"{"data":{"mergePullRequest":null},"errors":[{"type":"UNPROCESSABLE","message":"Pull Request is not mergeable"}]}"#
    check("머지 불가 → GitHub 메시지", merge(200, refused) == .notMergeable("Pull Request is not mergeable"))
    let badVar = #"{"errors":[{"message":"Variable $expectedHeadOid of type GitObjectID! was provided invalid value"}]}"#
    check("expectedHeadOid 변수 오류 → head 바뀜 아님 (GitHub 원문)",
          merge(200, badVar) == .notMergeable("Variable $expectedHeadOid of type GitObjectID! was provided invalid value"),
          "\(merge(200, badVar))")
    let movedLower = #"{"errors":[{"message":"head branch was modified"}]}"#
    check("head 바뀜 문구는 대소문자 무시", merge(200, movedLower) == .headChanged)
    check("머지 불가 사유 문구에 GitHub 메시지", GitHubMergeResult.notMergeable("x y").failureReason?.contains("x y") == true)
    let protected = #"{"errors":[{"message":"Repository rule violations found\n\nRequired status check \"build\" is expected."}]}"#
    check("여러 줄 메시지 → 한 줄",
          merge(200, protected) == .notMergeable(#"Repository rule violations found Required status check "build" is expected."#),
          "\(merge(200, protected))")
    let forbidden = #"{"data":{"mergePullRequest":null},"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by personal access token"}]}"#
    check("errors FORBIDDEN → forbidden", merge(200, forbidden) == .forbidden)
    check("403 (한도 헤더 없음) → forbidden", merge(403) == .forbidden)
    check("403 + x-ratelimit-remaining 0 → rateLimited", merge(403, "", ["X-RateLimit-Remaining": "0"]) == .rateLimited)
    check("403 + retry-after → rateLimited", merge(403, "", ["retry-after": "30"]) == .rateLimited)
    check("429 → rateLimited", merge(429) == .rateLimited)
    check("errors RATE_LIMITED → rateLimited",
          merge(200, #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#) == .rateLimited)
    check("401 → unauthorized", merge(401) == .unauthorized)
    let both = #"{"data":{"mergePullRequest":{"pullRequest":{"number":57,"state":"MERGED"}}},"errors":[{"type":"SOMETHING","message":"partial"}]}"#
    check("errors + data(MERGED) 동반 → merged (머지는 일어났다)", merge(200, both) == .merged)
    let open = #"{"data":{"mergePullRequest":{"pullRequest":{"number":57,"state":"OPEN"}}}}"#
    check("errors 없이 OPEN → 머지 아님", { if case .notMergeable = merge(200, open) { return true }; return false }())
    let oddState = #"{"data":{"mergePullRequest":{"pullRequest":{"number":57,"state":"QUEUED\n ghp_abcdef123 \#(String(repeating: "x", count: 200))"}}}}"#
    let oddReason: String = { if case .notMergeable(let why) = merge(200, oddState) { return why }; return "" }()
    check("서버 state 도 정규화 (한 줄·마스킹·자르기)",
          !oddReason.contains("\n") && !oddReason.contains("ghp_") && oddReason.contains("•••")
              && oddReason.count == GitHubAPIClient.mergeMessageMaxLength + 1 && oddReason.hasSuffix("…"),
          oddReason)
    check("깨진 JSON → failed(badResponse)", merge(200, "<html>") == .failed(.badResponse))
    check("data·errors 둘 다 없음 → failed(badResponse)", merge(200, "{}") == .failed(.badResponse))
    check("502 → failed(http(502))", merge(502) == .failed(.http(502)))
    check("302 → failed(http(302))", merge(302) == .failed(.http(302)))
    check("전송 실패 사유는 GitHubAPIError.detail",
          GitHubMergeResult.failed(.offline).failureReason == GitHubAPIError.offline.detail)

    // The row shows GitHub's text; a token-shaped string must never reach it.
    let token = "ghp_" + String(repeating: "A1b2", count: 9)
    let leaky = #"{"errors":[{"message":"bad credentials for \#(token) and github_pat_11ABC_def"}]}"#
    let reason = merge(200, leaky).failureReason ?? ""
    check("오류 문구에 토큰 문자열 없음", !reason.contains(token) && !reason.contains("github_pat_11ABC_def")
              && reason.contains("•••"), reason)
    for result in [GitHubMergeResult.headChanged, .forbidden, .unauthorized, .rateLimited,
                   .failed(.network), .notMergeable("x")] {
        check("고정 문구에 토큰 접두 없음 (\(result))", !(result.failureReason ?? "").contains("ghp_"))
    }
    let long = String(repeating: "가", count: 300)
    let cut = GitHubAPIClient.mergeMessage(long)
    check("긴 메시지는 잘림", cut.count == GitHubAPIClient.mergeMessageMaxLength + 1 && cut.hasSuffix("…"))
    check("짧은 메시지는 그대로", GitHubAPIClient.mergeMessage("Pull Request is not mergeable") == "Pull Request is not mergeable")
}

print("▸ 머지 버튼 노출 (GitHubMergePolicy.canOffer)")
do {
    func offer(_ p: GitHubPullRequest, _ section: PRSection = .mine) -> Bool {
        GitHubMergePolicy.canOffer(p, section: section)
    }
    let ready = pr(merge: .clean, nodeID: "PR_1", headSHA: "abc")
    check("CLEAN + 내 PR + id·SHA → 있음", offer(ready))
    for state in [PRMergeState.blocked, .dirty, .unknown, .behind, .unstable, .hasHooks, .draft] {
        check("\(state) → 없음", !offer(pr(merge: state, nodeID: "PR_1", headSHA: "abc")))
    }
    check("Draft (CLEAN 이어도) → 없음", !offer(pr(draft: true, merge: .clean, nodeID: "PR_1", headSHA: "abc")))
    check("최근 머지 섹션 → 없음", !offer(ready, .merged))
    check("nodeID 없음 → 없음", !offer(pr(merge: .clean, headSHA: "abc")))
    check("headSHA 없음 → 없음", !offer(pr(merge: .clean, nodeID: "PR_1")))
    check("링크 없음 (URL 이 https·github.com 검사를 못 넘김) → 없음",
          !offer(pr(merge: .clean, nodeID: "PR_1", headSHA: "abc", linked: false)))
    check("reviewDecision 없어도 CLEAN 이면 있음 (혼자 쓰는 저장소)",
          offer(pr(review: .none, merge: .clean, rollup: .none, nodeID: "PR_1", headSHA: "abc")))
}

print("▸ 머지 상태 이월 (GitHubMergePolicy.carryOver)")
do {
    let open = pr("mongshell/bookdam", 57)
    let gone = pr("mongshell/bookdam", 58)
    let before: [String: PRMergeActivity] = [
        open.id: .merged, gone.id: .merged,
        pr("mongshell/bookdam", 59).id: .merging,
        pr("mongshell/bookdam", 60).id: .failed("머지 불가 — x"),
    ]
    let after = GitHubMergePolicy.carryOver(before, into: [open, pr("mongshell/bookdam", 60)])
    check("목록에 남은 머지됨 PR → 유지 (search 색인 지연)", after[open.id] == .merged)
    check("목록에서 빠진 머지됨 PR → 지움", after[gone.id] == nil)
    check("진행 중 → 유지", after[pr("mongshell/bookdam", 59).id] == .merging)
    check("실패 사유 → 다음 성공 갱신에서 지움", after[pr("mongshell/bookdam", 60).id] == nil)
}

print("▸ 머지 요청 판정 (GitHubMergePolicy.gate)")
do {
    let ready = pr("mongshell/bookdam", 57, merge: .clean, nodeID: "PR_57", headSHA: "abc")
    let loaded = GitHubLoadState.loaded(.pat)
    func gate(_ mine: [GitHubPullRequest]?, head: String = "abc", state: GitHubLoadState = loaded,
              activity: PRMergeActivity? = nil, id: String? = nil,
              listGeneration: Int = 2, generation: Int = 2,
              listSource: GitHubTokenSource? = .pat, tokenSource: GitHubTokenSource = .pat) -> GitHubMergePolicy.Gate {
        GitHubMergePolicy.gate(id: id ?? ready.id, expectedHead: head, mine: mine,
                               listGeneration: listGeneration, generation: generation,
                               listSource: listSource, tokenSource: tokenSource,
                               state: state, activity: activity)
    }
    check("현재 목록의 머지 가능 PR, 같은 head → 보냄", gate([ready]) == .send(nodeID: "PR_57"))
    check("행이 보인 head 와 목록의 head 가 다름 → headMoved", gate([ready], head: "old") == .headMoved)
    // The row's copy said CLEAN; the list now says BLOCKED — the list wins.
    let nowBlocked = pr("mongshell/bookdam", 57, merge: .blocked, nodeID: "PR_57", headSHA: "abc")
    check("목록에서 다시 꺼낸 PR 이 더는 머지 불가 → 무시", gate([nowBlocked]) == .ignore)
    let newNode = pr("mongshell/bookdam", 57, merge: .clean, nodeID: "PR_57b", headSHA: "abc")
    check("node id 는 목록의 것", gate([newNode]) == .send(nodeID: "PR_57b"))
    check("목록에 없음 → 무시", gate([pr("mongshell/bookdam", 58, merge: .clean, nodeID: "x", headSHA: "abc")]) == .ignore)
    check("스냅샷 없음 → 무시", gate(nil) == .ignore)
    check("진행 중 → 무시", gate([ready], activity: .merging) == .ignore)
    check("머지됨 → 무시", gate([ready], activity: .merged) == .ignore)
    check("실패 후 재시도 → 보냄", gate([ready], activity: .failed("x")) == .send(nodeID: "PR_57"))
    // A PAT applied or cleared bumps the generation; `.loaded` and the old
    // list stay up until the new token answers.
    check("토큰을 바꾼 뒤 아직 옛 목록 (세대가 다름) → 보내지 않고 사유", gate([ready], generation: 3) == .listStale)
    check("옛 목록에서 head 도 바뀜 → 세대 사유가 먼저", gate([ready], head: "old", generation: 3) == .listStale)
    check("세대가 달라도 이미 나간 머지 → 무시", gate([ready], activity: .merging, generation: 3) == .ignore)
    check("세대가 달라도 정지 상태 → 무시", gate([ready], state: .patSaveFailed(-1), generation: 3) == .ignore)
    // `gh auth switch` outside the app: same generation, another account.
    let alice = GitHubTokenSource.ghCLI(account: "alice")
    check("목록과 같은 gh 계정 → 보냄",
          gate([ready], listSource: alice, tokenSource: alice) == .send(nodeID: "PR_57"))
    check("목록을 받은 gh 계정과 지금 계정이 다름 → listStale",
          gate([ready], listSource: alice, tokenSource: .ghCLI(account: "bob")) == .listStale)
    check("gh 로 받은 목록, 지금은 PAT → listStale", gate([ready], listSource: alice, tokenSource: .pat) == .listStale)
    check("PAT 로 받은 목록, 지금은 gh → listStale", gate([ready], listSource: .pat, tokenSource: alice) == .listStale)
    check("목록의 출처를 모름 → listStale", gate([ready], listSource: nil, tokenSource: .pat) == .listStale)
    check("계정이 달라도 head 보다 출처 사유가 먼저",
          gate([ready], head: "old", listSource: alice, tokenSource: .pat) == .listStale)
    check("계정이 달라도 이미 나간 머지 → 무시",
          gate([ready], activity: .merging, listSource: alice, tokenSource: .pat) == .ignore)
    let retry = Date(timeIntervalSince1970: 0)
    for state in [GitHubLoadState.loaded(.ghCLI(account: "a")), .loading, .rateLimited(retryAt: retry)] {
        check("\(state) → 보낼 수 있음", GitHubMergePolicy.allowsMerge(in: state) && gate([ready], state: state) == .send(nodeID: "PR_57"))
    }
    for state in [GitHubLoadState.off, .noToken, .keychainDenied, .unauthorized, .patSaveFailed(-1), .error("x")] {
        check("\(state) → 보내지 않음", !GitHubMergePolicy.allowsMerge(in: state) && gate([ready], state: state) == .ignore)
    }
}

// MARK: - 12. gh Keychain 값 디코딩

print("▸ decodeGHKeyringValue")
do {
    let decode = GitHubCredentialStore.decodeGHKeyringValue
    check("base64 접두", decode("go-keyring-base64:Z2hvX2FiYzEyMw==") == "gho_abc123", decode("go-keyring-base64:Z2hvX2FiYzEyMw=="))
    check("hex 접두", decode("go-keyring-encoded:67686f5f616263313233") == "gho_abc123")
    check("hex 대문자", decode("go-keyring-encoded:67686F5F616263313233") == "gho_abc123")
    check("접두 없음 → 그대로", decode("gho_plain") == "gho_plain")
    check("앞뒤 공백·개행 트림", decode("  gho_plain\n") == "gho_plain")
    check("접두 앞 공백도 트림 후 인식", decode("\ngo-keyring-base64:Z2hvX2FiYzEyMw==\n") == "gho_abc123")
    check("깨진 base64 → 원문", decode("go-keyring-base64:!!!") == "go-keyring-base64:!!!")
    check("깨진 hex(홀수 길이) → 원문", decode("go-keyring-encoded:abc") == "go-keyring-encoded:abc")
    check("디코딩 결과의 개행도 트림", decode("go-keyring-base64:Z2hvX2FiYzEyMwo=") == "gho_abc123")
}

// MARK: - CheckRun / StatusContext → outcome

print("▸ 검사 어휘 매핑")
do {
    let run = GitHubAPIClient.checkRunOutcome
    check("COMPLETED+SUCCESS → passed", run("COMPLETED", "SUCCESS") == .passed)
    for c in ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"] {
        check("COMPLETED+\(c) → failed", run("COMPLETED", c) == .failed)
    }
    check("COMPLETED+NEUTRAL → skipped", run("COMPLETED", "NEUTRAL") == .skipped)
    check("COMPLETED+SKIPPED → skipped", run("COMPLETED", "SKIPPED") == .skipped)
    check("COMPLETED+모르는 conclusion → failed (초록 아님·대기 아님)", run("COMPLETED", "NEW_THING") == .failed)
    check("COMPLETED+conclusion null → failed", run("COMPLETED", nil) == .failed)
    check("IN_PROGRESS → running", run("IN_PROGRESS", nil) == .running)
    for s in ["QUEUED", "WAITING", "PENDING", "REQUESTED", "SOMETHING_NEW"] {
        check("\(s) → queued", run(s, nil) == .queued)
    }
    check("status nil → queued", run(nil, "SUCCESS") == .queued)

    let ctx = GitHubAPIClient.statusContextOutcome
    check("StatusContext SUCCESS → passed", ctx("SUCCESS") == .passed)
    check("StatusContext FAILURE → failed", ctx("FAILURE") == .failed)
    check("StatusContext ERROR → failed", ctx("ERROR") == .failed)
    check("StatusContext PENDING → queued", ctx("PENDING") == .queued)
    check("StatusContext EXPECTED → queued", ctx("EXPECTED") == .queued)
    check("StatusContext 모르는 값 → queued", ctx("WHATEVER") == .queued)
    check("StatusContext nil → queued", ctx(nil) == .queued)
}

// MARK: - 연결 표시 (#117)
// 팝오버의 배지·배너·배너 버튼과 설정의 토큰 행·버튼. 상태마다 하나씩 고정한다 —
// 매핑 하나가 바뀌면 사용자가 보는 배지 문구나 버튼이 바뀐다.

do {
    func p(_ state: GitHubLoadState, _ source: GitHubTokenSource? = nil) -> GitHubPresentation {
        GitHubPresentation(loadState: state, tokenSource: source)
    }
    typealias B = GitHubPresentation.Banner
    typealias A = GitHubPresentation.BannerAction
    let retryAt = now.addingTimeInterval(300)
    let gh = GitHubTokenSource.ghCLI(account: "mongshellio")

    // 배지
    check("배지: off → 동기화 중 (loading 과 같다)", p(.off).badge == .syncing)
    check("배지: loading → 동기화 중", p(.loading).badge == .syncing)
    check("배지: loaded(gh) → 연결됨", p(.loaded(gh)).badge == .connected)
    check("배지: loaded(pat) → 연결됨", p(.loaded(.pat)).badge == .connected)
    check("배지: noToken → 토큰 없음", p(.noToken).badge == .noToken)
    check("배지: keychainDenied → 거부됨", p(.keychainDenied).badge == .denied)
    check("배지: rateLimited → 제한됨", p(.rateLimited(retryAt: retryAt)).badge == .limited)
    check("배지: unauthorized → 권한 부족", p(.unauthorized).badge == .unauthorized)
    check("배지: patSaveFailed → 오류", p(.patSaveFailed(-25300)).badge == .failed)
    check("배지: error → 오류", p(.error("x")).badge == .failed)

    // 배너와 그 버튼
    check("배너: off → 불러오는 중, 버튼 없음",
          p(.off).banner == B.loading && p(.off).bannerAction == A.none)
    check("배너: loading → 불러오는 중, 버튼 없음",
          p(.loading).banner == B.loading && p(.loading).bannerAction == A.none)
    check("배너: loaded(gh) → gh 계정명, 버튼 없음",
          p(.loaded(gh)).banner == B.ghAccount("mongshellio") && p(.loaded(gh)).bannerAction == A.none)
    check("배너: loaded(pat) → PAT 사용 중, 버튼 없음",
          p(.loaded(.pat)).banner == B.pat && p(.loaded(.pat)).bannerAction == A.none)
    check("배너: noToken → 설정 열기 버튼",
          p(.noToken).banner == B.noToken && p(.noToken).bannerAction == A.openSettings)
    check("배너: keychainDenied → gh Keychain 재시도 버튼",
          p(.keychainDenied).banner == B.keychainDenied && p(.keychainDenied).bannerAction == A.retryGHKeychain)
    check("배너: rateLimited → retryAt 그대로, 버튼 없음 (자동 재시도)",
          p(.rateLimited(retryAt: retryAt)).banner == B.rateLimited(retryAt: retryAt)
          && p(.rateLimited(retryAt: retryAt)).bannerAction == A.none)
    check("배너: unauthorized → 재시도 버튼",
          p(.unauthorized).banner == B.unauthorized && p(.unauthorized).bannerAction == A.retry)
    check("배너: patSaveFailed → status 그대로, 재시도 버튼",
          p(.patSaveFailed(-25300)).banner == B.patSaveFailed(-25300)
          && p(.patSaveFailed(-25300)).bannerAction == A.retry)
    check("배너: error → 메시지 그대로, 재시도 버튼",
          p(.error("boom")).banner == B.failed("boom") && p(.error("boom")).bannerAction == A.retry)

    // 설정 토큰 행 — PAT 는 연결 상태와 상관없이 지울 수 있다
    check("토큰: PAT + 401 → 거부됨, PAT 지우기",
          p(.unauthorized, .pat).token == .pat(rejected: true) && p(.unauthorized, .pat).tokenAction == .clearPAT)
    check("토큰: PAT + loaded → 사용 중, PAT 지우기",
          p(.loaded(.pat), .pat).token == .pat(rejected: false) && p(.loaded(.pat), .pat).tokenAction == .clearPAT)
    check("토큰: PAT + loading/rateLimited/error → 사용 중, PAT 지우기",
          [GitHubLoadState.loading, .rateLimited(retryAt: retryAt), .error("x")].allSatisfy {
              p($0, .pat).token == .pat(rejected: false) && p($0, .pat).tokenAction == .clearPAT
          })
    // 저장이 실패하면 Keychain 에 무엇이 남았는지 알 수 없고 방금 준 토큰은 아니다 — "사용 중" 으로
    // 보이지 않고, 방금 실패한 삭제와 같은 지우기 버튼도 두지 않는다. 다음 새로고침이 다시 읽는다 (#124).
    check("토큰: PAT 쓰던 중 patSaveFailed → 저장 실패, 버튼 없음 (#124)",
          p(.patSaveFailed(-25300), .pat).token == .patSaveFailed(-25300)
          && p(.patSaveFailed(-25300), .pat).tokenAction == .none)
    check("토큰: gh 쓰던 중·토큰 없던 중 patSaveFailed → 저장 실패 (#124)",
          p(.patSaveFailed(-25300), gh).token == .patSaveFailed(-25300)
          && p(.patSaveFailed(-25300), nil).token == .patSaveFailed(-25300))
    check("토큰: gh + 401 → 계정명·거부됨, 버튼 없음",
          p(.unauthorized, gh).token == .ghAccount("mongshellio", rejected: true)
          && p(.unauthorized, gh).tokenAction == .none)
    check("토큰: gh + loaded → 계정명 사용, 버튼 없음",
          p(.loaded(gh), gh).token == .ghAccount("mongshellio", rejected: false)
          && p(.loaded(gh), gh).tokenAction == .none)
    check("토큰: gh + loading/rateLimited → 계정명 사용, 버튼 없음",
          [GitHubLoadState.loading, .rateLimited(retryAt: retryAt)].allSatisfy {
              p($0, gh).token == .ghAccount("mongshellio", rejected: false) && p($0, gh).tokenAction == .none
          })
    check("토큰: 출처 없음 + keychainDenied → 거부됨, gh 토큰 다시 시도",
          p(.keychainDenied).token == .keychainDenied && p(.keychainDenied).tokenAction == .retryGHKeychain)
    check("토큰: 출처 없음 + loading → 확인 중, 버튼 없음",
          p(.loading).token == .checking && p(.loading).tokenAction == .none)
    check("토큰: 출처 없음 + 그 밖 → 없음, 버튼 없음",
          [GitHubLoadState.off, .noToken, .unauthorized, .rateLimited(retryAt: retryAt),
           .error("x")].allSatisfy {
              p($0).token == GitHubPresentation.Token.none && p($0).tokenAction == .none
          })
}

// MARK: - 영역 클릭 판정 (#58)
// 메뉴바는 버튼보다 높고 아이템 옆 여백 클릭도 버튼에 온다 — 판정은 경계 x 하나다.

do {
    let go = RegionClickRouting.clickGoesToGitHub
    check("경계 바로 오른쪽 → GitHub", go(200.5, 200, 52))
    check("경계 위 → GitHub (헤어라인 칸은 GitHub 영역)", go(200, 200, 52))
    check("경계 바로 왼쪽 → Claude", !go(199.5, 200, 52))
    check("영역 오른쪽 끝 바깥 여백 → GitHub (사각형 밖이어도)", go(260, 200, 52))
    check("영역 폭 0 (꺼짐) → Claude", !go(260, 200, 0))
    check("영역 프레임 없음 → Claude", !go(260, nil, 52))
}

// MARK: #138 PR 행 보조 배지 · 막힘 개수
// 뷰에 남아 있던 판정 — 보조 배지 목록과 그 순서, 팝오버 "내 PR" 의 막힘 개수.

print("▸ 보조 배지 (PRSecondaryBadge)")
do {
    func badges(_ p: GitHubPullRequest) -> [PRSecondaryBadge] {
        PRSecondaryBadge.of(p, verdict: PRVerdict.of(p))
    }
    check("검사 진행중: 롤업 PENDING 만으로도 (칩 없음)",
          badges(pr(rollup: .pending)) == [.checksPending])
    check("검사 진행중: 목록이 잘려 롤업이 SUCCESS 여도 도는 칩이 있으면",
          badges(pr(rollup: .success, checks: [chk("build", .running, end: nil)])) == [.checksPending])
    check("검사 진행중: 실패가 이긴 PR 이라도 대기 칩이 있으면",
          badges(pr(rollup: .failure, checks: [chk("a", .failed), chk("b", .queued, end: nil)],
                    complete: true)) == [.checksPending])
    check("검사 끝 → 진행중 배지 없음", badges(pr(rollup: .success)) == [])
    check("승인 + 판정이 다른 것(변경 요청 아님, Draft) → 보조 승인 배지",
          badges(pr(draft: true, review: .approved)) == [.approved])
    check("판정이 이미 승인 → 보조 승인 배지 없음",
          PRSecondaryBadge.of(pr(review: .approved), verdict: .approved) == [])
    check("판정이 머지 가능 → 보조 승인 배지 없음",
          badges(pr(review: .approved, merge: .clean)) == [])
    check("둘 다 (승인된 Draft, 검사 진행중) → 검사 진행중이 먼저",
          badges(pr(draft: true, review: .approved, rollup: .pending)) == [.checksPending, .approved])
}

print("▸ 팝오버 막힘 개수 (glance.lines.blocked)")
do {
    let s = snap(mine: [pr("o/a", 1, mergeable: .conflicting), pr("o/b", 2, rollup: .failure),
                        pr("o/c", 3, review: .changesRequested), pr("o/d", 4)])
    let lines = GitHubGlance.of(s, state: .loaded(.pat), hidden: [], mergeActivity: [:]).lines
    check("막힘 = 충돌·검사 실패·변경 요청", lines?.mine == 4 && lines?.blocked == 3)
    let hiddenLines = GitHubGlance.of(s, state: .loaded(.pat), hidden: ["o/a"], mergeActivity: [:]).lines
    check("숨긴 레포는 개수에서 빠진다 (목록과 같은 기준)",
          hiddenLines?.mine == 3 && hiddenLines?.blocked == 2)
}

// MARK: #136 GitHub 문자열은 DisplayText 규칙을 거친다
// PR 제목·레포 이름·검사 이름·StatusContext 이름은 파싱 경계에서 한 줄·유한 길이가 된다.

print("▸ GitHub 문자열 정규화 (DisplayText)")
do {
    /// A Swift string as a JSON string literal, escapes and all.
    func jsonString(_ raw: String) -> String {
        let array = String(decoding: try! JSONSerialization.data(withJSONObject: [raw]), as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
    func titled(_ title: String, repo: String = "mongshell/bookdam", rollup: String? = nil) -> GitHubPullRequest? {
        let raw = rollup.map { node(repo, rollup: $0) } ?? node(repo)
        return parsed(body(mine: [raw.replacingOccurrences(of: #""title":"t""#,
                                                           with: "\"title\":\(jsonString(title))")]))?.mine.first
    }
    func isOneLine(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.controlCharacters.union(.newlines).contains($0) }
    }

    let multiLine = titled("첫 줄\n둘째 줄\u{0007}끝\u{2028}")
    check("제목의 개행·제어문자 → 공백, 한 줄", multiLine?.title == "첫 줄 둘째 줄 끝",
          "\(String(describing: multiLine?.title))")

    let long = titled(String(repeating: "가", count: 5_000))
    check("과다 길이 제목 → Config 한도로 잘림",
          long?.title.count == Config.githubDisplayTextLimit, "\(String(describing: long?.title.count))")
    let zalgo = titled("a" + String(repeating: "\u{0301}", count: 2_000))
    check("조합문자 누적 제목 → 스칼라 한도",
          (zalgo?.title.unicodeScalars.count ?? .max) <= DisplayText.scalarLimit,
          "\(String(describing: zalgo?.title.unicodeScalars.count))")

    // `node` splices the repo into the JSON as-is, so it carries the escape itself.
    let repo = titled("t", repo: #"mongshell/book\ndam\u0000"#)
    check("레포 이름의 개행·제어문자 → 한 줄", repo?.repository == "mongshell/book dam",
          "\(String(describing: repo?.repository))")

    let checkRun: [String: Any] = ["__typename": "CheckRun", "name": "build\nlint\u{0000}",
                                   "status": "COMPLETED", "conclusion": "SUCCESS"]
    let status: [String: Any] = ["__typename": "StatusContext",
                                 "context": "ci/\u{2029}" + String(repeating: "s", count: 5_000),
                                 "state": "SUCCESS"]
    let rollup: [String: Any] = ["state": "SUCCESS", "contexts": ["nodes": [checkRun, status]]]
    let rollupJSON = String(decoding: try! JSONSerialization.data(withJSONObject: rollup), as: UTF8.self)
    let names = titled("t", rollup: rollupJSON)?.checks.map(\.name) ?? []
    let heads = names.map { String($0.prefix(16)) }
    check("검사 이름·StatusContext 이름 → 한 줄", names.count == 2 && names.allSatisfy(isOneLine), "\(heads)")
    check("CheckRun 이름 개행 → 공백", names.contains("build lint"), "\(heads)")
    check("과다 길이 StatusContext 이름 → Config 한도",
          names.contains { $0.hasPrefix("ci/") && $0.count == Config.githubDisplayTextLimit }, "\(names.map(\.count))")

    let message = GitHubAPIClient.mergeMessage("Pull\u{0000}Request\u{0007}is\u{2028}blocked")
    check("머지 메시지의 제어문자·줄 구분자 → 공백 (DisplayText 규칙)",
          message == "Pull Request is blocked", message)
}

print("")
if failures.isEmpty {
    print("✓ \(caseCount) cases passed")
} else {
    print("✗ \(failures.count)/\(caseCount) failed: \(failures.joined(separator: ", "))")
    exit(1)
}
