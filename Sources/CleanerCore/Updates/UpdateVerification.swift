// Verification of the new app, behind protocols so the install logic can be tested without real signatures.
//
//   BundleSignatureVerifying   Security.framework: the code signature of a bundle, all nested code, strict,
//                              against the designated requirement built from the compiled-in Team ID.
//   GatekeeperAssessing        `spctl --assess --type execute`: macOS must accept the bundle AND report it as
//                              notarized Developer ID.
//   BundleIdentity             after the signature is known good, the bundle id and version in its Info.plist.
import Foundation
import Security

public protocol BundleSignatureVerifying: Sendable {
    /// Throws `UpdateError.signatureInvalid` unless the bundle at `url` is intact and satisfies the requirement.
    func verifyBundle(at url: URL) throws
    /// The same requirement for the code that is running right now. Dev, ad-hoc and unsigned builds fail.
    func verifyRunningApp() throws
}

public protocol GatekeeperAssessing: Sendable {
    func assess(bundle: URL) async throws
}

public struct SecurityBundleVerifier: BundleSignatureVerifying {
    public let requirementText: String
    public init(requirementText: String) { self.requirementText = requirementText }
    public init(config: UpdateConfiguration) { self.requirementText = config.requirementText }

    static let validityFlags: UInt32 = kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        | kSecCSRestrictSymlinks

    private func requirement() throws -> SecRequirement {
        var req: SecRequirement?
        let status = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(rawValue: 0), &req)
        guard status == errSecSuccess, let req else { throw UpdateError.signatureInvalid("the requirement could not be built (\(status))") }
        return req
    }

    private func describe(_ status: OSStatus, _ errors: Unmanaged<CFError>?) -> String {
        if let e = errors?.takeRetainedValue() { return (CFErrorCopyDescription(e) as String?) ?? "status \(status)" }
        return (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }

    public func verifyBundle(at url: URL) throws {
        let requirement = try requirement()
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code)
        guard created == errSecSuccess, let code else { throw UpdateError.signatureInvalid(describe(created, nil)) }
        // Every architecture slice, every nested code item (the bundled command line tool), strict resource rules,
        // and no symbolic link that points outside the bundle (like `codesign --verify --strict`; strict validation
        // alone accepts a sealed link to, say, /tmp).
        let flags = SecCSFlags(rawValue: Self.validityFlags)
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &errors)
        guard status == errSecSuccess else { throw UpdateError.signatureInvalid(describe(status, errors)) }
    }

    public func verifyRunningApp() throws {
        let requirement = try requirement()
        var me: SecCode?
        let created = SecCodeCopySelf(SecCSFlags(rawValue: 0), &me)
        guard created == errSecSuccess, let me else { throw UpdateError.devBuild }
        var errors: Unmanaged<CFError>?
        let status = SecCodeCheckValidityWithErrors(me, SecCSFlags(rawValue: 0), requirement, &errors)
        guard status == errSecSuccess else { throw UpdateError.devBuild }
    }
}

public struct SpctlGatekeeper: GatekeeperAssessing {
    public init() {}

    /// spctl prints `source=Notarized Developer ID` for an app with a valid notarization ticket.
    public static func accepts(status: Int32, output: String) -> Bool {
        status == 0 && output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "source=Notarized Developer ID" }
    }

    public func assess(bundle: URL) async throws {
        let r = await runProcess("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", bundle.path], timeout: 90)
        guard r.launched else { throw UpdateError.gatekeeperRejected("spctl could not be started") }
        guard Self.accepts(status: r.status, output: r.stdout + "\n" + r.stderr) else {
            throw UpdateError.gatekeeperRejected(r.timedOut ? "the check timed out" : (r.lastLine.isEmpty ? "rejected" : r.lastLine))
        }
    }
}

public enum BundleIdentity {
    /// Reads the Info.plist of a bundle that has already passed the signature check and compares id and version.
    public static func check(bundle: URL, bundleID: String, version: SemanticVersion) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = object as? [String: Any] else {
            throw UpdateError.unexpectedArchive("no readable Info.plist")
        }
        let id = (info["CFBundleIdentifier"] as? String) ?? ""
        guard id == bundleID else { throw UpdateError.wrongBundleID(expected: bundleID, found: id) }
        let found = (info["CFBundleShortVersionString"] as? String) ?? ""
        guard let parsed = SemanticVersion(found), parsed == version else {
            throw UpdateError.wrongVersion(expected: version.description, found: found)
        }
    }
}
