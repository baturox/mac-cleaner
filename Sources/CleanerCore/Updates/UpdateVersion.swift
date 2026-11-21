// Semantic version parsing and comparison for the updater.
//
// Strict on purpose: the version text comes from the network, so anything that is not plainly
// `MAJOR.MINOR.PATCH[-prerelease][+build]` (an optional leading "v" is allowed) is rejected instead of guessed at.
import Foundation

public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public enum Identifier: Hashable, Sendable {
        case number(Int)
        case text(String)
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [Identifier]

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public init(major: Int, minor: Int, patch: Int, prerelease: [Identifier] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    /// nil for anything that is not a well-formed version. Build metadata (`+abc`) is accepted and ignored.
    public init?(_ raw: String) {
        guard raw.utf8.count <= 64 else { return nil }
        var text = Substring(raw)
        if text.hasPrefix("v") { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") {
            let build = text[text.index(after: plus)...]
            guard Self.validIdentifiers(build) else { return nil }
            text = text[..<plus]
        }
        var pre: Substring?
        if let dash = text.firstIndex(of: "-") {
            pre = text[text.index(after: dash)...]
            text = text[..<dash]
        }
        let core = text.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.number(core[0]), let minor = Self.number(core[1]), let patch = Self.number(core[2])
        else { return nil }
        var identifiers: [Identifier] = []
        if let pre {
            guard !pre.isEmpty else { return nil }
            for part in pre.split(separator: ".", omittingEmptySubsequences: false) {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
                if part.allSatisfy(\.isNumber) {
                    guard let n = Self.number(part) else { return nil }
                    identifiers.append(.number(n))
                } else {
                    identifiers.append(.text(String(part)))
                }
            }
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: identifiers)
    }

    /// ASCII digits only, no leading zeros, at most nine digits (so it can never overflow).
    private static func number(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= 9, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if s.count > 1 && s.first == "0" { return nil }
        return Int(s)
    }

    private static func validIdentifiers(_ s: Substring) -> Bool {
        guard !s.isEmpty else { return false }
        return s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            s += "-" + prerelease.map { id -> String in
                switch id {
                case .number(let n): return String(n)
                case .text(let t): return t
                }
            }.joined(separator: ".")
        }
        return s
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A release is newer than any of its prereleases.
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (x, y) {
            case (.number(let m), .number(let n)): return m < n
            case (.number, .text): return true
            case (.text, .number): return false
            case (.text(let s), .text(let t)): return s < t
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    /// True only when `candidate` is strictly newer than `current`: no downgrade, no reinstall of the same version.
    public static func isUpgrade(from current: SemanticVersion, to candidate: SemanticVersion) -> Bool {
        candidate > current
    }
}
