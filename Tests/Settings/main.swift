// Run as an AppKit executable in a graphical session. The save callback is a
// test double so this exercises the window without requesting rights or touching pf.
import AppKit

enum Commands {
    static var check = try! String(contentsOfFile: "Scripts/check.sh", encoding: .utf8)
    static let peer = ""
    static let baseRules = try! String(contentsOfFile: "Guard/guard.pf", encoding: .utf8)
}

func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.count == 3 {
    let mode = CommandLine.arguments[2]
    precondition(mode == "light" || mode == "dark", "Screenshot appearance must be light or dark.")
    app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
}
let suite = "VPNKillSwitch.SettingsTests." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
let legacySuite = suite + ".legacy"
let legacyPreferences = UserDefaults(suiteName: legacySuite)!
let geoIPDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
defer {
    preferences.removePersistentDomain(forName: suite)
    legacyPreferences.removePersistentDomain(forName: legacySuite)
    try? FileManager.default.removeItem(at: geoIPDirectory)
}
var savedConfiguration: VPNConfiguration?
let geoIP = GeoIPStore(directory: geoIPDirectory)
var exceptionList = "192.168.0.0/16"
let settings = SettingsWindow(readConfiguration: { savedConfiguration }, installedClients: { [.happPlus] },
                              readExceptions: { exceptionList }, geoIP: geoIP, preferences: preferences)
settings.present()
let window = settings.window!
let content = window.contentView!
content.layoutSubtreeIfNeeded()
let tabs = descendants(content).compactMap { $0 as? NSTabView }.first!
let expectedPanes = ["VPN Server", "Exceptions", "GeoIP"]
precondition(window.toolbar?.items.map(\.label) == expectedPanes,
             "Settings should offer three named toolbar panes.")
let toolbar = window.toolbar!
precondition(toolbar.items.allSatisfy { $0.image != nil })
precondition(toolbar.selectedItemIdentifier == toolbar.items[0].itemIdentifier)
func selectPane(_ index: Int) {
    let item = toolbar.items[index]
    precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
    precondition(toolbar.selectedItemIdentifier == item.itemIdentifier)
    precondition(tabs.selectedTabViewItem?.label == expectedPanes[index])
}
func selectPaneWithKeyboard(_ index: Int) {
    let key = String(index + 1)
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                 characters: key, charactersIgnoringModifiers: key,
                                 isARepeat: false, keyCode: [18, 19, 20][index])!
    precondition(window.performKeyEquivalent(with: event))
    precondition(toolbar.selectedItemIdentifier == toolbar.items[index].itemIdentifier)
    precondition(tabs.selectedTabViewItem?.label == expectedPanes[index])
}
let controls = descendants(tabs.tabViewItems[0].view!)
let fields = controls.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
let address = fields.first { $0.placeholderString == "IPv4 address" }!
let port = fields.first { $0.placeholderString == "1–65535" }!
let apply = controls.compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
let picker = controls.compactMap { $0 as? NSPopUpButton }.first!
let transport = controls.compactMap { $0 as? NSSegmentedControl }.first!
let logging = controls.compactMap { $0 as? NSButton }.first { $0.title == "Debug Logging" }!
let showLog = controls.compactMap { $0 as? NSButton }.first { $0.title == "Show in Finder" }!
let logPath = controls.compactMap { $0 as? NSTextField }.first { $0.stringValue == DebugLog.fileURL.path }!
let loggingFrame = alignmentFrame(logging)
let showLogFrame = alignmentFrame(showLog)
precondition(showLogFrame.minX > loggingFrame.maxX && abs(showLogFrame.midY - loggingFrame.midY) < 3)
precondition(showLog.isEnabled == FileManager.default.fileExists(atPath: DebugLog.fileURL.path))
precondition(logPath.isSelectable && !logPath.isEditable && !logPath.isHiddenOrHasHiddenAncestor)
logPath.selectText(nil)
let pathEditor = logPath.currentEditor() as! NSTextView
pathEditor.selectAll(nil)
let pathPasteboard = NSPasteboard.withUniqueName()
precondition(pathEditor.writeSelection(to: pathPasteboard, types: pathEditor.writablePasteboardTypes))
precondition(pathPasteboard.string(forType: .string) == DebugLog.fileURL.path)
pathEditor.setSelectedRange((pathEditor.string as NSString).range(of: "debug.log", options: .backwards))
pathPasteboard.clearContents()
precondition(pathEditor.writeSelection(to: pathPasteboard, types: pathEditor.writablePasteboardTypes))
precondition(pathPasteboard.string(forType: .string) == "debug.log")
pathPasteboard.releaseGlobally()
func verifyServerKeyOrder() {
    let serverKeyOrder: [NSView] = [picker, address, port, transport, apply, logging, showLog, logPath, picker]
    for (current, next) in zip(serverKeyOrder, serverKeyOrder.dropFirst()) {
        precondition(current.nextKeyView === next, "Unexpected key link from \(current) to \(String(describing: current.nextKeyView)); expected \(next).")
    }
}
verifyServerKeyOrder()
let serverApplyFrame = alignmentFrame(apply)
selectPaneWithKeyboard(1)
content.layoutSubtreeIfNeeded()
let exceptionsApplyFrame = alignmentFrame(settings.exceptions.apply)
precondition(exceptionsApplyFrame == serverApplyFrame,
             "Apply moved from \(serverApplyFrame) to \(exceptionsApplyFrame) when switching panes.")
selectPaneWithKeyboard(0)
selectPaneWithKeyboard(2)
precondition(window.defaultButtonCell == nil)
let geo = descendants(tabs.selectedTabViewItem!.view!)
let source = geo.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
let download = geo.compactMap { $0 as? NSButton }.first { $0.title == "Download Database" }!
let reload = geo.compactMap { $0 as? NSButton }.first { $0.title == "Update Installed Database" }
let geoLabels = geo.compactMap { $0 as? NSTextField }
precondition(geoLabels.contains { $0.stringValue == "No Database Installed" && !$0.isHiddenOrHasHiddenAncestor })
precondition(geoLabels.contains { $0.stringValue == "Click Download Database to show country flags beside the external IPv4." && !$0.isHiddenOrHasHiddenAncestor })
precondition(!geoLabels.contains { $0.stringValue == "0.00 MB" && !$0.isHiddenOrHasHiddenAncestor })
if CommandLine.arguments.count >= 2 {
    try captureWindow(window, named: "geoip-empty")
}
func alignmentFrame(_ view: NSView) -> NSRect {
    view.superview!.convert(view.alignmentRect(forFrame: view.frame), to: content)
}
func geoMessageFrame(_ message: String) -> NSRect {
    let label = geo.compactMap { $0 as? NSTextField }.first { $0.stringValue == message }!
    precondition(!label.isHiddenOrHasHiddenAncestor)
    content.layoutSubtreeIfNeeded()
    return alignmentFrame(label)
}
func verifyInlineGeoError(_ message: String) {
    let warning = geo.compactMap { $0 as? NSImageView }.first {
        !$0.isHiddenOrHasHiddenAncestor && $0.image != nil
    }
    precondition(warning != nil, "The inline GeoIP error should show a warning symbol.")
    let errorFrame = geoMessageFrame(message)
    let sourceFrame = alignmentFrame(source)
    let gap = sourceFrame.minY - errorFrame.maxY
    precondition(gap > 0 && gap <= 10, "The GeoIP error should appear directly below Database URL.")
    precondition(abs(alignmentFrame(warning!).minX - sourceFrame.minX) < 1 && errorFrame.minX > alignmentFrame(warning!).maxX && abs(errorFrame.maxX - sourceFrame.maxX) < 1,
                 "The GeoIP error \(errorFrame) should span the Database URL field \(sourceFrame).")
}
// Exception reads and validations run on a background queue and answer on the
// main queue, so spin the run loop until the view is idle instead of sleeping.
func settle(_ view: ExceptionsView = settings.exceptions) {
    let deadline = Date().addingTimeInterval(10)
    while view.isChecking && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    precondition(!view.isChecking, "The exception check should finish.")
}
func waitForGeoIPDownload() {
    let deadline = Date().addingTimeInterval(5)
    while geoIP.downloading && Date() < deadline {
        RunLoop.current.run(mode: .default, before: deadline)
    }
    precondition(!geoIP.downloading, "The injected download should finish.")
}

precondition(source.stringValue == geoIP.source)
precondition(!download.isHiddenOrHasHiddenAncestor && download.isEnabled && (reload?.isHidden ?? true))
source.stringValue = "http://insecure.example/database"
download.performClick(nil)
verifyInlineGeoError("Enter an HTTPS database URL.")

let installedSource = "https://example.invalid/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
// A V2Ray country record for DE with one IPv4 prefix, 192.0.2.0/24.
let database = Data([0x0a, 14, 0x0a, 2, 0x44, 0x45, 0x12, 8, 0x0a, 4, 192, 0, 2, 0, 0x10, 24])
geoIP.update(from: installedSource) { _ in database }
waitForGeoIPDownload()
precondition(geoIP.database?.country(for: "192.0.2.1") == "DE" && source.stringValue == installedSource)
precondition(!download.isHiddenOrHasHiddenAncestor && download.isEnabled,
             "Download Database should be available when the installed URL is unchanged.")
precondition(reload?.isHiddenOrHasHiddenAncestor == false && reload?.isEnabled == true)
if CommandLine.arguments.count >= 2 {
    try captureWindow(window, named: "geoip")
}

let downloadError = "Download failed. Check the URL and your connection."
geoIP.update(from: installedSource) { _ in
    throw NSError(domain: suite, code: 1, userInfo: [NSLocalizedDescriptionKey: downloadError])
}
precondition(!download.isHiddenOrHasHiddenAncestor && !download.isEnabled && reload?.isEnabled == false && !source.isEnabled)
let progressFrame = geoMessageFrame("Downloading…")
let downloadingButtonFrame = alignmentFrame(download)
precondition(abs(progressFrame.midY - downloadingButtonFrame.midY) < 1, "Progress should stay beside Download Database.")
waitForGeoIPDownload()
verifyInlineGeoError(downloadError)
precondition(geoIP.database?.country(for: "192.0.2.1") == "DE" && source.stringValue == installedSource)
if CommandLine.arguments.count >= 2 {
    try captureWindow(window, named: "geoip-failed")
}
precondition(!download.isHiddenOrHasHiddenAncestor && download.isEnabled && reload?.isEnabled == true && source.isEnabled)

let downloadFrame = download.convert(download.bounds, to: content)
settings.present(tab: .server)
content.layoutSubtreeIfNeeded()
let applyFrame = apply.convert(apply.bounds, to: content)
precondition(abs(applyFrame.width - apply.intrinsicContentSize.width) < 1)
precondition(abs(downloadFrame.width - download.intrinsicContentSize.width) < 1)
precondition(abs(applyFrame.maxX - downloadFrame.maxX) < 1 && abs(applyFrame.minY - downloadFrame.minY) < 1)
let serverLabels = controls.compactMap { $0 as? NSTextField }.filter { !$0.isEditable }
let serverRows: [(String, NSControl)] = [
    ("VPN client", picker), ("IPv4 address", address), ("Port", port), ("Transport", transport)
]
func baseline(_ view: NSView) -> CGFloat {
    let offset = view.firstBaselineOffsetFromTop
    let y = view.isFlipped ? offset : view.bounds.height - offset
    return view.convert(NSPoint(x: 0, y: y), to: content).y
}
for (title, control) in serverRows {
    let label = serverLabels.first { $0.stringValue == title }!
    precondition(abs(baseline(label) - baseline(control)) < 1, "\(title) should share its control's baseline.")
}
precondition(abs(alignmentFrame(picker).maxX - alignmentFrame(address).maxX) < 1)
precondition(abs(alignmentFrame(port).width - 80) < 1)
let addressHint = serverLabels.first { $0.stringValue.contains("TLS SNI or Host") }!
precondition(abs(alignmentFrame(addressHint).minX - alignmentFrame(address).minX) < 1)
precondition(alignmentFrame(addressHint).maxY < alignmentFrame(address).minY)
precondition(alignmentFrame(addressHint).minY > alignmentFrame(port).maxY)
precondition(addressHint.textColor == .secondaryLabelColor)
verifyServerKeyOrder()
precondition(picker.titleOfSelectedItem == "Happ Plus")
precondition(address.stringValue.isEmpty && port.stringValue.isEmpty)
precondition(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("TLS SNI or Host") })
var saves = 0
settings.onApply = { configuration in
    precondition(configuration.client == .happPlus)
    precondition(configuration.peer.address == "198.51.100.123" && configuration.peer.port == 8443)
    saves += 1
    savedConfiguration = configuration
    settings.finish(Admin.Result(ok: true, cancelled: false, message: ""), configuration: configuration)
}
func edit(_ field: NSTextField, _ text: String) {
    field.stringValue = text
    settings.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
}

edit(address, "bad")
apply.performClick(nil)
precondition(saves == 0)
precondition(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Enter an IPv4 address") })
edit(address, "198.51.100.123")
edit(port, "8443")
selectPane(2)
selectPane(0)
precondition(window.defaultButtonCell === apply.cell)
precondition(address.stringValue == "198.51.100.123" && port.stringValue == "8443")
settings.setBusy(true)
precondition(!apply.isEnabled)
settings.setBusy(false)
apply.performClick(nil)
precondition(saves == 1 && !apply.isEnabled)
settings.present()
precondition(settings.window === window)
window.performClose(nil)
settings.present()
precondition(settings.window === window && settings.window!.isVisible)
precondition(picker.titleOfSelectedItem == "Happ Plus" && address.stringValue == "198.51.100.123")

let shadowrocketRule = "pass out quick inet proto tcp from any to 203.0.113.7 port 443 flags any no state"
let happPlusRule = "pass out quick inet proto udp from any to 198.51.100.123 port 8443 no state"
let legacy = VPNConfiguration(rules: shadowrocketRule)!
precondition(legacy.client == .shadowrocket && legacy.peer.label == "203.0.113.7:443/TCP")
precondition(legacy.endpoints[.happPlus] == nil)
let happPlusMetadata = """
# client: happ-plus
# endpoint shadowrocket: 203.0.113.7 443 tcp
# endpoint happ-plus: 198.51.100.123 8443 udp
"""
let badSeparator = happPlusMetadata.replacingOccurrences(of: "client: happ-plus", with: "client:\u{00a0}happ-plus")
precondition(VPNConfiguration(rules: badSeparator + "\n" + happPlusRule) == nil)
let bothConfigured = VPNConfiguration(rules: happPlusMetadata + "\n" + happPlusRule)!
precondition(bothConfigured.client == .happPlus && bothConfigured.peer.label == "198.51.100.123:8443/UDP")
precondition(bothConfigured.endpoints[.shadowrocket] == legacy.peer)
precondition(bothConfigured.applyCommand.hasSuffix("'--apply' '198.51.100.123' '8443' 'udp' 'happ-plus'"))
precondition(VPNConfiguration(rules: happPlusMetadata + "\n" + shadowrocketRule) == nil)
precondition(VPNConfiguration(rules: happPlusMetadata + "\n# client: happ-plus\n" + happPlusRule) == nil)
precondition(VPNConfiguration(rules: happPlusRule + "\n# endpoint happ-plus: 198.51.100.123 8443 udp") == nil)
precondition(VPNConfiguration(rules: happPlusRule + "\n# client: happ-plus") == nil)
precondition(VPNConfiguration(rules: shadowrocketRule + "\n# endpoint shadowrocket: 203.0.113.7 443 tcp") == nil)
precondition(VPNConfiguration(rules: shadowrocketRule + "\n#\tclient shadowrocket") == nil)
precondition(VPNConfiguration(rules: shadowrocketRule + "\n# endpoint") == nil)
precondition(Peer(address: "203.0.113.7\0.example", port: "443", transport: "tcp") == nil)

func serverControls(_ controller: SettingsWindow) -> [NSView] {
    let tabs = descendants(controller.window!.contentView!).compactMap { $0 as? NSTabView }.first!
    return descendants(tabs.tabViewItems[0].view!)
}

let supportedClients = VPNClient.allCases
for installed in [[], [.shadowrocket], supportedClients] {
    let fresh = SettingsWindow(readConfiguration: { nil }, installedClients: { installed }, preferences: legacyPreferences)
    let server = serverControls(fresh)
    let picker = server.compactMap { $0 as? NSPopUpButton }.first!
    let apply = server.compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
    precondition(picker.itemTitles.contains("Shadowrocket") && picker.itemTitles.contains("Happ Plus"))
    precondition(picker.titleOfSelectedItem == (installed.count == 1 ? "Shadowrocket" : "Choose a VPN client"))
    precondition(apply.isEnabled == (installed.count == 1))
    if installed.isEmpty {
        precondition(server.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Install Shadowrocket or Happ Plus") })
    }
}

var stored = legacy
let upgraded = SettingsWindow(readConfiguration: { stored }, installedClients: { supportedClients }, preferences: legacyPreferences)
upgraded.present(tab: .server)
let upgradedControls = serverControls(upgraded)
let upgradedPicker = upgradedControls.compactMap { $0 as? NSPopUpButton }.first!
let upgradedFields = upgradedControls.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
let upgradedAddress = upgradedFields.first { $0.placeholderString == "IPv4 address" }!
let upgradedPort = upgradedFields.first { $0.placeholderString == "1–65535" }!
let upgradedTransport = upgradedControls.compactMap { $0 as? NSSegmentedControl }.first!
let upgradedApply = upgradedControls.compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
func selectClient(_ client: VPNClient, using picker: NSPopUpButton = upgradedPicker) {
    picker.selectItem(withTitle: client.name)
    precondition(picker.sendAction(picker.action, to: picker.target))
}
precondition(upgradedPicker.titleOfSelectedItem == "Shadowrocket" && upgradedAddress.stringValue == "203.0.113.7")
upgradedPort.stringValue = "44 "
upgraded.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: upgradedPort))
selectClient(.happPlus)
precondition(upgradedAddress.stringValue.isEmpty && upgradedPort.stringValue.isEmpty)
let editor = upgradedAddress.currentEditor() as! NSTextView
editor.insertText("unsaved", replacementRange: editor.selectedRange())
upgradedPort.stringValue = "84"
upgraded.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: upgradedPort))
upgradedTransport.selectedSegment = 1
precondition(upgradedTransport.sendAction(upgradedTransport.action, to: upgradedTransport.target))
upgraded.reloadIfClean()
precondition(editor.string == "unsaved" && stored == legacy)
selectClient(.shadowrocket)
precondition(upgradedAddress.stringValue == "203.0.113.7" && upgradedPort.stringValue == "44 ")
precondition(upgradedTransport.selectedSegment == 0)
upgraded.window!.performClose(nil)
upgraded.present(tab: .server)
precondition(upgradedPicker.titleOfSelectedItem == "Shadowrocket" && upgradedAddress.stringValue == "203.0.113.7")
precondition(upgradedPort.stringValue == "44 ")
upgradedPort.stringValue = "443"
upgraded.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: upgradedPort))

selectClient(.happPlus)
precondition(upgradedAddress.stringValue == "unsaved", "Closing settings must preserve the Happ Plus draft.")
precondition(upgradedPort.stringValue == "84" && upgradedTransport.selectedSegment == 1)
upgradedAddress.stringValue = "198.51.100.123"
upgradedPort.stringValue = "8443 "
var cancel = true
var shouldFail = false
var expectedClient = VPNClient.happPlus
upgraded.onApply = { configuration in
    precondition(configuration.client == expectedClient)
    precondition(configuration.endpoints[.shadowrocket] == legacy.peer)
    precondition(configuration.endpoints[.happPlus] == bothConfigured.peer)
    let ok = !cancel && !shouldFail
    if ok { stored = configuration }
    upgraded.finish(Admin.Result(ok: ok, cancelled: cancel, message: shouldFail ? "Could not update firewall." : ""), configuration: configuration)
}
upgradedApply.performClick(nil)
precondition(stored == legacy && upgradedApply.isEnabled && upgradedAddress.stringValue == "198.51.100.123")
precondition(upgradedControls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Changes canceled." })
cancel = false
shouldFail = true
upgradedApply.performClick(nil)
precondition(stored == legacy && upgradedApply.isEnabled)
precondition(upgradedControls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Could not apply VPN settings." })
shouldFail = false
upgradedApply.performClick(nil)
precondition(stored == bothConfigured && !upgradedApply.isEnabled)
precondition(upgradedPort.stringValue == "8443")
selectClient(.shadowrocket)
precondition(upgradedAddress.stringValue == "203.0.113.7" && upgradedPort.stringValue == "443")
precondition(upgradedTransport.selectedSegment == 0 && upgradedApply.isEnabled)
expectedClient = .shadowrocket
upgradedApply.performClick(nil)
selectClient(.happPlus)
precondition(upgradedAddress.stringValue == "198.51.100.123" && upgradedPort.stringValue == "8443")
precondition(upgradedTransport.selectedSegment == 1)
upgraded.close()

func verifyCachedEndpoints() {
    let cacheSuite = suite + ".cache"
    let cachePreferences = UserDefaults(suiteName: cacheSuite)!
    defer { cachePreferences.removePersistentDomain(forName: cacheSuite) }
    var applied: VPNConfiguration? = bothConfigured
    let startup = SettingsWindow(readConfiguration: { applied }, installedClients: { supportedClients },
                                 preferences: cachePreferences)
    precondition(!startup.window!.isVisible)
    applied = nil
    startup.reloadIfClean()
    let relaunched = SettingsWindow(readConfiguration: { applied }, installedClients: { supportedClients },
                                    preferences: UserDefaults(suiteName: cacheSuite)!)
    let controls = serverControls(relaunched)
    let picker = controls.compactMap { $0 as? NSPopUpButton }.first!
    let address = controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "IPv4 address" }!
    let port = controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "1–65535" }!
    let transport = controls.compactMap { $0 as? NSSegmentedControl }.first!
    precondition(picker.titleOfSelectedItem == "Choose a VPN client")
    selectClient(.shadowrocket, using: picker)
    precondition(address.stringValue == "203.0.113.7" && port.stringValue == "443" && transport.selectedSegment == 0)
    selectClient(.happPlus, using: picker)
    precondition(address.stringValue == "198.51.100.123" && port.stringValue == "8443" && transport.selectedSegment == 1)

    applied = bothConfigured
    relaunched.present(tab: .server)
    selectClient(.shadowrocket, using: picker)
    address.stringValue = ""
    relaunched.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: address))
    let newSR = Peer(address: "203.0.113.99", port: "9443", transport: "udp")!
    let newHP = Peer(address: "198.51.100.99", port: "443", transport: "tcp")!
    let updatedSR = VPNConfiguration(client: .shadowrocket, peer: newSR, preserving: bothConfigured)
    applied = VPNConfiguration(client: .happPlus, peer: newHP, preserving: updatedSR)
    relaunched.reloadIfClean(applied)
    precondition(picker.titleOfSelectedItem == "Shadowrocket" && address.stringValue.isEmpty && port.stringValue == "443")
    selectClient(.happPlus, using: picker)
    precondition(address.stringValue == "198.51.100.99" && port.stringValue == "443" && transport.selectedSegment == 0)
    // Removal now leaves the applied configuration available to a fresh app.
    relaunched.reloadIfClean()
    let reopened = SettingsWindow(readConfiguration: { applied }, installedClients: { supportedClients },
                                  preferences: UserDefaults(suiteName: cacheSuite)!)
    let reopenedControls = serverControls(reopened)
    let reopenedPicker = reopenedControls.compactMap { $0 as? NSPopUpButton }.first!
    let reopenedAddress = reopenedControls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "IPv4 address" }!
    precondition(reopenedPicker.titleOfSelectedItem == "Happ Plus" && reopenedAddress.stringValue == "198.51.100.99")
    precondition(!reopenedControls.compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!.isEnabled)
    selectClient(.shadowrocket, using: reopenedPicker)
    precondition(reopenedAddress.stringValue.isEmpty, "An intentionally empty draft survives removal and relaunch.")
    selectClient(.happPlus, using: reopenedPicker)
    precondition(reopenedAddress.stringValue == "198.51.100.99")
    relaunched.close()
}
verifyCachedEndpoints()

settings.present(tab: .exceptions)
settle()
content.layoutSubtreeIfNeeded()
let emptyExceptions = ExceptionsView(read: { "" })
emptyExceptions.refreshIfClean()
settle(emptyExceptions)
let emptyControls = descendants(emptyExceptions)
let emptyMessage = emptyControls.compactMap { $0 as? NSTextField }.first {
    $0.stringValue == "No exceptions. Localhost is always allowed."
}
precondition(emptyMessage?.isHiddenOrHasHiddenAncestor == false, "An empty list should show guidance.")
let realChecker = Commands.check
Commands.check = "echo 'The exception preferences are malformed.' >&2; exit 1"
let broken = ExceptionsView()
var unexpectedProtectedReads = 0
broken.onReadProtected = { _ in unexpectedProtectedReads += 1 }
broken.refreshIfClean()
settle(broken)
let brokenControls = descendants(broken)
precondition(brokenControls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("malformed") })
let retryBroken = brokenControls.compactMap { $0 as? NSButton }.first { $0.title == "Reload" }!
precondition(!retryBroken.isHidden)
retryBroken.performClick(nil)
settle(broken)
precondition(unexpectedProtectedReads == 0 && !retryBroken.isHidden)
Commands.check = "echo 203.0.113.0/24"
retryBroken.performClick(nil)
settle(broken)
precondition(retryBroken.isHidden)
precondition(brokenControls.compactMap { $0 as? NSTableView }.first!.numberOfRows == 1)
Commands.check = "echo 'Administrator access is needed to read exceptions.' >&2; exit 77"
let restricted = ExceptionsView()
var protectedReads = 0
restricted.onReadProtected = { completion in
    protectedReads += 1
    completion(Admin.Result(ok: true, cancelled: false, message: "192.168.0.0/16"))
}
restricted.refreshIfClean()
settle(restricted)
precondition(protectedReads == 0)
let restrictedControls = descendants(restricted)
let protectedRead = restrictedControls.compactMap { $0 as? NSButton }.first { $0.title == "Read with Administrator Access…" }!
precondition(!protectedRead.isHidden)
protectedRead.performClick(nil)
settle(restricted)
precondition(protectedRead.isHidden)
precondition(protectedReads == 1 && restrictedControls.compactMap { $0 as? NSTableView }.first!.numberOfRows == 1)
Commands.check = realChecker
let exceptionControls = descendants(settings.exceptions)
let list = exceptionControls.compactMap { $0 as? NSTableView }.first!
let buttons = exceptionControls.compactMap { $0 as? NSButton }
let addException = buttons.first { $0.accessibilityLabel() == "Add exception" }!
let removeException = buttons.first { $0.accessibilityLabel() == "Remove selected exceptions" }!
func exceptionButton(_ title: String) -> NSButton {
    exceptionControls.compactMap { $0 as? NSButton }.first { $0.title == title }!
}
precondition(addException.toolTip == "Add exception" && removeException.toolTip == "Remove selected exceptions")
precondition(!addException.isBordered && !removeException.isBordered && !removeException.isEnabled)
let input = exceptionControls.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "New exception" }!
precondition(window.defaultButtonCell === exceptionButton("Apply").cell && !addException.isEnabled)
precondition(buttons.filter { $0.title == "Reload" || $0.title == "Read with Administrator Access…" }.allSatisfy(\.isHidden))
func enterException(_ value: String) {
    window.makeFirstResponder(input)
    let editor = window.firstResponder as! NSTextView
    editor.selectAll(nil)
    editor.insertText(value, replacementRange: editor.selectedRange())
}
precondition(list.numberOfRows == 1 && list.visibleRect.height > 50)
list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
window.makeFirstResponder(list)
content.layoutSubtreeIfNeeded()
let selectedCell = list.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
let selectedLabel = selectedCell.textField!
let labelInTable = selectedLabel.convert(selectedLabel.bounds, to: list)
precondition(selectedLabel.stringValue == "192.168.0.0/16")
precondition(labelInTable.width < list.bounds.width / 2, "The editor should fit the address")
precondition(abs(labelInTable.midY - list.rect(ofRow: 0).midY) <= 1, "Center the address vertically inside its selection")
func clickAddress(_ row: Int) -> NSTextView {
    let rect = list.rect(ofRow: row)
    let location = list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    window.sendEvent(click)
    precondition(list.selectedRow == row)
    return window.firstResponder as! NSTextView
}

func replaceAddress(_ editor: NSTextView, with text: String) {
    editor.selectAll(nil)
    editor.insertText(text, replacementRange: editor.selectedRange())
}

list.deselectAll(nil)
let firstEditor = clickAddress(0)
replaceAddress(firstEditor, with: "10.*")
content.layoutSubtreeIfNeeded()
let shortWidth = selectedLabel.bounds.width
replaceAddress(firstEditor, with: "255.255.255.255/32")
content.layoutSubtreeIfNeeded()
precondition(selectedLabel.bounds.width > shortWidth + 40 && selectedLabel.bounds.width < list.bounds.width / 2)
replaceAddress(firstEditor, with: "203.0.113.999")
firstEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
settle()
precondition(window.firstResponder === firstEditor)
firstEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
precondition(selectedLabel.stringValue == "192.168.0.0/16" && !exceptionButton("Apply").isEnabled)

let secondEditor = clickAddress(0)
replaceAddress(secondEditor, with: "10.12.*")
secondEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
settle()
precondition(selectedLabel.stringValue == "10.12.0.0/16" && window.firstResponder === list)
precondition(exceptionList == "192.168.0.0/16" && exceptionButton("Apply").isEnabled)
let restoredEditor = clickAddress(0)
replaceAddress(restoredEditor, with: "192.168.*")
restoredEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
settle()
enterException("192.168.*")
let entryLabel = exceptionControls.compactMap { $0 as? NSTextField }.first { $0.stringValue == "New exception" }!
precondition(!entryLabel.isHiddenOrHasHiddenAncestor)
addException.performClick(nil)
settle()
precondition(list.numberOfRows == 1)
enterException("1.2.3.999")
addException.performClick(nil)
settle()
precondition(list.numberOfRows == 1)
enterException("198.51.100.15")
addException.performClick(nil)
settle()
precondition(list.numberOfRows == 2 && input.stringValue.isEmpty)
removeException.performClick(nil)
precondition(list.numberOfRows == 1)
enterException("203.0.113.8")
(window.firstResponder as! NSTextView).doCommand(by: #selector(NSResponder.insertNewline(_:)))
settle()
precondition(list.numberOfRows == 2 && input.stringValue.isEmpty && !addException.isEnabled)
selectPane(2)
precondition(window.defaultButtonCell == nil)
settings.present(tab: .exceptions)
settle()
precondition(list.numberOfRows == 2 && window.defaultButtonCell === exceptionButton("Apply").cell)
list.deselectAll(nil)
precondition(!removeException.isEnabled)
list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
removeException.performClick(nil)
var edits = 0
settings.exceptions.onApply = { previous, next in
    precondition(previous == "192.168.0.0/16" && next == "203.0.113.8/32")
    edits += 1
    if edits == 2 { exceptionList = next }
    settings.exceptions.finish(Admin.Result(ok: edits == 2, cancelled: edits == 1, message: ""))
}
exceptionButton("Apply").performClick(nil)
settle()
precondition(edits == 1 && exceptionButton("Apply").isEnabled)
exceptionButton("Apply").performClick(nil)
settle()
precondition(edits == 2 && !exceptionButton("Apply").isEnabled)
list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
removeException.performClick(nil)
precondition(list.numberOfRows == 0 && exceptionButton("Apply").isEnabled)
settings.exceptions.onApply = { previous, next in
    precondition(previous == exceptionList && next.isEmpty)
    settings.exceptions.finish(Admin.Result(ok: false, cancelled: false, message: "Exceptions changed elsewhere. Click Reload."))
}
exceptionButton("Apply").performClick(nil)
settle()
precondition(list.numberOfRows == 0 && exceptionButton("Apply").isEnabled)
precondition(!exceptionButton("Reload").isHidden)
settings.exceptions.onApply = { _, _ in
    settings.exceptions.finish(Admin.Result(ok: false, cancelled: true, message: ""))
}
exceptionButton("Apply").performClick(nil)
settle()
precondition(!exceptionButton("Reload").isHidden, "Canceling a retry should preserve recovery from the previous conflict.")
settings.exceptions.onApply = { _, _ in
    settings.exceptions.finish(Admin.Result(ok: false, cancelled: false, message: "Another firewall operation is in progress."))
}
exceptionButton("Apply").performClick(nil)
settle()
precondition(!exceptionButton("Reload").isHidden, "An unrelated failure should preserve recovery from the previous conflict.")
exceptionButton("Reload").performClick(nil)
settle()
precondition(list.numberOfRows == 1 && !exceptionButton("Apply").isEnabled)
let scroll = list.enclosingScrollView!
let scrollBounds = alignmentFrame(scroll)
let inputBounds = alignmentFrame(input)
let footer = input.superview!
let footerBounds = alignmentFrame(footer)
let plusFrame = alignmentFrame(addException)
let minusFrame = alignmentFrame(removeException)
precondition(!input.isBezeled && !input.isBordered && scroll.borderType == .noBorder)
precondition(abs(footerBounds.maxY + 1 - scrollBounds.minY) <= 1 && abs(footerBounds.minX - scrollBounds.minX) <= 1)
let rowField = (list.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!
let rowFieldBounds = alignmentFrame(rowField)
precondition(abs(rowFieldBounds.minX - alignmentFrame(entryLabel).minX) <= 1 && abs(rowFieldBounds.height - inputBounds.height) <= 1)
precondition(abs(plusFrame.midY - inputBounds.midY) <= 1 && abs(minusFrame.height - list.rect(ofRow: 0).height) <= 1)
precondition(abs(plusFrame.minX - inputBounds.maxX - 5) <= 1 && abs(minusFrame.minX - plusFrame.maxX - 1) <= 1)
precondition(abs(minusFrame.maxX - scrollBounds.maxX) <= 1)
let applyBounds = exceptionButton("Apply").convert(exceptionButton("Apply").bounds, to: content)
precondition(abs(applyBounds.maxX - scrollBounds.maxX) <= 6)
precondition(applyBounds.maxY < footerBounds.minY)
precondition(applyBounds.width >= exceptionButton("Apply").intrinsicContentSize.width - 1 && content.bounds.contains(applyBounds))
// Apply a replacement directly from its editor. Invalid and duplicate drafts
// must never reach the privileged save callback.
var replacements = 0
settings.exceptions.onApply = { previous, next in
    precondition(previous == "203.0.113.8/32" && next == "10.0.0.0/8")
    replacements += 1
    exceptionList = next
    settings.exceptions.finish(Admin.Result(ok: true, cancelled: false, message: ""))
}
enterException("192.168.*")
addException.performClick(nil)
settle()
let duplicateEditor = clickAddress(0)
replaceAddress(duplicateEditor, with: "192.168.*")
exceptionButton("Apply").performClick(nil)
settle()
precondition(replacements == 0 && list.numberOfRows == 2)
replaceAddress(window.firstResponder as! NSTextView, with: "invalid")
exceptionButton("Apply").performClick(nil)
settle()
precondition(replacements == 0)
let validEditor = window.firstResponder as! NSTextView
replaceAddress(validEditor, with: "203.0.113.8")
validEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
settle()
list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
removeException.performClick(nil)
precondition(list.numberOfRows == 1)
let applyEditor = clickAddress(0)
replaceAddress(applyEditor, with: "10.*")
exceptionButton("Apply").performClick(nil)
settle()
precondition(replacements == 1 && !exceptionButton("Apply").isEnabled)

// Asynchronous validation. A gate holds the injected checker so the test can
// change the input while a check is in flight, then release it.
final class Gate {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var threads: [Bool] = []
    var checkedOffMain: Bool { lock.lock(); defer { lock.unlock() }; return !threads.isEmpty && !threads.contains(true) }
    func record() { lock.lock(); threads.append(Thread.isMainThread); lock.unlock() }
}
let gate = Gate()
var gated = false
let asyncView = ExceptionsView(read: { "10.0.0.0/8" }, validate: { raw in
    gate.record()
    if gated { precondition(gate.semaphore.wait(timeout: .now() + 10) == .success) }
    if raw == "reject" { throw CocoaError(.fileReadUnknown) }
    return raw.hasSuffix(".*") ? raw.dropLast(2) + ".0.0/16" : raw + "/32"
})
let asyncHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
asyncHost.contentView = asyncView
asyncHost.makeKeyAndOrderFront(nil)
asyncView.refreshIfClean()
precondition(asyncView.isChecking, "The initial read should run in the background.")
settle(asyncView)
let asyncControls = descendants(asyncView)
let asyncList = asyncControls.compactMap { $0 as? NSTableView }.first!
let asyncAdd = asyncControls.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Add exception" }!
let asyncApply = asyncControls.compactMap { $0 as? NSButton }.first { $0.title == "Apply" }!
let asyncInput = asyncControls.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "New exception" }!
let asyncFeedback = asyncControls.compactMap { $0 as? NSTextField }.first { $0.stringValue == "" && $0.isEditable == false && $0.maximumNumberOfLines == 3 }!
func asyncType(_ value: String) {
    asyncHost.makeFirstResponder(asyncInput)
    let editor = asyncHost.firstResponder as! NSTextView
    editor.selectAll(nil)
    editor.insertText(value, replacementRange: editor.selectedRange())
}
precondition(asyncList.numberOfRows == 1)

// Add: the control stays disabled while the check runs, and the row appears afterwards.
gated = true
asyncType("192.168.*")
asyncAdd.performClick(nil)
precondition(asyncView.isChecking && !asyncAdd.isEnabled && !asyncApply.isEnabled && !asyncInput.isEnabled)
precondition(asyncList.numberOfRows == 1, "Nothing is added before the check answers.")
gate.semaphore.signal()
settle(asyncView)
precondition(asyncList.numberOfRows == 2 && asyncInput.stringValue.isEmpty && asyncApply.isEnabled)
precondition(gate.checkedOffMain, "The checker must not run on the main thread.")

// Reject: an invalid answer leaves the draft in place and reports the error.
asyncType("reject")
asyncAdd.performClick(nil)
gate.semaphore.signal()
settle(asyncView)
precondition(asyncList.numberOfRows == 2 && asyncInput.stringValue == "reject")
precondition(asyncFeedback.stringValue.hasPrefix("Enter an IPv4 address"))

// Stale add: the input changed while the check ran, so the old result is ignored.
asyncType("172.16.1.1")
asyncAdd.performClick(nil)
precondition(asyncView.isChecking)
asyncInput.stringValue = "172.16.1.2"
gate.semaphore.signal()
settle(asyncView)
precondition(asyncList.numberOfRows == 2 && asyncInput.stringValue == "172.16.1.2",
             "A stale result must not replace newer input.")
asyncInput.stringValue = ""

// Edit: leaving a row editor validates in the background and normalizes the row.
func asyncEditor(_ row: Int) -> NSTextView {
    let field = (asyncList.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView).textField!
    asyncHost.makeFirstResponder(field)
    // Leaving the previous editor starts a check. Editing resumes when it ends.
    settle(asyncView)
    asyncHost.makeFirstResponder(field)
    return asyncHost.firstResponder as! NSTextView
}
let editRow = asyncEditor(0)
editRow.selectAll(nil)
editRow.insertText("10.1.*", replacementRange: editRow.selectedRange())
editRow.doCommand(by: #selector(NSResponder.insertNewline(_:)))
precondition(asyncView.isChecking)
gate.semaphore.signal()
settle(asyncView)
precondition((asyncList.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!.stringValue == "10.1.0.0/16")

// Stale edit: typing again while the check runs keeps the newer text.
let staleRow = asyncEditor(0)
staleRow.selectAll(nil)
staleRow.insertText("10.2.*", replacementRange: staleRow.selectedRange())
staleRow.doCommand(by: #selector(NSResponder.insertNewline(_:)))
precondition(asyncView.isChecking)
staleRow.selectAll(nil)
staleRow.insertText("10.3.3.3", replacementRange: staleRow.selectedRange())
gate.semaphore.signal()
settle(asyncView)
precondition((asyncList.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!.stringValue == "10.3.3.3",
             "A stale edit result must not overwrite the newer text.")
gated = false

// Rejected edit: the draft stays editable and Apply never reaches the callback.
var asyncApplied = 0
asyncView.onApply = { _, _ in asyncApplied += 1 }
let badRow = asyncEditor(0)
badRow.selectAll(nil)
badRow.insertText("reject", replacementRange: badRow.selectedRange())
asyncApply.performClick(nil)
settle(asyncView)
precondition(asyncApplied == 0 && !asyncView.isChecking)
precondition(asyncFeedback.stringValue.hasPrefix("Enter an IPv4 address"))
asyncHost.close()

let riskyExceptions = ExceptionsView(read: { "192.168.0.0/16" })
let riskyHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
riskyHost.contentView = riskyExceptions
riskyHost.makeKeyAndOrderFront(nil)
riskyExceptions.refreshIfClean()
settle(riskyExceptions)
let riskyInput = descendants(riskyExceptions).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "New exception" }!
var riskySaves = 0
riskyExceptions.onApply = { _, next in
    precondition(next == "192.168.0.0/16\n0.0.0.0/0")
    riskySaves += 1
    riskyExceptions.finish(Admin.Result(ok: true, cancelled: false, message: ""))
}
riskyHost.makeFirstResponder(riskyInput)
let riskyEditor = riskyHost.firstResponder as! NSTextView
riskyEditor.insertText("0.0.0.0/0", replacementRange: riskyEditor.selectedRange())
func answerRiskWarning(_ title: String) {
    let deadline = Date().addingTimeInterval(3)
    while riskyHost.attachedSheet == nil && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let sheet = riskyHost.attachedSheet else { preconditionFailure("Applying all IPv4 should show a warning sheet.") }
    precondition(riskySaves == 0, "The save should wait for confirmation.")
    let button = descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
    button.performClick(nil)
    while riskyHost.attachedSheet != nil && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    precondition(riskyHost.attachedSheet == nil)
}
riskyExceptions.apply.performClick(nil)
settle(riskyExceptions)
answerRiskWarning("Cancel")
precondition(riskySaves == 0 && riskyExceptions.apply.isEnabled)
riskyExceptions.apply.performClick(nil)
settle(riskyExceptions)
answerRiskWarning("Allow All IPv4")
precondition(riskySaves == 1 && !riskyExceptions.apply.isEnabled)
riskyHost.close()

func captureWindow(_ window: NSWindow, named name: String) throws {
    let frame = window.contentView!.superview!
    frame.layoutSubtreeIfNeeded()
    window.display()
    let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
    frame.cacheDisplay(in: frame.bounds, to: bitmap)
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
}

if CommandLine.arguments.count >= 2 {
    for (index, name) in ["server", "exceptions"].enumerated() {
        selectPane(index)
        if name == "exceptions" {
            window.makeFirstResponder(list)
            settle()
            exceptionList = ""
            settings.exceptions.refreshIfClean()
            settle()
            precondition(list.numberOfRows == 0, "The empty screenshot must show the empty list.")
            try captureWindow(window, named: "exceptions-empty")
            exceptionList = "192.168.0.0/16"
            settings.exceptions.refreshIfClean()
            settle()
            window.makeKeyAndOrderFront(nil)
            let editor = clickAddress(0)
            editor.selectAll(nil)
        }
        try captureWindow(window, named: name)
    }
    selectPane(2)
}
let selectedPaneBeforeAbout = toolbar.selectedItemIdentifier
let knownWindows = app.windows
AboutPanel.present()
let about = app.windows.first { candidate in
    candidate.isVisible && !knownWindows.contains { $0 === candidate }
}!
let aboutText = descendants(about.contentView!).compactMap { $0 as? NSTextView }
precondition(aboutText.contains { view in
    guard let text = view.textStorage else { return false }
    let location = (text.string as NSString).range(of: "Open Guide").location
    guard location != NSNotFound else { return false }
    return (text.attribute(.link, at: location, effectiveRange: nil) as? URL)?.absoluteString
        == "https://github.com/ivan1911/vpn-kill-switch#readme"
}, "About should expose the guide link in its own window.")
precondition(window.isVisible && toolbar.selectedItemIdentifier == selectedPaneBeforeAbout)
if CommandLine.arguments.count >= 2 {
    try captureWindow(about, named: "about")
}
about.close()
window.close()
print("Passed first setup, legacy migration, per-client drafts, removal and relaunch, external endpoint changes, validation, cancellation and retry, window reuse, toolbar panes, and busy state.")
