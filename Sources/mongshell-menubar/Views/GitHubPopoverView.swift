import SwiftUI
import AppKit

/// The click popover of the GitHub region (mockup § C2): the same 308pt light
/// popover as the Claude one, with the two PR lists under a header and a
/// state banner. Every row is a link to its PR. The one moving part is the
/// elapsed time of a running check, which `TimelineView` advances once a
/// second while the popover is open; `GitHubModel.frozenNow` pins it for
/// the snapshot renderer.
struct GitHubPopoverView: View {
    @ObservedObject var model: GitHubModel
    @ObservedObject var prefs: Preferences
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    /// The lists are only shown when the glance reads the snapshot too
    /// (loaded, or loading / rate-limited with an earlier answer) — the
    /// region never claims a list under a "no token" or "rejected" banner.
    private var listedSnapshot: GitHubSnapshot? {
        guard model.glance.lines != nil else { return nil }
        return model.snapshot?.hiding(prefs.githubHiddenRepos)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            stateBanner
            if model.snapshot?.tokenScopesLackRepo == true {
                PopoverBanner(text: "토큰에 repo 권한이 없어 비공개 레포가 빠질 수 있어요",
                              tint: Palette.amber)
            }
            if let snapshot = listedSnapshot {
                prSection(title: "내 PR", prs: snapshot.mine,
                          cap: Config.githubSectionCaps.mine,
                          countText: mineCountText(snapshot.mine),
                          section: .mine)
                hairline
                mergedSection(snapshot.recentlyMerged)
                hairline
                footer(snapshot)
            }
        }
        .frame(width: 308)
        .background(Palette.popoverBG)
        .environment(\.colorScheme, .light)
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        PopoverHeader(title: "GitHub", badge: statusBadge,
                      onOpenSettings: onOpenSettings, onQuit: onQuit) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 18))
                .foregroundStyle(Palette.textSecondary)
        } beforeSettings: {
            Button("새로고침") { model.refreshNow() }
        } afterSettings: {
            EmptyView()
        }
    }

    private var statusBadge: (color: Color, text: String) {
        switch model.presentation.badge {
        case .syncing:      return (Palette.textTertiary, "동기화 중")
        case .connected:    return (Palette.onlineDot, "연결됨")
        case .noToken:      return (Palette.textTertiary, "토큰 없음")
        case .denied:       return (Palette.textTertiary, "거부됨")
        case .limited:      return (Palette.amber, "제한됨")
        case .unauthorized: return (Palette.red, "권한 부족")
        case .failed:       return (Palette.red, "오류")
        }
    }

    // MARK: State banner (mockup § C3)

    @ViewBuilder private var stateBanner: some View {
        let presentation = model.presentation
        let action = presentation.bannerAction
        switch presentation.banner {
        case .loading:
            PopoverBanner(text: "불러오는 중…", tint: Palette.textSecondary) { bannerButton(action) }
        case .ghAccount(let account):
            PopoverBanner(text: "gh CLI 계정 사용 중 · \(account)", tint: Palette.onlineDot) { bannerButton(action) }
        case .pat:
            PopoverBanner(text: "PAT 사용 중", tint: Palette.onlineDot) { bannerButton(action) }
        case .noToken:
            PopoverBanner(text: "GitHub 토큰이 없어요 — 로그인하면 PR 이 보여요", tint: Palette.amber) {
                bannerButton(action)
            }
        case .keychainDenied:
            PopoverBanner(text: "gh 토큰 접근이 거부됨", tint: Palette.amber) { bannerButton(action) }
        case .rateLimited(let retryAt):
            PopoverBanner(text: "API 한도 초과 — \(TimeText.minutesLeft(until: retryAt, now: model.frozenNow ?? Date()))분 후 자동 재시도",
                          tint: Palette.amber) { bannerButton(action) }
        case .unauthorized:
            PopoverBanner(text: "토큰이 거부되었어요 (401) — 권한 확인 필요", tint: Palette.red) {
                bannerButton(action)
            }
        case .patSaveFailed(let status):
            // Same wording as the hover's grey-dot line — one source for it.
            PopoverBanner(text: GitHubLoadState.patSaveFailed(status).hoverLabel, tint: Palette.red) {
                bannerButton(action)
            }
        case .failed(let message):
            PopoverBanner(text: message, tint: Palette.red) { bannerButton(action) }
        }
    }

    @ViewBuilder private func bannerButton(_ action: GitHubPresentation.BannerAction) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .openSettings:
            Button("설정…") { onOpenSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .retryGHKeychain:
            Button("다시 시도") { model.retryGHKeychain() }
                .controlSize(.small)
        case .retry:
            Button("재시도") { model.refreshNow() }
                .controlSize(.small)
        }
    }

    // MARK: PR sections

    private func mineCountText(_ mine: [GitHubPullRequest]) -> String {
        let blocked = mine.filter { PRVerdict.of($0).isBlocking }.count
        return blocked > 0 ? "\(mine.count)건 · 막힘 \(blocked)" : "\(mine.count)건"
    }

    /// One list: header with its count, then up to `cap` rows and a trailing
    /// "외 N건". An empty list still shows the section, with "없음" — the
    /// section being there says it was checked.
    private func prSection(title: String, prs: [GitHubPullRequest], cap: Int,
                           countText: String, section: PRSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title, trailing: countText)
            if prs.isEmpty {
                emptyRow
            }
            ForEach(prs.prefix(cap)) { pr in
                PRRow(pr: pr, verdict: PRVerdict.of(pr),
                      frozenNow: model.frozenNow,
                      offersMerge: GitHubMergePolicy.canOffer(pr, section: section),
                      mergeActivity: model.mergeActivity[pr.id],
                      onMerge: { head in model.merge(pr.id, expectedHead: head) })
            }
            if prs.count > cap {
                Text("외 \(prs.count - cap)건")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(trailing)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var emptyRow: some View {
        Text("없음")
            .font(.system(size: 12))
            .foregroundStyle(Palette.textTertiary)
    }

    // MARK: Recently merged

    private func mergedSection(_ merged: [GitHubPullRequest]) -> some View {
        let cap = Config.githubSectionCaps.merged
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("최근 머지 · \(Config.githubMergedWindowDays)일", trailing: "\(merged.count)건")
            if merged.isEmpty {
                emptyRow
            }
            ForEach(merged.prefix(cap)) { pr in
                mergedRow(pr)
            }
            if merged.count > cap {
                Text("외 \(merged.count - cap)건")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private func mergedRow(_ pr: GitHubPullRequest) -> some View {
        Button {
            if let url = pr.url { open(url) }
        } label: {
            HStack(spacing: 10) {
                Text("\(Text("#\(String(pr.number))").fontWeight(.semibold).foregroundStyle(Palette.prNumber)) \(pr.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let mergedAt = pr.mergedAt {
                    Text(TimeText.ago(mergedAt, now: model.frozenNow ?? Date()))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pr.url == nil)
    }

    // MARK: Footer

    private func footer(_ snapshot: GitHubSnapshot) -> some View {
        HStack {
            if let limit = snapshot.rateLimit, limit.limit > 0 {
                // A glance, not a readout: how much of the hourly budget is
                // spent. The exact figures sit in the tooltip and on the web.
                let used = min(100, max(0, Int((Double(limit.limit - limit.remaining)
                                                / Double(limit.limit) * 100).rounded())))
                HStack(spacing: 5) {
                    RingView(percent: used,
                             color: Palette.statusColor(for: used, colorCoding: prefs.colorCoding),
                             lineWidth: 2.5, diameter: 13)
                    Text("API")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
                .help("GitHub API 사용량 \(used)% — 남은 \(Self.grouped(limit.remaining)) / \(Self.grouped(limit.limit))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("GitHub API 사용량 \(used)퍼센트")
            }
            Spacer()
            Text(TimeText.updatedClock(snapshot.fetchedAt))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    /// "4,812" — a fixed locale so the reference images don't depend on the
    /// renderer's.
    private static func grouped(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "ko_KR")))
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - PR row

/// One pull request: repo and number, title, the verdict badge with any
/// secondary badge, and the checks line. The whole row is the link, and it
/// lights up under the cursor to say so; a row without a URL is dimmed
/// instead, as a disabled button is (`RowLink`). A mergeable PR of mine also gets the
/// squash merge control at the end of the badge line (Decision #49), and a
/// failed merge a red line at the bottom.
private struct PRRow: View {
    let pr: GitHubPullRequest
    let verdict: PRVerdict
    /// Snapshot clock; nil means the live one.
    let frozenNow: Date?
    /// `GitHubMergePolicy.canOffer` for this row's section.
    let offersMerge: Bool
    let mergeActivity: PRMergeActivity?
    /// The click — the model sends the merge for the head SHA the row
    /// showed at that moment.
    let onMerge: (_ expectedHead: String) -> Void

    // `@State` 를 손으로 펼친 것 (Decision #11-2, `OpenClawSettingsSection.urlError` 참조).
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    init(pr: GitHubPullRequest, verdict: PRVerdict, frozenNow: Date?,
         offersMerge: Bool, mergeActivity: PRMergeActivity?,
         onMerge: @escaping (_ expectedHead: String) -> Void) {
        self.pr = pr
        self.verdict = verdict
        self.frozenNow = frozenNow
        self.offersMerge = offersMerge
        self.mergeActivity = mergeActivity
        self.onMerge = onMerge
    }

    private var checksLine: ChecksLine { ChecksLine.fold(pr.checks) }
    private var hasRunningCheck: Bool { pr.checks.contains { $0.outcome == .running } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            topLine
            Text(pr.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            badges
            if hasRunningCheck {
                // A running check's elapsed time moves; only such rows
                // pay for the timeline. The snapshot clock, when set,
                // wins over the timeline's so reference images don't tick.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    checks(now: frozenNow ?? context.date)
                }
            } else {
                checks(now: frozenNow ?? Date())
            }
            if case .failed(let reason) = mergeActivity {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.mergeFailedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering && pr.url != nil ? Palette.rowHoverFill : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .modifier(RowLink(url: pr.url))
        // The highlight bleeds past the section's text edge, as the mockup's
        // negative margin does; the text itself stays aligned with the header.
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }

    private var topLine: some View {
        HStack(spacing: 8) {
            repoText
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let updatedAt = pr.updatedAt {
                Text(TimeText.ago(updatedAt, now: frozenNow ?? Date()))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// "mongshell/**bookdam** **#58**" — the name and the number carry the weight.
    private var repoText: Text {
        let parts = pr.repository.split(separator: "/", maxSplits: 1).map(String.init)
        let owner = parts.count == 2 ? parts[0] + "/" : ""
        let number = Text("#\(String(pr.number))").fontWeight(.semibold).foregroundStyle(Palette.prNumber)
        return Text("\(owner)\(Text(pr.repositoryName).fontWeight(.semibold)) \(number)")
    }

    // MARK: Badges (mockup § D)

    private var badges: some View {
        HStack(spacing: 5) {
            Badge(glyph: verdictGlyph, text: verdict.label, style: .fill(verdictTint))
            if checksPending {
                Badge(glyph: "circle.fill", glyphSize: Badge.dotGlyphSize, text: "검사 진행중",
                      style: .line(.amber))
            }
            if pr.reviewDecision == .approved, verdict != .approved, verdict != .mergeable {
                Badge(glyph: "checkmark", text: "승인", style: .line(.green))
            }
            // Only rows that have one make room: every other row lays out as
            // before.
            if offersMerge || mergeActivity == .merging || mergeActivity == .merged {
                Spacer(minLength: 6)
                mergeControl
            }
        }
    }

    // MARK: Squash merge (Decision #49)

    /// What the control shows: the button at rest (and after a failure, to
    /// retry), or the label of a merge out or done. Every face names the PR
    /// by number, so a click that lands after the list moved under the
    /// cursor says which PR it was for.
    private enum MergeFace: CaseIterable {
        case button, merging, merged
    }

    private var mergeFace: MergeFace {
        switch mergeActivity {
        case .merging:     return .merging
        case .merged:      return .merged
        case .failed, nil: return .button
        }
    }

    /// One button in every state, so a click on the "머지 중…" / "머지됨"
    /// label is still the button's — a child button's click wins over the
    /// row's tap (`RowLink`) — and does nothing: the second click of a
    /// double-click lands here, never on the row's link. Every face is laid
    /// out and only the current one shown, so the control is as wide as the
    /// widest in each state and no click slips past an edge that moved in.
    /// Same height as the badges, so the line — and the row — keeps its height.
    private var mergeControl: some View {
        Button(action: mergeClicked) {
            ZStack {
                ForEach(MergeFace.allCases, id: \.self) { face in
                    faceLabel(face)
                        .opacity(face == mergeFace ? 1 : 0)
                        .accessibilityHidden(face != mergeFace)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Self.controlHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(mergeFace == .button ? Palette.badgeOutline : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(mergeFace == .button ? "누르면 바로 squash 머지합니다 — 앱은 브랜치를 지우지 않습니다" : "")
    }

    @ViewBuilder private func faceLabel(_ face: MergeFace) -> some View {
        switch face {
        case .button:
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 10, weight: .semibold))
                Text("#\(String(pr.number)) 머지").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Palette.badgeGreenText)
        case .merging:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("#\(String(pr.number)) 머지 중…").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Palette.textSecondary)
        case .merged:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                Text("#\(String(pr.number)) 머지됨").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Palette.badgeGreenText)
        }
    }

    private static let controlHeight: CGFloat = 18

    /// One click merges the head this row shows now — what the user saw is
    /// what goes out as `expectedHeadOid`. The model re-judges it against
    /// its own list before sending (`GitHubMergePolicy.gate`). On a merge
    /// out or done the click is only absorbed.
    private func mergeClicked() {
        guard mergeFace == .button, let head = pr.headSHA else { return }
        onMerge(head)
    }

    /// The PR's checks are pending (the same reading the badge uses), or a
    /// chip is still going.
    private var checksPending: Bool {
        pr.effectiveChecks == .pending || pr.checks.contains { $0.outcome.isPending }
    }

    private var verdictGlyph: String {
        switch verdict {
        case .conflict:                        return "exclamationmark.triangle"
        case .checksFailed, .changesRequested: return "xmark"
        case .awaitingReview:                  return "eye"
        case .draft:                           return "pencil"
        case .approved:                        return "checkmark"
        case .mergeable:                       return "arrow.triangle.merge"
        }
    }

    private var verdictTint: Badge.Tint {
        switch verdict {
        case .conflict, .checksFailed, .changesRequested: return .red
        case .draft, .awaitingReview, .approved:          return .grey
        case .mergeable:                                  return .green
        }
    }

    // MARK: Checks line

    @ViewBuilder private func checks(now: Date) -> some View {
        switch checksLine {
        case .none:
            EmptyView()
        case .collapsed(let passed, let total, let skipped):
            FlowLayout(spacing: 4) {
                CheckChip(glyph: "checkmark", glyphColor: Palette.green,
                          text: "검사 \(passed)개 통과",
                          time: total.map { TimeText.duration(Int($0)) },
                          tone: .normal)
                // Matrix jobs share a name, so the name is no identity.
                ForEach(Array(skipped.enumerated()), id: \.offset) { _, check in
                    skippedChip(check)
                }
            }
            .padding(.top, 2)
        case .expanded(let all):
            FlowLayout(spacing: 4) {
                ForEach(Array(all.enumerated()), id: \.offset) { _, check in
                    chip(check, now: now)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func chip(_ check: PRCheck, now: Date) -> some View {
        switch check.outcome {
        case .passed:
            CheckChip(glyph: "checkmark", glyphColor: Palette.green, text: check.name,
                      time: Self.elapsedText(check), tone: .normal)
        case .failed:
            CheckChip(glyph: "xmark", glyphColor: Palette.red, text: check.name,
                      time: Self.elapsedText(check), tone: .failed)
        case .running:
            // Blink by the clock itself: no animation, and the snapshot's
            // frozen clock gives the same frame every time.
            let visible = Int(now.timeIntervalSince1970) % 2 == 0
            CheckChip(glyph: "circle.fill", glyphColor: visible ? Palette.amber : Palette.chipRunningDotDim,
                      text: check.name,
                      time: check.startedAt.map { TimeText.duration(Int(now.timeIntervalSince($0))) + "…" },
                      tone: .normal)
        case .queued:
            CheckChip(glyph: "circle.dotted", glyphColor: Palette.textTertiary, text: check.name,
                      time: nil, tone: .muted)
        case .skipped:
            skippedChip(check)
        }
    }

    private func skippedChip(_ check: PRCheck) -> some View {
        CheckChip(glyph: "circle.slash", glyphColor: Palette.textTertiary, text: check.name,
                  time: nil, tone: .muted)
    }

    /// Wall time of a finished check; nil when GitHub sent no times (an old
    /// Commit Status).
    private static func elapsedText(_ check: PRCheck) -> String? {
        guard let start = check.startedAt, let end = check.completedAt else { return nil }
        return TimeText.duration(Int(end.timeIntervalSince(start)))
    }
}

// MARK: - Row link

/// A PR row as a link, matching `mergedRow`'s button: with a URL, a tap and
/// the default accessibility action open it, and the row reads as a button;
/// without one, no tap and no button trait, and the row is dimmed as a
/// disabled button is. A tap gesture rather than a Button: the merge control
/// sits inside the row, and a child button's click wins over its parent's
/// gesture, where a button inside another button's label is not reliably
/// its own — a merge click must never also open the browser. `.contain`
/// keeps that merge button an accessibility element of its own.
private struct RowLink: ViewModifier {
    let url: URL?

    /// What `.disabled` does to a plain button's label, which `.disabled`
    /// itself can't be used for here: it would switch the merge button off.
    private static let disabledOpacity = 0.5

    @ViewBuilder func body(content: Content) -> some View {
        if let url {
            content
                .onTapGesture { NSWorkspace.shared.open(url) }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { NSWorkspace.shared.open(url) }
        } else {
            content
                .accessibilityElement(children: .contain)
                .opacity(Self.disabledOpacity)
        }
    }
}

// MARK: - Badge

/// A verdict or secondary badge: glyph + word, filled or outlined.
private struct Badge: View {
    enum Tint { case red, amber, green, grey }
    enum Style {
        case fill(Tint)
        case line(Tint?)
    }

    let glyph: String
    /// A filled circle at the glyph size reads as a blob; the "running" dot
    /// is drawn smaller.
    var glyphSize: CGFloat = 10
    let text: String
    let style: Style

    static let dotGlyphSize: CGFloat = 7

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: glyphSize, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5).strokeBorder(outlineColor, lineWidth: 1)
        )
    }

    private var textColor: Color {
        switch style {
        case .fill(let tint): return Self.text(for: tint)
        case .line(let tint): return tint.map(Self.text(for:)) ?? Palette.textSecondary
        }
    }

    private var fillColor: Color {
        switch style {
        case .fill(.red):   return Palette.badgeRedFill
        case .fill(.amber): return Palette.badgeAmberFill
        case .fill(.green): return Palette.badgeGreenFill
        case .fill(.grey):  return Palette.badgeGreyFill
        case .line:         return .clear
        }
    }

    private var outlineColor: Color {
        if case .line = style { return Palette.badgeOutline }
        return .clear
    }

    private static func text(for tint: Tint) -> Color {
        switch tint {
        case .red:   return Palette.badgeRedText
        case .amber: return Palette.badgeAmberText
        case .green: return Palette.badgeGreenText
        case .grey:  return Palette.badgeGreyText
        }
    }
}

// MARK: - Check chip

/// One check: glyph, name, and its time in a quieter color.
private struct CheckChip: View {
    enum Tone { case normal, failed, muted }

    let glyph: String
    let glyphColor: Color
    let text: String
    let time: String?
    let tone: Tone

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(glyphColor)
            Text(text)
                .foregroundStyle(textColor)
            if let time {
                Text(time)
                    .monospacedDigit()
                    .foregroundStyle(tone == .failed ? Palette.chipFailedTimeText : Palette.chipTimeText)
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .padding(.top, 3)
        .padding(.bottom, 3)
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tone == .failed ? Palette.chipFailedFill : Palette.chipFill)
        )
    }

    private var textColor: Color {
        switch tone {
        case .normal: return Palette.textSecondary
        case .failed: return Palette.red
        case .muted:  return Palette.textTertiary
        }
    }
}

// MARK: - Flow layout

/// Lays chips out left to right, wrapping to a new line when the next one
/// wouldn't fit. SwiftUI has no built-in wrapping stack; this is the small
/// one the checks line needs and nothing more.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(width: bounds.width, subviews: subviews).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0
        var lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}
