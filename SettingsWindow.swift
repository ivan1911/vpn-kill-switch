import AppKit

private struct ServerFields: Codable, Equatable {
    var address = ""
    var port = ""
    var transport = Transport.tcp

    var peer: Peer? {
        Peer(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
             port: port.trimmingCharacters(in: .whitespacesAndNewlines),
             transport: transport.rawValue)
    }
}

private struct StoredServerFields: Codable, Equatable {
    var applied: ServerFields?
    var draft: ServerFields?

    var fields: ServerFields { draft ?? applied ?? ServerFields() }
}

private final class LinkButton: NSButton {
    override var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }
}

private final class SettingsPaneWindow: NSWindow {
    var selectPane: ((Int) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let key = event.charactersIgnoringModifiers, let number = Int(key), (1...3).contains(number),
           let selectPane {
            selectPane(number - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindow: NSWindowController, NSTextFieldDelegate, NSTabViewDelegate, NSWindowDelegate, NSToolbarDelegate {
    enum Tab: String, CaseIterable {
        case server, exceptions, geoIP

        var title: String {
            switch self {
            case .server: return "VPN Server"
            case .exceptions: return "Exceptions"
            case .geoIP: return "GeoIP"
            }
        }

        var symbol: String {
            switch self {
            case .server: return "server.rack"
            case .exceptions: return "list.bullet.rectangle"
            case .geoIP: return "globe"
            }
        }

        var toolbarIdentifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
    }

    private static let chooseClientTitle = "Choose a VPN client"

    let exceptions: ExceptionsView
    let geoIP: GeoIPStore
    var onGeoIPChange: (() -> Void)?
    private let databaseURL = NSTextField()
    private let databaseName = NSTextField(labelWithString: "")
    private let databaseSize = NSTextField(labelWithString: "")
    private let databaseSource = NSTextField(wrappingLabelWithString: "")
    private let reloadDatabase = NSButton(title: "Update Installed Database", target: nil, action: nil)
    private var editedDatabaseURL = false
    private let databaseStatus = NSTextField(wrappingLabelWithString: "")
    private let databaseWarning = NSImageView()
    private let databaseError = NSTextField(wrappingLabelWithString: "")
    private let databaseDate = NSTextField(labelWithString: "")
    private let download = NSButton(title: "Download Database", target: nil, action: nil)
    private var databaseWasDownloading = false
    private let tabs = NSTabView()
    private let debugLogging = NSButton(checkboxWithTitle: "Debug Logging", target: nil, action: nil)
    private let showLog = LinkButton(title: "Show in Finder", target: nil, action: nil)
    private let logPath = NSTextField(wrappingLabelWithString: DebugLog.fileURL.path)
    private let clientPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let serverHint = NSTextField(wrappingLabelWithString: "")
    private let address = NSTextField()
    private let port = NSTextField()
    private let transport = NSSegmentedControl(labels: ["TCP", "UDP"], trackingMode: .selectOne, target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let apply = NSButton(title: "Apply", target: nil, action: nil)
    private let readConfiguration: () -> VPNConfiguration?
    private let installedClients: () -> [VPNClient]
    private let preferences: UserDefaults
    private var availableClients: [VPNClient] = []
    private var saved: VPNConfiguration?
    private var draftClient: VPNClient?
    private var isSaving = false
    private var operationBusy = false
    var onApply: ((VPNConfiguration) -> Void)?

    init(readConfiguration: @escaping () -> VPNConfiguration? = { VPNConfiguration.configured() },
         installedClients: @escaping () -> [VPNClient] = { VPNClient.allCases.filter(\.isInstalled) },
         readExceptions: (() throws -> String)? = nil,
         geoIP: GeoIPStore = GeoIPStore(),
         preferences: UserDefaults = .standard) {
        self.exceptions = ExceptionsView(read: readExceptions)
        self.geoIP = geoIP
        self.readConfiguration = readConfiguration
        self.installedClients = installedClients
        self.preferences = preferences
        let window = SettingsPaneWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 354),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "VPN Kill Switch Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: "VPNKillSwitch.SettingsPanes")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 510, height: 354))
        window.center()
        window.setFrameAutosaveName("VPNKillSwitch.Settings")
        window.selectPane = { [weak self] index in self?.select(Tab.allCases[index]) }

        tabs.tabViewType = .noTabsNoBorder
        addTab(.server, serverView())
        addTab(.exceptions, exceptions)
        addTab(.geoIP, databaseView(), initialFirstResponder: databaseURL)
        geoIP.onChange = { [weak self] in
            guard let self else { return }
            if self.databaseWasDownloading && !self.geoIP.downloading {
                DebugLog.write("settings.geoip.result outcome=\(self.geoIP.message.isEmpty ? "succeeded" : "failed")")
            }
            self.databaseWasDownloading = self.geoIP.downloading
            self.updateDatabaseControls()
            self.onGeoIPChange?()
        }
        updateDatabaseControls()
        window.defaultButtonCell = apply.cell as? NSButtonCell
        toolbar.selectedItemIdentifier = Tab.server.toolbarIdentifier
        tabs.delegate = self
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        loadSavedConfiguration()
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func present(tab: Tab? = nil) {
        guard let window else { return }
        if !window.isVisible && !isSaving {
            loadSavedConfiguration()
        }
        if let tab { select(tab) }
        let selected = (tabs.selectedTabViewItem?.identifier as? String).flatMap(Tab.init(rawValue:))
        if selected == .exceptions { exceptions.refreshIfClean() }
        DebugLog.write("settings.open tab=\(selected?.rawValue ?? "unknown")")
        updateDiagnostics()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if selected == .server { connectServerKeyViews() }
    }

    private func select(_ tab: Tab) {
        tabs.selectTabViewItem(withIdentifier: tab.rawValue)
    }

    @objc private func selectToolbarPane(_ sender: NSToolbarItem) {
        if let tab = Tab(rawValue: sender.itemIdentifier.rawValue) { select(tab) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectToolbarPane)
        return item
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let identifier = tabViewItem?.identifier as? String, let tab = Tab(rawValue: identifier) else { return }
        window?.toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
        window?.initialFirstResponder = tabViewItem?.initialFirstResponder
        switch tab {
        case .server:
            connectServerKeyViews()
            window?.defaultButtonCell = apply.cell as? NSButtonCell
        case .exceptions: window?.defaultButtonCell = exceptions.apply.cell as? NSButtonCell
        case .geoIP: window?.defaultButtonCell = nil
        }
        guard window?.isVisible == true else { return }
        if tab == .exceptions { exceptions.refreshIfClean() }
        DebugLog.write("settings.tab selected=\(tab.rawValue)")
    }

    // AppKit rebuilds the key loop when the window opens or the tab view switches panes.
    private func connectServerKeyViews() {
        clientPicker.nextKeyView = address
        address.nextKeyView = port
        port.nextKeyView = transport
        transport.nextKeyView = apply
        apply.nextKeyView = debugLogging
        debugLogging.nextKeyView = showLog
        showLog.nextKeyView = logPath
        logPath.nextKeyView = clientPicker
    }

    func windowWillClose(_ notification: Notification) {
        DebugLog.write("settings.close")
    }

    func windowDidMiniaturize(_ notification: Notification) {
        DebugLog.write("settings.minimize")
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        DebugLog.write("settings.restore")
    }

    func setBusy(_ busy: Bool) {
        operationBusy = busy
        exceptions.setBusy(busy)
        updateControls()
    }

    func finish(_ result: Admin.Result, configuration: VPNConfiguration) {
        DebugLog.write("settings.apply.result client=\(configuration.client.rawValue) outcome=\(result.cancelled ? "cancelled" : result.ok ? "succeeded" : "failed")")
        isSaving = false
        if result.ok {
            let applied = readConfiguration() ?? configuration
            updateSavedConfiguration(applied)
            if applied.endpoints[configuration.client] == configuration.peer {
                updateStoredFields(for: configuration.client) { $0.draft = nil }
            }
            showClient(applied.client)
            if FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/local.shadowrocket-killswitch.plist") {
                message("Saved \(applied.client.name) server \(applied.peer.label).")
            } else if availableClients.contains(applied.client) {
                message("Saved. Connect \(applied.client.name), then choose Install Kill Switch… in the menu bar.")
            } else {
                message("Saved. Install and connect \(applied.client.name), then choose Install Kill Switch… in the menu bar.")
            }
        } else {
            message(result.cancelled ? "Changes canceled." : "Could not apply VPN settings.", error: !result.cancelled)
        }
        updateControls()
    }

    func reloadIfClean() {
        reloadIfClean(readConfiguration())
    }

    func reloadIfClean(_ configuration: VPNConfiguration?) {
        guard !isSaving, configuration != saved else { return }
        let keepEditingClient = window?.isVisible == true && draftIsModified
        updateSavedConfiguration(configuration)
        let client = keepEditingClient ? draftClient : initialClient
        if client != draftClient || fields(for: client) != editorFields {
            window?.makeFirstResponder(nil)
            showClient(client)
        } else {
            updateControls()
        }
    }

    private var initialClient: VPNClient? {
        saved?.client ?? (availableClients.count == 1 ? availableClients.first : nil)
    }

    private var draftIsModified: Bool {
        draftClient != initialClient || draftClient.flatMap { storedFields(for: $0).draft } != nil
    }

    private func loadSavedConfiguration() {
        availableClients = installedClients()
        updateSavedConfiguration(readConfiguration())
        showClient(initialClient)
        let server = tabs.tabViewItem(at: 0)
        server.initialFirstResponder = draftClient == nil ? clientPicker : address
        window?.initialFirstResponder = tabs.selectedTabViewItem?.initialFirstResponder
    }

    private func updateSavedConfiguration(_ configuration: VPNConfiguration?) {
        saved = configuration
        // Older uninstallers may have cleared the root configuration. Keep the last known VPN server for each client.
        for (client, peer) in configuration?.endpoints ?? [:] {
            let applied = ServerFields(address: peer.address, port: String(peer.port), transport: peer.transport)
            updateStoredFields(for: client) {
                $0.applied = applied
                if $0.draft == applied { $0.draft = nil }
            }
        }
    }

    private func fields(for client: VPNClient?) -> ServerFields {
        client.map { storedFields(for: $0).fields } ?? ServerFields()
    }

    private func fieldsKey(for client: VPNClient) -> String {
        "vpnServerFields." + client.rawValue
    }

    private func storedFields(for client: VPNClient) -> StoredServerFields {
        guard let data = preferences.data(forKey: fieldsKey(for: client)),
              let stored = try? PropertyListDecoder().decode(StoredServerFields.self, from: data)
        else { return StoredServerFields() }
        return stored
    }

    private func updateStoredFields(for client: VPNClient, _ update: (inout StoredServerFields) -> Void) {
        let previous = storedFields(for: client)
        var updated = previous
        update(&updated)
        guard updated != previous, let data = try? PropertyListEncoder().encode(updated) else { return }
        preferences.set(data, forKey: fieldsKey(for: client))
    }

    private func showClient(_ client: VPNClient?) {
        draftClient = client
        clientPicker.selectItem(withTitle: client?.name ?? Self.chooseClientTitle)
        let fields = fields(for: client)
        address.stringValue = fields.address
        port.stringValue = fields.port
        transport.selectedSegment = fields.transport.segment
        if let client {
            let hint = "Use this IPv4 address in \(client.name) to reconnect without DNS. Keep any TLS SNI or Host value."
            serverHint.stringValue = availableClients.contains(client) ? hint : "Install \(client.name) to enable protection. " + hint
        } else {
            serverHint.stringValue = availableClients.isEmpty
                ? "Install Shadowrocket or Happ Plus to use VPN Kill Switch."
                : "Choose the VPN client you want to protect."
        }
        message("")
        updateControls()
    }

    private func addTab(_ id: Tab, _ view: NSView, initialFirstResponder: NSView? = nil) {
        let tab = NSTabViewItem(identifier: id.rawValue)
        tab.label = id.title
        tab.view = view
        tab.initialFirstResponder = initialFirstResponder
        tabs.addTabViewItem(tab)
    }

    private func serverView() -> NSView {
        let view = NSView()
        serverHint.textColor = .secondaryLabelColor
        serverHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clientPicker.addItems(withTitles: [Self.chooseClientTitle] + VPNClient.allCases.map(\.name))
        clientPicker.autoenablesItems = false
        clientPicker.item(at: 0)?.isEnabled = false
        clientPicker.setAccessibilityLabel("VPN client")
        clientPicker.target = self
        clientPicker.action = #selector(chooseClient)
        address.placeholderString = "IPv4 address"
        port.placeholderString = "1–65535"
        address.delegate = self
        port.delegate = self
        address.setAccessibilityLabel("Server IPv4 address")
        port.setAccessibilityLabel("Server port")
        transport.setAccessibilityLabel("Transport")
        transport.target = self
        transport.action = #selector(chooseTransport)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "VPN client"), clientPicker],
            [NSTextField(labelWithString: "IPv4 address"), address],
            [NSGridCell.emptyContentView, serverHint],
            [NSTextField(labelWithString: "Port"), port],
            [NSTextField(labelWithString: "Transport"), transport]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.columnSpacing = 14
        grid.rowSpacing = 10
        grid.rowAlignment = .firstBaseline
        let addressWidth: CGFloat = 320
        serverHint.preferredMaxLayoutWidth = addressWidth
        NSLayoutConstraint.activate([
            address.widthAnchor.constraint(equalToConstant: addressWidth),
            clientPicker.widthAnchor.constraint(equalTo: address.widthAnchor),
            serverHint.widthAnchor.constraint(equalTo: address.widthAnchor),
            port.widthAnchor.constraint(equalToConstant: 80)
        ])
        apply.target = self
        apply.action = #selector(submit)
        feedback.isSelectable = true
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        ])
        let diagnostics = diagnosticsView()
        diagnostics.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagnostics)
        NSLayoutConstraint.activate([
            diagnostics.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            diagnostics.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            diagnostics.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        addActionRow(to: view, below: diagnostics, status: feedback, button: apply)
        return view
    }

    static func positionActionButton(_ button: NSButton, in pane: NSView) {
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -14)
        ])
    }

    private func addActionRow(to view: NSView, below content: NSView, status: NSTextField, button: NSButton) {
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for control in [status, button] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        Self.positionActionButton(button, in: view)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            status.topAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: 8)
        ])
    }

    private func databaseView() -> NSView {
        let view = NSView()
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.fillColor = .controlBackgroundColor
        card.borderColor = .separatorColor
        card.contentViewMargins = NSSize(width: 12, height: 10)
        databaseName.font = .systemFont(ofSize: 15, weight: .semibold)
        databaseSize.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [databaseName, databaseSize])
        heading.spacing = 8
        databaseSource.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        databaseSource.lineBreakMode = .byCharWrapping
        databaseSource.maximumNumberOfLines = 2
        databaseSource.isSelectable = true
        databaseDate.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reloadDatabase.bezelStyle = .rounded
        reloadDatabase.setContentHuggingPriority(.required, for: .horizontal)
        reloadDatabase.target = self
        reloadDatabase.action = #selector(refreshInstalledDatabase)
        let pane = card.contentView!
        for control in [heading, databaseSource, databaseDate, reloadDatabase] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(control)
        }
        databaseSource.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        databaseSource.preferredMaxLayoutWidth = 350
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            heading.topAnchor.constraint(equalTo: pane.topAnchor),
            databaseSource.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            databaseSource.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            databaseSource.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            databaseDate.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            databaseDate.topAnchor.constraint(equalTo: databaseSource.bottomAnchor, constant: 4),
            reloadDatabase.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            reloadDatabase.centerYAnchor.constraint(equalTo: databaseDate.centerYAnchor)
        ])
        let label = NSTextField(labelWithString: "Database URL")
        databaseURL.stringValue = geoIP.source
        databaseURL.setAccessibilityLabel("Database URL")
        databaseURL.cell?.wraps = false
        databaseURL.cell?.isScrollable = true
        databaseURL.delegate = self
        databaseURL.target = self
        databaseURL.action = #selector(downloadDatabase)
        databaseDate.textColor = .secondaryLabelColor
        databaseStatus.textColor = .secondaryLabelColor
        databaseWarning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        databaseWarning.contentTintColor = .systemOrange
        databaseWarning.setAccessibilityElement(false)
        databaseWarning.translatesAutoresizingMaskIntoConstraints = false
        databaseError.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        databaseError.maximumNumberOfLines = 3
        databaseError.lineBreakMode = .byTruncatingTail
        databaseError.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        databaseError.translatesAutoresizingMaskIntoConstraints = false
        download.target = self
        download.action = #selector(downloadDatabase)
        let stack = NSStackView(views: [card, label, databaseURL])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(databaseWarning)
        view.addSubview(databaseError)
        addActionRow(to: view, below: stack, status: databaseStatus, button: download)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.heightAnchor.constraint(equalToConstant: 94),
            databaseURL.widthAnchor.constraint(equalTo: stack.widthAnchor),
            databaseError.topAnchor.constraint(equalTo: databaseURL.bottomAnchor, constant: 6),
            databaseWarning.leadingAnchor.constraint(equalTo: databaseURL.leadingAnchor),
            databaseWarning.topAnchor.constraint(equalTo: databaseError.topAnchor),
            databaseWarning.widthAnchor.constraint(equalToConstant: 14),
            databaseWarning.heightAnchor.constraint(equalToConstant: 14),
            databaseError.leadingAnchor.constraint(equalTo: databaseWarning.trailingAnchor, constant: 6),
            databaseError.trailingAnchor.constraint(equalTo: databaseURL.trailingAnchor),
            databaseError.bottomAnchor.constraint(lessThanOrEqualTo: download.topAnchor, constant: -8)
        ])
        return view
    }

    @objc private func refreshInstalledDatabase() {
        updateDatabase(from: geoIP.source, action: "update")
    }

    @objc private func downloadDatabase() {
        updateDatabase(from: databaseURL.stringValue, action: "download")
    }

    private func updateDatabase(from source: String, action: String) {
        DebugLog.write("settings.geoip.select action=\(action)")
        guard !geoIP.downloading else {
            DebugLog.write("settings.geoip.skipped reason=busy")
            return
        }
        geoIP.update(from: source)
        if !geoIP.downloading { DebugLog.write("settings.geoip.skipped reason=invalid-url") }
    }

    private func updateDatabaseControls() {
        let installed = geoIP.database != nil
        if !editedDatabaseURL { databaseURL.stringValue = geoIP.source }
        databaseURL.isEnabled = !geoIP.downloading
        download.isEnabled = !geoIP.downloading
        reloadDatabase.isHidden = !installed
        reloadDatabase.isEnabled = !geoIP.downloading
        databaseName.stringValue = installed ? "geoip.dat" : "No Database Installed"
        databaseSize.isHidden = !installed
        databaseSize.stringValue = installed ? String(format: "%.2f MB", Double(geoIP.byteCount) / 1_000_000) : ""
        databaseSource.stringValue = installed ? geoIP.source : "Click Download Database to show country flags beside the external IPv4."
        databaseSource.toolTip = installed ? geoIP.source : nil
        if let date = geoIP.updated {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "dd.MM.yyyy HH:mm"
            databaseDate.stringValue = "Last Updated: " + format.string(from: date)
        } else {
            databaseDate.stringValue = ""
        }
        let progress = geoIP.downloading ? geoIP.message : ""
        let error = geoIP.downloading ? "" : geoIP.message
        databaseStatus.stringValue = progress
        databaseStatus.toolTip = progress.isEmpty ? nil : progress
        databaseError.stringValue = error
        databaseError.toolTip = error.isEmpty ? nil : error
        databaseWarning.isHidden = error.isEmpty
        databaseError.isHidden = error.isEmpty
    }

    private func diagnosticsView() -> NSView {
        let title = NSTextField(labelWithString: "Diagnostics")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        debugLogging.target = self
        debugLogging.action = #selector(changeDebugLogging)
        debugLogging.toolTip = "Record diagnostic events locally."
        showLog.target = self
        showLog.action = #selector(revealDebugLog)
        showLog.isBordered = false
        showLog.contentTintColor = .linkColor
        showLog.toolTip = DebugLog.fileURL.path
        updateDiagnostics()
        let row = NSStackView(views: [debugLogging, showLog])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        logPath.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        logPath.textColor = .secondaryLabelColor
        logPath.lineBreakMode = .byCharWrapping
        logPath.isSelectable = true
        logPath.setAccessibilityLabel("Debug log path")
        let stack = NSStackView(views: [title, row, logPath])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        logPath.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func changeDebugLogging() {
        DebugLog.isEnabled = debugLogging.state == .on
        updateDiagnostics()
    }

    private func updateDiagnostics() {
        debugLogging.state = DebugLog.isEnabled ? .on : .off
        showLog.isEnabled = FileManager.default.fileExists(atPath: DebugLog.fileURL.path)
    }

    @objc private func revealDebugLog() {
        updateDiagnostics()
        guard showLog.isEnabled else { return }
        NSWorkspace.shared.activateFileViewerSelecting([DebugLog.fileURL])
    }

    private var editorFields: ServerFields {
        ServerFields(address: address.currentEditor()?.string ?? address.stringValue,
                     port: port.currentEditor()?.string ?? port.stringValue,
                     transport: Transport(segment: transport.selectedSegment))
    }

    private func saveDraft(for client: VPNClient, fields: ServerFields) {
        updateStoredFields(for: client) {
            $0.draft = fields == ($0.applied ?? ServerFields()) ? nil : fields
        }
    }

    private func message(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.toolTip = text.isEmpty ? nil : text
        feedback.textColor = error ? .systemRed : .secondaryLabelColor
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === databaseURL {
            editedDatabaseURL = true
            updateDatabaseControls()
        } else { edited() }
    }
    private func edited() {
        if let draftClient { saveDraft(for: draftClient, fields: editorFields) }
        message("")
        updateControls()
    }

    @objc private func chooseTransport() {
        DebugLog.write("settings.transport selected=\(Transport(segment: transport.selectedSegment).rawValue)")
        edited()
    }

    @objc private func chooseClient() {
        guard !operationBusy, !isSaving,
              let client = VPNClient.allCases.first(where: { $0.name == clientPicker.titleOfSelectedItem }),
              client != draftClient else { return }
        DebugLog.write("settings.client selected=\(client.rawValue)")
        window?.makeFirstResponder(nil)
        showClient(client)
        window?.makeFirstResponder(address)
    }

    private func updateControls() {
        let enabled = !operationBusy && !isSaving
        clientPicker.isEnabled = enabled
        let editing = enabled && draftClient != nil
        address.isEnabled = editing
        port.isEnabled = editing
        transport.isEnabled = editing
        apply.isEnabled = editing && (draftClient != saved?.client || editorFields.peer != saved?.peer)
    }

    @objc private func submit() {
        DebugLog.write("settings.apply.selected client=\(draftClient?.rawValue ?? "none")")
        guard !operationBusy, !isSaving else {
            DebugLog.write("settings.apply.skipped reason=busy")
            return
        }
        guard let client = draftClient else {
            DebugLog.write("settings.apply.skipped reason=client-unselected")
            return
        }
        let fields = editorFields
        saveDraft(for: client, fields: fields)
        guard let peer = fields.peer else {
            DebugLog.write("settings.apply.skipped reason=invalid-endpoint")
            message("Enter an IPv4 address and a port from 1 to 65535.", error: true)
            return
        }
        guard client != saved?.client || peer != saved?.peer else {
            DebugLog.write("settings.apply.skipped reason=no-changes")
            return
        }
        guard let onApply else {
            DebugLog.write("settings.apply.skipped reason=handler-unavailable")
            return
        }
        isSaving = true
        message("Applying…")
        updateControls()
        onApply(VPNConfiguration(client: client, peer: peer, preserving: saved))
    }
}

enum AboutPanel {
    static func present() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["VPNBuildIdentifier"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "—"
        let credits = NSMutableAttributedString(
            string: "Uses the macOS firewall to block internet access outside your selected VPN. Supports Shadowrocket and Happ Plus. Protection stays on when you quit the app.\n\n",
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(string: "Open Guide", attributes: [
            .link: URL(string: "https://github.com/ivan1911/vpn-kill-switch#readme")!
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "VPN Kill Switch",
            .applicationVersion: version,
            .credits: credits
        ]
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            options[.applicationIcon] = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
