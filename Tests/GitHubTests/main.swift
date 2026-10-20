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
        rollup: PRChecksRollup = .success,
        checks: [PRCheck] = []) -> GitHubPullRequest {
    GitHubPullRequest(repository: repo, number: number, title: "t", url: nil, isDraft: draft,
                      reviewDecision: review, mergeable: mergeable, checksRollup: rollup,
                      checks: checks, updatedAt: now, mergedAt: nil)
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
    check("검사 실패 근거는 칩이 아니라 rollup — 칩에 실패가 있어도 rollup success 면 아님",
          verdict(pr(rollup: .success, checks: [chk("build", .failed)])) == .awaitingReview)
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
    for state: GitHubLoadState in [.off, .keychainDenied, .unauthorized, .error("x")] {
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

print("")
if failures.isEmpty {
    print("✓ \(caseCount) cases passed")
} else {
    print("✗ \(failures.count)/\(caseCount) failed: \(failures.joined(separator: ", "))")
    exit(1)
}
