import SwiftUI

/// The API credit rows of the settings form (Decision #162). The Admin key
/// field is always shown — it is the only way in (PHILOSOPHY 원칙 2) — with
/// one line saying what it needs; the credit amount and renewal day appear
/// once a key is stored, with the menu bar ring's toggle (#165). The key itself is never shown back.
struct APICreditSettingsSection: View {
    @ObservedObject var model: APICreditModel
    @ObservedObject var prefs: Preferences

    // `@State` 를 손으로 펼친 것 (Decision #11-2, `OpenClawSettingsSection.urlError` 참조).
    // 입력 중인 키는 여기에만 두고 "저장" 때 모델로 넘긴 뒤 비운다.
    private var _draftKey = State(initialValue: "")
    private var draftKey: String {
        get { _draftKey.wrappedValue }
        nonmutating set { _draftKey.wrappedValue = newValue }
    }

    init(model: APICreditModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
    }

    private var draftKeyBinding: Binding<String> {
        Binding(get: { draftKey }, set: { draftKey = $0 })
    }

    private var monthlyBinding: Binding<Int> {
        Binding(get: { prefs.apiCreditMonthlyUSD }, set: { model.setMonthlyCredit($0) })
    }

    private var renewalDayBinding: Binding<Int> {
        Binding(get: { prefs.apiCreditRenewalDay }, set: { model.setRenewalDay($0) })
    }

    var body: some View {
        Text("Console 조직의 Admin API 키가 있으면 이번 주기의 남은 API 크레딧을 팝오버에 추정해 보여 줍니다.")
            .font(.caption).foregroundStyle(.secondary)

        LabeledContent("Admin 키", value: keyStateText)
        if model.keyState == .declined {
            Button("Keychain 다시 시도") { model.retryKeychain() }
        }

        SecureField("새 Admin 키", text: draftKeyBinding, prompt: Text("\(Config.adminKeyPrefix)01-…"))
            .onSubmit(saveKey)
        if let problem = AdminKeyInput.problem(draftKey), !problem.isEmpty {
            Text(problem)
                .font(.caption)
                .foregroundStyle(Palette.errorText)
        }
        HStack {
            Spacer()
            if model.keyState == .saved {
                Button("삭제") { Task { await model.clearKey() } }
            }
            Button("저장", action: saveKey)
                .disabled(AdminKeyInput.problem(draftKey) != nil)
        }
        Text("키는 Keychain 에만 저장되고 api.anthropic.com 에만 보냅니다.")
            .font(.caption).foregroundStyle(.secondary)

        if model.keyState == .saved {
            TextField("월 크레딧 (USD)", value: monthlyBinding, format: .number.grouping(.never))
            Stepper(value: renewalDayBinding, in: APICreditCycle.renewalDays) {
                LabeledContent("크레딧 갱신일", value: "매월 \(prefs.apiCreditRenewalDay)일")
            }
            Text("그달에 없는 날이면 말일에 갱신된 것으로 봅니다. 사용액은 UTC 일 단위로 합산합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("메뉴바에 크레딧 표시", isOn: $prefs.showCreditInMenuBar)
            Text("주간 게이지 옆에 남은 크레딧을 링으로 그립니다. 게이지·퍼센트 표시가 꺼져 있으면 함께 숨습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keyStateText: String {
        switch model.keyState {
        case .saved:                  return "저장됨"
        case .absent:                 return "없음"
        case .unknown:                return "확인 중…"
        case .saveFailed(let status): return "저장 실패 (\(status))"
        case .declined:               return "Keychain 접근 취소됨"
        }
    }

    private func saveKey() {
        guard AdminKeyInput.problem(draftKey) == nil else { return }
        let pasted = draftKey
        draftKey = ""
        Task { await model.saveKey(pasted) }
    }
}
