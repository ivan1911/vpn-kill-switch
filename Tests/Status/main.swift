import Foundation
// Snapshots are the checker's `--porcelain` output behind its exit code.
func snapshot(_ code: Int, _ lines: String...) -> String { ([String(code)] + lines).joined(separator: "\n") }
let active = snapshot(0, "protection=on", "tunnel=utun4", "client=shadowrocket", "client-name=Shadowrocket", "vpn=Connected", "vpn-interface=utun4")
let disconnected = snapshot(0, "protection=on", "tunnel=none", "client=shadowrocket", "client-name=Shadowrocket", "vpn=Disconnected")
let directDisconnected = snapshot(0, "protection=on", "direct=192.168.0.0/16", "tunnel=none", "client=shadowrocket", "client-name=Shadowrocket", "vpn=Disconnected")
precondition(GuardStatus(snapshot: disconnected).title == "Internet blocked")
precondition(GuardStatus(snapshot: directDisconnected).title == "Direct exceptions only")
precondition(GuardStatus(snapshot: active).title == "Protection on")
let waiting = GuardStatus(snapshot: directDisconnected + "\ndirect-waiting=yes")
precondition(waiting.state == .blocked && waiting.title == "Direct exceptions only")
let unreachable = GuardStatus(snapshot: snapshot(2, "protection=on", "direct=192.168.0.0/16", "tunnel=none", "client=shadowrocket", "client-name=Shadowrocket", "vpn=Disconnected", "problem=direct-routes"))
precondition(unreachable.state == .attention && unreachable.title == "Check direct routes")
let invalid = GuardStatus(snapshot: snapshot(2, "protection=on", "tunnel=none", "client=shadowrocket", "client-name=Shadowrocket", "vpn=Disconnected", "problem=invalid-direct"))
precondition(invalid.state == .attention && invalid.title == "Check direct config")
let off = snapshot(1, "protection=off", "tunnel=unrestricted", "client=shadowrocket", "client-name=Shadowrocket", "vpn=Connected", "vpn-interface=utun4")
let mismatch = snapshot(2, "protection=on", "tunnel=utun5", "client=shadowrocket", "client-name=Shadowrocket", "vpn=Connected", "vpn-interface=utun4", "problem=tunnel")
let mismatchStatus = GuardStatus(snapshot: mismatch)
precondition(mismatchStatus.state == .attention && mismatchStatus.title == "Check allowed tunnel")
precondition(GuardStatus(snapshot: off).title == "Protection off" && GuardStatus(snapshot: off).vpn == "Connected (utun4)")
let unknownCases = [snapshot(2, "protection=unknown"), snapshot(2, "protection=on"), "2\nerror", ""]
for (snapshot, state) in [(active, GuardState.active), (disconnected, .blocked), (off, .inactive), (mismatch, .attention)]
    + unknownCases.map({ ($0, GuardState.unknown) }) {
    precondition(GuardStatus(snapshot: snapshot).state == state)
}
// Human sentences are not part of the contract: a prose-only snapshot reads as unknown.
let prose = "0\nProtection: on.\nAllowed tunnel: utun4\nShadowrocket: Connected (utun4)"
precondition(GuardStatus(snapshot: prose).state == .unknown && GuardStatus(snapshot: prose).vpn == nil)
// Only a line that is exactly `key=value` counts; extra monitor lines and prose around the keys are ignored.
let noisy = active + "\nProtection: off (pf disabled).\nxprotection=off\nvpn-event=A:Shadowrocket:Connected\nsample-start=1\n"
precondition(GuardStatus(snapshot: noisy).state == .active && GuardStatus(snapshot: noisy).vpn == "Connected (utun4)")
// An unknown problem key still needs attention and defaults to the tunnel reason.
precondition(GuardStatus(snapshot: snapshot(2, "protection=on", "tunnel=none", "problem=other")).title == "Check allowed tunnel")
precondition(GuardStatus(snapshot: active).tunnel == "utun4")
precondition(GuardStatus(snapshot: disconnected).vpn == "Disconnected")
let happActive = snapshot(0, "protection=on", "tunnel=utun9", "client=happ-plus", "client-name=Happ Plus", "vpn=Connected", "vpn-interface=utun9")
let happLocked = snapshot(0, "protection=on", "tunnel=none", "client=happ-plus", "client-name=Happ Plus", "vpn=Disconnected")
precondition(GuardStatus(snapshot: happActive).vpn == "Connected (utun9)", "Decode the Happ Plus status line")
precondition(GuardStatus(snapshot: happLocked).vpn == "Disconnected")
precondition(GuardStatus(snapshot: happActive).belongs(to: "Happ Plus"))
precondition(!GuardStatus(snapshot: happActive).belongs(to: "Shadowrocket"))
precondition(!GuardStatus(snapshot: active).belongs(to: "Happ Plus"))
precondition(GuardStatus(snapshot: snapshot(1, "protection=off", "tunnel=unrestricted")).belongs(to: nil))
precondition(GuardStatus(snapshot: off).belongs(to: "Shadowrocket") && !GuardStatus(snapshot: off).belongs(to: "Happ Plus"))
let protectionMenuTitles = [
    (GuardStatus(snapshot: active), "Protection: On"),
    (GuardStatus(snapshot: disconnected), "Protection: Internet blocked"),
    (GuardStatus(snapshot: directDisconnected), "Protection: Direct exceptions only"),
    (GuardStatus(snapshot: off), "Protection: Off"),
    (mismatchStatus, "Protection: Check tunnel"),
    (unreachable, "Protection: Check direct routes"),
    (invalid, "Protection: Check direct config"),
    (GuardStatus.unread, "Protection: Status unknown")
]
for (status, expected) in protectionMenuTitles {
    precondition(status.protectionMenuTitle(isBusy: false) == expected)
    precondition(status.protectionMenuTitle(isBusy: true) == "Protection: Working…")
}
let menuCases: [(String, KillSwitchAction?)] = [
    (active, .remove), (disconnected, .remove), (mismatch, .remove),
    (off, .install), (snapshot(1, "protection=off", "tunnel=unrestricted"), .install), ("2\nerror", nil)
]
for (snapshot, expected) in menuCases {
    precondition(GuardStatus(snapshot: snapshot).state.menuAction == expected)
}
precondition(KillSwitchAction.install.rawValue == "Install Kill Switch" && KillSwitchAction.remove.rawValue == "Remove Kill Switch")
print("Status and menu action cases passed")
if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    precondition((attributes[.ownerAccountID] as? NSNumber)?.intValue == 0)
    let live = GuardStatus(snapshot: try String(contentsOf: url, encoding: .utf8))
    precondition(live.state == .active && live.tunnel != nil && live.vpn != nil)
    print(live.title, live.tunnel!, live.vpn!)
}

let change = Date(timeIntervalSince1970: 100.5)
precondition(!GuardStatus.sampleIsCurrent(active, after: change))
precondition(!GuardStatus.sampleIsCurrent(active + "\nsample-start=100\n", after: change))
precondition(GuardStatus.sampleIsCurrent(off + "\nsample-start=101\n", after: change))
