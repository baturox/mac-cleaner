// Fake data for screenshots and UI work. Debug builds only: a release build contains neither this engine
// nor the MACCLEANER_* environment hooks that drive it.
#if DEBUG
import Foundation
import CleanerCore

/// Fake engine with realistic data and delays. Never touches the file system.
/// Used with `MACCLEANER_MOCK=1` for development and screenshots.
final class MockEngine: CleanerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var removedPaths = Set<String>()
    private var removedCategories = Set<String>()
    private var removedItemIDs = Set<String>()
    private var freedSoFar: Int64 = 0
    private var settings = EngineSettings()
    private let home = Fmt.homePath
    private let GB: Int64 = 1_000_000_000
    private let MB: Int64 = 1_000_000

    func diskInfo() -> DiskInfo {
        let free = 6_800 * MB + lock.withLock { freedSoFar }
        return DiskInfo(totalBytes: 494 * GB, freeBytes: free, availableWithPurgeableBytes: free + 11 * GB)
    }

    func configure(_ settings: EngineSettings) async {
        lock.withLock { self.settings = settings }
    }

    // MARK: Audit log (fake history for screenshots)

    private var mockAudit: [AuditRecord]?

    private func makeAudit() -> [AuditRecord] {
        func it(_ rel: String, _ name: String, _ mb: Int64, cat: String? = nil, kind: String? = nil, outcome: AuditOutcome = .ok,
                reason: String? = nil, action: AuditAction = .deleted) -> AuditItem {
            AuditItem(path: home + "/" + rel, name: name, categoryID: cat, artifactKind: kind, sizeBytes: mb * MB, action: action,
                      outcome: outcome, reason: reason)
        }
        func rec(_ ago: Double, _ client: AuditClient, _ kind: AuditOperationKind, _ items: [AuditItem], mode: DeleteMode = .permanent,
                 plan: String? = nil) -> AuditRecord {
            let start = Date().addingTimeInterval(-ago * 3600)
            let freed = mode == .trash ? 0 : items.filter { $0.outcome == .ok }.reduce(0) { $0 + $1.sizeBytes }
            return AuditRecord(startedAt: start, endedAt: start.addingTimeInterval(4), client: client, appVersion: "0.1.0", kind: kind, mode: mode,
                               planID: plan, freeBytesBefore: 6 * GB, freeBytesAfter: 6 * GB + freed, freedBytes: freed, itemCount: items.count,
                               failedItemCount: items.filter { $0.outcome != .ok }.count, items: items)
        }
        return [
            rec(1.5, .app, .cleanup, [it("Library/Caches/com.apple.dt.Xcode", "Xcode caches", 2_400, cat: "xcode-derived"),
                                      it("Library/Developer/Xcode/DerivedData/Shop-abc", "Shop (DerivedData)", 5_100, cat: "xcode-derived"),
                                      it(".npm/_cacache", "npm cache", 3_800, cat: "npm"),
                                      it("Library/Caches/Homebrew", "Homebrew downloads", 1_200, cat: "homebrew")]),
            rec(20, .mcp, .projectArtifacts, [it("Developer/shop-web/node_modules", "shop-web/node_modules", 1_900, kind: "node_modules"),
                                              it("Developer/old-api/target", "old-api/target", 4_200, kind: "target"),
                                              it("Developer/landing/.next", "landing/.next", 640, kind: "next")], plan: "plan_3f9a0c21d4b7e605"),
            rec(55, .cli, .cleanup, [it("Library/Caches/pip", "pip cache", 780, cat: "pip"),
                                     it("Library/Logs/DiagnosticReports", "Diagnostic reports", 310, cat: "logs", outcome: .failed,
                                        reason: "3 entries in DiagnosticReports could not be removed (in use or protected by macOS)")]),
            rec(30 * 24, .app, .removeClones, [AuditItem(path: home + "/Developer/shop-web-copy", name: "shop-web-copy", sizeBytes: 2_800 * MB, action: .deleted,
                                                          outcome: .ok, remote: "github.com/acme/shop-web", branch: "main", fullyBackedUp: true, forced: false),
                                               AuditItem(path: home + "/Developer/scratch-agent-wt", name: "scratch-agent-wt", sizeBytes: 900 * MB, action: .deleted,
                                                         outcome: .refused, reason: "Kept: 2 uncommitted changes. Back it up or remove it with force.",
                                                         remote: "github.com/acme/api", branch: "agent/try-1", fullyBackedUp: false, forced: false)]),
            rec(8 * 24, .app, .explorerDelete, [it("Downloads/installer-old.dmg", "installer-old.dmg", 1_100)], mode: .trash),
            rec(11 * 24, .cli, .projectArtifacts, [it("Developer/blog/node_modules", "blog/node_modules", 820, kind: "node_modules"),
                                                   it("Developer/blog/.astro", "blog/.astro", 40, kind: ".astro")]),
            rec(21 * 24, .app, .cleanup, [it("Library/Caches/Google/Chrome", "Chrome cache", 1_700, cat: "user-caches"),
                                          it("Library/Application Support/Code/Cache", "VS Code cache", 460, cat: "ide-caches")]),
            rec(40 * 24, .mcp, .cleanup, [it(".cache/huggingface/xet", "Hugging Face xet cache", 6_300, cat: "hf-xet")], plan: "plan_77c1be90a2d4f318"),
        ]
    }

    func auditLog(limit: Int, before: Date?) async -> [AuditRecord] {
        let all = lock.withLock { () -> [AuditRecord] in
            if mockAudit == nil { mockAudit = makeAudit() }
            return mockAudit ?? []
        }
        return Array(all.filter { before == nil || $0.startedAt < before! }.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    func auditStats(since: Date?) async -> AuditStats {
        let all = await auditLog(limit: 100_000, before: nil).filter { since == nil || $0.startedAt >= since! }
        return AuditStats(operations: all.count, freedBytes: all.reduce(0) { $0 + $1.freedBytes },
                          itemsRemoved: all.reduce(0) { $0 + $1.items.filter { $0.outcome == .ok }.count }, skippedLines: 0)
    }

    func clearAuditLog() async { lock.withLock { mockAudit = [] } }

    func hasFullDiskAccess() -> Bool {
        ProcessInfo.processInfo.environment["MACCLEANER_FDA"] == "granted"
    }

    private func url(_ rel: String) -> URL { URL(fileURLWithPath: home + "/" + rel) }
    private func daysAgo(_ d: Int) -> Date { Date().addingTimeInterval(-Double(d) * 86_400) }

    /// Splits `total` over `names` with a decaying distribution.
    private func spread(_ names: [String], base: String, total: Int64) -> [CleanItem] {
        let weights = names.indices.map { pow(0.82, Double($0)) }
        let sum = weights.reduce(0, +)
        return names.enumerated().map { i, n in
            CleanItem(url: url("\(base)/\(n)"), sizeBytes: Int64(Double(total) * weights[i] / sum))
        }
    }

    private func item(_ rel: String, _ mb: Int64, label: String? = nil, ago: Int? = nil, cmd: [String]? = nil) -> CleanItem {
        CleanItem(url: url(rel), sizeBytes: mb * MB, label: label, lastUsed: ago.map(daysAgo), deleteCommand: cmd)
    }

    private func cat(_ id: String, _ name: String, _ detail: String, _ level: SafetyLevel, _ symbol: String, _ group: CategoryGroup,
                     items: [CleanItem], commands: [[String]] = [], size: Int64? = nil, upper: Bool = false,
                     selectable: Bool = false) -> CleanCategory {
        let total = size ?? items.reduce(0) { $0 + $1.sizeBytes }
        return CleanCategory(id: id, name: name, detail: detail, level: level, symbol: symbol,
                             items: items.sorted { $0.sizeBytes > $1.sizeBytes }, commands: commands,
                             sizeBytes: total, sizeIsUpperBound: upper, group: group, itemsSelectable: selectable)
    }

    // MARK: Categories

    private func allCategories() -> [CleanCategory] {
        let cacheNames = ["com.spotify.client", "com.google.Chrome", "com.apple.Safari", "Homebrew", "com.microsoft.VSCode",
                          "Yarn", "com.figma.Desktop", "com.apple.dt.Xcode", "pip", "go-build", "com.docker.docker",
                          "org.swift.swiftpm", "com.slack.Slack", "JetBrains", "CocoaPods", "com.tinyspeck.slackmacgap",
                          "com.apple.python", "node-gyp", "ms-playwright", "SentryCrash"]
            + (1...20).map { "com.vendor.app\($0)" }

        let claudeSessions = [
            ("Developer/acme/storefront-feat-1234", 2_150, 4), ("Developer/acme/storefront", 1_480, 9),
            ("Developer/acme/payments-api", 920, 17), ("Developer/agents/run-0042/storefront", 780, 33),
            ("Developer/rust-gateway", 610, 48), ("Desktop/Personal/blog", 540, 75), ("Developer/ml-notebook", 430, 102),
            ("Developer/ios-playground", 380, 131), ("Developer/acme/design-system", 340, 160),
            ("Documents/uni/thesis-demo", 210, 245), ("Developer/legacy-api", 175, 301), ("Desktop/Personal/old-shop", 96, 410),
        ].map { item(".claude/projects/-" + $0.0.replacingOccurrences(of: "/", with: "-"), Int64($0.1),
                     label: "~/" + $0.0, ago: $0.2) }

        let cursor = [
            ("storefront-feat-1234", 640, 5), ("payments-api", 410, 21), ("design-system", 280, 64),
            ("blog", 190, 118), ("ml-notebook", 150, 190), ("old-shop", 85, 330),
        ].map { item("Library/Application Support/Cursor/User/workspaceStorage/\(abs($0.0.hashValue) % 100_000_000)", Int64($0.1),
                     label: "Cursor workspace: \($0.0)", ago: $0.2) }

        let codex = [
            ("2026-11", 320, 3), ("2026-10", 540, 20), ("2026-09", 610, 48), ("2026-08", 470, 79), ("2026-07", 390, 110), ("2026-06", 250, 150),
        ].map { item(".codex/sessions/\($0.0)", Int64($0.1), label: "Codex sessions \($0.0)", ago: $0.2) }

        let hf = [
            ("meta-llama/Llama-3.1-8B-Instruct", 16_100, 22), ("openai/whisper-large-v3", 6_200, 95), ("BAAI/bge-m3", 2_300, 140),
            ("stabilityai/sdxl-base-1.0", 13_900, 210), ("mistralai/Mistral-7B-v0.3", 14_500, 260), ("datasets/squad", 420, 300),
        ].map { item(".cache/huggingface/hub/models--" + $0.0.replacingOccurrences(of: "/", with: "--"), Int64($0.1), label: $0.0, ago: $0.2) }

        let ollama = [
            ("llama3.1:8b", 4_900, 12), ("qwen2.5-coder:14b", 9_000, 40), ("mistral:7b", 4_100, 120), ("codellama:34b", 19_000, 200),
        ].map { item(".ollama/models/manifests/registry.ollama.ai/library/" + $0.0.replacingOccurrences(of: ":", with: "/"), Int64($0.1),
                     label: $0.0, ago: $0.2, cmd: ["ollama", "rm", $0.0]) }

        let lmstudio = [
            ("lmstudio-community/Qwen2.5-7B-Instruct-GGUF", 4_700, 31), ("TheBloke/deepseek-coder-6.7B-GGUF", 3_800, 170),
        ].map { item(".lmstudio/models/" + $0.0, Int64($0.1), label: $0.0, ago: $0.2) }

        let nodes = [
            ("20.11.1", 310, 2), ("18.20.4", 290, 85), ("16.20.2", 270, 400), ("14.21.3", 250, 620),
        ].map { item(".local/share/fnm/node-versions/v\($0.0)", Int64($0.1), label: "Node \($0.0)", ago: $0.2, cmd: ["fnm", "uninstall", $0.0]) }

        let rust = [
            ("stable-aarch64-apple-darwin", 1_450, 1), ("nightly-2024-06-01", 1_300, 240), ("1.70.0-aarch64-apple-darwin", 1_100, 500),
        ].map { item(".rustup/toolchains/" + $0.0, Int64($0.1), label: "Rust " + $0.0, ago: $0.2, cmd: ["rustup", "toolchain", "uninstall", $0.0]) }

        let pyenv = [("3.12.2", 420, 6), ("3.9.18", 380, 330), ("3.8.18", 360, 700)]
            .map { item(".pyenv/versions/" + $0.0, Int64($0.1), label: "Python " + $0.0, ago: $0.2, cmd: ["pyenv", "uninstall", "-f", $0.0]) }

        let sims = [
            ("iOS 18.0 Simulator", 7_400, 12, "A1B2C3D4-0001"), ("iOS 17.2 Simulator", 6_900, 140, "A1B2C3D4-0002"),
            ("iOS 16.4 Simulator", 6_200, 420, "A1B2C3D4-0003"), ("watchOS 10.2 Simulator", 3_100, 300, "A1B2C3D4-0004"),
        ].map { item("Library/Developer/CoreSimulator/Volumes/" + $0.3, Int64($0.1), label: $0.0, ago: $0.2,
                     cmd: ["xcrun", "simctl", "runtime", "delete", $0.3]) }

        let archives = [("ios-app 2.4.0", 1_900, 190), ("ios-app 2.3.1", 1_750, 330), ("widget-kit-demo 1.0", 420, 520)]
            .map { item("Library/Developer/Xcode/Archives/\($0.0.replacingOccurrences(of: " ", with: "-")).xcarchive", Int64($0.1), label: $0.0 + " archive", ago: $0.2) }

        let backups = [("iPhone 14 backup", 38_200, 280), ("iPad backup", 12_400, 610)]
            .map { item("Library/Application Support/MobileSync/Backup/\($0.0.hashValue.magnitude % 1_000_000)", Int64($0.1), label: $0.0, ago: $0.2) }

        let installers = [
            ("Xcode_16.2.xip", 2_900, 20), ("Docker.dmg", 650, 150), ("zoom.pkg", 190, 220), ("Figma.dmg", 140, 310),
            ("node-v18.pkg", 60, 400), ("android-studio.dmg", 1_100, 95),
        ].map { item("Downloads/" + $0.0, Int64($0.1), ago: $0.2) }

        let screenshots = [("Screen Recording 2026-04-02.mov", 1_400, 210), ("Screen Recording 2026-02-11.mov", 880, 270), ("Screenshot 2026-01.png", 6, 300)]
            .map { item("Desktop/" + $0.0, Int64($0.1), ago: $0.2) }

        let vms = [("colima default disk", 21_000, 45), ("Multipass ubuntu-22.04", 8_700, 160)]
            .map { item("Library/Containers/vm/" + $0.0.replacingOccurrences(of: " ", with: "-"), Int64($0.1), label: $0.0, ago: $0.2,
                        cmd: $0.0.hasPrefix("colima") ? ["colima", "delete", "default"] : ["multipass", "delete", "--purge", "ubuntu-22.04"]) }

        let derived = ["storefront-ios-bwq", "ios-playground-eao", "widget-kit-demo-hnc", "Preview-Support", "ModuleCache.noindex"]
        let cats: [CleanCategory] = [
            // System & apps
            cat("user-caches", "User caches", "App caches in ~/Library/Caches — apps rebuild them as needed", .safe, "internaldrive", .system,
                items: spread(cacheNames, base: "Library/Caches", total: 19_300 * MB)),
            cat("app-caches", "App caches", "Slack, Discord, Teams and browser caches inside Application Support", .safe, "app.dashed", .system,
                items: spread(["Slack/Cache", "discord/Cache", "Code/CachedData", "Google/Chrome/Default/Service Worker"], base: "Library/Application Support", total: 2_800 * MB)),
            cat("logs", "Logs & crash reports", "Diagnostic reports and app logs; macOS writes new ones when needed", .safe, "doc.text", .system,
                items: spread(["DiagnosticReports", "com.apple.coresymbolicationd", "Docker", "JetBrains"], base: "Library/Logs", total: 1_600 * MB)),
            cat("trash", "Trash", "Items you already deleted; emptying is permanent", .caution, "trash", .system,
                items: spread(["old-project.zip", "Screenshot folder", "export.mov"], base: ".Trash", total: 1_100 * MB)),
            cat("ios-backups", "iOS device backups", "Local iPhone and iPad backups; you cannot recreate them once deleted", .caution, "iphone.gen3", .system,
                items: backups, selectable: true),
            // Package managers
            cat("npm", "npm cache", "Downloaded packages; npm fetches them again when needed", .safe, "shippingbox", .packageManagers,
                items: [item(".npm/_cacache", 5_400)]),
            cat("yarn", "Yarn cache", "Downloaded packages; Yarn fetches them again when needed", .safe, "shippingbox", .packageManagers,
                items: spread(["v6", "berry"], base: "Library/Caches/Yarn", total: 2_200 * MB)),
            cat("cargo", "Cargo registry", "Downloaded crates and sources; cargo fetches them again", .safe, "shippingbox", .packageManagers,
                items: spread(["registry/cache", "registry/src", "git/db"], base: ".cargo", total: 6_100 * MB)),
            cat("cocoapods", "CocoaPods cache", "Downloaded pods; pod install fetches them again", .safe, "shippingbox", .packageManagers,
                items: [item("Library/Caches/CocoaPods", 2_700)]),
            cat("pip", "pip cache", "Downloaded wheels; pip fetches them again", .safe, "shippingbox", .packageManagers,
                items: [item(".cache/pip", 1_400)]),
            cat("pnpm", "pnpm store", "Shared package store; `pnpm store prune` removes unreferenced packages only", .safe, "shippingbox.fill", .packageManagers,
                items: [], commands: [["pnpm", "store", "prune"]], size: 3_500 * MB, upper: true),
            cat("brew", "Homebrew old versions", "Outdated formula versions and downloads", .safe, "mug", .packageManagers,
                items: [], commands: [["brew", "cleanup", "-s"]], size: 0),
            // Xcode & mobile
            cat("derived-data", "Xcode DerivedData", "Build products and indexes; Xcode regenerates them", .safe, "hammer", .xcode,
                items: spread(derived, base: "Library/Developer/Xcode/DerivedData", total: 14_800 * MB)),
            cat("xcode-device-support", "Xcode device support", "Symbols for iOS versions you connected; re-created on next connect", .safe, "iphone", .xcode,
                items: spread(["17.5 (21F79) arm64e", "17.2 (21C62) arm64e", "16.4 (20E247) arm64e"], base: "Library/Developer/Xcode/iOS DeviceSupport", total: 4_500 * MB)),
            cat("simulators", "Simulator runtimes", "Installed simulator runtimes; download them again from Xcode when needed", .caution, "ipad.and.iphone", .xcode,
                items: sims, selectable: true),
            cat("xcode-archives", "Xcode archives", "Archived app builds; keep the ones you may need to symbolicate or re-submit", .caution, "archivebox", .xcode,
                items: archives, selectable: true),
            // AI coding tools
            cat("claude-sessions", "Claude Code sessions", "Conversation transcripts per project; deleting one loses its resumable history", .caution, "bubble.left.and.text.bubble.right", .aiTools,
                items: claudeSessions, selectable: true),
            cat("cursor-workspaces", "Cursor workspace storage", "Per-workspace caches, indexes and chat history", .caution, "cursorarrow.rays", .aiTools,
                items: cursor, selectable: true),
            cat("codex-sessions", "Codex sessions", "Session logs grouped by month", .caution, "terminal", .aiTools,
                items: codex, selectable: true),
            cat("ai-cache", "AI tool caches", "Shell snapshots, telemetry and todo files that tools recreate", .safe, "sparkles", .aiTools,
                items: spread(["shell-snapshots", "statsig", "todos", "ide"], base: ".claude", total: 920 * MB)),
            // AI models
            cat("hf", "Hugging Face models", "Downloaded model weights; large to fetch again", .caution, "brain", .models,
                items: hf, selectable: true),
            cat("ollama", "Ollama models", "Local LLMs; removed with `ollama rm`, pulled again on demand", .caution, "cube", .models,
                items: ollama, selectable: true),
            cat("lmstudio", "LM Studio models", "GGUF models downloaded through LM Studio", .caution, "cpu", .models,
                items: lmstudio, selectable: true),
            cat("torch", "Torch & Whisper caches", "Pretrained weights cached by libraries; re-downloaded when used", .safe, "memorychip", .models,
                items: spread(["torch/hub", "whisper", "pyannote"], base: ".cache", total: 2_400 * MB)),
            // Toolchains
            cat("node-versions", "Node.js versions", "Versions installed with fnm; pick the ones you no longer use", .caution, "n.circle", .toolchains,
                items: nodes, selectable: true),
            cat("rustup", "Rust toolchains", "Toolchains installed with rustup", .caution, "gearshape.2", .toolchains,
                items: rust, selectable: true),
            cat("pyenv", "Python versions", "Interpreters installed with pyenv", .caution, "p.circle", .toolchains,
                items: pyenv, selectable: true),
            cat("go-mod", "Go module cache", "Downloaded modules; `go clean -modcache` removes them, go fetches them again", .safe, "shippingbox", .toolchains,
                items: [], commands: [["go", "clean", "-modcache"]], size: 4_100 * MB, upper: true),
            // Containers & VMs
            cat("docker-images", "Docker images & volumes", "Everything `docker system prune -a` removes; images are pulled again, volumes are not", .caution, "shippingbox.circle", .containers,
                items: [], commands: [["docker", "system", "prune", "-af"]], size: 38_000 * MB, upper: true),
            cat("docker-builder", "Docker build cache", "Layers cached by BuildKit; rebuilt on the next build", .safe, "externaldrive", .containers,
                items: [], commands: [["docker", "builder", "prune", "-af"]], size: 9_200 * MB, upper: true),
            cat("vms", "Virtual machines", "Disk images of local VMs; removed with their CLI", .caution, "macwindow", .containers,
                items: vms, selectable: true),
            // Personal data
            cat("installers", "Old installers", "Disk images and packages in Downloads", .caution, "arrow.down.app", .personal,
                items: installers, selectable: true),
            cat("recordings", "Screen recordings", "Screenshots and recordings left on the Desktop", .caution, "record.circle", .personal,
                items: screenshots, selectable: true),
        ]
        return cats
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    func scanCategories(progress: @escaping ProgressHandler) async -> [CleanCategory] {
        let all = allCategories()
        for c in all {
            progress("Measuring \(c.name)…")
            await sleep(0.1)
            if Task.isCancelled { return [] }
        }
        let (removedCats, removedItems) = lock.withLock { (removedCategories, removedItemIDs) }
        var out: [CleanCategory] = []
        for var c in all where !removedCats.contains(c.id) {
            if !c.items.isEmpty {
                c.items = c.items.filter { !removedItems.contains($0.id) }
                if c.items.isEmpty && c.commands.isEmpty { continue }
                if !c.sizeIsUpperBound { c.sizeBytes = c.items.reduce(0) { $0 + $1.sizeBytes } }
            }
            out.append(c)
        }
        // Exact sizes largest first, then upper-bound / command-only ones.
        return out.sorted {
            let a = $0.sizeIsUpperBound || $0.items.isEmpty, b = $1.sizeIsUpperBound || $1.items.isEmpty
            if a != b { return !a }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    // MARK: Projects

    private func projectList() -> [ProjectArtifact] {
        var out: [ProjectArtifact] = []
        func add(_ proj: String, _ kind: String, _ mb: Int64, _ idle: Int) {
            let p = URL(fileURLWithPath: home + "/" + proj)
            out.append(ProjectArtifact(url: p.appendingPathComponent(kind), kind: kind, projectURL: p, sizeBytes: mb * MB, idleDays: idle))
        }
        add("Developer/rust-gateway", "target", 33_800, 0)
        let sizes: [Int64] = [2_400, 2_100, 1_900, 1_800, 1_700, 1_600, 1_500, 1_400, 1_350, 1_300, 1_250, 1_200]
        for (i, s) in sizes.enumerated() {
            add("Developer/acme/storefront-feat-\(1234 + i * 7)", "node_modules", s, i < 4 ? 0 : (i < 8 ? 1 : 2))
        }
        add("Developer/acme/storefront-feat-1234", ".next", 1_500, 0)
        add("Developer/acme/storefront-feat-1241", ".next", 640, 0)
        add("Developer/acme/storefront-feat-1234", "dist", 210, 0)
        add("Developer/acme/payments-api", "node_modules", 880, 6)
        add("Developer/acme/payments-api", ".turbo", 120, 6)
        add("Desktop/Personal/old-shop", "node_modules", 1_050, 36)
        add("Desktop/Personal/blog", "node_modules", 720, 58)
        add("Desktop/Personal/blog", ".next", 310, 58)
        add("Developer/ios-playground", "Pods", 890, 93)
        add("Developer/ios-playground", "DerivedData", 2_900, 93)
        add("Developer/swift-server", ".build", 1_650, 71)
        add("Developer/rust-experiments", "target", 4_200, 121)
        add("Developer/ml-notebook", ".venv", 3_100, 154)
        add("Developer/ml-notebook", "__pycache__", 85, 154)
        add("Developer/infra", ".terraform", 540, 40)
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
            await sleep(0.5)
            if Task.isCancelled { return [] }
        }
        let removed = lock.withLock { removedPaths }
        return all.filter { $0.sizeBytes >= minBytes && !removed.contains($0.id) }
    }

    // MARK: Repos

    private func repoList() -> [RepoGroup] {
        func clone(_ rel: String, branch: String?, worktree: Bool = false, uncommitted: Int = 0, unpushed: Int? = 0,
                   stash: Bool = false, commit: Int, idle: Int, gb: Double, rebuildable: Double,
                   ignored: Int = 0, untrusted: [String]? = nil) -> RepoClone {
            RepoClone(url: url(rel), branch: untrusted == nil ? branch : nil, isLinkedWorktree: worktree, uncommittedCount: uncommitted,
                      unpushedCount: untrusted == nil ? unpushed : nil, hasStash: stash,
                      lastCommit: untrusted == nil ? daysAgo(commit) : nil, idleDays: idle,
                      sizeBytes: Int64(gb * Double(GB)), artifactBytes: Int64(rebuildable * Double(GB)),
                      ignoredFileCount: ignored, untrustedConfigKeys: untrusted)
        }
        func group(_ name: String, _ remote: String?, _ clones: [RepoClone]) -> RepoGroup {
            RepoGroup(id: remote ?? url(name).path, name: name, remote: remote, clones: clones.sorted { $0.sizeBytes > $1.sizeBytes })
        }
        return [
            group("acme/storefront", "github.com/acme/storefront", [
                clone("Developer/acme/storefront", branch: "main", commit: 2, idle: 1, gb: 3.9, rebuildable: 2.6),
                clone("Developer/acme/storefront-feat-1234", branch: "feat/cart-redesign", worktree: true, commit: 4, idle: 0, gb: 3.4, rebuildable: 2.4),
                clone("Developer/acme/storefront-feat-1241", branch: "feat/checkout-v2", worktree: true, uncommitted: 3, commit: 5, idle: 0, gb: 2.9, rebuildable: 2.1),
                clone("Developer/acme/storefront-fix-1255", branch: "fix/tax-rounding", worktree: true, commit: 12, idle: 11, gb: 2.6, rebuildable: 1.9),
                clone("Developer/agents/run-0042/storefront", branch: "agent/refactor-hooks", unpushed: 0, commit: 33, idle: 31, gb: 3.7, rebuildable: 2.5),
                clone("Desktop/storefront-copy", branch: "feat/cart", uncommitted: 7, unpushed: 2, stash: true, commit: 61, idle: 58, gb: 3.2, rebuildable: 2.2),
                clone("Documents/old/storefront", branch: nil, commit: 160, idle: 158, gb: 2.1, rebuildable: 1.1),
            ]),
            group("acme/payments-api", "github.com/acme/payments-api", [
                clone("Developer/acme/payments-api", branch: "main", commit: 6, idle: 6, gb: 1.8, rebuildable: 0.9),
                clone("Developer/agents/run-0039/payments-api", branch: "agent/retry-logic", unpushed: 4, commit: 40, idle: 40, gb: 1.7, rebuildable: 0.9),
                clone("Developer/acme/payments-api-hotfix", branch: "hotfix/idempotency", worktree: true, commit: 90, idle: 88, gb: 1.2, rebuildable: 0.8),
            ]),
            group("acme/design-system", "github.com/acme/design-system", [
                clone("Developer/acme/design-system", branch: "main", commit: 14, idle: 14, gb: 1.4, rebuildable: 0.9),
                clone("Documents/uni/design-system", branch: "main", commit: 280, idle: 280, gb: 1.3, rebuildable: 0.9, ignored: 2),
            ]),
            group("acme/mobile-app", "github.com/acme/mobile-app", [
                clone("Developer/ios-playground", branch: "main", commit: 93, idle: 93, gb: 4.4, rebuildable: 3.8),
                clone("Developer/mobile-app-spike", branch: "spike/widgets", uncommitted: 12, unpushed: nil, commit: 130, idle: 130, gb: 2.2, rebuildable: 1.6),
            ]),
            group("acme/infra", "github.com/acme/infra", [
                clone("Developer/infra", branch: "main", commit: 40, idle: 40, gb: 0.9, rebuildable: 0.5),
            ]),
            group("acme/ml-pipeline", "github.com/acme/ml-pipeline", [
                clone("Developer/ml-notebook", branch: "exp/embeddings", unpushed: 3, commit: 154, idle: 154, gb: 3.4, rebuildable: 3.1),
            ]),
            group("rust-gateway", nil, [
                clone("Developer/rust-gateway", branch: "main", uncommitted: 2, unpushed: nil, commit: 0, idle: 0, gb: 34.6, rebuildable: 33.8),
            ]),
            group("unpacked-sample", nil, [
                clone("Downloads/unpacked-sample", branch: nil, commit: 0, idle: 3, gb: 0.4, rebuildable: 0,
                      untrusted: ["core.fsmonitor", "filter.*.clean"]),
            ]),
            group("acme/docs-site", "github.com/acme/docs-site", [
                clone("Desktop/Personal/blog", branch: "main", commit: 58, idle: 58, gb: 1.1, rebuildable: 1.0),
            ]),
        ]
    }

    func scanRepos(root: URL, progress: @escaping ProgressHandler) async -> [RepoGroup] {
        let all = repoList()
        for dir in ["Developer", "Desktop", "Documents"] {
            progress("Looking for repositories in ~/\(dir)…")
            await sleep(0.55)
            if Task.isCancelled { return [] }
        }
        let removed = lock.withLock { removedPaths }
        return all.compactMap { g in
            var g = g
            g.clones.removeAll { removed.contains($0.id) }
            return g.clones.isEmpty ? nil : g
        }.sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: Growth

    func recordSnapshot(categories: [CleanCategory], artifacts: [ProjectArtifact]) async -> GrowthReport {
        if ProcessInfo.processInfo.environment["MACCLEANER_GROWTH"] == "first" { return GrowthReport(previousDate: nil, freeDeltaBytes: 0, entries: []) }
        func factor(_ id: String) -> Double {
            var h: UInt64 = 1469598103934665603
            for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            let r = Double(h % 1000) / 1000
            let overrides: [String: Double] = ["claude-sessions": 0.55, "derived-data": 0.55, "hf": 0.9, "ollama": 0.85,
                                               "node-versions": 1.0, "cursor-workspaces": 0.7, "simulators": 1.0]
            if let o = overrides[id] { return o }
            if id.hasSuffix("/rust-gateway/target") { return 0.6 }
            if r < 0.22 { return 0.45 + r }        // grew a lot
            if r < 0.30 { return 1.18 }            // shrank (user cleaned something)
            return 1.0
        }
        var entries: [GrowthEntry] = []
        for c in categories where !c.sizeIsUpperBound && c.sizeBytes > 0 {
            let prev = Int64(Double(c.sizeBytes) * factor(c.id))
            entries.append(GrowthEntry(id: c.id, name: c.name, url: c.items.first?.url.deletingLastPathComponent(), previousBytes: prev, currentBytes: c.sizeBytes))
        }
        for a in artifacts {
            let prev = Int64(Double(a.sizeBytes) * factor(a.id))
            entries.append(GrowthEntry(id: a.id, name: a.projectURL.lastPathComponent + "/" + a.kind, url: a.url, previousBytes: prev, currentBytes: a.sizeBytes))
        }
        let kept = entries.filter { abs($0.deltaBytes) >= 50 * MB }.sorted { $0.deltaBytes > $1.deltaBytes }
        let total = kept.reduce(0) { $0 + $1.deltaBytes }
        return GrowthReport(previousDate: daysAgo(2), freeDeltaBytes: -(total + 800 * MB), entries: kept)
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
        await clean(categories: cats, mode: .permanent, progress: progress)
    }

    func clean(categories cats: [CleanCategory], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        var freed: Int64 = 0
        var messages: [String] = []
        for c in cats {
            progress("Cleaning \(c.name)…")
            await sleep(0.7)
            freed += c.sizeIsUpperBound ? c.sizeBytes / 3 : c.sizeBytes
            lock.withLock {
                for i in c.items { removedItemIDs.insert(i.id) }
                if !c.commands.isEmpty { removedCategories.insert(c.id) }
                if c.items.isEmpty { removedCategories.insert(c.id) }
            }
            for i in c.items {
                if let cmd = i.deleteCommand { messages.append("$ " + cmd.joined(separator: " ") + "\n(mock) done") }
            }
            for cmd in c.commands { messages.append("$ " + cmd.joined(separator: " ") + "\n(mock) done") }
        }
        let failed = cats.count > 2 ? 3 : 0
        if failed > 0 {
            messages.append("Could not remove ~/Library/Caches/com.apple.Safari/WebKitCache: Operation not permitted (protected by macOS)")
            messages.append("Skipped ~/Library/Caches/com.docker.docker: in use by a running process")
            messages.append("Failed to remove ~/Library/Caches/Homebrew/downloads/.lock: permission denied")
        }
        if mode == .trash {
            messages.insert("(mock) Moved items to the Trash. Empty the Trash to free the space.", at: 0)
            freed = 0
        }
        lock.withLock { freedSoFar += freed }
        return CleanResult(freedBytes: freed, failedCount: failed, messages: messages)
    }

    func delete(urls: [URL], progress: @escaping ProgressHandler) async -> CleanResult {
        await delete(urls: urls, mode: .permanent, progress: progress)
    }

    func delete(urls: [URL], mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        for u in urls {
            progress("\(mode == .trash ? "Moving to Trash" : "Deleting") \(u.abbreviatedPath)…")
            await sleep(0.5)
            lock.withLock { _ = removedPaths.insert(u.standardizedFileURL.path) }
        }
        let freed = mode == .trash ? 0 : 2 * GB
        lock.withLock { freedSoFar += freed }
        return CleanResult(freedBytes: freed, failedCount: 0, messages: [])
    }

    func removeClones(_ clones: [RepoClone], force: Bool, mode: DeleteMode, progress: @escaping ProgressHandler) async -> CleanResult {
        var freed: Int64 = 0
        var failed = 0
        var messages: [String] = []
        for c in clones {
            progress("Removing \(c.url.abbreviatedPath)…")
            await sleep(0.5)
            if !c.wasInspected {
                failed += 1
                messages.append("Kept \(c.url.abbreviatedPath): its git configuration could run programs, so it was not inspected.")
                continue
            }
            if !c.isFullyBackedUp && !force {
                failed += 1
                messages.append("Refused to remove \(c.url.abbreviatedPath): it has work that is not backed up.")
                continue
            }
            lock.withLock { _ = removedPaths.insert(c.id) }
            freed += c.sizeBytes
            messages.append(c.isLinkedWorktree ? "(mock) removed the worktree \(c.url.abbreviatedPath)\n$ git worktree prune" : "(mock) removed \(c.url.abbreviatedPath)")
        }
        if mode == .trash {
            messages.insert("(mock) Moved the copies to the Trash. Empty the Trash to free the space.", at: 0)
            freed = 0
        }
        lock.withLock { freedSoFar += freed }
        return CleanResult(freedBytes: freed, failedCount: failed, messages: messages)
    }
}
#endif
