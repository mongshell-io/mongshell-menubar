import SwiftUI

/// The GitHub rows of the settings form (Decision #45). The "GitHub 표시"
/// toggle is always shown — it is the only way into an opt-in region — and
/// everything else appears once it is on: where the token comes from, a PAT
/// field, the poll interval, and repositories to hide.
struct GitHubSettingsSection: View {
    @ObservedObject var model: GitHubModel
    @ObservedObject var prefs: Preferences

    // `@State` 를 손으로 펼친 것 (Decision #11-2, `OpenClawSettingsSection.urlError` 참조).
    // 입력 중인 값은 여기에만 두고 "적용"/"숨기기" 때 모델로 넘긴다.
    private var _draftPAT = State(initialValue: "")
    private var draftPAT: String {
        get { _draftPAT.wrappedValue }
        nonmutating set { _draftPAT.wrappedValue = newValue }
    }
    private var _draftRepo = State(initialValue: "")
    private var draftRepo: String {
        get { _draftRepo.wrappedValue }
        nonmutating set { _draftRepo.wrappedValue = newValue }
    }

    init(model: GitHubModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
    }

    /// Switching on is the gesture the first Keychain read happens in, so the
    /// toggle goes through the model rather than binding to the preference.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { prefs.githubEnabled }, set: { model.setEnabled($0) })
    }

    private var draftPATBinding: Binding<String> {
        Binding(get: { draftPAT }, set: { draftPAT = $0 })
    }

    private var draftRepoBinding: Binding<String> {
        Binding(get: { draftRepo }, set: { draftRepo = $0 })
    }

    var body: some View {
        Toggle("GitHub 표시", isOn: enabledBinding)
        Text("메뉴바 오른쪽에 PR 영역이 생깁니다 — 내 PR 의 막힘과 검사 진행.")
            .font(.caption).foregroundStyle(.secondary)

        if prefs.githubEnabled {
            tokenRow

            SecureField("PAT", text: draftPATBinding, prompt: Text("ghp_…"))
                .onSubmit(applyPAT)
            HStack {
                Spacer()
                Button("적용", action: applyPAT)
                    .disabled(draftPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("classic PAT, repo 권한. Keychain 에만 저장됩니다. gh CLI 로 로그인되어 있으면 비워 두어도 됩니다.")
                .font(.caption).foregroundStyle(.secondary)

            Stepper(value: $prefs.githubPollSeconds,
                    in: Config.githubPollRange, step: Self.pollStep) {
                LabeledContent("갱신 주기", value: "\(prefs.githubPollSeconds / Self.pollStep)분")
            }
            Text("팝오버를 열면 즉시, 진행중 검사가 있으면 30초.")
                .font(.caption).foregroundStyle(.secondary)

            hiddenRepos
        }
    }

    private static let pollStep = 60

    // MARK: Token

    @ViewBuilder private var tokenRow: some View {
        let presentation = model.presentation
        switch presentation.token {
        case .pat(rejected: true):
            LabeledContent("토큰", value: "PAT 사용 중 — 거부됨 (401)")
        case .pat(rejected: false):
            LabeledContent("토큰", value: "PAT 사용 중")
        case .patSaveFailed(let status):
            LabeledContent("토큰", value: "PAT 저장 실패 (\(status))")
        case .ghAccount(let account, rejected: true):
            LabeledContent("토큰", value: "gh CLI 계정 \(account) — 거부됨 (401)")
        case .ghAccount(let account, rejected: false):
            LabeledContent("토큰", value: "gh CLI 계정 \(account) 사용")
        case .keychainDenied:
            LabeledContent("토큰", value: "gh 토큰 접근이 거부됨")
        case .checking:
            LabeledContent("토큰", value: "확인 중…")
        case .none:
            LabeledContent("토큰", value: "없음")
        }
        switch presentation.tokenAction {
        case .none:
            EmptyView()
        case .clearPAT:
            Button("PAT 지우기") { model.clearPAT() }
        case .retryGHKeychain:
            Button("gh 토큰 다시 시도") { model.retryGHKeychain() }
        }
    }

    private func applyPAT() {
        model.applyPAT(draftPAT)
        draftPAT = ""
    }

    // MARK: Hidden repositories

    @ViewBuilder private var hiddenRepos: some View {
        TextField("레포 숨기기", text: draftRepoBinding, prompt: Text("owner/name"))
            .autocorrectionDisabled()
            .onSubmit(hideDraftRepo)
        HStack {
            Spacer()
            Button("숨기기", action: hideDraftRepo)
                .disabled(!Self.looksLikeRepository(draftRepo))
        }
        ForEach(prefs.githubHiddenRepos.sorted(), id: \.self) { repo in
            LabeledContent(repo) {
                Button("보이기") { model.setRepoHidden(repo, hidden: false) }
            }
        }
        Text("숨긴 레포의 PR 은 메뉴바 숫자·호버·팝오버 어디에도 세지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func hideDraftRepo() {
        guard Self.looksLikeRepository(draftRepo) else { return }
        model.setRepoHidden(draftRepo, hidden: true)
        draftRepo = ""
    }

    /// "owner/name" with both halves present — the only shape the hidden set
    /// is compared against.
    private static func looksLikeRepository(_ raw: String) -> Bool {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
    }
}
