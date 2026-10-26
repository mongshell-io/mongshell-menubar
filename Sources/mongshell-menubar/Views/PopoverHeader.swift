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
