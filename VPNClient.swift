import AppKit

// The only Swift list of supported clients. Guard/config.sh keeps the matching
// client_table; Tests/clients.sh fails when the two disagree.
enum VPNClient: String, CaseIterable {
    case shadowrocket
    case happPlus = "happ-plus"

    var name: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .happPlus: return "Happ Plus"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .shadowrocket: return "com.liguangming.Shadowrocket"
        case .happPlus: return "su.ffg.happ.plus"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier).contains { candidate in
            let url = candidate.resolvingSymlinksInPath()
            let unavailable = [".trash", ".trashes", "apptranslocation"]
            guard !url.pathComponents.contains(where: { unavailable.contains($0.lowercased()) }),
                  (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == false,
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleIdentifier,
                  let executable = bundle.executableURL else { return false }
            return FileManager.default.isExecutableFile(atPath: executable.path)
        }
    }
}
