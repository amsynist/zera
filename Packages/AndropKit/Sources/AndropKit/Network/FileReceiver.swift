import Foundation
import CryptoKit

/// All persistence happens on the server's serial file queue.
public final class FileReceiver {
    public static let shared = FileReceiver(directory: ProcessInfo.processInfo.environment["ANDROP_INBOX"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    // Compatibility for older base64 clients only. v3 files are streamed to disk without this cap.
    public static let maximumBytes = 8 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    private let directory: URL?
    public init(directory: URL? = nil) { self.directory = directory }
    public var saveDirectory: URL {
        directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Androp", isDirectory: true)
    }

    public func begin(name: String, size: Int64?) throws -> IncomingFile {
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        return try IncomingFile(directory: saveDirectory, name: name, expected: size)
    }

    public func saveFile(name: String, base64Data: String) throws -> URL {
        let raw = base64Data.hasPrefix("data:") ? String(base64Data.split(separator: ",", maxSplits: 1).last ?? "") : base64Data
        guard raw.utf8.count <= (Self.maximumBytes + 2) / 3 * 4,
              let data = Data(base64Encoded: raw), data.count <= Self.maximumBytes else { throw ReceiveError.invalidData }
        let file = try begin(name: name, size: Int64(data.count))
        defer { file.abort() }
        for offset in stride(from: 0, to: data.count, by: Self.chunkBytes) {
            try file.append(data.subdata(in: offset..<min(data.count, offset + Self.chunkBytes)))
        }
        return try file.finish(bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    public final class IncomingFile {
        private let directory: URL
        private let temporary: URL
        private let name: String
        private let expected: Int64?
        private var handle: FileHandle?
        private var digest = SHA256()
        public private(set) var received: Int64 = 0

        fileprivate init(directory: URL, name: String, expected: Int64?) throws {
            guard expected == nil || expected! >= 0 else { throw ReceiveError.invalidData }
            self.directory = directory
            self.expected = expected
            let leaf = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "File"
            let cleaned = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(180))
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            self.name = cleaned.isEmpty ? "File" : cleaned
            temporary = directory.appendingPathComponent(".incoming-" + UUID().uuidString)
            try Self.checkSpace(directory, needed: expected ?? Int64(FileReceiver.chunkBytes))
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ReceiveError.disk }
            do { handle = try FileHandle(forWritingTo: temporary) }
            catch { try? FileManager.default.removeItem(at: temporary); throw error }
        }
        private static func checkSpace(_ directory: URL, needed: Int64) throws {
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),
               available < 64 * 1024 * 1024 || needed > available - 64 * 1024 * 1024 { throw ReceiveError.disk }
        }
        public func append(_ data: Data) throws {
            guard let handle, !data.isEmpty, data.count <= FileReceiver.chunkBytes,
                  received <= Int64.max - Int64(data.count), expected == nil || received + Int64(data.count) <= expected! else { throw ReceiveError.invalidData }
            if received % (8 * 1024 * 1024) < Int64(FileReceiver.chunkBytes) {
                try Self.checkSpace(directory, needed: max(Int64(data.count), (expected ?? received) - received))
            }
            try handle.write(contentsOf: data)
            digest.update(data: data)
            received += Int64(data.count)
        }
        public func finish(bytes: Int64, sha256: String) throws -> URL {
            guard let handle, bytes == received, expected == nil || expected == received,
                  digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else { throw ReceiveError.integrity }
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            let original = directory.appendingPathComponent(name)
            var destination = original
            var suffix = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                let ext = original.pathExtension
                destination = directory.appendingPathComponent("\(original.deletingPathExtension().lastPathComponent) (\(suffix))\(ext.isEmpty ? "" : "." + ext)")
                suffix += 1
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            let quarantine = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Androp;"
            quarantine.withCString { value in _ = setxattr(destination.path, "com.apple.quarantine", value, strlen(value), 0, 0) }
            return destination
        }
        public func abort() { try? handle?.close(); handle = nil; try? FileManager.default.removeItem(at: temporary) }
        deinit { abort() }
    }
}

public enum ReceiveError: LocalizedError {
    case invalidData, disk, integrity
    public var errorDescription: String? {
        switch self {
        case .invalidData: return "Invalid transfer data. Update both Androp apps and try again."
        case .disk: return "Your Mac needs more free disk space to receive this file."
        case .integrity: return "The file was incomplete or failed verification. No partial file was saved."
        }
    }
}
