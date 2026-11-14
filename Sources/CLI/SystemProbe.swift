// Read-only questions about the machine, used by `doctor`. Behind a protocol so tests can fake it.
import CleanerCore
import Foundation

protocol SystemProbe: Sendable {
    func osVersion() -> String
    func architecture() -> String
    func detectedTools(home: URL) -> [DetectedTool]
    func apfsLayout() -> (volumes: [APFSVolume], containerFreeBytes: Int64?)?
    func localSnapshots() -> [LocalSnapshot]?
    func swapBytes() -> Int64?
}

/// Optional tools whose caches or data the cleanup categories know about.
let optionalToolNames = [
    "brew", "npm", "pnpm", "yarn", "bun", "node", "nvm", "cargo", "rustup", "go", "python3", "pip3", "uv", "conda",
    "gem", "pod", "gradle", "docker", "ollama", "git", "gh", "xcodebuild", "xcrun", "simctl", "claude", "codex", "gemini",
]

struct LiveProbe: SystemProbe {
    func osVersion() -> String { ProcessInfo.processInfo.operatingSystemVersionString }

    func architecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    /// The tools as the ENGINE would find them: its own search order and trust checks, not this shell's
    /// PATH. A tool that is installed but missing here was rejected (see SECURITY.md, "Helper programs").
    func detectedTools(home: URL) -> [DetectedTool] {
        optionalToolNames.compactMap { name in
            ToolLocator.path(for: name).map { DetectedTool(name: name, path: abbreviateHome($0, home: home)) }
        }
    }

    func apfsLayout() -> (volumes: [APFSVolume], containerFreeBytes: Int64?)? {
        guard let data = runProcess(["/usr/sbin/diskutil", "apfs", "list", "-plist"], timeout: 30) else { return nil }
        return Self.parseAPFS(data)
    }

    func localSnapshots() -> [LocalSnapshot]? {
        guard let data = runProcess(["/usr/bin/tmutil", "listlocalsnapshots", "/"], timeout: 15),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseSnapshots(text)
    }

    func swapBytes() -> Int64? {
        let dir = "/private/var/vm"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var total: Int64 = 0
        for n in names {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/" + n),
               let size = attrs[.size] as? NSNumber { total += size.int64Value }
        }
        return total
    }

    // MARK: Parsers (static so tests can feed them samples)

    /// The container that holds the System volume; volumes largest first.
    static func parseAPFS(_ data: Data) -> (volumes: [APFSVolume], containerFreeBytes: Int64?)? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        for c in containers {
            let vols = c["Volumes"] as? [[String: Any]] ?? []
            let hasSystem = vols.contains { ($0["Roles"] as? [String] ?? []).contains("System") }
            guard hasSystem else { continue }
            let parsed = vols.map { v in
                APFSVolume(name: v["Name"] as? String ?? "?", roles: v["Roles"] as? [String] ?? [],
                           bytesInUse: (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
            }.sorted { $0.bytesInUse > $1.bytesInUse }
            return (parsed, (c["CapacityFree"] as? NSNumber)?.int64Value)
        }
        return nil
    }

    static func parseSnapshots(_ text: String) -> [LocalSnapshot] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.") }
            .map { name in
                let kind = name.contains("os.update") ? "macOS update"
                    : (name.contains("TimeMachine") || name.contains("timemachine") ? "Time Machine" : "other")
                return LocalSnapshot(name: name, kind: kind)
            }
    }
}

/// Runs a program and returns its stdout, or nil if it cannot run or exceeds `timeout` seconds.
func runProcess(_ argv: [String], timeout: TimeInterval) -> Data? {
    guard let exe = argv.first, FileManager.default.isExecutableFile(atPath: exe) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = Array(argv.dropFirst())
    // A fixed, minimal environment: nothing from this process reaches the helper.
    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": AccountEnvironment.home, "LANG": "C", "LC_ALL": "C"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return p.terminationStatus == 0 ? data : nil
}
