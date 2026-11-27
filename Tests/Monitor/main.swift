import Foundation
enum Commands {
    static let check = try! String(contentsOfFile: "Scripts/check.sh", encoding: .utf8)
}
print(Admin.monitor(snapshot: URL(fileURLWithPath: CommandLine.arguments[1]), pid: Int32(CommandLine.arguments[2])!,
                    lease: URL(fileURLWithPath: CommandLine.arguments[3])))
