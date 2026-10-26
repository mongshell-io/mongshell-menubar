import SwiftUI

/// The header both popovers share (#107): a leading mark, the title, the
/// connection badge and the ⋯ menu. The menu always holds "설정…" and ends in
/// a divider and "종료" — #74 was the GitHub menu drifting from the Claude
/// one until it had no way to quit. Each region supplies only its own items,
/// before and after "설정…".
struct PopoverHeader<Mark: View, BeforeSettings: View, AfterSettings: View>: View {
    let title: String
    let badge: (color: Color, text: String)
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var beforeSettings: () -> BeforeSettings
    @ViewBuilder var afterSettings: () -> AfterSettings

    var body: some View {
        HStack(spacing: 9) {
            mark()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
            Circle().fill(badge.color).frame(width: 7, height: 7)
            Text(badge.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            Menu {
                beforeSettings()
                Button("설정…") { onOpenSettings() }
                afterSettings()
                Divider()
                Button("mongshell-menubar 종료") { onQuit() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 22)
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }
}

/// The clock both popover headers run on: while the manual refresh is held
/// back `until` a date, `TimeText.minuteTick` from the start and then `until`
/// itself, so the "N분 후 가능" item turns back into "새로고침" when the hold
/// lifts rather than up to a minute later; otherwise a single entry and no
/// further updates. One schedule type for both states keeps the header in the
/// same `TimelineView` when a rate limit starts or ends — swapping a
/// TimelineView branch for a plain one gives the header a new identity and
/// rebuilds its ⋯ menu, which can close it while open (#153). Changing
/// `until` works the way `.animation(paused:)` does: a changed schedule value
/// restarts the timeline from the current date.
struct HeaderClockSchedule: TimelineSchedule {
    let until: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        // Ascending, as TimelineSchedule requires: minute steps clamped to
        // `until`, which is the last entry. A hold already over by the start
        // leaves just the start.
        var pending: Date? = startDate
        return AnyIterator {
            guard let current = pending else { return nil }
            if let until, current < until {
                pending = min(current.addingTimeInterval(TimeText.minuteTick), until)
            } else {
                pending = nil
            }
            return current
        }
    }
}
