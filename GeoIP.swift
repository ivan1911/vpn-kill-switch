import Darwin
import Foundation

private enum GeoIPError: LocalizedError {
    case invalidData, downloadFailed, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidData: return "Choose a V2Ray geoip.dat with IPv4 country ranges."
        case .downloadFailed: return "Download failed. Check the URL and your connection."
        case .tooLarge: return "The database exceeds the 64 MB size limit."
        }
    }
}

// Walk a protobuf message within its byte boundaries, skipping unknown fields.
private struct ProtoReader {
    let bytes: UnsafeRawBufferPointer
    var offset: Int
    let end: Int

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < end else { throw GeoIPError.invalidData }
            let byte = bytes[offset]
            offset += 1
            guard shift < 63 || byte <= 1 else { throw GeoIPError.invalidData }
            value |= UInt64(byte & 127) << shift
            if byte < 128 { return value }
        }
        throw GeoIPError.invalidData
    }

    mutating func fields(_ visit: (UInt64, Range<Int>, UInt64) throws -> Void) throws {
        while offset < end {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 0x1fffffff else { throw GeoIPError.invalidData }
            let length: UInt64
            var number: UInt64 = 0
            switch tag & 7 {
            case 0: number = try varint(); length = 0
            case 1: length = 8
            case 2: length = try varint()
            case 5: length = 4
            default: throw GeoIPError.invalidData
            }
            guard length <= UInt64(end - offset) else { throw GeoIPError.invalidData }
            let start = offset
            offset += Int(length)
            try visit(tag, start..<offset, number)
        }
    }
}

struct GeoIPDatabase {
    static let sizeLimit = 64 * 1024 * 1024
    // One table per prefix length. An empty code denotes conflicting country records.
    private var prefixes = Array(repeating: [UInt32: String](), count: 33)

    init(_ data: Data) throws {
        guard data.count <= Self.sizeLimit else { throw GeoIPError.tooLarge }
        // Foundation also lists the EU, Eurozone, UN and Outlying Oceania.
        let regions = Set(Locale.Region.isoRegions.map(\.identifier)).subtracting(["EU", "EZ", "UN", "QO"])
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func reader(_ range: Range<Int>) -> ProtoReader {
                ProtoReader(bytes: bytes, offset: range.lowerBound, end: range.upperBound)
            }
            var list = reader(0..<bytes.count)
            try list.fields { tag, entry, _ in
                guard tag == 10 else { return }
                // country_code and inverse_match may follow the repeated CIDRs.
                var record = reader(entry)
                var code = ""
                var inverse = false
                try record.fields { tag, payload, value in
                    if tag == 10 && payload.count <= 64 {
                        code = String(decoding: bytes[payload], as: UTF8.self).uppercased()
                    }
                    if tag == 24 { inverse = value != 0 }
                }
                guard !inverse, code.utf8.count == 2, regions.contains(code),
                      code.utf8.allSatisfy({ (65...90).contains($0) }) else { return }
                record = reader(entry)
                try record.fields { tag, cidr, _ in
                    guard tag == 18 else { return }
                    var block = reader(cidr)
                    var ip = 0..<0
                    var bits: UInt64 = 0
                    try block.fields { tag, payload, value in
                        if tag == 10 { ip = payload }
                        if tag == 16 { bits = value }
                    }
                    guard (ip.count == 4 || ip.count == 16), bits <= ip.count * 8 else {
                        throw GeoIPError.invalidData
                    }
                    guard ip.count == 4 else { return }
                    let address = bytes[ip].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    let prefix = Int(bits)
                    let key = address >> (32 - prefix)
                    let old = prefixes[prefix][key]
                    prefixes[prefix][key] = old == nil || old == code ? code : ""
                }
            }
        }
        guard prefixes.contains(where: { !$0.isEmpty }) else { throw GeoIPError.invalidData }
    }

    func country(for address: String) -> String? {
        var parsed = in_addr()
        guard !address.utf8.contains(0), inet_pton(AF_INET, address, &parsed) == 1 else { return nil }
        let ip = UInt32(bigEndian: parsed.s_addr)
        for prefix in (0...32).reversed() {
            if let code = prefixes[prefix][ip >> (32 - prefix)] { return code.isEmpty ? nil : code }
        }
        return nil
    }

    static func flag(_ code: String) -> String {
        String(code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(Character.init))
    }
}

final class GeoIPStore {
    static let defaultSource = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    private struct DownloadInfo: Codable {
        let source: String
        let updated: Date
    }

    private let package: URL
    private let queue = DispatchQueue(label: "vpn-ks.geoip", qos: .utility)
    private(set) var database: GeoIPDatabase?
    private(set) var byteCount = 0
    private var info: DownloadInfo?
    var updated: Date? { info?.updated }
    private(set) var downloading = false
    private(set) var message = ""
    var onChange: (() -> Void)?
    var source: String { info?.source ?? Self.defaultSource }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.ivan1911.vpn-kill-switch")) {
        package = directory.appendingPathComponent("GeoIP", isDirectory: true)
        queue.async { [self] in
            let file = package.appendingPathComponent("geoip.dat")
            guard FileManager.default.fileExists(atPath: package.path) else { return }
            do {
                let attr = try file.resourceValues(forKeys: [.fileSizeKey])
                guard (attr.fileSize ?? 0) <= GeoIPDatabase.sizeLimit else { throw GeoIPError.tooLarge }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let size = data.count
                let db = try GeoIPDatabase(data)
                let metadata = try Data(contentsOf: package.appendingPathComponent("download.json"))
                let info = try JSONDecoder().decode(DownloadInfo.self, from: metadata)
                DispatchQueue.main.async {
                    self.database = db
                    self.byteCount = size
                    self.info = info
                    self.onChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.message = "Could not read the saved database. Download it again."
                    self.onChange?()
                }
            }
        }
    }

    func update(from input: String, fetch: @escaping (URL) throws -> Data = GeoIPStore.fetch) {
        guard !downloading else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            message = "Enter an HTTPS database URL."
            onChange?()
            return
        }
        downloading = true
        message = "Downloading…"
        onChange?()
        queue.async { [self] in
            do {
                let data = try fetch(url)
                let db = try GeoIPDatabase(data)
                let size = data.count
                let info = DownloadInfo(source: text, updated: Date())
                let files = FileWrapper(directoryWithFileWrappers: [
                    "geoip.dat": FileWrapper(regularFileWithContents: data),
                    "download.json": FileWrapper(regularFileWithContents: try JSONEncoder().encode(info))
                ])
                try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Commit the database and the source displayed in Settings together.
                try files.write(to: package, options: .atomic, originalContentsURL: nil)
                DispatchQueue.main.async {
                    self.database = db
                    self.byteCount = size
                    self.info = info
                    self.finish("")
                }
            } catch {
                DispatchQueue.main.async { self.finish(error.localizedDescription) }
            }
        }
    }

    private func finish(_ message: String) {
        downloading = false
        self.message = message
        onChange?()
    }

    static func fetch(_ url: URL) throws -> Data {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-q", "--fail", "--silent", "--location", "--proto", "=https", "--proto-redir", "=https",
                          "--connect-timeout", "10", "--max-time", "120", "--max-filesize", String(GeoIPDatabase.sizeLimit),
                          "--url", url.absoluteString]
        task.standardOutput = pipe
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        defer {
            pipe.fileHandleForReading.closeFile()
            if task.isRunning { task.terminate() }
            task.waitUntilExit()
        }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard chunk.count <= GeoIPDatabase.sizeLimit - data.count else { throw GeoIPError.tooLarge }
            data.append(chunk)
        }
        task.waitUntilExit()
        if task.terminationStatus == 63 { throw GeoIPError.tooLarge }
        guard task.terminationStatus == 0 else { throw GeoIPError.downloadFailed }
        return data
    }
}
