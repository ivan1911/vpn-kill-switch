import Foundation

enum Commands {
    static let check = ""
}

// Exercise the public logger in a separate process with an isolated macOS user domain.
let files = FileManager.default
if CommandLine.arguments.count == 1 {
    let home = files.temporaryDirectory.appendingPathComponent("vpn-ks-debug-" + UUID().uuidString)
    try files.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: home) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.environment = ProcessInfo.processInfo.environment.merging(["CFFIXED_USER_HOME": home.path]) { _, new in new }
    child.arguments = [home.path]
    try child.run()
    child.waitUntilExit()
    precondition(child.terminationStatus == 0)
} else {
    let home = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    precondition(files.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == home.path)
    let log = DebugLog.fileURL
    precondition(log.resolvingSymlinksInPath().path.hasPrefix(home.path + "/"))
    DebugLog.isEnabled = true
    DebugLog.write("menu.install\nclicked")
    var contents = try String(contentsOf: log, encoding: .utf8)
    precondition(contents.contains("menu.install clicked"))
    let attributes = try files.attributesOfItem(atPath: log.path)
    precondition(attributes[.posixPermissions] as? Int == 0o600)

    DebugLog.isEnabled = false
    contents = try String(contentsOf: log, encoding: .utf8)
    DebugLog.write("disabled marker")
    let afterDisable = try String(contentsOf: log, encoding: .utf8)
    precondition(contents == afterDisable)

    DebugLog.isEnabled = true
    try Data(repeating: 65, count: 1_048_576).write(to: log)
    DebugLog.write("install.preflight")
    let previous = try Data(contentsOf: URL(fileURLWithPath: log.path + ".1"))
    let current = try String(contentsOf: log, encoding: .utf8)
    precondition(previous.count == 1_048_576 && current.contains("install.preflight"))

    let target = home.appendingPathComponent("target.txt")
    try "keep".write(to: target, atomically: true, encoding: .utf8)
    try files.removeItem(at: log)
    try files.createSymbolicLink(at: log, withDestinationURL: target)
    DebugLog.write("ignored")
    let untouched = try String(contentsOf: target, encoding: .utf8)
    precondition(untouched == "keep")
    print("Debug journal, permissions, disable, rotation and symlink checks passed.")
}
