import SwiftUI

/// The popover's API credit section (Decision #162): the estimated credit
/// left this cycle, a bar of it, and when it renews. `PopoverView` draws it
/// only while an Admin key is stored — with none there is no trace of it.
struct APICreditPopoverSection: View {
    @ObservedObject var credit: APICreditModel
    @ObservedObject var prefs: Preferences

    /// Stands in for the amount before the first read lands.
    private static let unreadText = "—"

    var body: some View {
        // The cycle — and whether the spend read still belongs to it — turns
        // over at a local midnight, so the section keeps its own clock.
        TimelineView(.periodic(from: .now, by: TimeText.minuteTick)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let estimate = credit.estimate(now: now)
        let cycle = credit.cycle(now: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                Text("API 크레딧")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                Text(TimeText.creditRenewal(cycle.nextRenewal))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(estimate.map { "약 \(APICreditEstimate.dollarsText(cents: $0.remainingCents)) 남음" }
                         ?? Self.unreadText)
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(estimate == nil ? Palette.textTertiary : Palette.textPrimary)
                    Spacer(minLength: 8)
                    Text("/ \(APICreditEstimate.wholeDollarsText(prefs.apiCreditMonthlyUSD))")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                bar(estimate)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let error = credit.lastError {
                    Text(error.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Text("추정치 · 최근 비용 반영 몇 분 지연")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 16)
    }

    /// The fill is what is left; the color is the risk of what was spent,
    /// as for the usage bars (Views/CLAUDE.md § 표시 모드), mono with color
    /// coding off. No estimate yet: an empty track.
    private func bar(_ estimate: APICreditEstimate?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.trackBar)
                if let estimate {
                    Capsule()
                        .fill(Palette.statusColor(for: estimate.spentPercent, colorCoding: prefs.colorCoding))
                        .frame(width: max(0, geo.size.width * CGFloat(estimate.remainingFraction)))
                }
            }
        }
        .frame(height: 5)
    }
}
