import Foundation
import CleanerCore

/// Fake engine with realistic data and delays. Never touches the file system.
final class MockEngine: CleanerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var removedPaths = Set<String>()
    private var removedCategories = Set<String>()
    private var freedSoFar: Int64 = 0
    private let home = Fmt.homePath
    private let GB: Int64 = 1_000_000_000
    private let MB: Int64 = 1_000_000

    func diskInfo() -> DiskInfo {
        let free = 2 * GB + lock.withLock { freedSoFar }
        return DiskInfo(totalBytes: 460 * GB, freeBytes: free, availableWithPurgeableBytes: free + 6 * GB)
    }

    private func url(_ rel: String) -> URL { URL(fileURLWithPath: home + "/" + rel) }

    /// Splits `total` over `names` with a decaying distribution.
    private func spread(_ names: [String], base: String, total: Int64) -> [CleanItem] {
        let weights = names.indices.map { pow(0.82, Double($0)) }
        let sum = weights.reduce(0, +)
        return names.enumerated().map { i, n in
            CleanItem(url: url("\(base)/\(n)"), sizeBytes: Int64(Double(total) * weights[i] / sum))
        }
    }

    private func categories() -> [CleanCategory] {
        let cacheNames = ["com.spotify.client", "com.google.Chrome", "com.apple.Safari", "Homebrew", "com.microsoft.VSCode",
                          "Yarn", "com.figma.Desktop", "com.apple.dt.Xcode", "pip", "go-build", "com.docker.docker",
                          "org.swift.swiftpm", "com.slack.Slack", "JetBrains", "CocoaPods", "com.tinyspeck.slackmacgap",
                          "com.apple.python", "node-gyp", "ms-playwright", "SentryCrash"]
            + (1...20).map { "com.vendor.app\($0)" }
        let c: [CleanCategory] = [
            CleanCategory(id: "user-caches", name: "User caches", detail: "App caches in ~/Library/Caches — apps rebuild them as needed",
                          level: .safe, symbol: "internaldrive", items: spread(cacheNames, base: "Library/Caches", total: 19_300_000_000),
                          commands: [], sizeBytes: 19_300_000_000),
            CleanCategory(id: "dot-cache", name: "~/.cache", detail: "Tool caches (uv, pip, puppeteer, huggingface hub index) — re-downloaded on demand",
                          level: .safe, symbol: "folder.badge.gearshape",
                          items: spread(["uv", "puppeteer", "pip", "node-gyp", "prisma", "turbo", "whisper", "torch"], base: ".cache", total: 9_400_000_000),
                          commands: [], sizeBytes: 9_400_000_000),
            CleanCategory(id: "npm", name: "npm cache", detail: "Downloaded packages; npm fetches them again when needed",
                          level: .safe, symbol: "shippingbox", items: [CleanItem(url: url(".npm/_cacache"), sizeBytes: 5_400_000_000)],
                          commands: [], sizeBytes: 5_400_000_000),
            CleanCategory(id: "xcode-device-support", name: "Xcode device support", detail: "Symbols for iOS versions you connected; re-created on next connect",
                          level: .safe, symbol: "iphone",
                          items: spread(["17.5 (21F79) arm64e", "17.2 (21C62) arm64e", "16.4 (20E247) arm64e"], base: "Library/Developer/Xcode/iOS DeviceSupport", total: 4_500_000_000),
                          commands: [], sizeBytes: 4_500_000_000),
            CleanCategory(id: "app-caches", name: "App caches", detail: "Slack, Discord, Teams and browser caches inside Application Support",
                          level: .safe, symbol: "app.dashed",
                          items: spread(["Slack/Cache", "discord/Cache", "Code/CachedData", "Google/Chrome/Default/Service Worker"], base: "Library/Application Support", total: 2_800_000_000),
                          commands: [], sizeBytes: 2_800_000_000),
            CleanCategory(id: "hf", name: "Hugging Face models", detail: "Downloaded model weights; large to fetch again",
                          level: .caution, symbol: "brain",
                          items: spread(["models--meta-llama--Llama-3.2-3B", "models--openai--whisper-large-v3", "models--BAAI--bge-m3", "datasets--squad"], base: ".cache/huggingface/hub", total: 4_600_000_000),
                          commands: [], sizeBytes: 4_600_000_000),
            CleanCategory(id: "trash", name: "Trash", detail: "Items you already deleted; emptying is permanent",
                          level: .caution, symbol: "trash",
                          items: spread(["old-project.zip", "Screenshot folder", "export.mov"], base: ".Trash", total: 1_100_000_000),
                          commands: [], sizeBytes: 1_100_000_000),
            CleanCategory(id: "pnpm", name: "pnpm store", detail: "Shared package store; `pnpm store prune` removes unreferenced packages only",
                          level: .safe, symbol: "shippingbox.fill", items: [], commands: [["pnpm", "store", "prune"]],
                          sizeBytes: 3_500_000_000, sizeIsUpperBound: true),
            CleanCategory(id: "brew", name: "Homebrew old versions", detail: "Outdated formula versions and downloads",
                          level: .safe, symbol: "mug", items: [], commands: [["brew", "cleanup", "-s"]], sizeBytes: 0),
        ]
        return c
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    func scanCategories(progress: @escaping ProgressHandler) async -> [CleanCategory] {
        let all = categories()
        for c in all {
            progress("Measuring \(c.name)…")
            await sleep(0.5)
        }
        let removed = lock.withLock { removedCategories }
        return all.filter { !removed.contains($0.id) }
    }

    private func projectList() -> [ProjectArtifact] {
        var out: [ProjectArtifact] = []
        func add(_ proj: String, _ kind: String, _ mb: Int64, _ idle: Int) {
            let p = URL(fileURLWithPath: home + "/" + proj)
            out.append(ProjectArtifact(url: p.appendingPathComponent(kind), kind: kind, projectURL: p, sizeBytes: mb * MB, idleDays: idle))
        }
        add("Developer/rust-gateway", "target", 33_800, 0)
        let sizes: [Int64] = [2_400, 2_100, 1_900, 1_800, 1_700, 1_600, 1_500, 1_400, 1_350, 1_300, 1_250, 1_200]
        for (i, s) in sizes.enumerated() {
            add("Developer/acme/storefront-feat\(1040 + i * 7)", "node_modules", s, i < 4 ? 0 : (i < 8 ? 1 : 2))
        }
        add("Developer/acme/storefront-feat1040", ".next", 1_500, 0)
        add("Developer/acme/storefront-feat1047", ".next", 640, 0)
        add("Desktop/Personal/old-shop", "node_modules", 1_050, 36)
        add("Desktop/Personal/blog", "node_modules", 720, 58)
        add("Desktop/Personal/blog", ".next", 310, 58)
        add("Developer/ios-playground", "Pods", 890, 93)
        add("Developer/ios-playground", "DerivedData", 2_900, 93)
        add("Developer/rust-experiments", "target", 4_200, 121)
        add("Developer/ml-notebook", ".venv", 3_100, 154)
        add("Developer/ml-notebook", "__pycache__", 85, 154)
        add("Developer/legacy-api", "node_modules", 980, 201)
        add("Developer/legacy-api", "vendor", 130, 201)
        add("Documents/uni/thesis-demo", "node_modules", 540, 277)
        add("Documents/uni/thesis-demo", "build", 96, 277)
        add("Desktop/Personal/tiny-lib", "dist", 62, 12)
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    func scanProjects(root: URL, minBytes: Int64, progress: @escaping ProgressHandler) async -> [ProjectArtifact] {
        let all = projectList()
        for dir in ["Desktop", "Developer", "Documents", "Downloads"] {
            progress("Scanning ~/\(dir)…")
            await sleep(0.7)
        }
        let removed = lock.withLock { removedPaths }
        return all.filter { $0.sizeBytes >= minBytes && !removed.contains($0.id) }
    }

    // MARK: Explorer

    private func rng(_ path: String) -> () -> Double {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return {
            h &+= 0x9E3779B97F4A7C15
            var z = h
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double(z ^ (z >> 31)) / Double(UInt64.max)
        }
    }

    func listFolder(_ url: URL) async -> [FolderEntry] {
        await sleep(url.path == home ? 1.8 : 0.9)
        if Task.isCancelled { return [] }
        let path = url.standardizedFileURL.path
        var raw: [(String, Int64, Bool)]
        if path == home {
            raw = [("Library", 138 * GB, true), ("Desktop", 96 * GB, true), ("Developer", 41 * GB, true),
                   (".cache", 14 * GB, true), ("Downloads", 12 * GB, true), ("Documents", 9 * GB, true),
                   (".npm", 5_400 * MB, true), ("Movies", 3_800 * MB, true), (".Trash", 1_100 * MB, true),
                   ("Pictures", 900 * MB, true), (".zsh_history", 240_000, false), ("notes.txt", 12_000, false)]
        } else {
            let r = rng(path)
            let depth = path.split(separator: "/").count - home.split(separator: "/").count
            let pool = ["src", "assets", "Backups", "node_modules", "archive", "Media", "Cache", "build", "vendor", "data",
                        "Projects", "Old", "Exports", "Logs", "Resources", "Frameworks", "Support", "tmp"]
            let files = ["video.mov", "dump.sql", "image.png", "report.pdf", "data.csv", "archive.zip", "disk.dmg", "notes.md", "model.bin"]
            let n = 5 + Int(r() * 9)
            raw = []
            var used = Set<String>()
            for _ in 0..<n {
                let isDir = depth < 4 && r() < 0.65
                let base = isDir ? pool[Int(r() * Double(pool.count))] : files[Int(r() * Double(files.count))]
                let name = used.contains(base) ? base + " \(Int(r() * 90) + 2)" : base
                used.insert(name)
                let size = Int64(pow(10, 5 + r() * 4.6)) // 100 KB ... ~4 GB
                raw.append((name, size, isDir))
            }
        }
        let removed = lock.withLock { removedPaths }
        return raw.map { FolderEntry(url: url.appendingPathComponent($0.0), name: $0.0, sizeBytes: $0.1, isDirectory: $0.2) }
            .filter { !removed.contains($0.url.standardizedFileURL.path) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Fake deletion (state only)

    func clean(categories cats: [CleanCategory], progress: @escaping ProgressHandler) async -> CleanResult {
        var freed: Int64 = 0
        for c in cats {
            progress("Cleaning \(c.name)…")
            await sleep(0.9)
            freed += c.sizeIsUpperBound ? c.sizeBytes / 3 : c.sizeBytes
            lock.withLock { _ = removedCategories.insert(c.id) }
        }
        lock.withLock { freedSoFar += freed }
        return CleanResult(freedBytes: freed, failedCount: cats.count > 2 ? 3 : 0,
                           messages: cats.flatMap { $0.commands }.map { "$ " + $0.joined(separator: " ") + "\n(mock) done" })
    }

    func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        for u in urls {
            progress("Deleting \(u.abbreviatedPath)…")
            await sleep(0.6)
            lock.withLock { _ = removedPaths.insert(u.standardizedFileURL.path) }
        }
        lock.withLock { freedSoFar += 2 * GB }
        return CleanResult(freedBytes: 2 * GB, failedCount: 0, messages: [])
    }
}
