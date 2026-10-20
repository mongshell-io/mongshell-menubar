import SwiftUI

/// The one-line state strip under a popover's header: a tinted dot, the
/// message, and an optional trailing control. Shared by the Claude and the
/// GitHub popover so the two read as one app.
struct PopoverBanner<Trailing: View>: View {
    let text: String
    let tint: Color
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(tint.opacity(0.06))
    }
}

extension PopoverBanner where Trailing == EmptyView {
    init(text: String, tint: Color) {
        self.init(text: text, tint: tint) { EmptyView() }
    }
}
