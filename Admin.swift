import Foundation
import Darwin

enum Admin {
    // The sticky temporary directory protects the root-owned session directory.
    // Only the bundled, compiled-in command text is executed. No shell startup files.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func monitor(snapshot: URL, pid: Int32, lease: URL) -> String {
        let loop = """
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
        set -u
        zmodload zsh/zselect || exit 1
        umask 077
        directory=\(quote(snapshot.deletingLastPathComponent().path))
        /bin/mkdir -m 755 "$directory" || exit 1
        target="$directory/status"
        trap 'rm -f "$target" "$target.next" "$directory/check" "$directory/wake"; rmdir "$directory"' EXIT
        /usr/bin/mkfifo -m 600 "$directory/wake" || exit 1
        exec 3<> "$directory/wake" || exit 1
        /usr/sbin/chown \(getuid()) "$directory/wake" || exit 1
        event=
        remaining=0
        parent=\(pid)
        started=$(ps -p "$parent" -o lstart=) || exit 1
        while [ -d \(quote(lease.path)) ] && [ "$(ps -p "$parent" -o lstart= 2>/dev/null)" = "$started" ]; do
            sampled=$(date +%s) || exit 1
            /bin/sh -c \(quote(Commands.check)) _ --porcelain > "$directory/check" 2>&1
            result=$?
            delay=30
            if [ "$remaining" -gt 0 ]; then
                # The service can take a tick to update the tunnel rule. Verify the
                # checker also observed the new session before reporting agreement.
                client=${event#*:}
                client=${client%:*}
                if [ "$result" = 0 ] && ! awk -v client="$client" -v state="${event##*:}" '
                    $0 == "client-name=" client { named=1 }
                    $0 == "vpn=" state { found=1 }
                    END { exit !(named && (state == "Refresh" || found)) }
                ' "$directory/check"; then
                    result=2
                fi
                if [ "$result" = 2 ]; then
                    remaining=$((remaining - 1))
                    delay=3
                else
                    remaining=0
                fi
            fi
            { printf '%s\\n' "$result"; cat "$directory/check"; printf '\\nvpn-event=%s' "$event"; printf '\\nsample-start=%s\\n' "$sampled"; } > "$target.next" || exit 1
            chmod 644 "$target.next" && mv -f "$target.next" "$target" || exit 1
            # Wait on the FIFO with a kernel timeout. A signal-based read timeout
            # can hang when the authorization helper passes on a blocked SIGALRM.
            if zselect -t "$((delay * 100))" -r 3 && IFS= read -r request <&3; then
                case "$request" in
                    *:*:*)
                        case "${request##*:}" in
                            Connected|Disconnected|Refresh) event=$request; remaining=3 ;;
                        esac
                        ;;
                esac
            fi
        done
        """
        return "exec /bin/zsh -fc " + quote(loop)
    }

    // Only send a wake-up to this monitor's FIFO. O_RDWR prevents SIGPIPE if
    // the monitor quits between open and write. One short line is atomic.
    static func wakeMonitor(snapshot: URL, event: String) -> Bool {
        let path = snapshot.deletingLastPathComponent().appendingPathComponent("wake").path
        let fd = open(path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              info.st_uid == getuid() else { return false }
        let data = Data((event + "\n").utf8)
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
    }

    struct Result {
        let ok: Bool
        let cancelled: Bool
        let message: String
        var sample: Sample? = nil
    }

    struct Sample {
        let started: Date
        let snapshot: String
    }

    enum Operation: String {
        case install, remove, apply, exceptions, monitor
    }

    static func exceptionReadExplanation(_ details: String) -> String? {
        if details.contains("The exception preferences are malformed.") {
            return "The exception preferences are malformed. Have an administrator repair the file, then click Reload."
        }
        if details.contains("The saved exceptions file is a symbolic link.") {
            return "The saved exceptions file is a symbolic link. Have an administrator restore a regular file, then click Reload."
        }
        if details.contains("The saved exceptions are not in a regular file.") {
            return "The saved exceptions need a regular file. Have an administrator repair the file, then click Reload."
        }
        if details.contains("Exception settings have unsafe permissions.") {
            return "Exception settings have unsafe permissions. Have an administrator correct the file ownership and permissions, then click Reload."
        }
        return nil
    }

    struct Failure {
        enum Kind {
            case install, remove, apply, exceptions, readExceptions, monitor, monitorSetup
        }

        enum Recovery: String {
            case retry = "Retry"
            case openSettings = "Open Settings"
            case showLog = "Show Log"
        }

        let title: String
        let explanation: String
        private let recovery: [Recovery]
        let details: String
        let requiresReload: Bool

        func recoveryActions(logAvailable: Bool) -> [Recovery] {
            recovery.filter { $0 != .showLog || logAvailable }
        }

        init?(_ kind: Kind, result: Result) {
            guard !result.ok, !result.cancelled else { return nil }
            details = result.message
            switch kind {
            case .install:
                title = "Could not install the kill switch"
                recovery = [.openSettings, .retry, .showLog]
            case .remove:
                title = "Could not remove the kill switch"
                recovery = [.retry, .showLog]
            case .apply:
                title = "Could not apply VPN settings"
                recovery = [.openSettings, .showLog]
            case .exceptions:
                title = "Could not apply exceptions"
                recovery = [.openSettings, .showLog]
            case .readExceptions:
                title = "Could not read exceptions"
                recovery = [.openSettings, .showLog]
            case .monitor:
                title = "Could not check protection"
                recovery = [.retry, .showLog]
            case .monitorSetup:
                title = "Could not start checking protection"
                recovery = [.retry, .showLog]
            }

            let lines = details.components(separatedBy: .newlines)
            requiresReload = kind == .exceptions && lines.contains { $0.hasPrefix("Exceptions changed elsewhere.") }
            if requiresReload {
                explanation = "The saved exceptions changed while you were editing. Open Settings, click Reload and edit the latest list."
            } else if kind == .install, lines.contains(where: { $0.hasPrefix("Connect ") && $0.hasSuffix(" and run the installer again.") }) {
                explanation = "The applied VPN was disconnected or its tunnel was unavailable. Connect the VPN, then retry."
            } else if kind == .install, lines.contains(where: { $0.hasPrefix("Set a valid VPN server") }) {
                explanation = "A valid VPN server has not been saved. Open Settings and apply the server details before installing."
            } else if lines.contains(where: { $0.hasPrefix("Another firewall operation is in progress.") }) {
                explanation = "Another firewall operation is in progress. Wait for it to finish and try again."
            } else if kind == .apply, lines.contains("PF is inactive. Check protection and retry Apply.") {
                explanation = "PF is inactive. Check Protection in the menu bar and restore protection before trying Apply again."
            } else if kind == .apply, lines.contains("PF stopped during Apply.") {
                explanation = "PF stopped during Apply. Check Protection in the menu bar and restore protection before trying Apply again."
            } else if kind == .apply, lines.contains("The installed guard is recovering. Check protection and retry Apply.") {
                explanation = "The installed service is recovering. Check Protection in the menu bar and wait for recovery before trying Apply again."
            } else if kind == .apply, lines.contains(where: { $0.hasPrefix("The installed VPN service is incomplete.") }) {
                explanation = "The installed VPN service is incomplete. Reinstall the kill switch before applying settings."
            } else if kind == .apply, lines.contains(where: { $0.hasPrefix("The installed VPN service is inactive.") }) {
                explanation = "The installed VPN service is inactive. Reinstall the kill switch before applying settings."
            } else if kind == .exceptions, lines.contains("The installed service is incomplete or stopped. Reinstall it first.") {
                explanation = "The installed VPN service is incomplete or stopped. Reinstall the kill switch before applying exceptions."
            } else if result.sample == nil, [.install, .remove, .apply, .exceptions].contains(kind) {
                explanation = "macOS did not return a result from the administrator command. Check Protection in the menu bar before trying again."
            } else {
                switch kind {
                case .install:
                    explanation = "Installation could not verify the VPN connection or set up its firewall rules. Check the VPN server in Settings, connect your VPN and retry."
                case .remove:
                    explanation = "The installer could not finish removing the firewall service or rules. Retry removal."
                case .apply:
                    explanation = "The firewall could not save or activate the VPN configuration. Open Settings, check the server and try Apply again."
                case .exceptions:
                    explanation = "The firewall could not save or activate the edited list. Open Settings, check the entries and try Apply again."
                case .readExceptions:
                    explanation = Admin.exceptionReadExplanation(details)
                        ?? "The checker could not read the saved exceptions with administrator access. Open Settings and try reading them again."
                case .monitor:
                    explanation = "The background firewall check stopped before it could continue reporting protection. Retry to start a new check."
                case .monitorSetup:
                    explanation = "The app could not create the temporary folder used to check protection. Retry to start a new check."
                }
            }
        }
    }

    // Run the read-only checker in the same authorization, after the mutation
    // exits (including rollback). Keep both exit codes independent.
    static func checkedCommand(_ command: String, marker: String, debug: Bool = false) -> String {
        let diagnostics = debug ? marker + "-debug" : ""
        let script = """
        VPN_KS_DEBUG_MARKER=\(quote(diagnostics)) /bin/sh -c \(quote(command)) 2>&1
        operation=$?
        started=$(/bin/date +%s)
        output=$(VPN_KS_DEBUG_MARKER= /bin/sh -c \(quote(Commands.check)) _ --porcelain 2>&1)
        checked=$?
        printf '\\n%s\\n%d\\n%s\\n%d\\n%s\\n' \(quote(marker)) "$operation" "$started" "$checked" "$output"
        """
        return "/bin/sh -c " + quote(script)
    }

    private static let diagnosticValues: [String: Set<String>] = [
        "install.stage": ["precheck", "precheck-passed", "settings", "validate-anchor",
                          "validate-service", "validate-pf-config", "vpn-precheck", "https-precheck",
                          "activate", "https-verify", "rollback", "complete"],
        "vpn.context": ["console-user", "console-lookup-failed", "root-direct", "user-direct"],
        "vpn.list": ["failed", "parse-failed"],
        "vpn.profiles": ["none", "one", "multiple"],
        "vpn.status": ["failed"],
        "vpn.state": ["Connected", "Connecting", "Disconnected", "Disconnecting", "Invalid", "unknown"],
        "vpn.interface": ["missing", "ambiguous", "parse-failed", "not-present"]
    ]

    private static func diagnostic(_ line: Substring) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let key = String(fields[0])
        let value = String(fields[1])
        let interface = (key == "vpn.interface" || key == "vpn.interface-candidate")
            && value.range(of: #"\Autun[0-9]{1,10}\z"#, options: .regularExpression) != nil
        guard interface || diagnosticValues[key]?.contains(value) == true else { return nil }
        return "\(key)=\(value)"
    }

    static func checkedResult(_ result: Result, marker: String, record: (String) -> Void = { _ in }) -> Result {
        let prefix = marker + "-debug "
        let text = result.message.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").compactMap { line -> String? in
                guard let range = line.range(of: prefix) else { return line }
                if let event = diagnostic(line[range.upperBound...]) { record(event) }
                return range.lowerBound == line.startIndex ? nil : String(line[..<range.lowerBound])
            }.joined(separator: "\n")
        guard result.ok else {
            return Result(ok: false, cancelled: result.cancelled,
                          message: text.trimmingCharacters(in: .whitespacesAndNewlines), sample: result.sample)
        }
        let parts = text.components(separatedBy: marker + "\n")
        guard parts.count == 2 else {
            return Result(ok: false, cancelled: false, message: "Could not read the operation result.\n" + text)
        }
        let fields = parts[1].split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let code = Int(fields[0]), let seconds = TimeInterval(fields[1]) else {
            return Result(ok: false, cancelled: false, message: "Incomplete operation result.\n" + text)
        }
        record("operation.exit code=\(code)")
        let sample = Sample(started: Date(timeIntervalSince1970: seconds), snapshot: String(fields[2]))
        return Result(ok: code == 0, cancelled: false,
                      message: parts[0].trimmingCharacters(in: .whitespacesAndNewlines), sample: sample)
    }

    static func runMutation(command: String, prompt: String, operation: Operation,
                            completion: @escaping (Result) -> Void) {
        let marker = "vpn-ks-result-" + UUID().uuidString
        let debug = DebugLog.isEnabled
        run(command: checkedCommand(command, marker: marker, debug: debug), prompt: prompt, operation: operation) {
            completion(checkedResult($0, marker: marker) { event in
                if debug { DebugLog.write("\(event) operation=\(operation.rawValue)") }
            })
        }
    }

    static func run(command: String, prompt: String, operation: Operation = .monitor,
                    completion: @escaping (Result) -> Void) {
        DebugLog.write("authorization.request operation=\(operation.rawValue)")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", """
                on run argv
                    with timeout of 31536000 seconds
                        do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges
                    end timeout
                end run
                """, command, prompt]
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let result: Result
            do {
                try process.run()
                DebugLog.write("authorization.launch operation=\(operation.rawValue) result=started")
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result = Result(ok: process.terminationStatus == 0,
                                cancelled: process.terminationStatus != 0 && message.hasSuffix("(-128)"), message: message)
                let outcome = result.ok ? "returned" : (result.cancelled ? "cancelled" : "failed")
                DebugLog.write("authorization.finish operation=\(operation.rawValue) result=\(outcome) exit=\(process.terminationStatus)")
            } catch {
                DebugLog.write("authorization.launch operation=\(operation.rawValue) result=failed")
                result = Result(ok: false, cancelled: false, message: error.localizedDescription)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// This journal runs in the menu app, with the current user's permissions.
// Callers pass action names and allowlisted diagnostic fields, never shell output.
enum DebugLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VPN Kill Switch/debug.log")
    private static let preference = "VPNKillSwitchDebugLogging"
    private static let lock = NSLock()
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: preference) as? Bool
                ?? (Bundle.main.object(forInfoDictionaryKey: "VPNKillSwitchDebugDefault") as? Bool ?? false)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            let changed = isEnabled != newValue
            UserDefaults.standard.set(newValue, forKey: preference)
            if changed { append(newValue ? "logging.enabled" : "logging.disabled", to: fileURL) }
        }
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if isEnabled { append(message, to: fileURL) }
    }

    // Keep the current and previous 1 MiB file. An unavailable log never blocks an operation.
    private static func append(_ message: String, to url: URL) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return }
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var fd = open(url.path, flags, 0o600)
        guard fd >= 0 else { return }
        defer { if fd >= 0 { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { return }
        if info.st_size >= 1_048_576 {
            guard rename(url.path, url.path + ".1") == 0 else { return }
            close(fd)
            fd = open(url.path, flags | O_EXCL, 0o600)
            guard fd >= 0 else { return }
        }
        let event = String(message.prefix(400)).components(separatedBy: .controlCharacters).joined(separator: " ")
        let line = "\(timestamp.string(from: Date())) pid=\(getpid()) \(event)\n"
        let data = Data(line.utf8)
        data.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let n = Darwin.write(fd, address, remaining)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                remaining -= n
                address = address.advanced(by: n)
            }
        }
    }
}
