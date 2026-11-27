import AppKit
import SystemConfiguration

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// How long a monitor or mutation sample stays usable. The monitor refreshes every 30 seconds.
    private static let sampleLifetime: TimeInterval = 50
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusDetails = NSMenu(title: "Status")
    private let statusLine = NSMenuItem()
    private let activityLine = NSMenuItem()
    private let ruIPLine = NSMenuItem()
    private let externalIPLine = NSMenuItem()
    private let externalIP = ExternalIP()
    private let menuFeedback = StatusMenuFeedback()
    private var protectionMenuOpen = false
    private let tunnelLine = NSMenuItem()
    private let vpnLine = NSMenuItem()
    private let settingsLine = NSMenuItem()
    private let readLine = NSMenuItem()
    private let actionLine = NSMenuItem()
    private let actionSeparator = NSMenuItem.separator()
    private let updatedLine = NSMenuItem()
    private lazy var diagnostics = ProtectionMenuDiagnostics(rows: [tunnelLine, updatedLine])

    private var status = GuardStatus.unread
    private let settings = SettingsWindow()
    private var busy: String? {
        didSet { settings.setBusy(busy != nil) }
    }
    private var samplingStarted: Date?
    private var modified: Date?
    private var monitorRequested = false
    private var monitorLease: URL?
    private var lastMutation: Date?
    private var immediateSample: Admin.Sample?
    private var selectedClient = VPNConfiguration.configured()?.client
    private var selectionGeneration = UUID()
    private var clientInstalled: Bool?
    private var checkingInstallation = false
    private var lookingUpProfile = false
    private var observedProfileID: UUID?
    private var vpnConnection: SCNetworkConnection?
    private var lastVPNStatus: SCNetworkConnectionStatus?
    private var lastProfileAvailable: Bool?
    private var lastLoggedVPNStatus: SCNetworkConnectionStatus?
    private var lastLoggedProtection: String?
    private var vpnEvent: VPNCheckEvent?
    private var eventSent = false
    private var snapshot: URL?
    private var timer: Timer?
    private var directoryWatch: DispatchSourceFileSystemObject?
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["VPNBuildIdentifier"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        DebugLog.write("app.launch version=\(version) build=\(build) client=\(selectedClient?.rawValue ?? "none")")
        settings.onApply = { [weak self] configuration in self?.applyConfiguration(configuration) }
        settings.exceptions.onReadProtected = { [weak self] completion in
            guard let self else { return }
            self.busy = "Reading exceptions…"
            self.draw()
            let command = "/bin/sh -c " + Admin.quote(Commands.check) + " _ --list-direct"
            Admin.run(command: command, prompt: "Read the saved VPN exceptions?", operation: .exceptions) { result in
                self.busy = nil
                completion(result)
                self.draw()
                self.showFailure(.readExceptions, result: result, settingsTab: .exceptions)
            }
        }
        settings.exceptions.onApply = { [weak self] previous, next in
            guard let self else { return }
            self.busy = "Applying exceptions…"
            self.draw()
            let event = self.vpnEvent
            let command = "/bin/sh -c " + Admin.quote(Commands.exceptions) + " _ " + Admin.quote(previous) + " " + Admin.quote(next)
            let prompt = next.split(separator: "\n").contains(Substring(ExceptionsView.allIPv4Destination))
                ? "Allow all IPv4 traffic outside the VPN, even when disconnected?"
                : "Apply the edited list of destinations allowed outside the VPN?"
            Admin.runMutation(command: command, prompt: prompt, operation: .exceptions) { result in
                self.finishMutation(result, eventAtStart: event, clientChanged: false)
                self.settings.exceptions.finish(result)
                self.refresh()
                self.showFailure(.exceptions, result: result, settingsTab: .exceptions)
            }
        }
        settings.onGeoIPChange = { [weak self] in self?.displayExternalIP() }
        externalIP.onResult = { [weak self] in self?.draw() }
        configureMainMenu()
        configureStatusMenu()
        draw()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.syncAppliedClient()
            self.observeVPN()
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if selectedClient == nil {
            settings.present(tab: .server)
        } else {
            startMonitoring(source: "launch")
        }
        observeVPN()
    }

    private func observeVPN() {
        guard let client = selectedClient, !lookingUpProfile else { return }
        lookingUpProfile = true
        let generation = selectionGeneration
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", Commands.check, "_", "--profile-id"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            var profile: UUID?
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    profile = UUID(uuidString: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            let id = profile
            DispatchQueue.main.async {
                guard self.selectionGeneration == generation else { return }
                self.lookingUpProfile = false
                guard VPNConfiguration.configured()?.client == client else { return }
                let available = id != nil
                if !DebugLog.isEnabled {
                    self.lastProfileAvailable = nil
                } else if self.lastProfileAvailable != available {
                    self.lastProfileAvailable = available
                    DebugLog.write("vpn.profile client=\(client.rawValue) available=\(available)")
                }
                guard id != self.observedProfileID else {
                    self.logVPNStatus(self.lastVPNStatus ?? .invalid)
                    return
                }
                self.stopObservingVPN()
                if let id { self.observeProfile(id) }
                if self.vpnConnection == nil { self.vpnStatusChanged(.invalid) }
            }
        }
    }

    private func observeProfile(_ id: UUID) {
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id.uuidString as CFString,
            { connection, status, _ in
                guard let menu = NSApp.delegate as? MenuApp, let active = menu.vpnConnection,
                      connection === active else { return }
                menu.vpnStatusChanged(status)
            }, nil) else { return }
        guard SCNetworkConnectionSetDispatchQueue(connection, .main) else { return }
        observedProfileID = id
        vpnConnection = connection
        vpnStatusChanged(SCNetworkConnectionGetStatus(connection))
    }

    private func stopObservingVPN() {
        let previous = vpnConnection
        vpnConnection = nil
        observedProfileID = nil
        lastVPNStatus = nil
        if let previous { SCNetworkConnectionSetDispatchQueue(previous, nil) }
    }

    // Command-line installation or removal can change the policy while this app is open.
    private func syncAppliedClient() {
        guard busy == nil else { return }
        let configuration = VPNConfiguration.configured()
        settings.reloadIfClean(configuration)
        let applied = configuration?.client
        guard applied != selectedClient else { return }
        selectClient(applied)
        immediateSample = nil
        modified = nil
        lastMutation = Date()
        samplingStarted = lastMutation
        if applied != nil { requestVPNCheck(.refresh) }
    }

    private func selectClient(_ client: VPNClient?) {
        guard selectedClient != client else { return }
        stopObservingVPN()
        selectedClient = client
        DebugLog.write("vpn.selected client=\(client?.rawValue ?? "none")")
        selectionGeneration = UUID()
        lookingUpProfile = false
        lastProfileAvailable = nil
        lastLoggedVPNStatus = nil
        checkingInstallation = false
        clientInstalled = nil
        vpnEvent = nil
        eventSent = false
        externalIP.invalidate()
        observeVPN()
    }

    private func vpnStatusChanged(_ newStatus: SCNetworkConnectionStatus) {
        guard lastVPNStatus != newStatus else { return }
        logVPNStatus(newStatus)
        if newStatus == .invalid { stopObservingVPN() }
        lastVPNStatus = newStatus
        externalIP.invalidate()
        if snapshot != nil {
            switch newStatus {
            case .connected: requestVPNCheck(.connected)
            case .disconnected: requestVPNCheck(.disconnected)
            case .invalid: requestVPNCheck(.refresh)
            default: break
            }
        }
        refresh()
    }

    private func logVPNStatus(_ status: SCNetworkConnectionStatus) {
        guard DebugLog.isEnabled else {
            lastLoggedVPNStatus = nil
            return
        }
        guard lastLoggedVPNStatus != status else { return }
        lastLoggedVPNStatus = status
        let state: String
        switch status {
        case .invalid: state = "invalid"
        case .disconnected: state = "disconnected"
        case .connecting: state = "connecting"
        case .connected: state = "connected"
        case .disconnecting: state = "disconnecting"
        @unknown default: state = "unknown"
        }
        DebugLog.write("vpn.status client=\(selectedClient?.rawValue ?? "none") state=\(state)")
    }

    private func requestVPNCheck(_ state: VPNCheckEvent.State) {
        guard let selectedClient else { return }
        DebugLog.write("monitor.check-request client=\(selectedClient.rawValue) state=\(state.rawValue.lowercased())")
        vpnEvent = VPNCheckEvent(clientName: selectedClient.name, state: state)
        // Only a check started in response to this event can echo its new ID.
        lastMutation = nil
        eventSent = false
        immediateSample = nil
        modified = nil
        samplingStarted = Date()
    }

    private func configureStatusMenu() {
        menu.showsStateColumn = false
        statusDetails.showsStateColumn = false
        menu.autoenablesItems = false
        menu.delegate = self
        statusDetails.autoenablesItems = false
        statusDetails.delegate = self
        menu.addItem(statusLine)
        statusLine.submenu = statusDetails
        ruIPLine.isHidden = true
        for line in [activityLine, vpnLine, tunnelLine, externalIPLine, ruIPLine, updatedLine] {
            line.isEnabled = false
            statusDetails.addItem(line)
        }
        for line in [externalIPLine, ruIPLine] {
            line.target = self
            line.action = #selector(copyIPAddress(_:))
        }
        readLine.title = "Check Status…"
        readLine.target = self
        readLine.action = #selector(checkStatus)
        statusDetails.addItem(readLine)

        menu.addItem(actionSeparator)
        add(actionLine, "", #selector(changeGuard))
        menu.addItem(.separator())
        add(settingsLine, "Settings…", #selector(openSettings))
        settingsLine.image = nil
        add(NSMenuItem(), "About", #selector(openAbout))
        menu.addItem(.separator())
        add(NSMenuItem(), "Quit", #selector(quitApp))
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            for row in menu.items where !row.isSeparatorItem {
                row.preferredImageVisibility = row === statusLine ? .visible : .hidden
            }
        }
        #endif
        diagnostics.stopTracking()
        item.menu = menu
    }

    private func add(_ entry: NSMenuItem, _ title: String, _ action: Selector) {
        entry.title = title
        entry.action = action
        entry.target = self
        menu.addItem(entry)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusDetails {
            protectionMenuOpen = false
            diagnostics.stopTracking()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusDetails { diagnostics.prepareForOpen() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusDetails {
            protectionMenuOpen = true
            diagnostics.startTracking()
            DebugLog.write("menu.open protection")
        } else if menu === self.menu {
            DebugLog.write("menu.open status-item")
        }
        syncAppliedClient()
        refresh()
        if menu === self.menu && status.state.menuAction == .install { checkInstallation() }
    }

    private func checkInstallation() {
        guard let client = selectedClient, !checkingInstallation else { return }
        checkingInstallation = true
        let generation = selectionGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = client.isInstalled
            DispatchQueue.main.async {
                guard self.selectionGeneration == generation else { return }
                if self.clientInstalled != installed {
                    DebugLog.write("vpn.client-installation client=\(client.rawValue) installed=\(installed)")
                }
                self.clientInstalled = installed
                self.checkingInstallation = false
                self.draw()
            }
        }
    }

    @objc private func checkStatus() {
        DebugLog.write("menu.select check-status")
        startMonitoring(source: "menu")
    }

    private func startMonitoring(source: String) {
        DebugLog.write("monitor.start source=\(source) replacing=\(snapshot != nil)")
        guard busy == nil else {
            DebugLog.write("monitor.skipped reason=busy")
            return
        }
        let id = UUID().uuidString
        let url = URL(fileURLWithPath: "/private/tmp/local.vpn-ks.\(id)/status")
        let lease = FileManager.default.temporaryDirectory.appendingPathComponent("vpn-ks-monitor-" + id)
        do {
            try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        } catch {
            DebugLog.write("monitor.failed reason=lease-creation")
            let result = Admin.Result(ok: false, cancelled: false, message: error.localizedDescription)
            let previousSnapshot = snapshot
            showFailure(.monitorSetup, result: result) { [weak self] in
                guard let self, self.snapshot == previousSnapshot else { return }
                self.startMonitoring(source: "retry")
            }
            return
        }
        endMonitorLease()
        monitorLease = lease
        directoryWatch?.cancel()
        directoryWatch = nil
        vpnEvent = nil
        eventSent = false
        self.snapshot = url
        observeSamples(in: url)
        modified = nil
        status = .unread
        monitorRequested = true
        samplingStarted = Date()
        refresh()
        let command = Admin.monitor(snapshot: url, pid: ProcessInfo.processInfo.processIdentifier, lease: lease)
        Admin.run(command: command, prompt: "Read firewall status while VPN Kill Switch is open.") { [weak self] result in
            guard let self else { return }
            guard self.snapshot == url else {
                DebugLog.write("monitor.finished result=replaced")
                return
            }
            DebugLog.write("monitor.finished result=\(result.cancelled ? "cancelled" : result.ok ? "stopped" : "failed")")
            self.directoryWatch?.cancel()
            self.directoryWatch = nil
            self.endMonitorLease()
            self.snapshot = nil
            self.samplingStarted = nil
            self.modified = nil
            self.monitorRequested = false
            self.refresh()
            self.showFailure(.monitor, result: result) { [weak self] in
                guard let self, self.snapshot == nil else { return }
                self.startMonitoring(source: "retry")
            }
        }
    }

    private func endMonitorLease() {
        guard let lease = monitorLease else { return }
        try? FileManager.default.removeItem(at: lease)
        if let snapshot { _ = Admin.wakeMonitor(snapshot: snapshot, event: "stop") }
        monitorLease = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.write("app.terminate")
        stopObservingVPN()
        endMonitorLease()
    }

    private func observeSamples(in url: URL) {
        // The root monitor creates this directory only after authorization.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.snapshot == url else { return }
            let fd = open(url.deletingLastPathComponent().path, O_EVTONLY | O_NOFOLLOW)
            if fd < 0 { self.observeSamples(in: url); return }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            watch.setEventHandler { [weak self] in self?.refresh() }
            watch.setCancelHandler { close(fd) }
            self.directoryWatch = watch
            watch.resume()
            DebugLog.write("monitor.watching")
            self.refresh()
        }
    }

    private func refresh() {
        if let url = snapshot, let vpnEvent, !eventSent {
            eventSent = Admin.wakeMonitor(snapshot: url, event: vpnEvent.token)
            if eventSent { DebugLog.write("monitor.check-delivered") }
        }
        let source: String
        if let url = snapshot,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
           let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < Self.sampleLifetime,
           let data = try? String(contentsOf: url, encoding: .utf8),
           GuardStatus.sampleIsCurrent(data, after: lastMutation),
           vpnEvent?.matches(data) ?? true, let checked = selectedStatus(from: data) {
            immediateSample = nil
            modified = date
            status = checked
            monitorRequested = true
            source = "monitor"
        } else if let sample = immediateSample, Date().timeIntervalSince(sample.started) < Self.sampleLifetime,
                  let checked = selectedStatus(from: sample.snapshot) {
            modified = sample.started
            status = checked
            source = "mutation"
        } else {
            immediateSample = nil
            if let date = modified ?? samplingStarted, Date().timeIntervalSince(date) >= Self.sampleLifetime {
                monitorRequested = false
            }
            status = .unread
            source = monitorRequested ? "waiting" : "unavailable"
        }
        logProtectionState(source: source)
        draw()
    }

    private func logProtectionState(source: String) {
        guard DebugLog.isEnabled else {
            lastLoggedProtection = nil
            return
        }
        let vpn: String
        switch status.vpnConnection {
        case "Connected": vpn = "connected"
        case "Disconnected": vpn = "disconnected"
        case "Connecting": vpn = "connecting"
        case "Disconnecting": vpn = "disconnecting"
        default: vpn = "unknown"
        }
        let observedTunnel = status.vpnInterface.map { Self.interfaceForLog($0[...]) ?? "unknown" }
            ?? (vpn == "unknown" ? "unknown" : "none")
        let allowedTunnel = status.tunnel.flatMap { Self.interfaceForLog($0[...]) }
            ?? (status.tunnel == "none" ? "none" : "unknown")
        let entry = "protection.state source=\(source) client=\(selectedClient?.rawValue ?? "none") state=\(status.state) vpn=\(vpn) observedTunnel=\(observedTunnel) allowedTunnel=\(allowedTunnel)"
        guard entry != lastLoggedProtection else { return }
        DebugLog.write(entry)
        lastLoggedProtection = entry
    }

    private static func interfaceForLog(_ name: Substring) -> String? {
        guard name.hasPrefix("utun"), let index = UInt32(name.dropFirst(4)), "utun\(index)" == name else { return nil }
        return "utun\(index)"
    }

    private func selectedStatus(from snapshot: String) -> GuardStatus? {
        let checked = GuardStatus(snapshot: snapshot)
        return checked.belongs(to: selectedClient?.name) ? checked : nil
    }

    private var vpnConnectionState: String {
        switch lastVPNStatus {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        default: return status.vpnConnection ?? "—"
        }
    }

    private func draw() {
        let glyph = MenuGlyph(state: status.state, busy: busy != nil)
        item.button?.image = glyph.image
        statusLine.image = glyph.statusDot
        let summary = busy ?? (monitorRequested && modified == nil ? "Waiting for firewall check…" : status.title)
        item.button?.toolTip = "VPN Kill Switch · " + summary
        item.button?.setAccessibilityLabel("VPN Kill Switch · " + summary)
        statusLine.toolTip = summary
        statusLine.title = status.protectionMenuTitle(isBusy: busy != nil)
        statusLine.setAccessibilityLabel(statusLine.title)
        activityLine.title = summary
        tunnelLine.title = "Allowed tunnel: " + (status.tunnel ?? "—")
        vpnLine.title = (selectedClient?.name ?? "VPN client") + ": " + vpnConnectionState
        externalIP.update(status: busy == nil ? status : .unread, visible: protectionMenuOpen)
        displayExternalIP()
        updatedLine.title = modified.map { "Checked at " + clock.string(from: $0) } ?? "Waiting for firewall check"
        readLine.isHidden = monitorRequested
        readLine.isEnabled = busy == nil
        let action = status.state.menuAction
        var actionTitle = action.map { $0.rawValue + "…" } ?? ""
        var missingClientReason: String?
        actionLine.action = #selector(changeGuard)
        actionLine.isHidden = action == nil
        actionSeparator.isHidden = action == nil
        let checkingClient = action == .install && selectedClient != nil && clientInstalled == nil
        if action == .install {
            if let selectedClient {
                if checkingClient { checkInstallation() }
                if clientInstalled == false {
                    actionTitle = selectedClient.name + " required…"
                    missingClientReason = "Install \(selectedClient.name) in Applications and connect it first."
                    actionLine.action = #selector(openSettings)
                }
            } else {
                actionTitle = "Set Up VPN Server…"
            }
        }
        StatusMenuFeedback.setActionTitle(actionTitle, reason: missingClientReason, on: actionLine)
        actionLine.isEnabled = action != nil && busy == nil && !checkingClient
    }

    private func displayExternalIP() {
        setIPLine(externalIPLine, label: "External IPv4", address: externalIP.value)
        if let address = externalIP.distinctRUAddress {
            setIPLine(ruIPLine, label: "External RU IPv4", address: address, source: "internet-lab.ru")
            ruIPLine.isHidden = false
        } else {
            ruIPLine.isHidden = true
            ruIPLine.isEnabled = false
            ruIPLine.representedObject = nil
            ruIPLine.title = ""
            ruIPLine.toolTip = nil
            ruIPLine.setAccessibilityLabel(nil)
        }
    }

    private func setIPLine(_ line: NSMenuItem, label: String, address: String, source: String? = nil) {
        let ip = ExternalIP.parse(Data(address.utf8))
        line.representedObject = ip
        line.isEnabled = ip != nil
        let copyHint = ip == nil ? nil : "Click to copy IP"
        if let code = settings.geoIP.database?.country(for: address) {
            let name = Locale(identifier: "en").localizedString(forRegionCode: code) ?? code
            line.title = label + ": " + GeoIPDatabase.flag(code) + " " + address
            line.toolTip = [name + " (" + code + ")", source, copyHint].compactMap { $0 }.joined(separator: " · ")
            line.setAccessibilityLabel(label + ": " + address + ", " + name)
        } else {
            line.title = label + ": " + address
            line.toolTip = ip == nil ? nil : [source, copyHint].compactMap { $0 }.joined(separator: " · ")
            line.setAccessibilityLabel(line.title)
        }
    }

    @objc private func copyIPAddress(_ sender: NSMenuItem) {
        menuFeedback.copyAddress(from: sender, anchor: item.button)
    }

    private func showFailure(_ kind: Admin.Failure.Kind, result: Admin.Result,
                             settingsTab: SettingsWindow.Tab = .server, retry: (() -> Void)? = nil) {
        guard let failure = Admin.Failure(kind, result: result) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.explanation
        if !failure.details.isEmpty {
            let frame = NSRect(x: 0, y: 0, width: 340, height: 94)
            let scroll = NSScrollView(frame: frame)
            scroll.borderType = .bezelBorder
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: frame)
            text.isEditable = false
            text.isSelectable = true
            text.isVerticallyResizable = true
            text.autoresizingMask = .width
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 5, height: 5)
            text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            text.string = failure.details
            text.setAccessibilityLabel("Technical details")
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        // Close is the default so pressing Return cannot start another privileged action.
        alert.addButton(withTitle: "Close")
        let actions = failure.recoveryActions(logAvailable: FileManager.default.fileExists(atPath: DebugLog.fileURL.path))
        for action in actions { alert.addButton(withTitle: action.rawValue) }
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
        guard actions.indices.contains(index) else { return }
        switch actions[index] {
        case .retry: retry?()
        case .openSettings: settings.present(tab: settingsTab)
        case .showLog: NSWorkspace.shared.activateFileViewerSelecting([DebugLog.fileURL])
        }
    }

    private func showError(_ text: String, title: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }

    private func configureMainMenu() {
        let bar = NSMenu()
        let appItem = bar.addItem(withTitle: "VPN Kill Switch", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "VPN Kill Switch")
        appItem.submenu = appMenu
        let preferences = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        preferences.image = nil
        #if compiler(>=6.4)
        if #available(macOS 27, *) { preferences.preferredImageVisibility = .hidden }
        #endif
        let close = appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.target = nil
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q").target = self
        let edit = NSMenu(title: "Edit")
        bar.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = bar
    }

    @objc private func openSettings() {
        DebugLog.write("menu.select settings")
        settings.present(tab: .server)
    }

    @objc private func openAbout() {
        DebugLog.write("menu.select about")
        AboutPanel.present()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLog.write("app.reopen")
        settings.present()
        return false
    }

    private func applyConfiguration(_ configuration: VPNConfiguration) {
        DebugLog.write("settings.apply.authorization client=\(configuration.client.rawValue)")
        busy = "Applying VPN settings…"
        draw()
        let clientAtStart = selectedClient
        let eventAtStart = vpnEvent
        let prompt = "Allow \(configuration.client.name) to reach \(configuration.peer.label) through the firewall?"
        Admin.runMutation(command: configuration.applyCommand, prompt: prompt, operation: .apply) { [weak self] result in
            guard let self else { return }
            if result.ok { self.selectClient((VPNConfiguration.configured() ?? configuration).client) }
            self.finishMutation(result, eventAtStart: eventAtStart, clientChanged: clientAtStart != self.selectedClient)
            self.settings.finish(result, configuration: configuration)
            self.refresh()
            self.showFailure(.apply, result: result)
            if result.ok && self.snapshot == nil { self.startMonitoring(source: "settings-apply") }
        }
    }

    private func finishMutation(_ result: Admin.Result, eventAtStart: VPNCheckEvent?, clientChanged: Bool) {
        if !result.cancelled {
            let keepSample = clientChanged || vpnEvent == eventAtStart
            if selectedClient != nil {
                switch lastVPNStatus {
                case .connected: requestVPNCheck(.connected)
                case .disconnected: requestVPNCheck(.disconnected)
                default: requestVPNCheck(.refresh)
                }
            } else {
                lastMutation = Date()
                samplingStarted = lastMutation
                modified = nil
            }
            immediateSample = keepSample ? result.sample : nil
            status = .unread
        }
        busy = nil
    }

    @objc private func changeGuard() { confirmGuardChange(expecting: nil) }

    private func confirmGuardChange(expecting expectedAction: KillSwitchAction?) {
        DebugLog.write("menu.select firewall-action")
        guard busy == nil else {
            DebugLog.write("firewall.skipped reason=busy")
            if expectedAction != nil {
                showError("Wait for the current operation to finish, then try again.", title: "Another firewall operation is in progress")
            }
            return
        }
        if expectedAction != nil { refresh() }
        guard let action = status.state.menuAction else {
            DebugLog.write("firewall.skipped reason=action-unavailable state=\(status.state)")
            if expectedAction != nil {
                showError("Check Protection in the menu bar before trying again.", title: "Firewall action unavailable")
            }
            return
        }
        guard expectedAction == nil || expectedAction == action else {
            showError("Check Protection in the menu bar before trying again.", title: "Firewall status changed")
            return
        }
        let install = action == .install
        let operation = install ? "install" : "remove"
        DebugLog.write("firewall.selected action=\(operation)")
        refresh()
        guard status.state.menuAction == action else {
            DebugLog.write("firewall.skipped action=\(operation) stage=selection reason=status-changed state=\(status.state)")
            return
        }
        let client = selectedClient
        if install && client == nil {
            DebugLog.write("firewall.skipped action=install reason=client-unconfigured")
            settings.present(tab: .server)
            return
        }
        if install && clientInstalled != true {
            DebugLog.write("firewall.skipped action=install reason=client-installation-unverified")
            return
        }
        let confirmation = GuardConfirmation(action, clientName: client?.name)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.write("firewall.confirmation.open action=\(operation) client=\(client?.rawValue ?? "none")")
        guard confirmation.runModal() else {
            DebugLog.write("firewall.confirmation.cancelled action=\(operation)")
            return
        }
        DebugLog.write("firewall.confirmation.accepted action=\(operation)")
        refresh()
        if busy != nil {
            DebugLog.write("firewall.skipped action=\(operation) stage=confirmation reason=busy")
            showError("Wait for the current operation to finish, then try again.", title: "Another firewall operation is in progress")
            return
        }
        if status.state.menuAction != action || (install && client != selectedClient) {
            let reason = status.state.menuAction != action ? "status-changed" : "client-changed"
            DebugLog.write("firewall.skipped action=\(operation) stage=confirmation reason=\(reason) state=\(status.state) client=\(selectedClient?.rawValue ?? "none")")
            showError("Check Protection in the menu bar and try again when the action is available.",
                      title: reason == "status-changed" ? "Firewall status changed" : "Selected VPN changed")
            return
        }
        busy = install ? "Installing kill switch…" : "Removing kill switch…"
        draw()
        let command = "/bin/sh -c " + Admin.quote(install ? Commands.install : Commands.remove)
        let eventAtStart = vpnEvent
        DebugLog.write("firewall.authorization action=\(operation)")
        Admin.runMutation(command: command, prompt: confirmation.alert.messageText, operation: install ? .install : .remove) { [weak self] result in
            guard let self else { return }
            DebugLog.write("firewall.result action=\(operation) result=\(result.cancelled ? "cancelled" : result.ok ? "succeeded" : "failed")")
            if result.ok { self.selectClient(VPNConfiguration.configured()?.client) }
            self.finishMutation(result, eventAtStart: eventAtStart, clientChanged: client != self.selectedClient)
            self.refresh()
            let generation = self.selectionGeneration
            self.showFailure(install ? .install : .remove, result: result) { [weak self] in
                guard let self else { return }
                self.syncAppliedClient()
                guard self.selectionGeneration == generation else {
                    self.showError("Check Protection in the menu bar before trying again.", title: "Selected VPN changed")
                    return
                }
                self.confirmGuardChange(expecting: action)
            }
            if result.ok {
                self.settings.reloadIfClean()
                if !self.monitorRequested { self.startMonitoring(source: operation) }
            }
        }
    }

    @objc private func quitApp() {
        DebugLog.write("menu.select quit busy=\(busy != nil)")
        if busy == nil { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = MenuApp()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
