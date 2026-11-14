// Declarative category table: categories whose items are plain glob matches or a measured folder plus a command.
// Categories that need parsing (models, toolchains, sessions, simulators, Docker…) live in their own files.
import Foundation

struct CatDef {
    var id: String
    var name: String
    var detail: String
    var level: SafetyLevel
    var symbol: String
    var group: CategoryGroup = .system
    var selectable = false
    /// Also require items to be older than `EngineSettings.sessionRetentionDays`.
    var useRetention = false
    var minAgeDays: Int = 0
    /// Judge age by the newest change anywhere inside each item, not by the item's own timestamp.
    var deepAge = false
    var globs: [String] = []
    /// fnmatch patterns on the last path component; matching items are dropped.
    var exclude: [String] = []
    /// Absolute paths (already expanded); items equal to or below them are dropped.
    var excludePaths: [String] = []
    var cmds: [[String]] = []
    var needs: String = ""
    var measure: [String] = []
    /// Used instead of `globs`/`cmds` when the `needs` tool is missing (e.g. offer the folder when `uv` is absent).
    var fallbackGlobs: [String] = []
}

private let appSupport = "~/Library/Application Support"
private let electronDirs = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
                            "DawnWebGPUCache", "CachedData", "CachedExtensionVSIXs",
                            "Service Worker/CacheStorage", "Service Worker/ScriptCache", "Crashpad/completed"]
private let chromium = ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Chromium"]

/// Application Support folders owned by dedicated categories (editors, Claude desktop); the generic
/// "app caches" category skips them so nothing is counted twice.
let dedicatedAppSupportDirs = ["Cursor", "Windsurf", "Code", "Code - Insiders", "VSCodium", "Antigravity", "Claude"]

/// ~/Library/Caches children that belong to a dedicated category.
private let carvedLibraryCaches = ["Homebrew", "ms-playwright", "pip", "pypoetry", "CocoaPods", "org.swift.swiftpm",
                                   "org.carthage.CarthageKit", "deno", "composer", "go-build", "ccache",
                                   "Mozilla.sccache", "JetBrains", "Zed", "Yarn"]
/// ~/.cache children that belong to a dedicated category.
private let carvedXDGCaches = ["huggingface", "puppeteer", "uv", "pip", "torch", "whisper", "lm-studio", "composer", "ccache"]

func makeCategoryDefs(env: EngineEnvironment) -> [CatDef] {
    let h = env.home
    var appCacheGlobs: [String] = []
    for d in electronDirs { appCacheGlobs.append("\(appSupport)/*/\(d)") }
    for b in chromium { for d in electronDirs { appCacheGlobs.append("\(appSupport)/\(b)/*/\(d)") } }
    for b in chromium { for d in ["GrShaderCache", "ShaderCache", "component_crx_cache"] { appCacheGlobs.append("\(appSupport)/\(b)/\(d)") } }

    var tempGlobs = [env.tmp + "/*", env.privateTmp + "/*"]
    if let v = env.varFolders { tempGlobs.append(v + "/C/*") }

    let uvCache = env.variable("UV_CACHE_DIR") ?? "~/.cache/uv"
    let composer = env.variable("COMPOSER_HOME").map { $0 + "/cache" } ?? "~/.composer/cache"
    let terraform = env.variable("TF_PLUGIN_CACHE_DIR") ?? "~/.terraform.d/plugin-cache"
    let ccache = env.variable("CCACHE_DIR").map { [$0] } ?? ["~/.ccache", "~/Library/Caches/ccache", "~/.cache/ccache"]
    let conda = ["~/.conda/pkgs", "~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/miniforge3/pkgs", "~/mambaforge/pkgs",
                 "~/micromamba/pkgs", "~/.local/share/mamba/pkgs", "~/opt/anaconda3/pkgs", "/opt/homebrew/Caskroom/miniconda/base/pkgs"]
    let bazel = env.bazelRoot.map { [$0] } ?? []

    return [
        // ---- System & apps
        CatDef(id: "caches", name: "Other app caches", detail: "Rebuilt automatically by apps (browsers, system frameworks…); caches with their own card are listed separately",
               level: .safe, symbol: "folder", globs: ["~/Library/Caches/*"], exclude: carvedLibraryCaches),
        CatDef(id: "logs", name: "User logs & crash reports", detail: "Old log and crash report files; apps write new ones",
               level: .safe, symbol: "doc.text", globs: ["~/Library/Logs/*", "\(appSupport)/CrashReporter/*"]),
        CatDef(id: "temp", name: "Temp files older than 7 days", detail: "Leftovers in temporary folders that nothing has touched for a week",
               level: .safe, symbol: "clock", minAgeDays: 7, globs: tempGlobs, exclude: ["claude-*"]),
        CatDef(id: "app-caches", name: "App caches (Slack, Chrome, Electron…)", detail: "Web and shader caches inside app data; quit the apps first for a clean result",
               level: .safe, symbol: "app.dashed", globs: appCacheGlobs,
               excludePaths: dedicatedAppSupportDirs.map { h + "/Library/Application Support/" + $0 }),
        CatDef(id: "xdg-cache", name: "Other CLI caches (~/.cache)", detail: "Rebuilt automatically by command-line tools",
               level: .safe, symbol: "terminal", globs: ["~/.cache/*"], exclude: carvedXDGCaches),
        CatDef(id: "snapshots", name: "Time Machine local snapshots", detail: "Deleted data stays on disk until these go",
               level: .safe, symbol: "clock.arrow.circlepath", needs: "tmutil"),

        // ---- Package managers
        CatDef(id: "npm", name: "npm / npx cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/.npm/_cacache", "~/.npm/_npx", "~/.npm/_logs"]),
        CatDef(id: "bun", name: "Bun install cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "bolt", group: .packageManagers, globs: ["~/.bun/install/cache"]),
        CatDef(id: "yarn", name: "Yarn cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "shippingbox", group: .packageManagers,
               globs: ["~/.yarn/berry/cache", "~/.yarn/cache", "~/Library/Caches/Yarn"]),
        CatDef(id: "pnpm", name: "pnpm store (unreferenced packages)", detail: "Size is the whole store; only packages no project uses are removed",
               level: .safe, symbol: "shippingbox", group: .packageManagers, cmds: [["pnpm", "store", "prune"]], needs: "pnpm",
               measure: ["~/Library/pnpm/store"]),
        CatDef(id: "cargo", name: "Cargo registry cache", detail: "Re-downloaded on the next build",
               level: .safe, symbol: "gearshape.2", group: .packageManagers, globs: ["~/.cargo/registry/cache", "~/.cargo/registry/src"]),
        CatDef(id: "gradle", name: "Gradle caches", detail: "Re-downloaded on the next build",
               level: .safe, symbol: "gearshape", group: .packageManagers,
               globs: ["~/.gradle/caches", "~/.gradle/daemon", "~/.gradle/wrapper/dists"]),
        CatDef(id: "maven", name: "Maven local repository", detail: "Re-downloaded on the next build, which can be slow on large projects",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/.m2/repository"]),
        CatDef(id: "uv", name: "uv cache", detail: "Runs `uv cache prune`, which removes only entries uv no longer needs; size shown is the whole cache",
               level: .safe, symbol: "bolt.horizontal", group: .packageManagers, cmds: [["uv", "cache", "prune"]], needs: "uv",
               measure: [uvCache], fallbackGlobs: [uvCache + "/*"]),
        CatDef(id: "pip", name: "pip cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/Library/Caches/pip", "~/.cache/pip"]),
        CatDef(id: "poetry", name: "Poetry cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/Library/Caches/pypoetry"]),
        CatDef(id: "conda", name: "Conda / Mamba package cache", detail: "Downloaded packages; environments keep their own hard links",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: conda),
        CatDef(id: "cocoapods", name: "CocoaPods cache & specs", detail: "Re-downloaded by `pod install`",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/Library/Caches/CocoaPods", "~/.cocoapods/repos"]),
        CatDef(id: "swiftpm", name: "SwiftPM cache", detail: "Cloned package repositories and manifests; re-fetched on the next resolve",
               level: .safe, symbol: "swift", group: .packageManagers, globs: ["~/Library/Caches/org.swift.swiftpm"]),
        CatDef(id: "carthage", name: "Carthage cache", detail: "Re-downloaded on the next update",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/Library/Caches/org.carthage.CarthageKit"]),
        CatDef(id: "deno", name: "Deno cache", detail: "Re-downloaded on the next run",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/Library/Caches/deno", "~/.deno/gen", "~/.deno/deps"]),
        CatDef(id: "pub", name: "Dart / Flutter pub cache", detail: "Hosted and git packages are re-downloaded; activated global tools are kept",
               level: .safe, symbol: "shippingbox", group: .packageManagers,
               globs: ["~/.pub-cache/hosted", "~/.pub-cache/hosted-hashes", "~/.pub-cache/git"]),
        CatDef(id: "composer", name: "Composer cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: [composer, "~/Library/Caches/composer", "~/.cache/composer"]),
        CatDef(id: "nuget", name: "NuGet packages", detail: "Restored again on the next build",
               level: .safe, symbol: "shippingbox", group: .packageManagers, globs: ["~/.nuget/packages"]),
        CatDef(id: "bazel", name: "Bazel output base", detail: "Rebuilt by the next Bazel build (a full rebuild)",
               level: .safe, symbol: "hammer", group: .packageManagers, globs: bazel + ["~/Library/Caches/bazelisk"]),
        CatDef(id: "ccache", name: "ccache / sccache", detail: "Compiler caches; the next build is slower once",
               level: .safe, symbol: "hammer", group: .packageManagers, globs: ccache + ["~/Library/Caches/Mozilla.sccache"]),
        CatDef(id: "go-build", name: "Go build cache", detail: "Rebuilt by the next `go build`",
               level: .safe, symbol: "chevron.left.forwardslash.chevron.right", group: .packageManagers, globs: ["~/Library/Caches/go-build"]),
        CatDef(id: "go-mod", name: "Go module cache", detail: "Re-downloaded on next build; size shown is the whole cache",
               level: .safe, symbol: "chevron.left.forwardslash.chevron.right", group: .packageManagers,
               cmds: [["go", "clean", "-modcache"]], needs: "go", measure: ["~/go/pkg/mod"]),
        CatDef(id: "terraform", name: "Terraform plugin cache", detail: "Providers are downloaded again by `terraform init`",
               level: .safe, symbol: "cube", group: .packageManagers, globs: [terraform]),
        CatDef(id: "brew", name: "Homebrew old versions & downloads", detail: "Removes outdated formula versions and downloads (brew cleanup)",
               level: .safe, symbol: "mug", group: .packageManagers, cmds: [["brew", "cleanup", "-s", "--prune=all"]], needs: "brew",
               measure: ["~/Library/Caches/Homebrew"]),

        // ---- Xcode & mobile
        CatDef(id: "xcode-support", name: "Xcode device support files", detail: "Symbols copied from devices; re-created when a device is plugged in",
               level: .safe, symbol: "iphone", group: .xcode, selectable: true,
               globs: ["iOS", "watchOS", "tvOS", "visionOS"].map { "~/Library/Developer/Xcode/\($0) DeviceSupport/*" }),
        CatDef(id: "sim-caches", name: "Simulator caches", detail: "Rebuilt automatically by the iOS Simulator",
               level: .safe, symbol: "ipad.and.iphone", group: .xcode, globs: ["~/Library/Developer/CoreSimulator/Caches/*"]),
        CatDef(id: "sim-unavailable", name: "Simulators for runtimes no longer installed", detail: "Removes simulator devices whose runtime was deleted (xcrun simctl delete unavailable)",
               level: .safe, symbol: "iphone.slash", group: .xcode, cmds: [["xcrun", "simctl", "delete", "unavailable"]], needs: "xcrun"),
        CatDef(id: "xcode-previews", name: "SwiftUI previews & test devices", detail: "Preview and test simulators idle for a week; Xcode creates them again",
               level: .safe, symbol: "rectangle.on.rectangle", group: .xcode, minAgeDays: 7,
               globs: ["~/Library/Developer/Xcode/UserData/Previews/*", "~/Library/Developer/XCPGDevices/*", "~/Library/Developer/XCTestDevices/*"]),
        CatDef(id: "xcode-docs", name: "Xcode documentation cache", detail: "Rebuilt by Xcode when you open documentation",
               level: .safe, symbol: "book", group: .xcode,
               globs: ["~/Library/Developer/Xcode/DocumentationCache", "~/Library/Developer/Xcode/DocumentationIndex"]),
        CatDef(id: "xcode-device-logs", name: "Device logs (older than 30 days)", detail: "Crash and console logs copied from connected devices",
               level: .safe, symbol: "doc.text", group: .xcode, minAgeDays: 30, globs: ["~/Library/Developer/Xcode/iOS Device Logs/*"]),

        // ---- AI coding tools: Claude Code (age-gated by the retention setting unless noted)
        CatDef(id: "claude-cache", name: "Claude Code caches & logs", detail: "Shell snapshots, debug logs, paste cache and telemetry older than the retention period; regenerated automatically",
               level: .safe, symbol: "sparkles", group: .aiTools, useRetention: true,
               globs: ["~/.claude/shell-snapshots/*", "~/.claude/debug/*", "~/.claude/paste-cache/*", "~/.claude/statsig/*",
                       "~/.claude/telemetry/*"]),
        CatDef(id: "claude-state", name: "Claude Code old session state", detail: "To-do lists, file edit history (used by rewind) and session environments of old sessions",
               level: .caution, symbol: "sparkles", group: .aiTools, useRetention: true,
               globs: ["~/.claude/todos/*", "~/.claude/file-history/*", "~/.claude/session-env/*"]),
        CatDef(id: "claude-scratch", name: "Claude Code scratch folders", detail: "Temporary working folders of finished Claude Code runs, untouched for a day",
               level: .safe, symbol: "sparkles", group: .aiTools, minAgeDays: 1, deepAge: true, globs: [env.privateTmp + "/claude-*/*"]),
        CatDef(id: "claude-desktop-caches", name: "Claude desktop app caches", detail: "Web caches of the Claude app; rebuilt automatically",
               level: .safe, symbol: "bubble.left.and.bubble.right", group: .aiTools,
               globs: ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad/completed",
                       "Service Worker/CacheStorage"].map { "\(appSupport)/Claude/\($0)" }),
        CatDef(id: "claude-desktop-vm", name: "Claude desktop VM & downloaded runtimes", detail: "Virtual machine bundles and Claude Code builds used by the app; downloaded again when needed (large)",
               level: .caution, symbol: "bubble.left.and.bubble.right", group: .aiTools, selectable: true,
               globs: ["vm_bundles", "claude-code-vm", "claude-code"].map { "\(appSupport)/Claude/\($0)" }),

        // ---- AI coding tools: other agents
        CatDef(id: "codex-history", name: "Codex CLI sessions & logs", detail: "Session transcripts and logs older than the retention period",
               level: .caution, symbol: "terminal", group: .aiTools, useRetention: true,
               globs: ["~/.codex/sessions/*/*/*/*", "~/.codex/archived_sessions/*", "~/.codex/log/*", "~/.codex/logs_*.sqlite*"]),
        CatDef(id: "codex-cache", name: "Codex CLI caches", detail: "Shell snapshots and model lists; regenerated automatically",
               level: .safe, symbol: "terminal", group: .aiTools, minAgeDays: 1,
               globs: ["~/.codex/shell_snapshots/*", "~/.codex/models_cache.json"]),
        CatDef(id: "gemini-history", name: "Gemini CLI & Antigravity history", detail: "Chats, checkpoints and agent artifacts older than the retention period",
               level: .caution, symbol: "terminal", group: .aiTools, useRetention: true, deepAge: true,
               globs: ["~/.gemini/tmp/*", "~/.gemini/history/*", "~/.gemini/antigravity/conversations/*",
                       "~/.gemini/antigravity/brain/*", "~/.gemini/antigravity/code_tracker/*"]),
        CatDef(id: "copilot-history", name: "GitHub Copilot CLI sessions & logs", detail: "Session state and logs older than the retention period",
               level: .caution, symbol: "terminal", group: .aiTools, useRetention: true, deepAge: true,
               globs: ["~/.copilot/logs/*", "~/.copilot/session-state/*"]),
        CatDef(id: "continue-history", name: "Continue sessions & logs", detail: "Chat sessions and logs older than the retention period",
               level: .caution, symbol: "terminal", group: .aiTools, useRetention: true, deepAge: true,
               globs: ["~/.continue/sessions/*", "~/.continue/logs/*", "~/.continue/dev_data/*"]),
        CatDef(id: "continue-index", name: "Continue codebase index", detail: "Search index of your code; rebuilt when Continue re-indexes",
               level: .safe, symbol: "terminal", group: .aiTools, globs: ["~/.continue/index/*"]),
        CatDef(id: "aider-cache", name: "Aider caches", detail: "Model metadata and repo-map caches; rebuilt automatically",
               level: .safe, symbol: "terminal", group: .aiTools, globs: ["~/.aider/caches/*"]),
        CatDef(id: "claude-mem-history", name: "claude-mem logs & observer sessions", detail: "Worker logs and observer sessions older than the retention period; the memory database is never touched",
               level: .caution, symbol: "brain", group: .aiTools, useRetention: true,
               globs: ["~/.claude-mem/logs/*", "~/.claude-mem/observer-sessions/*"]),

        // ---- Personal data
        CatDef(id: "trash", name: "Trash", detail: "Permanent: emptied items cannot be recovered",
               level: .caution, symbol: "trash", group: .personal, globs: ["~/.Trash/*"]),
    ]
}
