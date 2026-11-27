import Foundation

func varint(_ value: Int) -> [UInt8] {
    var n = value
    var result: [UInt8] = []
    while n >= 128 {
        result.append(UInt8(n & 127) | 128)
        n >>= 7
    }
    return result + [UInt8(n)]
}

func field(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
    [tag] + varint(bytes.count) + bytes
}
func entry(_ code: String, _ ip: [UInt8], _ prefix: UInt8, inverse: Bool = false) -> [UInt8] {
    let cidr = field(10, ip) + [16, prefix]
    return field(10, field(18, cidr) + field(10, Array(code.utf8)) + [24, inverse ? 1 : 0])
}

var bytes = entry("DE", [192,0,2,0], 24)
bytes += entry("CLOUDFLARE", [192,0,2,0], 24)
bytes += entry("US", [192,0,2,8], 32)
bytes += entry("CA", [192,0,2,8], 32)
bytes += entry("GB", [192,0,2,4], 32, inverse: true)
bytes += entry("FR", [198,51,100,0], 24)
bytes += entry("US", Array(repeating: 0, count: 16), 64)
let raw = Data(bytes)
let db = try GeoIPDatabase(raw)
precondition(db.country(for: "192.0.2.4") == "DE" && GeoIPDatabase.flag("DE") == "🇩🇪")
precondition(db.country(for: "192.0.2.8") == nil)
precondition(db.country(for: "203.0.113.1") == nil && db.country(for: "Blocked") == nil)
for bad in [Data(), Data("garbage".utf8), raw.dropLast(), Data(entry("PRIVATE", [0,0,0,0], 0)),
            Data(entry("DE", [1,2,3,4], 33)), Data([10] + Array(repeating: 255, count: 12))] {
    precondition((try? GeoIPDatabase(bad)) == nil)
}

func wait(_ ready: () -> Bool) {
    let end = Date().addingTimeInterval(10)
    while !ready() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.015)) }
    precondition(ready())
}
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temp) }
let store = GeoIPStore(directory: temp)
let url = "https://example.org/database.dat"
store.update(from: url) { _ in raw }
wait { !store.downloading }
precondition(store.byteCount == raw.count && store.source == url && store.updated != nil)
let date = store.updated
store.update(from: "https://example.org/bad.dat") { _ in Data([255]) }
wait { !store.downloading }
precondition(!store.message.isEmpty && store.updated == date && store.source == url)
let reloaded = GeoIPStore(directory: temp)
wait { reloaded.database != nil }
precondition(reloaded.source == url && reloaded.updated == date && reloaded.byteCount == raw.count)
let new = Data(entry("US", [192,0,2,0], 24))
store.update(from: url) { _ in new }
wait { !store.downloading }
precondition(store.byteCount == new.count && store.database?.country(for: "192.0.2.5") == "US")
if CommandLine.arguments.count == 2 {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let real = try GeoIPDatabase(data)
    let known = real.country(for: "8.8.8.8")
    precondition(known != nil)
    print("Reference database:", data.count, "bytes. 8.8.8.8:", known!)
}
print("Country ranges, invalid inputs, conflicting matches, flags, persistence and update rollback passed.")
