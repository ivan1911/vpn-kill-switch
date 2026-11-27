import AppKit
import Darwin

enum Transport: String, Codable {
    case tcp, udp

    /// Position in the Settings TCP/UDP control.
    init(segment: Int) { self = segment == 1 ? .udp : .tcp }
    var segment: Int { self == .udp ? 1 : 0 }
}

struct Peer: Equatable {
    let address: String
    let port: Int
    let transport: Transport

    init?(address: String, port: String, transport: String) {
        var packed = in_addr()
        guard !address.utf8.contains(0), inet_pton(AF_INET, address, &packed) == 1,
              let octet = address.split(separator: ".").first.flatMap({ Int($0) }),
              (1..<224).contains(octet), octet != 127,
              let number = Int(port), (1...65535).contains(number), String(number) == port,
              let kind = Transport(rawValue: transport) else { return nil }
        self.address = address
        self.port = number
        self.transport = kind
    }

    init?(rules: String) {
        let rows = rules.split(separator: "\n").map { $0.split { $0 == " " || $0 == "\t" } }.filter {
            $0.count >= 12 && $0.prefix(5).elementsEqual(["pass", "out", "quick", "inet", "proto"])
                && $0[6...8].elementsEqual(["from", "any", "to"]) && $0[10] == "port"
        }
        guard rows.count == 1, let row = rows.first else { return nil }
        self.init(address: String(row[9]), port: String(row[11]), transport: String(row[5]))
    }

    var label: String { "\(address):\(port)/\(transport.rawValue.uppercased())" }

    fileprivate func applyCommand(for client: VPNClient) -> String {
        let parameters = ["_", "--apply", address, String(port), transport.rawValue, client.rawValue]
        let args = parameters.map(Admin.quote).joined(separator: " ")
        return "printf '%s' " + Admin.quote(Commands.baseRules) + " | /bin/sh -c " + Admin.quote(Commands.peer) + " " + args
    }
}

struct VPNConfiguration: Equatable {
    let client: VPNClient
    let peer: Peer
    let endpoints: [VPNClient: Peer]

    init(client: VPNClient, peer: Peer, preserving previous: VPNConfiguration?) {
        self.client = client
        self.peer = peer
        var endpoints = previous?.endpoints ?? [:]
        endpoints[client] = peer
        self.endpoints = endpoints
    }

    init?(rules: String) {
        guard let peer = Peer(rules: rules) else { return nil }
        var selected: VPNClient?
        var endpoints: [VPNClient: Peer] = [:]
        for line in rules.split(separator: "\n") where line.first == "#" {
            let fields = line.split { $0 == " " || $0 == "\t" }
            guard fields.count >= 2, fields[0] == "#" else { continue }
            let key = fields[1]
            if key == "client" || key.hasPrefix("client:") {
                guard fields.count == 3, fields[1] == "client:", selected == nil,
                      let client = VPNClient(rawValue: String(fields[2])) else { return nil }
                selected = client
            } else if key == "endpoint" || key.hasPrefix("endpoint:") {
                guard fields.count == 6, fields[1] == "endpoint", fields[2].last == ":",
                      let client = VPNClient(rawValue: String(fields[2].dropLast())), endpoints[client] == nil,
                      let endpoint = Peer(address: String(fields[3]), port: String(fields[4]), transport: String(fields[5]))
                else { return nil }
                endpoints[client] = endpoint
            }
        }
        let client: VPNClient
        if let selected {
            client = selected
        } else {
            guard endpoints.isEmpty else { return nil }
            client = .shadowrocket
            endpoints[client] = peer
        }
        guard endpoints[client] == peer else { return nil }
        self.client = client
        self.peer = peer
        self.endpoints = endpoints
    }

    static func configured(at path: String = "/etc/pf.anchors/local.shadowrocket-guard") -> VPNConfiguration? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return VPNConfiguration(rules: text)
    }

    var applyCommand: String { peer.applyCommand(for: client) }
}
