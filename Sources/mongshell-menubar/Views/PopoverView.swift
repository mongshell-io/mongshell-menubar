import SwiftUI

/// Apple-style light popover reproducing the mongshell-menubar handoff (308px wide).
struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var openClaw: OpenClawModel
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private var snap: UsageSnapshot { model.snapshot }
    /// nil when the weekly limit could not be read (#130).
    private var weeklyMeter: Meter? { snap.weeklyAllPercent.map(meter) }
    private func meter(_ used: Int) -> Meter {
        Meter(usedPercent: used, showRemaining: prefs.showRemaining, colorCoding: prefs.colorCoding)
    }
    /// Stands in for the number of a limit that could not be read.
    private static let unreadText = "—"
    /// Explicit label (both modes) so it's never ambiguous whether the
    /// numbers/graphs show consumed vs remaining amount.
    private var modeSuffix: String { prefs.showRemaining ? " · 남은 양" : " · 사용량" }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            stateBanner
            primaryGauge
            if !snap.models.isEmpty || !snap.extraLimits.isEmpty {
                hairline
                detailLimitsSection
            }
            if prefs.showsOpenClaw {
                hairline
                openClawSection
                if let host = openClaw.hostHealth.host {
                    hairline
                    serverHostSection(host)
                }
            }
            hairline
            footer
        }
        .frame(width: 308)
        .background(Palette.popoverBG)
        .environment(\.colorScheme, .light)
    }

    // MARK: openclaw (unified section)

    private var openClawSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                Text("openclaw")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                Circle()
                    .fill(openClaw.health.dotColor)
                    .frame(width: 7, height: 7)
                Text(openClaw.health.shortLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }

            if let detail = openClaw.health.detailText {
                // Remote text: already flattened and capped by the client, and
                // capped again here so it can never push the section around.
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if openClaw.hostHealth.host == nil {
                openClawCheckedRow
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, Self.sectionBottomPadding)
    }

    // MARK: Server host (Decision #31)

    /// Space under the openclaw and server sections, above the next hairline.
    private static let sectionBottomPadding: CGFloat = 16

    /// The server's own signals, under the service that runs on it. Rows the
    /// server didn't send (no battery → no power row, no CI runners → no
    /// runner row) leave no gap.
    private func serverHostSection(_ host: ServerHost) -> some View {
        // Once the server has gone quiet the figures are only the last ones
        // known: greyed, and no row is pointed at as the cause.
        let stale: Bool
        if case .unreachable = openClaw.hostHealth { stale = true } else { stale = false }
        let powerText = host.power?.lineText
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                Text("오픈클로 서버")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                // The agent's build (Decision #81), beside the server it runs on.
                if let version = openClaw.agentVersion {
                    Text(version)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let dotColor = openClaw.hostHealth.dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Text(openClaw.hostHealth.shortLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }

            if powerText != nil || host.disk != nil || host.runners != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let power = host.power, let powerText {
                        serverHostRow(glyph: "bolt.fill", text: powerText,
                                      level: power.level, stale: stale)
                    }
                    if let disk = host.disk {
                        serverHostRow(glyph: "internaldrive.fill", text: disk.lineText,
                                      level: disk.level, stale: stale)
                    }
                    if let runners = host.runners {
                        serverHostRow(glyph: "gearshape.2.fill", text: runners.lineText,
                                      level: runners.level, stale: stale)
                    }
                }
            }

            openClawCheckedRow
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, Self.sectionBottomPadding)
    }

    /// One figure. The glyph takes the signal's level color when that signal
    /// is a reason for the header's verdict; the text stays readable.
    private func serverHostRow(glyph: String, text: String, level: ServerHostLevel,
                               stale: Bool) -> some View {
        let flagged = !stale && level != .ok
        return HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(flagged ? level.color : Palette.textTertiary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(stale ? Palette.textTertiary : Palette.textPrimary)
        }
    }

    /// When the openclaw status document was last read, and a way to read it
    /// again — at the foot of the last section that document fills (the
    /// server section, or the openclaw one when the server sent no host), so
    /// it isn't mistaken for the Claude usage clock in the footer. Read-only
    /// by design (Decision #25): restarts happen on the server.
    private var openClawCheckedRow: some View {
        HStack(spacing: 8) {
            Text(openClaw.checkedClockText.map { "오픈클로 서버 확인 \($0)" } ?? "오픈클로 서버 확인 기록 없음")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("새로고침") { openClaw.refreshNow() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    // MARK: Header

    /// The ⋯ menu's items are rebuilt from the header's body, so the minute
    /// clock wraps the whole header rather than the item — and ticks only
    /// while the manual refresh is blocked, since nothing else in it moves by
    /// the minute, plus once when the block lifts. It shares the rate-limit
    /// banner's period so the two numbers agree. Always the same TimelineView, so the open menu survives a limit
    /// starting or ending (#153).
    private var header: some View {
        let until = model.presentation.manualRefreshBlockedUntil
        return TimelineView(HeaderClockSchedule(until: until)) { context in
            header(now: context.date)
        }
    }

    private func header(now: Date) -> some View {
        let presentation = model.presentation
        return PopoverHeader(title: "mongshell-menubar", badge: statusBadge,
                             onOpenSettings: onOpenSettings, onQuit: onQuit) {
            usageRing(weeklyMeter, lineWidth: 3, diameter: 18)
        } beforeSettings: {
            if let until = presentation.manualRefreshBlockedUntil {
                Button("새로고침 — \(TimeText.minutesLeft(until: until, now: now))분 후 가능") {}
                    .disabled(true)
            } else {
                Button("새로고침") { model.refreshNow() }
            }
        } afterSettings: {
            if presentation.offersSignOut {
                Button("로그아웃") { Task { await model.signOut() } }
            }
        }
    }

    /// Real connection status (replaces the old fabricated Off-peak label —
    /// the usage endpoint provides no peak-window data). Freshness is shown
    /// separately in the footer, so this only conveys the connection state.
    private var statusBadge: (color: Color, text: String) {
        switch model.presentation.badge {
        case .connected: return (Palette.onlineDot, "연결됨")
        case .syncing:   return (Palette.textTertiary, "동기화 중")
        case .sample:    return (Palette.textTertiary, "샘플")
        case .limited:   return (Palette.amber, "제한됨")
        case .failed:    return (Palette.red, "오류")
        }
    }

    // MARK: Connection banner (only when not cleanly loaded)

    @ViewBuilder private var stateBanner: some View {
        let presentation = model.presentation
        let action = presentation.bannerAction
        switch presentation.banner {
        case .none:
            EmptyView()
        case .signedOut:
            banner(text: "샘플 데이터 표시 중 — 로그인하면 실제 사용량이 보여요",
                   tint: Palette.amber) { bannerButton(action) }
        case .sessionExpired:
            banner(text: "로그인이 만료되었어요 — 다시 로그인하면 실제 사용량이 보여요",
                   tint: Palette.amber) { bannerButton(action) }
        case .loading:
            banner(text: "불러오는 중…", tint: Palette.textSecondary) { bannerButton(action) }
        case .rateLimited(let retryAt):
            // Nothing is published until `retryAt`, so the minutes tick here.
            TimelineView(.periodic(from: .now, by: TimeText.minuteTick)) { context in
                banner(text: "요청이 제한되었습니다 — \(TimeText.minutesLeft(until: retryAt, now: context.date))분 후 자동 재시도",
                       tint: Palette.amber) { bannerButton(action) }
            }
        case .failed(let message):
            banner(text: message, tint: Palette.red) { bannerButton(action) }
        case .cliAccount:
            banner(text: "Claude Code 계정 사용 중", tint: Palette.onlineDot) { bannerButton(action) }
        case .unreadLimits:
            banner(text: "사용량 형식을 읽지 못했습니다 — 읽지 못한 한도는 비워 둡니다",
                   tint: Palette.red) { bannerButton(action) }
        case .keychainDeclined(let fallback, let limitsUnread):
            // The format notice it stands in for rides along (#130); the lead
            // is cut short then so the banner stays within two lines.
            banner(text: limitsUnread
                       ? "Keychain 접근 취소 — \(declinedFallbackText(fallback)) · 한도 형식 오류"
                       : "Keychain 접근을 취소했어요 — \(declinedFallbackText(fallback))",
                   tint: Palette.amber) { bannerButton(action) }
        }
    }

    private func declinedFallbackText(_ fallback: UsagePresentation.DeclinedFallback) -> String {
        switch fallback {
        case .cliAccount: return "Claude Code 계정 사용 중"
        case .heldLogin:  return "저장 못 한 로그인으로 사용 중"
        case .sample:     return "샘플 데이터 표시 중"
        }
    }

    @ViewBuilder private func bannerButton(_ action: UsagePresentation.BannerAction) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .signIn:
            Button("로그인") { Task { await model.signIn() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .retry:
            Button("재시도") { model.refreshNow() }
                .controlSize(.small)
        case .allowKeychain:
            Button("다시 허용") { model.refreshNow() }
                .controlSize(.small)
        }
    }

    private func banner<Trailing: View>(text: String, tint: Color,
                                        @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        PopoverBanner(text: text, tint: tint, trailing: trailing)
    }

    // MARK: Primary weekly gauge

    private var primaryGauge: some View {
        VStack(spacing: 0) {
            ZStack {
                usageRing(weeklyMeter, lineWidth: 8, diameter: 132)
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(weeklyMeter.map { "\($0.displayPercent)" } ?? Self.unreadText)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(weeklyMeter == nil ? Palette.textTertiary : Palette.textPrimary)
                        .tracking(-1)
                    if weeklyMeter != nil {
                        Text("%")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .frame(width: 132, height: 132)
            .padding(.bottom, 12)

            Text("7일 한도" + modeSuffix)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .padding(.bottom, 3)
            // The countdown is phrased here, not stored, so it keeps moving
            // between polls (#133). With no reset time the line stays empty
            // rather than claiming "곧 초기화".
            TimelineView(.periodic(from: .now, by: TimeText.minuteTick)) { context in
                Text(TimeText.resetsIn(snap.weeklyResetAt, now: context.date))
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: Detail limits

    /// The per-model weekly rows and anything else the response carries. The
    /// all-models figure is the main gauge, so it has no row here.
    private var detailLimitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("세부 한도" + modeSuffix)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(snap.models) { m in
                    usageBar(meter: meter(m.percent), label: m.name, color: Palette.fablePurple)
                }

                // Limits the app has no rule for (a reset/bonus granted from
                // the settings page). Risk-colored; the reset caption is left
                // out, not left blank, when the entry has no reset time.
                ForEach(snap.extraLimits) { limit in
                    VStack(alignment: .leading, spacing: 6) {
                        usageBar(meter: meter(limit.percent), label: limit.name, color: nil)
                        if let resetAt = limit.resetAt {
                            Text(TimeText.resetsAt(resetAt))
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 18)
    }

    /// `color` nil = use the meter's risk color; non-nil = fixed brand color
    /// (e.g. Fable purple). Fill width + number follow the display mode.
    private func usageBar(meter: Meter, label: String, color: Color?) -> some View {
        let pct = meter.displayPercent
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.trackBar)
                    Capsule().fill(color ?? meter.color)
                        .frame(width: max(0, geo.size.width * CGFloat(pct) / 100))
                }
            }
            .frame(height: 5)
        }
    }

    /// The meter's ring, or the dashed grey one when there is no value.
    @ViewBuilder private func usageRing(_ meter: Meter?, lineWidth: CGFloat, diameter: CGFloat) -> some View {
        if let meter {
            RingView(percent: meter.displayPercent, color: meter.color, lineWidth: lineWidth, diameter: diameter)
        } else {
            Circle()
                .stroke(Palette.usageUnknown, style: Palette.usageUnknownStroke(lineWidth: lineWidth))
                .frame(width: diameter, height: diameter)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let credits = snap.creditsText {
                Text(credits)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Text(TimeText.updatedClock(snap.lastUpdated))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

/// A progress ring drawn with SwiftUI trim (top-start, clockwise).
struct RingView: View {
    let percent: Int
    let color: Color
    var lineWidth: CGFloat
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}
