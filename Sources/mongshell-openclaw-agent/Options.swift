import Foundation

struct Options: Equatable {
    static let defaultInterval = 60
    /// A probe takes up to 27s (25s timeout + kill and read grace) and a heal
    /// adds a kickstart, 3s and a re-probe; below this the loop would spend
    /// most of its time probing.
    static let minimumInterval = 30
    /// A day. Clients derive their "server unreachable" threshold from
    /// 3×interval, so an unbounded value would mean a dead agent is never
    /// noticed (and the product could overflow).
    static let maximumInterval = 86_400
    static let defaultSelfLabel = "com.mongshell.openclaw-agent"

    static let usage = """
        사용법: mongshell-openclaw-agent --status-file <path> [옵션]
          --status-file <path>     판정 결과 JSON 을 쓸 경로 (필수)
          --gateway-label <label>  재시작할 게이트웨이 launchd 레이블 (기본: 자동 탐색)
          --interval <sec>         probe 주기, 초 (기본 \(defaultInterval), \(minimumInterval)~\(maximumInterval))
          --no-auto-heal           자동복구 끄기
          --self-label <label>     이 에이전트의 launchd 레이블 (기본 \(defaultSelfLabel))
          --build-version <v>      상태 파일에 실을 빌드 버전 (install.sh 가 git 에서 정해 넘긴다)
          --print-gateway-label    찾은 게이트웨이 레이블을 출력하고 끝낸다 (못 찾으면 빈 출력, install.sh 용)
        """

    var statusFile: URL
    var gatewayLabel: String?
    var interval = defaultInterval
    var autoHeal = true
    var selfLabel = defaultSelfLabel
    /// Published as `agentVersion`; nil when absent or not publishable.
    var buildVersion: String?

    enum Parsed: Equatable {
        case run(Options)
        case help
        /// Print the discovered gateway label and exit — `--self-label` still
        /// applies, `--status-file` is not needed.
        case printGatewayLabel(selfLabel: String)
        /// The message for the usage error; the caller prints it and exits.
        case invalid(String)
    }

    /// Pure, so the rules are testable: printing and exiting stay with the
    /// caller (#105).
    static func parse(_ args: [String]) -> Parsed {
        var statusFile: URL?
        var gatewayLabel: String?
        var interval = defaultInterval
        var autoHeal = true
        var selfLabel = defaultSelfLabel
        var buildVersion: String?
        var printGatewayLabel = false

        var rest = args[...]
        while let arg = rest.popFirst() {
            func value() -> String? {
                guard let v = rest.first, !v.hasPrefix("--") else { return nil }
                rest.removeFirst()
                return v
            }
            switch arg {
            case "--status-file":
                guard let v = value() else { return .invalid("\(arg) 에 값이 필요합니다") }
                statusFile = URL(fileURLWithPath: v).standardizedFileURL
            case "--gateway-label":
                guard let v = value() else { return .invalid("\(arg) 에 값이 필요합니다") }
                gatewayLabel = v
            case "--interval":
                guard let raw = value() else { return .invalid("\(arg) 에 값이 필요합니다") }
                guard let n = Int(raw) else { return .invalid("--interval 은 정수여야 합니다: \(raw)") }
                interval = min(max(n, minimumInterval), maximumInterval)
            case "--no-auto-heal":
                autoHeal = false
            case "--self-label":
                guard let v = value() else { return .invalid("\(arg) 에 값이 필요합니다") }
                selfLabel = v
            case "--build-version":
                // Unpublishable → logged at startup and left out, not fatal: a
                // bad stamp must not stop the watchdog.
                guard let v = value() else { return .invalid("\(arg) 에 값이 필요합니다") }
                buildVersion = v
            case "--print-gateway-label":
                printGatewayLabel = true
            case "-h", "--help":
                return .help
            default:
                return .invalid("알 수 없는 인자: \(arg)")
            }
        }
        if printGatewayLabel { return .printGatewayLabel(selfLabel: selfLabel) }
        guard let statusFile else { return .invalid("--status-file 은 필수입니다") }
        return .run(Options(statusFile: statusFile, gatewayLabel: gatewayLabel,
                            interval: interval, autoHeal: autoHeal, selfLabel: selfLabel,
                            buildVersion: buildVersion))
    }
}
