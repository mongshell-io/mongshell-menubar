import SwiftUI

/// Design tokens from the mongshell-menubar handoff. Single source of truth for colors.
///
/// Status color logic mirrors the prototype `makeStage()`:
///   pct < 50 → green, pct < 80 → amber, else red. Monochrome fallback otherwise.
enum Palette {
    // Status (usage) colors
    static let green = Color(hex: 0x3F9E69)
    static let amber = Color(hex: 0xD1962F)
    static let red   = Color(hex: 0xCF3B2C)
    static let mono  = Color(hex: 0x2B2B30)

    // Popover text
    static let textPrimary   = Color(hex: 0x1D1D1F)
    static let textSecondary = Color(hex: 0x86868B)
    static let textTertiary  = Color(hex: 0xA1A1A6)
    /// GitHub PR/이슈 번호 — 회색 줄 안에서도 바로 읽히도록 본문색으로 띄운다.
    static let prNumber      = textPrimary

    // Popover surfaces / lines
    static let popoverBG = Color(hex: 0xFBFBFD)
    static let hairline  = Color.black.opacity(0.07)
    static let border    = Color.black.opacity(0.08)
    static let track     = Color.black.opacity(0.07)
    static let trackBar  = Color.black.opacity(0.08)

    // System-appearance surfaces (settings window)
    /// 에러 캡션 — 시스템 외관을 따르는 설정창용. 라이트 고정 팝오버의
    /// `red`(고정 hex)와 달리 시스템 시맨틱 red 라 다크 모드에 적응한다.
    static let errorText = Color.red

    // Accents
    static let onlineDot = Color(hex: 0x34C759)
    static let fablePurple = Color(hex: 0xAF52DE)
    /// Claude brand terracotta — the menu-bar mark's fixed color.
    static let claudeOrange = Color(hex: 0xD97757)

    // GitHub popover badges and check chips (Decision #45, mockup § D). The
    // filled badge pairs a tinted background with a darker text of the same
    // hue; the outlined badge only borders. All sit on the light popover.
    static let badgeRedFill   = red.opacity(0.12)
    static let badgeRedText   = red
    static let badgeAmberFill = amber.opacity(0.14)
    static let badgeAmberText = Color(hex: 0x9A6A12)
    static let badgeGreenFill = green.opacity(0.13)
    static let badgeGreenText = Color(hex: 0x2C7A4F)
    static let badgeGreyFill  = Color.black.opacity(0.07)
    static let badgeGreyText  = textSecondary
    static let badgeOutline   = border
    static let chipFill       = Color.black.opacity(0.04)
    static let chipFailedFill = red.opacity(0.08)
    static let chipTimeText   = textTertiary
    static let chipFailedTimeText = red.opacity(0.8)
    /// The running check's dot blinks between `amber` and this.
    static let chipRunningDotDim = amber.opacity(0.35)
    /// A PR row under the cursor — the whole row is the click target.
    static let rowHoverFill   = Color.black.opacity(0.035)

    // Squash merge on my PR rows (Decision #49). The button itself is an
    // outlined badge (`badgeGreenText` · `badgeOutline`).
    /// The failure line under a row.
    static let mergeFailedText  = red

    // Merge-ready pill in the menu-bar GitHub region (#56). Fixed colors on
    // both status-bar appearances: the pill is its own background.
    static let mergePillFill  = green
    static let mergePillGlyph = Color.white

    /// Usage → status color, honoring the color-coding toggle.
    static func statusColor(for pct: Int, colorCoding: Bool) -> Color {
        guard colorCoding else { return mono }
        if pct < 50 { return green }
        if pct < 80 { return amber }
        return red
    }
}

/// Maps a raw *used* percent + display mode into what the UI shows, so the
/// number/gauge and the (risk-based) color are computed in one place.
struct Meter {
    let usedPercent: Int
    let showRemaining: Bool
    /// `Preferences.colorCoding` — off means the mono fallback, never a
    /// risk color (Views/CLAUDE.md § 디자인 토큰).
    let colorCoding: Bool

    /// The number to display: consumed amount, or remaining amount.
    var displayPercent: Int { showRemaining ? 100 - usedPercent : usedPercent }
    /// Color always reflects risk (how much is consumed), regardless of mode —
    /// or the mono fallback when color coding is off.
    var color: Color { Palette.statusColor(for: usedPercent, colorCoding: colorCoding) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
