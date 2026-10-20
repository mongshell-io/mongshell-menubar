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

func snap(review: [GitHubPullRequest] = [], mine: [GitHubPullRequest] = [],
          merged: [GitHubPullRequest] = []) -> GitHubSnapshot {
    GitHubSnapshot(reviewRequested: review, mine: mine, recentlyMerged: merged,
                   rateLimit: nil, fetchedAt: now, tokenScopesLackRepo: nil)
}

func verdict(_ p: GitHubPullRequest, requested: Bool = false) -> PRVerdict {
    PRVerdict.of(p, reviewRequested: requested)
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
    check("리뷰 요청받은 남의 PR 이 Draft → 내 리뷰 대기",
          verdict(pr(draft: true), requested: true) == .myReviewPending)
    check("리뷰 요청받은 PR 의 검사 실패는 내 리뷰 대기보다 앞",
          verdict(pr(rollup: .failure), requested: true) == .checksFailed)
    check("mergeable unknown → 충돌 아님 (리뷰 대기)",
          verdict(pr(mergeable: .unknown)) == .awaitingReview)
    check("리뷰 판정 없음·검사 통과 → 리뷰 대기",
          verdict(pr(review: .none)) == .awaitingReview)
    check("reviewRequired → 리뷰 대기",
          verdict(pr(review: .reviewRequired)) == .awaitingReview)
    check("우선순위 = 선언 순서 (min 이 이김)",
          [PRVerdict.draft, .conflict, .approved].min() == .conflict
              && PRVerdict.conflict < .checksFailed && PRVerdict.checksFailed < .changesRequested
              && PRVerdict.changesRequested < .myReviewPending && PRVerdict.myReviewPending < .draft
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
              && PRVerdict.changesRequested.isBlocking && !PRVerdict.myReviewPending.isBlocking
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

// MARK: - 4. Glance (메뉴바 숫자·점)

print("▸ Glance")
do {
    let blocked = pr("mongshell/bookdam", 45, rollup: .failure, checks: [chk("build", .failed)])
    let fine = pr("mongshell/bookdam", 46)
    let r1 = pr("mongshell/bookdam", 58), r2 = pr("mongshell/menubar", 12)

    let g = GitHubGlance.of(snap(review: [r1, r2], mine: [blocked, fine]), state: .loaded(.pat), hidden: [])
    check("리뷰 요청 2 + 내 PR 막힘 1 → count 3·빨강", g.count == 3 && g.dot == .red, "\(g)")

    let amber = GitHubGlance.of(snap(review: [r1], mine: [fine]), state: .loaded(.pat), hidden: [])
    check("리뷰 요청만 → 주황·1", amber.count == 1 && amber.dot == .amber, "\(amber)")

    let green = GitHubGlance.of(snap(mine: [fine]), state: .loaded(.pat), hidden: [])
    check("처리할 것 없음 → 초록·0", green.count == 0 && green.dot == .green, "\(green)")

    let hidden = GitHubGlance.of(snap(review: [r1, r2], mine: [blocked, fine]),
                                 state: .loaded(.pat), hidden: ["mongshell/bookdam"])
    check("숨긴 레포 → count·점·hover 어디에도 없음",
          hidden.count == 1 && hidden.dot == .amber
              && !hidden.hoverLine1.contains("bookdam") && !hidden.hoverLine2.contains("#45")
              && hidden.hoverLine1 == "리뷰 요청 1 · menubar #12"
              && hidden.hoverLine2 == "내 PR 0 · 막힘 0", "\(hidden)")
    let hiddenUpper = GitHubGlance.of(snap(mine: [blocked]), state: .loaded(.pat), hidden: ["mongshell/bookdam"])
    check("숨김 비교는 소문자 기준", hiddenUpper.count == 0 && hiddenUpper.dot == .green)
    check("hiding 은 머지 목록도 거른다",
          snap(merged: [fine]).hiding(["mongshell/bookdam"]).recentlyMerged.isEmpty)

    let noToken = GitHubGlance.of(snap(review: [r1], mine: [blocked]), state: .noToken, hidden: [])
    check("noToken → 회색·0 (스냅샷이 있어도)", noToken.count == 0 && noToken.dot == .grey
              && noToken.hoverLine1 == "GitHub 토큰 없음", "\(noToken)")
    for state: GitHubLoadState in [.off, .keychainDenied, .unauthorized, .patSaveFailed(-25299), .error("x")] {
        let g = GitHubGlance.of(snap(review: [r1]), state: state, hidden: [])
        check("\(state) → 회색·0", g.count == 0 && g.dot == .grey)
    }
    let loading = GitHubGlance.of(snap(review: [r1], mine: [blocked]), state: .loading, hidden: [])
    check("loading + 마지막 스냅샷 → 값 유지", loading.count == 2 && loading.dot == .red)
    let limited = GitHubGlance.of(snap(review: [r1]), state: .rateLimited(retryAt: now), hidden: [])
    check("rateLimited + 마지막 스냅샷 → 값 유지", limited.count == 1 && limited.dot == .amber)
    let loadingEmpty = GitHubGlance.of(nil, state: .loading, hidden: [])
    check("loading + 스냅샷 없음 → 회색·0", loadingEmpty.count == 0 && loadingEmpty.dot == .grey)
    check("draft 는 막힘이 아니다",
          GitHubGlance.of(snap(mine: [pr(draft: true)]), state: .loaded(.pat), hidden: []).dot == .green)
}

// MARK: - 5. hover 문구

print("▸ hover 문구")
do {
    let fail = pr("mongshell/bookdam", 45, rollup: .failure, checks: [chk("lint", .passed), chk("build", .failed)])
    let conflict = pr("mongshell/bookdam", 47, mergeable: .conflicting)
    let changes = pr("mongshell/bookdam", 48, review: .changesRequested)
    let r1 = pr("mongshell/bookdam", 58), r2 = pr("mongshell/menubar", 12)

    func line2(_ mine: [GitHubPullRequest]) -> String {
        GitHubGlance.of(snap(mine: mine), state: .loaded(.pat), hidden: []).hoverLine2
    }
    check("검사 실패 → \"#45 build 실패\" (첫 실패 검사 이름)",
          line2([pr("mongshell/bookdam", 1), fail]) == "내 PR 2 · 막힘 1 · #45 build 실패", line2([fail]))
    check("충돌 → \"#47 충돌\"", line2([conflict]) == "내 PR 1 · 막힘 1 · #47 충돌", line2([conflict]))
    check("변경 요청 → \"#48 변경 요청\"", line2([changes]) == "내 PR 1 · 막힘 1 · #48 변경 요청")
    check("막힘 0 → 뒤에 아무것도 없음", line2([pr()]) == "내 PR 1 · 막힘 0", line2([pr()]))
    check("막힘 여럿 → 첫 번째만", line2([conflict, fail]) == "내 PR 2 · 막힘 2 · #47 충돌")
    let noChip = pr("mongshell/bookdam", 49, rollup: .failure, checks: [])
    check("rollup 실패인데 실패 칩 없음 → 배지 이름", line2([noChip]) == "내 PR 1 · 막힘 1 · #49 검사 실패")

    func line1(_ review: [GitHubPullRequest]) -> String {
        GitHubGlance.of(snap(review: review), state: .loaded(.pat), hidden: []).hoverLine1
    }
    check("리뷰 요청 2 → \"리뷰 요청 2 · bookdam #58 외 1\"",
          line1([r1, r2]) == "리뷰 요청 2 · bookdam #58 외 1", line1([r1, r2]))
    check("리뷰 요청 1 → 외 N 없음", line1([r1]) == "리뷰 요청 1 · bookdam #58")
    check("리뷰 요청 0 → 숫자만", line1([]) == "리뷰 요청 0")

    // The hover view draws the parts, not the joined strings: the numbers
    // get a color and the rest is greyed.
    let parts = GitHubGlance.of(snap(review: [r1, r2], mine: [pr("mongshell/bookdam", 1), fail]),
                                state: .loaded(.pat), hidden: []).lines
    check("lines 는 숫자와 나머지를 따로 든다",
          parts == GitHubGlance.Lines(reviewRequested: 2, mine: 2, blocked: 1,
                                      line1Rest: "bookdam #58 외 1",
                                      line2Rest: "막힘 1 · #45 build 실패"), "\(String(describing: parts))")
    check("리뷰 요청 0 → line1Rest 비어 있음",
          GitHubGlance.of(snap(mine: [pr()]), state: .loaded(.pat), hidden: []).lines?.line1Rest == "")
    let noLines = GitHubGlance.of(snap(review: [r1]), state: .unauthorized, hidden: [])
    check("스냅샷을 읽지 않는 상태 → lines 없음·stateLabel 만",
          noLines.lines == nil && noLines.stateLabel == "토큰이 거부되었어요 (401)")
    let saveFailed = GitHubGlance.of(snap(review: [r1]), state: .patSaveFailed(-25299), hidden: [])
    check("PAT 저장 실패 → stateLabel 에 상태 코드, 토큰 값 없음",
          saveFailed.stateLabel == "PAT 를 Keychain 에 저장하지 못했어요 (-25299)", saveFailed.stateLabel)
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
    check("hasPendingChecks: 두 목록 중 하나라도 running/queued",
          snap(review: [pr(checks: [chk("a", .queued)])]).hasPendingChecks
              && snap(mine: [pr(checks: [chk("a", .running)])]).hasPendingChecks
              && !snap(mine: [pr(checks: [chk("a", .passed)])], merged: [pr(checks: [chk("a", .running)])]).hasPendingChecks)
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

print("▸ GitHubPollPolicy.nextWait")
do {
    func wait(base: Int = 180, backoff: Int = 0, open: Bool = false, pending: Bool = false) -> Int {
        GitHubPollPolicy.nextWait(base: base, backoff: backoff, popoverOpen: open, hasPendingChecks: pending)
    }
    check("열림 + 진행중 → 30", wait(open: true, pending: true) == 30)
    check("열림 + 진행중 없음 → base", wait(open: true, pending: false) == 180)
    check("닫힘 + 진행중 → base", wait(open: false, pending: true) == 180)
    check("백오프 중엔 30 무시 → base·2^backoff", wait(backoff: 1, open: true, pending: true) == 360)
    check("백오프 상한 3600", wait(base: 600, backoff: 4) == 3600)
    check("base 하한 60", wait(base: 5) == 60)
    check("base 상한 600", wait(base: 10_000) == 600)
}

print("▸ GitHubPollPolicy.nextAutoWait")
do {
    func auto(_ state: GitHubLoadState, backoff: Int = 0, open: Bool = false, pending: Bool = false) -> Int? {
        GitHubPollPolicy.nextAutoWait(after: state, base: 180, backoff: backoff,
                                      popoverOpen: open, hasPendingChecks: pending)
    }
    check("401 이후 자동 대기 없음 (무효 토큰 재전송 정지)", auto(.unauthorized) == nil)
    check("401 이후엔 열림 + 진행중이어도 자동 대기 없음", auto(.unauthorized, open: true, pending: true) == nil)
    check("401 이후엔 백오프 중이어도 자동 대기 없음", auto(.unauthorized, backoff: 2) == nil)
    check("성공 후 → base", auto(.loaded(.pat)) == 180)
    check("PAT 저장 실패 후 자동 대기 없음 (다른 토큰으로 나가지 않음)", auto(.patSaveFailed(-25299)) == nil)
    check("PAT 저장 실패 후엔 열림 + 진행중이어도 자동 대기 없음",
          auto(.patSaveFailed(-25299), open: true, pending: true) == nil)
    check("다른 오류 후 → base (정지는 401·PAT 저장 실패만)", auto(.error("x")) == 180)
    check("한도 초과 후 → 백오프 대기", auto(.rateLimited(retryAt: now), backoff: 1) == 360)
    check("성공 후 열림 + 진행중 → 30", auto(.loaded(.pat), open: true, pending: true) == 30)
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

func body(review: [String] = [], mine: [String] = [], merged: [String]? = [],
          rateLimit: String? = #"{"cost":12,"remaining":4812,"limit":5000,"resetAt":"2026-09-29T04:00:00Z"}"#,
          errors: String? = nil) -> Data {
    var data = ["\"reviewRequested\":{\"nodes\":[\(review.joined(separator: ","))]}",
                "\"mine\":{\"nodes\":[\(mine.joined(separator: ","))]}"]
    if let merged { data.append("\"merged\":{\"nodes\":[\(merged.joined(separator: ","))]}") }
    if let rateLimit { data.append("\"rateLimit\":\(rateLimit)") }
    var root = ["\"data\":{\(data.joined(separator: ","))}"]
    if let errors { root.append("\"errors\":\(errors)") }
    return Data("{\(root.joined(separator: ","))}".utf8)
}

func parsed(_ data: Data) -> GitHubSnapshot? { try? GitHubAPIClient.parse(data, now: now) }

print("▸ parse 관대함")
do {
    let s = parsed(body(review: [node()], mine: [node("mongshell/menubar", 7)], merged: nil))
    check("alias 누락(merged) → 그 목록만 빈 배열, 나머지는 채움",
          s?.reviewRequested.count == 1 && s?.mine.count == 1 && s?.recentlyMerged.isEmpty == true,
          "\(String(describing: s))")
    check("rateLimit 읽음", s?.rateLimit == GitHubRateLimit(cost: 12, remaining: 4812, limit: 5000,
                                                        resetAt: ISO8601DateFormatter().date(from: "2026-09-29T04:00:00Z")))
    check("URL·repository·number 읽음",
          s?.reviewRequested.first?.url?.absoluteString == "https://github.com/mongshell/bookdam/pull/45"
              && s?.reviewRequested.first?.repository == "mongshell/bookdam"
              && s?.reviewRequested.first?.number == 45)

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
    let g = full.map { GitHubGlance.of($0, state: .loaded(.pat), hidden: []) }
    check("Glance 도 정리된 판정 — 막힘 0·초록·\"막힘 0\"",
          g?.count == 0 && g?.dot == .green && g?.hoverLine2 == "내 PR 1 · 막힘 0", "\(String(describing: g))")

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
              && fs.map { GitHubGlance.of($0, state: .loaded(.pat), hidden: []).hoverLine2 } == "내 PR 1 · 막힘 1 · #45 test 실패")
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
    check("alias 3개", q.contains("reviewRequested: search(") && q.contains("mine: search(") && q.contains("merged: search("))
    check("검색어", q.contains("is:pr is:open review-requested:@me") && q.contains("is:pr is:open author:@me")
              && q.contains("is:pr is:merged author:@me"))
    check("rateLimit 포함", q.contains("rateLimit { cost remaining limit resetAt }"))
    check("statusCheckRollup 과 두 컨텍스트 타입",
          q.contains("statusCheckRollup { state") && q.contains("... on CheckRun {") && q.contains("... on StatusContext {"))
    check("mergeStateStatus 요청", q.contains(" mergeStateStatus "))
    check("first: 20 / contexts first: 30", q.contains("first: 20)") && q.contains("contexts(first: 30)"))
    check("contexts 의 totalCount 요청", q.contains("contexts(first: 30) { totalCount nodes"))
    check("CheckRun 의 워크플로 이름·앱 slug 요청",
          q.contains("checkSuite { workflowRun { workflow { name } } app { slug } }"))
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
    check("리뷰 요청 섹션 → 없음", !offer(ready, .reviewRequested))
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
              listGeneration: Int = 2, generation: Int = 2) -> GitHubMergePolicy.Gate {
        GitHubMergePolicy.gate(id: id ?? ready.id, expectedHead: head, mine: mine,
                               listGeneration: listGeneration, generation: generation,
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

print("")
if failures.isEmpty {
    print("✓ \(caseCount) cases passed")
} else {
    print("✗ \(failures.count)/\(caseCount) failed: \(failures.joined(separator: ", "))")
    exit(1)
}
