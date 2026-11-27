import AppKit

struct GuardConfirmation {
    let alert = NSAlert()
    private let acceptedResponse: NSApplication.ModalResponse

    init(_ action: KillSwitchAction, clientName: String?) {
        alert.messageText = action.rawValue + "?"
        if action == .install, let clientName {
            alert.informativeText = "Connect \(clientName) first. Protection blocks internet access outside the VPN, even after a restart."
        } else {
            alert.informativeText = "Removing the service and its rules lets this Mac go online without the VPN. Your VPN settings are kept for the next install."
        }
        switch action {
        case .install:
            alert.addButton(withTitle: action.rawValue)
            alert.addButton(withTitle: "Cancel")
            acceptedResponse = .alertFirstButtonReturn
        case .remove:
            let cancel = alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: action.rawValue).hasDestructiveAction = true
            cancel.keyEquivalent = "\r"
            acceptedResponse = .alertSecondButtonReturn
        }
    }

    func runModal() -> Bool {
        guard acceptedResponse == .alertSecondButtonReturn else {
            return alert.runModal() == acceptedResponse
        }

        // Cancel already uses Return here. Keep Escape available for dismissal.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.charactersIgnoringModifiers == "\u{1B}",
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            alert.buttons[0].performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal() == acceptedResponse
    }
}
