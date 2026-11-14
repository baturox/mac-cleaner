// The documented JSON output of every read command.
//
// Every document has `schemaVersion` (currently 1). Fields are only ever added within a schema
// version. Dates are ISO 8601 (UTC). Paths inside the engine's contract types (`CleanItem.url`,
// `ProjectArtifact.url`, …) are encoded as `file://` URLs, exactly as `URL` is Codable.
import CleanerCore
import Foundation

let jsonSchemaVersion = 1

/// `DiskInfo` plus its derived numbers, so consumers do not have to compute them.
struct DiskReport: Codable, Equatable {
    var totalBytes: Int64
    var usedBytes: Int64
    /// Really free right now (what `df` reports).
    var freeBytes: Int64
    /// Free + purgeable: what Finder calls "available".
    var availableWithPurgeableBytes: Int64
    var purgeableBytes: Int64

    init(_ d: DiskInfo) {
        totalBytes = d.totalBytes
        usedBytes = d.usedBytes
        freeBytes = d.freeBytes
        availableWithPurgeableBytes = d.availableWithPurgeableBytes
        purgeableBytes = d.purgeableBytes
    }
}

/// `mac-cleaner scan --json`
struct ScanReport: Codable {
    var schemaVersion = jsonSchemaVersion
    var generatedAt: Date
    var disk: DiskReport
    /// Contract type `CleanCategory`; `group` is the `CategoryGroup` raw value.
    var categories: [CleanCategory]
    /// Sum of categories whose size is exact.
    var exactBytes: Int64
    /// Sum of categories whose size is only an upper bound.
    var upperBoundBytes: Int64
    var safeBytes: Int64
    var cautionBytes: Int64
}

/// `mac-cleaner clean --dry-run --json`
struct CleanPlanReport: Codable {
    var schemaVersion = jsonSchemaVersion
    var dryRun = true
    var mode: DeleteMode
    var selected: [CleanCategory]
    var exactBytes: Int64
    var upperBoundBytes: Int64
}

/// `mac-cleaner projects --json`
struct ProjectsReport: Codable {
    var schemaVersion = jsonSchemaVersion
    var root: String
    var minDaysIdle: Int
    var minBytes: Int64
    var kinds: [String]
    var artifacts: [ProjectArtifact]
    var totalBytes: Int64
}

/// `mac-cleaner repos --json`
struct ReposReport: Codable {
    var schemaVersion = jsonSchemaVersion
    var root: String
    var groups: [RepoGroupReport]
    var totalBytes: Int64
    /// Paths `--remove-clean` would remove.
    var removable: [String]
}

struct RepoGroupReport: Codable {
    var id: String
    var name: String
    var remote: String?
    var totalBytes: Int64
    var clones: [RepoCloneReport]
}

struct RepoCloneReport: Codable {
    /// Contract type `RepoClone`.
    var clone: RepoClone
    var isFullyBackedUp: Bool
    /// False when git was not run in this working copy because its own git configuration could run programs
    /// (see `clone.untrustedConfigKeys`); its counts are then unknown and it is never removable.
    var wasInspected: Bool
    /// Human-readable status, e.g. "clean & pushed" or "3 uncommitted, 1 unpushed".
    var status: String
    /// True when `--remove-clean` would remove this clone.
    var removable: Bool
}

/// `mac-cleaner explore --json`
struct ExploreReport: Codable {
    var schemaVersion = jsonSchemaVersion
    var path: String
    var totalBytes: Int64
    var entries: [FolderEntry]
    /// Entries not shown because of `--top`.
    var omittedCount: Int
}

/// `mac-cleaner growth --json`
struct GrowthOutput: Codable {
    var schemaVersion = jsonSchemaVersion
    var disk: DiskReport
    var report: GrowthReport
}

/// `mac-cleaner doctor --json`
struct DoctorReport: Codable {
    var schemaVersion = jsonSchemaVersion
    var cliVersion: String
    var macOSVersion: String
    var architecture: String
    var disk: DiskReport
    var fullDiskAccess: Bool
    var tools: [DetectedTool]
    var apfsVolumes: [APFSVolume]
    var apfsContainerFreeBytes: Int64?
    var localSnapshots: [LocalSnapshot]
    var swapBytes: Int64?
    var settings: SettingsReport
    /// How to start the MCP server (see the README).
    var mcpCommand: String = "mac-cleaner mcp"
    var recordAuditLog: Bool = true
}

/// What protects the user's own folders in this run.
struct SettingsReport: Codable, Equatable {
    /// The shared settings file (written by the app, read by both).
    var file: String?
    /// "ok", "missing" (defaults apply) or "corrupt" (defaults apply and nothing can be deleted).
    var status: String
    var problem: String?
    /// From the settings file.
    var protectedPaths: [String]
    /// Added with `--protect` for this run.
    var extraProtectedPaths: [String]
    /// Always protected; "~" is the home folder, entries with "*" are patterns.
    var builtInProtectedPaths: [String]
    var sessionRetentionDays: Int
}

struct DetectedTool: Codable, Equatable {
    var name: String
    /// Location with the home folder abbreviated to `~`.
    var path: String
}

struct APFSVolume: Codable, Equatable {
    var name: String
    var roles: [String]
    var bytesInUse: Int64
}

struct LocalSnapshot: Codable, Equatable {
    var name: String
    /// "macOS update" or "Time Machine" (or "other").
    var kind: String
}

enum JSONOutput {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}

extension Context {
    func emit<T: Encodable>(_ value: T) {
        // Not sanitized: JSON escapes control characters itself, and the data must stay exact.
        console.outRaw(JSONOutput.encode(value))
    }
}
