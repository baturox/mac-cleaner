// Xcode (DerivedData, simulator runtimes and devices), personal data (iOS backups, archives) and Docker.
import Foundation

// MARK: - Xcode

enum XcodeScanner {
    /// "MyApp-bqkpfnwlbgvbkshgztbpfdcnjzel" -> "MyApp".
    static func derivedDataLabel(_ name: String) -> String {
        if let r = name.range(of: #"-[a-z]{28}$"#, options: .regularExpression) { return String(name[name.startIndex..<r.lowerBound]) }
        return name
    }

    struct Runtime: Equatable {
        var identifier: String
        var label: String
        var path: String
        var bytes: Int64
        var lastUsed: Date?
    }

    /// Parses `xcrun simctl runtime list -j`: a dictionary keyed by runtime identifier. Only deletable runtimes.
    static func parseRuntimes(_ data: Data) -> [Runtime] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let platforms = ["iphonesimulator": "iOS", "watchsimulator": "watchOS", "appletvsimulator": "tvOS",
                         "xrsimulator": "visionOS", "iphoneos": "iOS", "xros": "visionOS"]
        let iso = ISO8601DateFormatter()
        var out: [Runtime] = []
        for (key, value) in obj {
            guard let d = value as? [String: Any], (d["deletable"] as? Bool) != false else { continue }
            let id = (d["identifier"] as? String) ?? key
            let version = d["version"] as? String ?? ""
            let platformKey = ((d["platformIdentifier"] as? String) ?? "").components(separatedBy: ".").last ?? ""
            var platform = platforms[platformKey]
            if platform == nil, let rid = d["runtimeIdentifier"] as? String,
               let part = rid.components(separatedBy: "SimRuntime.").last?.components(separatedBy: "-").first, !part.isEmpty {
                platform = part == "xrOS" ? "visionOS" : part
            }
            let bytes: Int64
            if let n = d["sizeBytes"] as? NSNumber { bytes = n.int64Value } else { bytes = 0 }
            out.append(Runtime(identifier: id, label: "\(platform ?? "Simulator") \(version) Simulator".replacingOccurrences(of: "  ", with: " "),
                               path: (d["path"] as? String) ?? (d["runtimeBundlePath"] as? String) ?? "",
                               bytes: bytes, lastUsed: (d["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }))
        }
        // Distinguish same-named runtimes by build.
        let counts = Dictionary(out.map { ($0.label, 1) }, uniquingKeysWith: +)
        if counts.values.contains(where: { $0 > 1 }), let builds = obj as? [String: [String: Any]] {
            for i in out.indices where counts[out[i].label, default: 0] > 1 {
                if let b = builds[out[i].identifier]?["build"] as? String { out[i].label += " (\(b))" }
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    struct Device: Equatable { var udid: String; var path: String; var label: String; var state: Int }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-4" -> "iOS 18.4".
    static func runtimeName(_ id: String) -> String {
        guard let tail = id.components(separatedBy: "SimRuntime.").last, tail != id else { return id }
        let parts = tail.split(separator: "-").map(String.init)
        guard let platform = parts.first else { return tail }
        return ([platform == "xrOS" ? "visionOS" : platform] + [parts.dropFirst().joined(separator: ".")]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func simulatorDevices(devicesDir: String) -> [Device] {
        var out: [Device] = []
        for e in readDir(devicesDir) ?? [] where e.isDir && !e.isLink {
            let dir = devicesDir + "/" + e.name
            guard let data = FileManager.default.contents(atPath: dir + "/device.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let name = plist["name"] as? String ?? e.name
            let runtime = (plist["runtime"] as? String).map(runtimeName)
            let state = (plist["state"] as? Int) ?? 0
            out.append(Device(udid: (plist["UDID"] as? String) ?? e.name, path: dir,
                              label: runtime.map { "\(name) — \($0)" } ?? name, state: state))
        }
        return out
    }

    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        ctx.progress("Measuring Xcode data…")
        let derivedDir = ctx.home + "/Library/Developer/Xcode/DerivedData"
        let derived = (readDir(derivedDir) ?? []).filter { $0.isDir && !$0.isLink }.map { derivedDir + "/" + $0.name }
        let labels = Dictionary(derived.map { ($0, derivedDataLabel(($0 as NSString).lastPathComponent)) }, uniquingKeysWith: { a, _ in a })
        async let derivedItems = ctx.items(derived, labels: labels)
        async let runtimes = runtimeCategory(ctx)
        async let devices = deviceCategory(ctx)
        var out: [CleanCategory] = []
        if let c = ctx.category(id: "xcode-derived", name: "Xcode DerivedData", detail: "Build products per project; the next build of that project is a full rebuild",
                                level: .safe, symbol: "hammer", group: .xcode, items: await derivedItems, selectable: true) { out.append(c) }
        if let c = await runtimes { out.append(c) }
        if let c = await devices { out.append(c) }
        return out
    }

    private static func runtimeCategory(_ ctx: ScanContext) async -> CleanCategory? {
        guard ToolPaths.which("xcrun") != nil else { return nil }
        let r = await runCommand(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 30)
        guard r.ok else { return nil }
        let items = parseRuntimes(Data(r.stdout.utf8)).filter { $0.bytes > 0 }.map {
            CleanItem(url: URL(fileURLWithPath: $0.path), sizeBytes: $0.bytes, label: $0.label, lastUsed: $0.lastUsed,
                      deleteCommand: ["xcrun", "simctl", "runtime", "delete", $0.identifier])
        }
        return ctx.category(id: "xcode-sim-runtimes", name: "Simulator runtimes",
                            detail: "iOS, watchOS, tvOS and visionOS simulators; download them again in Xcode settings",
                            level: .caution, symbol: "ipad.and.iphone", group: .xcode, items: items, selectable: true)
    }

    private static func deviceCategory(_ ctx: ScanContext) async -> CleanCategory? {
        guard ToolPaths.which("xcrun") != nil else { return nil }
        let dir = ctx.home + "/Library/Developer/CoreSimulator/Devices"
        let devices = await onBackground { simulatorDevices(devicesDir: dir) }.filter { $0.state == 1 && ctx.visible($0.path) }
        let sizes = await ctx.sizes(devices.map(\.path))
        let items = devices.compactMap { d -> CleanItem? in
            guard let size = sizes[d.path], size > 0 else { return nil }
            return CleanItem(url: URL(fileURLWithPath: d.path), sizeBytes: size, label: d.label,
                             lastUsed: modificationDate(d.path), deleteCommand: ["xcrun", "simctl", "delete", d.udid])
        }.sorted { $0.sizeBytes > $1.sizeBytes }
        return ctx.category(id: "xcode-sim-devices", name: "Simulator devices",
                            detail: "Apps and data inside each simulator device; booted devices are never listed",
                            level: .caution, symbol: "iphone", group: .xcode, items: items, selectable: true)
    }
}

// MARK: - Personal data

enum PersonalScanner {
    private static func plist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    struct Described { var path: String; var label: String; var date: Date? }

    /// One entry per backup folder: "Device name — last backup date".
    static func iosBackups(dir: String) -> [Described] {
        (readDir(dir) ?? []).filter { $0.isDir && !$0.isLink }.map { e in
            let p = dir + "/" + e.name
            let info = plist(p + "/Info.plist")
            let name = info?["Device Name"] as? String
            let date = info?["Last Backup Date"] as? Date
            var label = name ?? "Backup \(e.name.prefix(8))"
            if let date { label += " — " + dateText(date) }
            return Described(path: p, label: label, date: date ?? modificationDate(p))
        }
    }

    /// One entry per .xcarchive (they sit in per-day folders): "App 1.2.3 (45) — date".
    static func xcodeArchives(dir: String) -> [Described] {
        var out: [Described] = []
        for day in readDir(dir) ?? [] where day.isDir && !day.isLink {
            for a in readDir(dir + "/" + day.name) ?? [] where a.isDir && !a.isLink && a.name.hasSuffix(".xcarchive") {
                let p = dir + "/" + day.name + "/" + a.name
                let info = plist(p + "/Info.plist")
                let props = info?["ApplicationProperties"] as? [String: Any]
                let name = (info?["Name"] as? String) ?? (a.name as NSString).deletingPathExtension
                let version = props?["CFBundleShortVersionString"] as? String
                let build = props?["CFBundleVersion"] as? String
                var label = name
                if let version { label += " " + version }
                if let build { label += " (\(build))" }
                let date = (info?["CreationDate"] as? Date) ?? modificationDate(p)
                if let date { label += " — " + dateText(date) }
                out.append(Described(path: p, label: label, date: date))
            }
        }
        return out
    }

    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        ctx.progress("Measuring backups and archives…")
        let backupsDir = ctx.home + "/Library/Application Support/MobileSync/Backup"
        let archivesDir = ctx.home + "/Library/Developer/Xcode/Archives"
        let (backups, archives) = await onBackground { (iosBackups(dir: backupsDir), xcodeArchives(dir: archivesDir)) }
        @Sendable func items(_ list: [Described]) async -> [CleanItem] {
            await ctx.items(list.map(\.path), labels: Dictionary(list.map { ($0.path, $0.label) }, uniquingKeysWith: { a, _ in a }),
                            dates: Dictionary(list.compactMap { d in d.date.map { (d.path, $0) } }, uniquingKeysWith: { a, _ in a }))
        }
        async let b = items(backups)
        async let a = items(archives)
        return [
            ctx.category(id: "ios-backups", name: "iPhone/iPad local backups", detail: "Your only copy if you do not back up to iCloud",
                         level: .caution, symbol: "iphone.gen3", group: .personal, items: await b, selectable: true),
            ctx.category(id: "xcode-archives", name: "Xcode archives", detail: "Needed to symbolicate crashes of builds you shipped",
                         level: .caution, symbol: "archivebox", group: .personal, items: await a, selectable: true),
        ].compactMap { $0 }
    }
}

// MARK: - Docker

enum ContainerScanner {
    /// Docker prints decimal sizes: "1.2GB", "512MB", "16.38kB", "0B", optionally followed by "(45%)".
    static func parseDockerSize(_ text: String) -> Int64 {
        let head = text.split(separator: " ").first.map(String.init) ?? text
        let number = head.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return 0 }
        let unit = head.dropFirst(number.count).lowercased()
        let mult: Double = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15][unit] ?? 1
        return Int64(value * mult)
    }

    struct Row: Equatable { var type: String; var reclaimable: Int64; var total: Int64 }

    /// Parses `docker system df --format '{{json .}}'` (one JSON object per line).
    static func parseDf(_ output: String) -> [Row] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["Type"] as? String else { return nil }
            return Row(type: type, reclaimable: parseDockerSize((obj["Reclaimable"] as? String) ?? ""),
                       total: parseDockerSize((obj["Size"] as? String) ?? ""))
        }
    }

    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        guard ToolPaths.which("docker") != nil else { return [] }
        ctx.progress("Asking Docker what is reclaimable…")
        let r = await runCommand(["docker", "system", "df", "--format", "{{json .}}"], timeout: 25)
        guard r.ok else { return [] }
        var out: [CleanCategory] = []
        for row in parseDf(r.stdout) where row.reclaimable >= oneMB {
            let spec: (id: String, name: String, detail: String, level: SafetyLevel, cmd: [String], upper: Bool)?
            switch row.type {
            case "Images":
                spec = ("docker-images", "Docker unused images", "Images no container uses; pulled or rebuilt when needed. Shared layers may free less",
                        .caution, ["docker", "image", "prune", "-af"], true)
            case "Build Cache":
                spec = ("docker-build-cache", "Docker build cache", "Layer cache of image builds; the next build is slower once",
                        .safe, ["docker", "builder", "prune", "-af"], false)
            case "Containers":
                spec = ("docker-containers", "Docker stopped containers", "Stopped containers and anything written inside them",
                        .caution, ["docker", "container", "prune", "-f"], false)
            case "Local Volumes":
                spec = ("docker-volumes", "Docker unused volumes", "Volumes no container uses; databases and uploads live here, so this deletes data",
                        .caution, ["docker", "volume", "prune", "-af"], false)
            default: spec = nil
            }
            guard let s = spec else { continue }
            out.append(CleanCategory(id: s.id, name: s.name, detail: s.detail, level: s.level, symbol: "shippingbox.circle",
                                     items: [], commands: [s.cmd], sizeBytes: row.reclaimable, sizeIsUpperBound: s.upper,
                                     group: .containers, itemsSelectable: false))
        }
        return out
    }
}
