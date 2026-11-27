import AppKit

final class StatusMenuFeedback {
    private let pasteboard: NSPasteboard
    private var confirmation: NSPanel?
    private var dismissTimer: Timer?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    static func setActionTitle(_ title: String, reason: String?, on item: NSMenuItem) {
        let explanation = reason.map { title + " " + $0 }
        if #available(macOS 14.4, *) {
            item.title = title
            item.subtitle = reason
        } else {
            item.title = explanation ?? title
            item.toolTip = reason
        }
        item.setAccessibilityLabel(explanation)
    }

    func copyAddress(from item: NSMenuItem, anchor: NSStatusBarButton?) {
        guard item.isEnabled, !item.isHidden, let address = item.representedObject as? String else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(address, forType: .string) else { return }

        // AppKit closes the menu after choosing a native item.
        if let anchor, let window = anchor.window {
            showConfirmation(below: window.convertToScreen(anchor.convert(anchor.bounds, to: nil)))
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "IPv4 address copied.",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func showConfirmation(below anchor: NSRect) {
        dismissTimer?.invalidate()
        confirmation?.orderOut(nil)

        let label = NSTextField(labelWithString: "Copied")
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 12, y: 7))
        let size = NSSize(width: label.frame.width + 24, height: label.frame.height + 14)
        let rect = NSRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 4,
                          width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView?.addSubview(label)
        panel.orderFrontRegardless()
        confirmation = panel

        let timer = Timer(timeInterval: 2, repeats: false) { [weak self, weak panel] _ in
            panel?.orderOut(nil)
            self?.confirmation = nil
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

final class ProtectionMenuDiagnostics {
    private let rows: [NSMenuItem]
    private let modifierFlags: () -> NSEvent.ModifierFlags
    private var timer: Timer?

    init(rows: [NSMenuItem], modifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }) {
        self.rows = rows
        self.modifierFlags = modifierFlags
        rows.forEach { $0.isHidden = true }
    }

    func prepareForOpen() {
        updateVisibility()
    }

    func startTracking() {
        timer?.invalidate()
        // AppKit consumes modifier events during menu tracking. Read the key state in that run-loop mode.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateVisibility()
        }
        timer.fireDate = Date()
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stopTracking() {
        timer?.invalidate()
        timer = nil
        rows.forEach { $0.isHidden = true }
    }

    private func updateVisibility() {
        let hide = !modifierFlags().contains(.option)
        for row in rows where row.isHidden != hide { row.isHidden = hide }
    }

    deinit { timer?.invalidate() }
}
