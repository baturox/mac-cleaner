// The real-machine side of the Apps feature: Spotlight, the process list and code-signing entitlements.
// All of it is read through in-process APIs (no `mdls`, `ps` or `codesign` child per app) and none of it needs
// AppKit. The engine reaches it only through `EngineEnvironment`, so tests replace it.
import CoreServices
import Foundation
import Security

/// What Spotlight says about when a bundle was last opened.
enum LastUsedLookup: Sendable, Equatable {
    case date(Date)
    /// Spotlight knows the bundle and has no launch record for it.
    case never
    /// Spotlight has no entry for it (not indexed, or indexing is off): nothing can be said.
    case unknown
}

enum SystemApps {
    static func lastUsed(_ path: String) -> LastUsedLookup {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return .unknown }
        if let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { return .date(date) }
        // An indexed bundle always has a content type; without a launch date it was never opened (as far as
        // macOS recorded). A bundle Spotlight never indexed has neither, which is "unknown", not "never".
        if MDItemCopyAttribute(item, kMDItemContentType) != nil { return .never }
        return .unknown
    }

    /// Paths of the executables of every process this user can see.
    static func runningExecutables() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard got > 0 else { return [] }
        var out: [String] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if n > 0 { out.append(String(cString: buffer)) }
        }
        return out
    }

    /// `com.apple.security.application-groups` of the bundle's code signature (read, not verified).
    static func applicationGroups(_ path: String) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return [] }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }
}
