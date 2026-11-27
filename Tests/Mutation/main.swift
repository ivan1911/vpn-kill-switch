// Exercise the same shell and AppleScript output path without changing pf or requesting rights.
import Foundation

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: folder) }
let flag = Admin.quote(folder.appendingPathComponent("enabled").path)
enum Commands {
    static var check: String {
        """
        if [ -n "${VPN_KS_DEBUG_MARKER:-}" ]; then echo 'Unexpected debug environment'; fi
        [ "${1:-}" = --porcelain ] || { echo 'The app must request the porcelain form.'; exit 3; }
        if [ "$(cat \(flag) 2>/dev/null)" = happ-plus ]; then
            printf 'protection=on\\ntunnel=none\\nclient=happ-plus\\nclient-name=Happ Plus\\nvpn=Disconnected\\n'
        elif [ -f \(flag) ]; then
            printf 'protection=on\\ntunnel=none\\nclient=shadowrocket\\nclient-name=Shadowrocket\\nvpn=Disconnected\\n'
        else
            echo 'protection=off'
            exit 1
        fi
        """
    }
}

func change(_ command: String, debug: Bool = false, record: (String) -> Void = { _ in }) throws -> Admin.Result {
    let marker = UUID().uuidString
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "on run argv\nreturn do shell script (item 1 of argv)\nend run",
                      Admin.checkedCommand(command, marker: marker, debug: debug)]
    try task.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    task.waitUntilExit()
    let response = Admin.Result(ok: task.terminationStatus == 0, cancelled: false,
                                message: text.trimmingCharacters(in: .whitespacesAndNewlines))
    return Admin.checkedResult(response, marker: marker, record: record)
}

let installed = try change("touch " + flag)
precondition(installed.ok && GuardStatus(snapshot: installed.sample!.snapshot).state == .blocked)
let switched = try change("printf '%s' happ-plus > " + flag)
let switchedStatus = GuardStatus(snapshot: switched.sample!.snapshot)
precondition(switched.ok && switchedStatus.state == .blocked && switchedStatus.belongs(to: "Happ Plus"))
let failed = try change("echo 'Operation failed' >&2; exit 1")
precondition(!failed.ok && failed.message == "Operation failed")
let restored = GuardStatus(snapshot: failed.sample!.snapshot)
precondition(restored.state == .blocked && restored.belongs(to: "Happ Plus"))
let removed = try change("unlink " + flag)
precondition(removed.ok && GuardStatus(snapshot: removed.sample!.snapshot).state == .inactive)
let cancelled = Admin.checkedResult(Admin.Result(ok: false, cancelled: true, message: "Canceled"), marker: "unused")
precondition(cancelled.cancelled && cancelled.sample == nil)
let diagnostics = #"""
    if [ -n "$VPN_KS_DEBUG_MARKER" ]; then
        printf '%s install.stage vpn-precheck\n' "$VPN_KS_DEBUG_MARKER" >&2
        printf '%s vpn.interface utun4\n' "$VPN_KS_DEBUG_MARKER" >&2
        printf '%s vpn.interface utun4-extra\n' "$VPN_KS_DEBUG_MARKER" >&2
        printf '%s vpn.state unknown https://secret.invalid\n' "$VPN_KS_DEBUG_MARKER" >&2
        printf '%s vpn.profile aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' "$VPN_KS_DEBUG_MARKER" >&2
    fi
    """#
var events: [String] = []
let logged = try change(diagnostics + "\necho 'Operation failed' >&2; exit 17", debug: true) { events.append($0) }
precondition(!logged.ok && logged.message == "Operation failed")
precondition(logged.sample?.snapshot.contains("Unexpected debug environment") == false)
precondition(events == ["install.stage=vpn-precheck", "vpn.interface=utun4", "operation.exit code=17"])
events.removeAll()
let unlogged = try change(diagnostics + "\necho 'Operation complete'") { events.append($0) }
precondition(unlogged.ok && unlogged.message == "Operation complete")
precondition(events == ["operation.exit code=0"])
let denied = Admin.checkedResult(Admin.Result(ok: false, cancelled: false,
    message: "Authorization failed fixture-debug vpn.interface utun4;secret"), marker: "fixture")
precondition(denied.message == "Authorization failed" && denied.sample == nil)
print("Immediate status verified after install, client Apply, failed operation and removal.")

let failureCases: [(Admin.Failure.Kind, String, [Admin.Failure.Recovery])] = [
    (.install, "Could not install the kill switch", [.openSettings, .retry, .showLog]),
    (.remove, "Could not remove the kill switch", [.retry, .showLog]),
    (.apply, "Could not apply VPN settings", [.openSettings, .showLog]),
    (.exceptions, "Could not apply exceptions", [.openSettings, .showLog]),
    (.readExceptions, "Could not read exceptions", [.openSettings, .showLog]),
    (.monitor, "Could not check protection", [.retry, .showLog]),
    (.monitorSetup, "Could not start checking protection", [.retry, .showLog])
]
for (kind, title, recovery) in failureCases {
    let failure = Admin.Failure(kind, result: failed)!
    precondition(failure.title == title && !failure.explanation.isEmpty && failure.explanation != failed.message)
    precondition(failure.recoveryActions(logAvailable: true) == recovery && failure.details == "Operation failed")
    precondition(failure.recoveryActions(logAvailable: false) == recovery.dropLast())
    precondition(Admin.Failure(kind, result: installed) == nil)
    precondition(Admin.Failure(kind, result: cancelled) == nil)
}

let conflict = try change("echo 'Exceptions changed elsewhere. Click Reload and edit the latest list.' >&2; exit 1")
let conflictAlert = Admin.Failure(.exceptions, result: conflict)!
precondition(conflictAlert.requiresReload && conflictAlert.explanation.contains("Reload"))
precondition(conflictAlert.recoveryActions(logAvailable: false) == [.openSettings])
let missingEnvelope = Admin.checkedResult(Admin.Result(ok: true, cancelled: false, message: "Tool output"), marker: "missing")
precondition(Admin.Failure(.apply, result: missingEnvelope)?.details.contains("Tool output") == true)
let disconnected = try change("echo 'Connect Happ Plus and run the installer again.' >&2; exit 1")
precondition(Admin.Failure(.install, result: disconnected)?.explanation.contains("Connect") == true)
let knownFailures: [(Admin.Failure.Kind, String, String, String)] = [
    (.apply, "PF is inactive. Check protection and retry Apply.", "PF is inactive", "Check Protection"),
    (.apply, "PF stopped during Apply.", "PF stopped during Apply", "Check Protection"),
    (.apply, "The installed guard is recovering. Check protection and retry Apply.", "recovering", "Check Protection"),
    (.apply, "The installed VPN service is incomplete. Reinstall the kill switch before applying settings.", "incomplete", "Reinstall"),
    (.apply, "The installed VPN service is inactive. Reinstall the kill switch before applying settings.", "inactive", "Reinstall"),
    (.exceptions, "The installed service is incomplete or stopped. Reinstall it first.", "incomplete or stopped", "Reinstall")
]
for (kind, output, cause, action) in knownFailures {
    let result = try change("echo " + Admin.quote(output) + " >&2; exit 1")
    let failure = Admin.Failure(kind, result: result)!
    precondition(failure.explanation.contains(cause) && failure.explanation.contains(action), output)
}
print("Failure causes, recovery actions, command details and cancellation verified.")
