import Foundation
import Darwin

/// Used on the main queue. Only the curl process and its short read run off it.
final class ExternalIP {
    enum Route: Equatable {
        case tunnel(String), system
    }

    enum Source: String, CaseIterable {
        case external = "https://ifconfig.co/ip"
        case ruSite = "https://internet-lab.ru/ip"
    }

    private var addresses: [Source: String] = [:]
    var distinctRUAddress: String? {
        guard let primary = addresses[.external], let ru = addresses[.ruSite], ru != primary else { return nil }
        return ru
    }

    private var route: Route?
    private var generation = 0
    private var lastAttempt: TimeInterval?
    private(set) var value = "—"
    var onResult: (() -> Void)?

    func invalidate() {
        generation += 1
        route = nil
        addresses.removeAll()
        value = "—"
    }

    func update(status: GuardStatus, visible: Bool,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                lookup: (Source, @escaping (String?) -> Void) -> Void = ExternalIP.lookup) {
        let current: Route?
        switch status.state {
        case .active: current = status.tunnel.map { .tunnel($0) }
        case .inactive: current = .system
        default: current = nil
        }
        if current != route {
            invalidate()
            route = current
        }
        guard current != nil else {
            value = status.state == .blocked ? "Blocked" : "—"
            return
        }
        guard visible else { return }
        if let lastAttempt, now - lastAttempt < 60 {
            if value == "—" { value = "Pending" }
            return
        }
        lastAttempt = now
        value = "Checking…"
        addresses.removeAll()
        generation += 1
        let request = generation
        for source in Source.allCases {
            lookup(source) { [weak self] address in
                guard let self, self.generation == request else { return }
                self.addresses[source] = address
                if source == .external { self.value = address ?? "Unavailable" }
                self.onResult?()
            }
        }
    }

    static func parse(_ data: Data) -> String? {
        guard data.count <= 64, let text = String(data: data, encoding: .utf8) else { return nil }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = in_addr()
        guard !address.utf8.contains(0), inet_pton(AF_INET, address, &parsed) == 1 else { return nil }
        return address
    }

    static func lookup(_ source: Source, _ completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.arguments = ["-q", "-4", "--noproxy", "*", "--fail", "--silent",
                              "--connect-timeout", "5", "--max-time", "8", "--max-filesize", "64",
                              source.rawValue]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            var address: String?
            if (try? task.run()) != nil {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if task.terminationStatus == 0 { address = parse(data) }
            }
            let result = address
            DispatchQueue.main.async { completion(result) }
        }
    }
}
