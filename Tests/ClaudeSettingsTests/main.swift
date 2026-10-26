import Foundation

// Regression tests for the ~/.claude/settings.json read/write path.
//
// These cover one invariant above all: **the app must never destroy settings it
// cannot see.** That file is the user's real Claude Code config, shared with the
// CLI, and a bad save costs them permission rules and plugin config this app
// doesn't even know exist. Both holes fixed in review — a failed read being
// downgraded to "empty file", and a key of an unexpected type being deleted as
// if the user had cleared it — are pinned here.
//
// Run with `./scripts/test.sh`, which compiles this against the real sources.
// There is no SwiftPM test target: `swift test` needs XCTest or swift-testing
// and neither ships with the Command Line Tools this project builds against.
//
// Every case runs against a throwaway file via MONGSHELL_CLAUDE_SETTINGS.
// Nothing here touches the real ~/.claude.

var failures: [String] = []

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

func checkThrows(_ label: String, _ body: () throws -> Void) {
    do {
        try body()
        check(label, false, "오류가 발생해야 하는데 성공했습니다")
    } catch {
        check(label, true)
    }
}

/// Stands in for a lived-in settings file: our five keys plus a pile of keys
/// the app has no idea about.
let fixture = """
{
  "model": "opus",
  "permissions": {
    "defaultMode": "auto",
    "allow": ["Bash(git status)", "Bash(npm test *)", "Read(~/.zshrc)"],
    "additionalDirectories": ["/tmp/a", "/tmp/b"]
  },
  "enabledPlugins": { "some-plugin@vendor": false },
  "extraKnownMarketplaces": { "vendor": { "source": { "repo": "vendor/plugins" } } },
  "skipWorkflowUsageWarning": true
}
"""

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("claude-settings-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

/// Both exits below call `exit()`, which skips `defer` — cleanup has to be
/// explicit or every run leaves a directory behind.
func finish(_ code: Int32) -> Never {
    // The unreadable-file case leaves a 000-mode file behind. 0o700 rather than
    // 0o600: deleting an entry needs the execute bit on its *directory*, and the
    // walk hits directories too.
    if let entries = FileManager.default.enumerator(atPath: root.path) {
        for case let entry as String in entries {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: root.appendingPathComponent(entry).path)
        }
    }
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

var caseIndex = 0

/// Fresh temp file per case, pointed at by MONGSHELL_CLAUDE_SETTINGS. `seeded`
/// controls whether the fixture is written first.
func newCase(seeded: Bool = true) -> URL {
    caseIndex += 1
    let dir = root.appendingPathComponent("case-\(caseIndex)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("settings.json")
    if seeded { try! fixture.write(to: file, atomically: true, encoding: .utf8) }
    setenv("MONGSHELL_CLAUDE_SETTINGS", file.path, 1)
    return file
}

func allowCount(_ dict: [String: Any]) -> Int? {
    ((dict["permissions"] as? [String: Any])?["allow"] as? [Any])?.count
}

func permissions(_ dict: [String: Any]) -> [String: Any]? {
    dict["permissions"] as? [String: Any]
}

// MARK: - 읽기 실패는 절대 "빈 파일"이 되어선 안 된다

print("\n읽기 실패 처리")

_ = newCase(seeded: false)
check("파일이 아예 없으면 최초 실행으로 간주", (try? ClaudeSettingsStore.load())?.isEmpty == true)

do {
    let file = newCase()
    try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    checkThrows("읽을 수 없는 파일은 오류") { _ = try ClaudeSettingsStore.load() }
    checkThrows("읽을 수 없는 파일에는 쓰지 않는다") {
        _ = try ClaudeSettingsStore.mutate { ClaudeSettingsModel.apply(ClaudeSettings(), to: &$0) }
    }
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    check("거부된 쓰기 이후에도 내용 온전", allowCount(try! ClaudeSettingsStore.load()) == 3)
}

do {
    let file = newCase(seeded: false)
    try! Data().write(to: file)
    checkThrows("0바이트 파일은 오류 (중단된 쓰기의 잔해)") { _ = try ClaudeSettingsStore.load() }
}

do {
    let file = newCase(seeded: false)
    try! "{ not json".write(to: file, atomically: true, encoding: .utf8)
    checkThrows("깨진 JSON 은 오류") { _ = try ClaudeSettingsStore.load() }
    checkThrows("깨진 JSON 에는 쓰지 않는다") { _ = try ClaudeSettingsStore.mutate { _ in } }
    check("깨진 파일은 손대지 않는다",
          (try? String(contentsOf: file, encoding: .utf8)) == "{ not json")
}

// MARK: - 앱이 모르는 키의 보존

print("\n모르는 키 보존")

do {
    _ = newCase()
    var s = ClaudeSettingsModel.parse(try! ClaudeSettingsStore.load())
    s.model = "sonnet"
    let after = try! ClaudeSettingsStore.mutate { ClaudeSettingsModel.apply(s, to: &$0) }

    check("우리 키는 갱신됨", after["model"] as? String == "sonnet")
    check("permissions.allow 보존", allowCount(after) == 3)
    check("permissions.additionalDirectories 보존",
          permissions(after)?["additionalDirectories"] as? [String] == ["/tmp/a", "/tmp/b"])
    check("enabledPlugins 보존", after["enabledPlugins"] != nil)
    check("extraKnownMarketplaces 보존", after["extraKnownMarketplaces"] != nil)
    check("그 외 top-level 키 보존", after["skipWorkflowUsageWarning"] as? Bool == true)
    check("백업 파일 생성", FileManager.default.fileExists(atPath: ClaudeSettingsStore.fileURL.path + ".bak"))
}

// 읽지 못한 값은 "사용자가 비웠다"와 구별되어야 한다.
do {
    var dict: [String: Any] = [
        "model": ["unexpected": "shape"],
        "effortLevel": 42,
        "fallbackModel": "sonnet",
        "autoCompactEnabled": "yes",
        "permissions": ["defaultMode": ["a"], "allow": ["Bash(ls)"]],
    ]
    ClaudeSettingsModel.apply(ClaudeSettings(), to: &dict)

    check("타입이 다른 model 은 삭제되지 않음", dict["model"] != nil)
    check("타입이 다른 effortLevel 은 삭제되지 않음", dict["effortLevel"] != nil)
    check("타입이 다른 fallbackModel 은 삭제되지 않음", dict["fallbackModel"] != nil)
    check("타입이 다른 autoCompactEnabled 는 삭제되지 않음", dict["autoCompactEnabled"] != nil)
    check("타입이 다른 defaultMode 는 삭제되지 않음", permissions(dict)?["defaultMode"] != nil)
    check("형제 allow 목록도 그대로", permissions(dict)?["allow"] != nil)
}

do {
    var dict: [String: Any] = ["permissions": "auto"]
    ClaudeSettingsModel.apply(ClaudeSettings(), to: &dict)
    check("객체가 아닌 permissions 는 건드리지 않음", dict["permissions"] as? String == "auto")
}

// MARK: - JSON ↔ 구조체 매핑

print("\n매핑")

do {
    _ = newCase()
    let s = ClaudeSettingsModel.parse(try! ClaudeSettingsStore.load())
    check("model 파싱", s.model == "opus", "got '\(s.model)'")
    check("permissions.defaultMode 파싱", s.permissionMode == "auto", "got '\(s.permissionMode)'")
    check("없는 키는 빈 값", s.effortLevel.isEmpty && s.fallbackPrimary.isEmpty)
    check("autoCompact 는 키 부재 시 켜짐 (Claude Code 기본값)", s.autoCompact)
}

do {
    _ = newCase()
    var s = ClaudeSettings()
    s.model = "haiku"
    s.effortLevel = "xhigh"
    s.fallbackPrimary = "opus"
    s.fallbackSecondary = "sonnet"
    s.autoCompact = false
    s.permissionMode = "ask"

    _ = try! ClaudeSettingsStore.mutate { ClaudeSettingsModel.apply(s, to: &$0) }
    check("쓰고 다시 읽으면 같은 값", ClaudeSettingsModel.parse(try! ClaudeSettingsStore.load()) == s)
}

do {
    _ = newCase()
    let after = try! ClaudeSettingsStore.mutate { ClaudeSettingsModel.apply(ClaudeSettings(), to: &$0) }
    check("기본값 복귀는 model 키 삭제", after["model"] == nil)
    check("기본값 복귀는 effortLevel 키 삭제", after["effortLevel"] == nil)
    check("기본값 복귀는 fallbackModel 키 삭제", after["fallbackModel"] == nil)
    check("autoCompact 켜짐은 키 삭제로 표현", after["autoCompactEnabled"] == nil)
    check("기본값 복귀는 defaultMode 만 삭제", permissions(after)?["defaultMode"] == nil)
    check("permissions 객체와 형제 키는 생존", allowCount(after) == 3)
}

do {
    var s = ClaudeSettings()
    s.fallbackSecondary = "sonnet"
    var dict: [String: Any] = [:]
    ClaudeSettingsModel.apply(s, to: &dict)
    check("1차가 비면 2차가 승격", dict["fallbackModel"] as? [String] == ["sonnet"])

    s.fallbackPrimary = "opus"
    s.fallbackSecondary = "opus"
    dict = [:]
    ClaudeSettingsModel.apply(s, to: &dict)
    check("중복 대체 모델은 하나로 합쳐짐", dict["fallbackModel"] as? [String] == ["opus"])
}

do {
    var dict: [String: Any] = ["permissions": ["defaultMode": "ask"]]
    ClaudeSettingsStore.setNested(&dict, "permissions", "defaultMode", nil) { $0 is String }
    check("비게 된 중첩 객체는 제거", dict["permissions"] == nil)
}

// UI 는 대체 모델 슬롯을 2개만 보여주지만 키는 3개를 받는다 — 안 보이는 3번째를
// 화면에 있는 값으로 덮어써 지우면 안 된다.
do {
    var dict: [String: Any] = ["fallbackModel": ["opus", "sonnet", "haiku"]]
    var s = ClaudeSettings()
    s.fallbackPrimary = "fable"
    ClaudeSettingsModel.apply(s, to: &dict)
    check("화면에 없는 3번째 대체 모델은 보존", dict["fallbackModel"] as? [String] == ["fable", "haiku"])
}

// 워처가 외부 변경을 놓친 상태에서 무관한 항목을 저장해도, 방금 CLI 가 바꾼
// 권한 모드를 되돌리면 안 된다. (권한 모드는 도구 실행 승인 게이트다.)
do {
    let file = newCase()
    let stale = ClaudeSettingsModel.parse(try! ClaudeSettingsStore.load())
    check("사전 조건: 스냅샷의 권한 모드는 auto", stale.permissionMode == "auto")

    // 앱 몰래 CLI 가 바꿨다고 가정.
    var onDisk = try! ClaudeSettingsStore.load()
    var perms = onDisk["permissions"] as! [String: Any]
    perms["defaultMode"] = "deny"
    onDisk["permissions"] = perms
    try! JSONSerialization.data(withJSONObject: onDisk, options: [.prettyPrinted])
        .write(to: file, options: .atomic)

    // 사용자가 설정창에서 전혀 다른 항목(자동 압축)만 토글. `applyChange` 는
    // 실제 저장이 쓰는 바로 그 함수다.
    let written = try! ClaudeSettingsStore.mutate { dict in
        ClaudeSettingsModel.applyChange(\.autoCompact, false, to: &dict)
    }
    check("무관한 항목 저장이 외부 권한 모드 변경을 덮지 않음",
          (written["permissions"] as? [String: Any])?["defaultMode"] as? String == "deny")
    check("의도한 항목은 반영됨", written["autoCompactEnabled"] as? Bool == false)
}

// 대상이 없는 심링크는 resolvingSymlinksInPath 가 풀지 못한다 — 저장이 링크를
// 일반 파일로 갈아치우면 사용자의 dotfile repo 설정이 조용히 끊긴다.
do {
    caseIndex += 1
    let dir = root.appendingPathComponent("case-\(caseIndex)")
    let realDir = dir.appendingPathComponent("real")
    try! FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

    let target = realDir.appendingPathComponent("settings.json")
    let link = dir.appendingPathComponent("settings.json")
    try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    setenv("MONGSHELL_CLAUDE_SETTINGS", link.path, 1)

    var s = ClaudeSettings()
    s.model = "sonnet"
    _ = try! ClaudeSettingsStore.mutate { ClaudeSettingsModel.apply(s, to: &$0) }

    let attrs = try? FileManager.default.attributesOfItem(atPath: link.path)
    check("대상이 없던 심링크가 살아남음",
          (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink)
    check("쓰기가 링크 대상에 도달함", FileManager.default.fileExists(atPath: target.path))
}

// 심링크 사이클은 풀 수 없다 — 링크를 일반 파일로 갈아치우느니 거부해야 한다.
do {
    caseIndex += 1
    let dir = root.appendingPathComponent("case-\(caseIndex)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("a.json")
    let b = dir.appendingPathComponent("b.json")
    try! FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: b.path)
    try! FileManager.default.createSymbolicLink(atPath: b.path, withDestinationPath: a.path)
    setenv("MONGSHELL_CLAUDE_SETTINGS", a.path, 1)

    checkThrows("심링크 사이클에는 쓰지 않는다") {
        _ = try ClaudeSettingsStore.mutate { ClaudeSettingsModel.apply(ClaudeSettings(), to: &$0) }
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: a.path)
    check("사이클 심링크가 일반 파일로 바뀌지 않음",
          (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink)
}

// MARK: - 모델 저장 실패

print("\n모델 저장 실패")

// 쓰기만 실패하고 읽기는 되는 흔한 경우 (#129): 되돌리기 위한 재읽기가 성공해도
// 오류 문구는 남아야 한다. 폴더를 읽기 전용으로 두면 파일은 읽히지만 atomic
// 쓰기의 임시 파일을 만들 수 없다.
do {
    let file = newCase()
    let dir = file.deletingLastPathComponent()
    try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    MainActor.assumeIsolated {
        let model = ClaudeSettingsModel.shared
        model.reload()
        check("읽기 전용 폴더에서도 읽기는 성공", model.lastError == nil, model.lastError ?? "")
        model.binding(\.autoCompact).wrappedValue = false
        check("쓰기 실패 후 오류 문구가 남는다", model.lastError != nil)
        check("쓰기 실패 후 UI 는 디스크 값으로 돌아간다", model.settings.autoCompact == true)
        model.reload()
        check("외부 편집 반영용 reload 는 여전히 오류를 지운다", model.lastError == nil)
    }
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
}

// MARK: - 선택지

print("\n선택지")

do {
    let opts = ClaudeChoices.options(ClaudeChoices.models, current: "claude-opus-4-1", emptyLabel: "기본값")
    check("파일에 있는 모르는 값도 선택지에 남는다", opts.contains { $0.value == "claude-opus-4-1" })
    let known = ClaudeChoices.options(ClaudeChoices.models, current: "opus", emptyLabel: "기본값")
    check("아는 값은 중복 노출되지 않는다", known.filter { $0.value == "opus" }.count == 1)

    // 라벨만 정리하고, 되쓰는 값은 원본 그대로여야 한다.
    let spoofed = "opus\u{202E}ynned"
    let opt = ClaudeChoices.options(ClaudeChoices.models, current: spoofed, emptyLabel: "기본값").last!
    check("라벨에서 양방향 제어문자 제거", !opt.label.unicodeScalars.contains("\u{202E}"))
    check("저장되는 값은 원본 유지", opt.value == spoofed)

    let long = String(repeating: "z", count: 500)
    let longOpt = ClaudeChoices.options(ClaudeChoices.models, current: long, emptyLabel: "기본값").last!
    check("긴 값은 라벨에서 절단", longOpt.label.count < 100)
}

// MARK: - 결과

if failures.isEmpty {
    print("\n전부 통과 (\(caseIndex)개 케이스)")
    finish(0)
} else {
    print("\n실패 \(failures.count)건:")
    failures.forEach { print("  - \($0)") }
    finish(1)
}
