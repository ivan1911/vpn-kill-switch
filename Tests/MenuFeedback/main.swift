import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let reason = "Install Shadowrocket in Applications and connect it first."
let action = NSMenuItem()
StatusMenuFeedback.setActionTitle("Shadowrocket required…", reason: reason, on: action)
if #available(macOS 14.4, *) {
    precondition(action.subtitle == reason)
} else {
    precondition(action.title.contains(reason))
}
precondition(action.accessibilityLabel() == "Shadowrocket required… " + reason)
StatusMenuFeedback.setActionTitle("Install Kill Switch…", reason: nil, on: action)
if #available(macOS 14.4, *) { precondition(action.subtitle == nil) }
precondition(action.title == "Install Kill Switch…")
precondition(action.accessibilityLabel() == nil)

let protection = NSMenu()
let ordinary = NSMenuItem(title: "External IPv4", action: nil, keyEquivalent: "")
let tunnel = NSMenuItem(title: "Allowed tunnel: utun4", action: nil, keyEquivalent: "")
let timestamp = NSMenuItem(title: "Checked at 13:20", action: nil, keyEquivalent: "")
[ordinary, tunnel, timestamp].forEach(protection.addItem)
var modifiers: NSEvent.ModifierFlags = []
let diagnostics = ProtectionMenuDiagnostics(rows: [tunnel, timestamp], modifierFlags: { modifiers })
func checkVisibleRows(_ expected: [String]) {
    let visible = protection.items.filter { !$0.isHidden }.map(\.title)
    precondition(visible == expected, "Expected \(expected), saw \(visible)")
}
func runTrackingLoop(for duration: TimeInterval = 0.2) {
    let end = Date(timeIntervalSinceNow: duration)
    while Date() < end {
        if !RunLoop.current.run(mode: .eventTracking, before: end) { break }
    }
}
checkVisibleRows(["External IPv4"])
modifiers = [.option, .shift]
diagnostics.prepareForOpen()
diagnostics.startTracking()
checkVisibleRows(["External IPv4", "Allowed tunnel: utun4", "Checked at 13:20"])
modifiers = []
runTrackingLoop()
checkVisibleRows(["External IPv4"])
modifiers = [.option]
runTrackingLoop()
checkVisibleRows(["External IPv4", "Allowed tunnel: utun4", "Checked at 13:20"])
diagnostics.stopTracking()
runTrackingLoop()
checkVisibleRows(["External IPv4"])

let anchor = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
anchor.button?.title = "Test"
let pasteboard = NSPasteboard.withUniqueName()
let feedback = StatusMenuFeedback(pasteboard: pasteboard)
let ip = NSMenuItem(title: "External IPv4: 192.0.2.5", action: nil, keyEquivalent: "")
ip.representedObject = "192.0.2.5"
ip.isEnabled = true
feedback.copyAddress(from: ip, anchor: anchor.button!)
precondition(pasteboard.string(forType: .string) == "192.0.2.5")
let confirmation = app.windows.first { $0.isVisible && ($0.contentView?.subviews.first as? NSTextField)?.stringValue == "Copied" }
precondition(confirmation != nil, "Copy confirmation should appear without a menu open")
let expiry = Date(timeIntervalSinceNow: 3)
while confirmation?.isVisible == true && Date() < expiry {
    if !RunLoop.current.run(mode: .eventTracking, before: expiry) { break }
}
precondition(confirmation?.isVisible == false, "Copy confirmation should dismiss during menu tracking")
pasteboard.releaseGlobally()
print("Missing-client reason, accessibility label, Option diagnostics, clipboard and confirmation passed.")
