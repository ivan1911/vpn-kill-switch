// Run the real monitor without privileges. Only the checker reads test fixtures.
import Foundation

let files = FileManager.default
let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try files.createDirectory(at: folder, withIntermediateDirectories: false)
defer { try? files.removeItem(at: folder) }
let lease = folder.appendingPathComponent("lease")
try files.createDirectory(at: lease, withIntermediateDirectories: false)
let snapshot = folder.appendingPathComponent("session/status")
let fixture = folder.appendingPathComponent("check.sh")
enum Commands {
    static var check: String { "exec /bin/sh " + Admin.quote(fixture.path) + " \"$@\"" }
}

func setChecker(_ vpn: String, _ tunnel: String, client: String = "Shadowrocket", exit: Int = 0,
                before: String = "") throws {
    // The call sites pass the old display form such as "Connected (utun4)".
    let parts = vpn.split(separator: " ", maxSplits: 1).map(String.init)
    let vpnState = parts[0]
    let interface = parts.count == 2 ? String(parts[1].dropFirst().dropLast()) : ""
    let script = """
    \(before)
    [ "${1:-}" = --porcelain ] || { echo 'The app must request the porcelain form.' >&2; exit 3; }
    echo 'protection=on'
    echo 'tunnel=\(tunnel)'
    echo 'client-name=\(client)'
    echo 'vpn=\(vpnState)'
    \(interface.isEmpty ? "" : "echo 'vpn-interface=\(interface)'")
    exit \(exit)
    """
    try script.write(to: fixture, atomically: true, encoding: .utf8)
}

@discardableResult
func expect(_ state: GuardState, event: String, seconds: TimeInterval = 2) -> String {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if let data = try? String(contentsOf: snapshot, encoding: .utf8),
           data.components(separatedBy: .newlines).contains("vpn-event=" + event),
           GuardStatus(snapshot: data).state == state { return data }
        Thread.sleep(forTimeInterval: 0.02)
    } while ProcessInfo.processInfo.systemUptime < deadline
    fatalError("Missing \(state) for event \(event)")
}

try setChecker("Disconnected", "none")
let monitor = Process()
// Block SIGALRM in the child itself so Process() cannot reset the mask before
// the monitor starts. Both event wake-ups and timeout retries must still work.
monitor.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
monitor.arguments = ["-c", """
    import os, signal, sys
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    os.execl("/bin/sh", "sh", "-c", sys.argv[1])
    """, Admin.monitor(snapshot: snapshot, pid: getpid(), lease: lease)]
try monitor.run()
defer { if monitor.isRunning { monitor.terminate() } }
expect(.blocked, event: "")

// The event arrives before the checker sees the new profile. Retry after the guard tick.
precondition(Admin.wakeMonitor(snapshot: snapshot, event: "A:Shadowrocket:Connected"))
expect(.attention, event: "A:Shadowrocket:Connected")
try setChecker("Connected (utun4)", "utun4")
expect(.active, event: "A:Shadowrocket:Connected", seconds: 5)

// The profile is now disconnected but the old tunnel rule is still installed.
try setChecker("Disconnected", "utun4", exit: 2)
precondition(Admin.wakeMonitor(snapshot: snapshot, event: "B:Shadowrocket:Disconnected"))
expect(.attention, event: "B:Shadowrocket:Disconnected")
try setChecker("Disconnected", "none")
expect(.blocked, event: "B:Shadowrocket:Disconnected", seconds: 5)

// A rapid reconnect supersedes the previous check even within the same wall-clock second.
try setChecker("Connected (utun8)", "utun8")
precondition(Admin.wakeMonitor(snapshot: snapshot, event: "C:Shadowrocket:Disconnected"))
precondition(Admin.wakeMonitor(snapshot: snapshot, event: "D:Shadowrocket:Connected"))
expect(.active, event: "D:Shadowrocket:Connected")

// A Shadowrocket check must not acknowledge a Happ Plus connect event.
precondition(Admin.wakeMonitor(snapshot: snapshot, event: "E:Happ Plus:Connected"))
expect(.attention, event: "E:Happ Plus:Connected")
try setChecker("Connected (utun10)", "utun10", client: "Happ Plus")
expect(.active, event: "E:Happ Plus:Connected", seconds: 5)

try setChecker("Disconnected", "utun10", client: "Happ Plus", exit: 2)
precondition(Admin.wakeMonitor(snapshot: snapshot, event: "F:Happ Plus:Disconnected"))
expect(.attention, event: "F:Happ Plus:Disconnected")
try setChecker("Disconnected", "none", client: "Happ Plus")
expect(.blocked, event: "F:Happ Plus:Disconnected", seconds: 5)

// Hold the old check open while the new selection is applied. Then let it
// finish before the new, already-connected profile reports its current state.
let ready = folder.appendingPathComponent("ready")
let release = folder.appendingPathComponent("release")
let newRelease = folder.appendingPathComponent("new-release")
func waitForRelease(_ file: URL) -> String {
    """
    attempts=0
    while [ ! -e \(Admin.quote(file.path)) ] && [ "$attempts" -lt 250 ]; do
        sleep 0.02
        attempts=$((attempts + 1))
    done
    [ -e \(Admin.quote(file.path)) ] || exit 2
    """
}
try setChecker("Disconnected", "none", client: "Happ Plus", before: """
    touch \(Admin.quote(ready.path))
    \(waitForRelease(release))
    """)
let previous = VPNCheckEvent(clientName: "Happ Plus", state: .disconnected)
precondition(Admin.wakeMonitor(snapshot: snapshot, event: previous.token))
let deadline = ProcessInfo.processInfo.systemUptime + 2
while !files.fileExists(atPath: ready.path) && ProcessInfo.processInfo.systemUptime < deadline {
    Thread.sleep(forTimeInterval: 0.02)
}
precondition(files.fileExists(atPath: ready.path), "The old checker should be in flight")

try setChecker("Connected (utun11)", "utun11", before: waitForRelease(newRelease))
let selected = VPNCheckEvent(clientName: "Shadowrocket", state: .refresh)
precondition(Admin.wakeMonitor(snapshot: snapshot, event: selected.token))
try Data().write(to: release)
let late = expect(.blocked, event: previous.token)
precondition(!selected.matches(late) && !GuardStatus(snapshot: late).belongs(to: selected.clientName))
try Data().write(to: newRelease)
let latest = expect(.active, event: selected.token)
precondition(selected.matches(latest) && GuardStatus(snapshot: latest).belongs(to: selected.clientName))
precondition(GuardStatus(snapshot: latest).tunnel == "utun11")

try files.removeItem(at: lease)
precondition(Admin.wakeMonitor(snapshot: snapshot, event: "stop"))
monitor.waitUntilExit()
precondition(monitor.terminationStatus == 0 && !files.fileExists(atPath: snapshot.deletingLastPathComponent().path))
print("Both clients, convergence retries, rapid reconnect, in-flight switch and monitor cleanup passed.")
