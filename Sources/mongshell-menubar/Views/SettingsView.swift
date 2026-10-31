import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var openClaw: OpenClawModel
    @ObservedObject var claude: ClaudeSettingsModel
    @ObservedObject var loginItem: LoginItemModel
    @ObservedObject var github: GitHubModel

    private let intervals = [180, 300, 600, 900]

    /// The live menu bar's dots, by the same rule.
    private var previewDots: OpenClawDots { OpenClawDots(prefs: prefs, openClaw: openClaw) }

    var body: some View {
        Form {
            Section("일반") {
                // The system's Login Items list is the SSOT; the model only
                // caches it, so the toggle reads through the model and writes
                // through its method (no direct binding to flip).
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Palette.errorText)
                }
            }

            Section("메뉴바") {
                // Live preview of the bar content with the current settings.
                LabeledContent("미리보기") {
                    MenuBarContent(weeklyUsed: model.snapshot.weeklyAllPercent,
                                   showRemaining: prefs.showRemaining,
                                   colorCoding: prefs.colorCoding,
                                   showPercent: prefs.showPercent,
                                   weeklyReset: TimeText.weekdayClockShort(model.snapshot.weeklyResetAt),
                                   openClawDotColor: previewDots.openClaw,
                                   serverHostDotColor: previewDots.serverHost)
                }

                Toggle("사용량 3단계 색상", isOn: $prefs.colorCoding)
                Toggle("사용량 게이지·퍼센트 표시", isOn: $prefs.showPercent)
                Toggle("남은 양으로 표시 (기본: 사용한 양)", isOn: $prefs.showRemaining)
            }

            Section("업데이트") {
                Picker("폴링 간격", selection: $prefs.pollIntervalSeconds) {
                    ForEach(intervals, id: \.self) { s in
                        Text("\(s / 60)분").tag(s)
                    }
                }
                Text("최소 3분 — 더 짧으면 서버가 요청을 제한합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("25/50/75/90% 도달 알림", isOn: $prefs.notifyThresholds)
            }

            Section("Claude Code") {
                ClaudeSettingsSection(claude: claude)
            }

            Section("서버") {
                OpenClawSettingsSection(prefs: prefs, openClaw: openClaw)
            }

            Section("GitHub") {
                GitHubSettingsSection(model: github, prefs: prefs)
            }

            Section("계정") {
                accountRow
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 700)
    }

    @ViewBuilder private var accountRow: some View {
        switch model.presentation.account {
        case .ownLogin:
            LabeledContent("상태", value: "로그인됨 (OAuth)")
            Button("로그아웃") { Task { await model.signOut() } }
        case .cliAccount:
            LabeledContent("상태", value: "Claude Code 계정 사용 중")
            Button("이 앱 계정으로 로그인") { Task { await model.signIn() } }
        case .signedOut:
            LabeledContent("상태", value: "로그아웃됨")
            Button("Claude 계정으로 로그인") { Task { await model.signIn() } }
        }
    }
}
