// SHA-256 checksum files (`shasum -a 256` format) and streaming verification of a downloaded file.
import CryptoKit
import Foundation

public enum UpdateChecksums {
    /// Parses `<64 hex>  <name>` / `<64 hex> *<name>` lines into name -> lowercase hex. Lines that do not look like
    /// that are ignored. A name listed twice with different hashes is dropped: the file is ambiguous for it.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var ambiguous: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { continue }
            var name = parts[1].drop(while: { $0 == " " })
            if name.hasPrefix("*") { name = name.dropFirst() }
            let key = String(name)
            guard !key.isEmpty, !key.contains("/"), !key.contains("\0") else { continue }
            if let old = result[key], old != hash { ambiguous.insert(key) }
            result[key] = hash
        }
        for key in ambiguous { result[key] = nil }
        return result
    }

    /// SHA-256 of a file, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Throws `.checksumMissing` when the file has no entry for `name`, `.checksumMismatch` when it differs.
    public static func verify(file: URL, name: String, against sums: [String: String]) throws {
        guard let expected = sums[name] else { throw UpdateError.checksumMissing }
        let actual = try sha256(of: file)
        guard constantTimeEqual(actual, expected) else { throw UpdateError.checksumMismatch }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
