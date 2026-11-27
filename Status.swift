import Foundation

enum KillSwitchAction: String {
    case install = "Install Kill Switch"
    case remove = "Remove Kill Switch"
}

enum GuardState: Equatable {
    case active, blocked, inactive, attention, unknown

    var menuAction: KillSwitchAction? {
        switch self {
        case .active, .blocked, .attention: return .remove
        case .inactive: return .install
        case .unknown: return nil
        }
    }
}

struct VPNCheckEvent: Equatable {
    enum State: String {
        case connected = "Connected"
        case disconnected = "Disconnected"
        case refresh = "Refresh"
    }

    let clientName: String
    let state: State
    private let id = UUID()

    var token: String { "\(id.uuidString):\(clientName):\(state.rawValue)" }

    func matches(_ snapshot: String) -> Bool {
        snapshot.components(separatedBy: .newlines).contains("vpn-event=" + token)
    }
}

struct GuardStatus {
    var state: GuardState
    var title: String
    var tunnel: String?
    private(set) var vpnConnection: String?
    private(set) var vpnInterface: String?
    private(set) var vpnClientName: String?
    private var needsTunnelCheck = false

    var vpn: String? {
        vpnConnection.map { $0 + (vpnInterface.map { " (\($0))" } ?? "") }
    }

    static let unread = GuardStatus(state: .unknown, title: "Status unknown")

    init(state: GuardState, title: String, tunnel: String? = nil) {
        self.state = state
        self.title = title
        self.tunnel = tunnel
    }

    func protectionMenuTitle(isBusy: Bool) -> String {
        if isBusy { return "Protection: Working…" }
        switch state {
        case .active: return "Protection: On"
        case .inactive: return "Protection: Off"
        case .attention where needsTunnelCheck: return "Protection: Check tunnel"
        case .blocked, .attention, .unknown: return "Protection: " + title
        }
    }

    static func sampleIsCurrent(_ snapshot: String, after mutation: Date?) -> Bool {
        guard let mutation else { return true }
        guard let stamp = snapshot.split(separator: "\n").last,
              stamp.hasPrefix("sample-start="),
              let seconds = TimeInterval(stamp.dropFirst("sample-start=".count)) else { return false }
        return seconds > mutation.timeIntervalSince1970
    }

    func belongs(to clientName: String?) -> Bool {
        if let vpnClientName { return vpnClientName == clientName }
        return state == .unknown || state == .inactive
    }

    // Snapshot format: exit code of `check.sh --porcelain`, then its key=value
    // lines. Only those keys are read; any other line is ignored.
    init(snapshot: String) {
        self = .unread
        let lines = snapshot.components(separatedBy: .newlines)
        func field(_ key: String) -> String? {
            lines.dropFirst().first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        guard let code = lines.first.flatMap(Int.init) else { return }
        if let name = field("client-name"), let state = field("vpn") {
            vpnClientName = name
            vpnConnection = state
            vpnInterface = field("vpn-interface")
        }
        let protection = field("protection")
        if code == 1 && protection == "off" {
            state = .inactive
            title = "Protection off"
            return
        }
        guard protection == "on", let allowed = field("tunnel") else { return }
        tunnel = allowed
        if code == 0 {
            state = allowed == "none" ? .blocked : .active
            let blockedTitle = field("direct") == nil ? "Internet blocked" : "Direct exceptions only"
            title = state == .blocked ? blockedTitle : "Protection on"
        } else {
            state = .attention
            switch field("problem") {
            case "invalid-direct": title = "Check direct config"
            case "direct-routes": title = "Check direct routes"
            default:
                needsTunnelCheck = true
                title = "Check allowed tunnel"
            }
        }
    }
}
