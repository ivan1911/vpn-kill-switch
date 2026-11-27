// Run in a graphical session. The confirmation returns a decision without requesting rights.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
app.activate(ignoringOtherApps: true)

func answer(_ confirmation: GuardConfirmation, with respond: @escaping (NSAlert) -> Void) -> Bool {
    let alert = confirmation.alert
    let input = Timer(timeInterval: 0.1, repeats: false) { _ in respond(alert) }
    let timeout = Timer(timeInterval: 2, repeats: false) { _ in
        preconditionFailure("The alert did not respond to the test input.")
    }
    for timer in [input, timeout] {
        RunLoop.current.add(timer, forMode: .modalPanel)
    }
    defer { timeout.invalidate() }
    return confirmation.runModal()
}

func press(_ characters: String, keyCode: UInt16, in confirmation: GuardConfirmation) -> Bool {
    answer(confirmation) { alert in
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: alert.window.windowNumber, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: keyCode)!
        app.postEvent(event, atStart: true)
    }
}

func click(_ title: String, in confirmation: GuardConfirmation) -> Bool {
    answer(confirmation) { alert in
        alert.buttons.first { $0.title == title }!.performClick(nil)
    }
}

func installation() -> GuardConfirmation {
    GuardConfirmation(.install, clientName: "Shadowrocket")
}

func removal() -> GuardConfirmation {
    GuardConfirmation(.remove, clientName: nil)
}

precondition(!press("\r", keyCode: 36, in: removal()), "Return must cancel removal.")
precondition(!press("\u{1B}", keyCode: 53, in: removal()), "Escape must cancel removal.")
precondition(press("\r", keyCode: 36, in: installation()), "Return must confirm installation.")
precondition(!press("\u{1B}", keyCode: 53, in: installation()), "Escape must cancel installation.")
precondition(!click("Cancel", in: removal()), "Clicking Cancel must cancel removal.")
precondition(!click("Cancel", in: installation()), "Clicking Cancel must cancel installation.")
precondition(click("Remove Kill Switch", in: removal()), "Only explicit confirmation may proceed with removal.")
precondition(click("Install Kill Switch", in: installation()), "Clicking Install must confirm installation.")

let installAlert = installation().alert
let removeAlert = removal().alert
precondition(removeAlert.buttons.first { $0.title == "Remove Kill Switch" }!.hasDestructiveAction)
precondition(!installAlert.buttons.contains { $0.hasDestructiveAction })
precondition(installAlert.messageText == "Install Kill Switch?")
precondition(installAlert.informativeText == "Connect Shadowrocket first. Protection blocks internet access outside the VPN, even after a restart.")
precondition(removeAlert.messageText == "Remove Kill Switch?")
precondition(removeAlert.informativeText == "Removing the service and its rules lets this Mac go online without the VPN. Your VPN settings are kept for the next install.")

print("Install and remove confirmation tests passed")
