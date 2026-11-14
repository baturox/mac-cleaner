// Category table, ported from the Python tool's CATS.
import Foundation

struct CatDef {
    var id: String
    var name: String
    var detail: String
    var level: SafetyLevel
    var symbol: String
    var globs: [String] = []
    var exclude: Set<String> = []
    var minAgeDays: Int = 0
    var cmds: [[String]] = []
    var needs: String = ""
    var measure: [String] = []
}

enum Roots {
    /// Real path of the home directory.
    static let home: String = realPath(NSHomeDirectory()) ?? NSHomeDirectory()
    /// Real path of the per-user temp dir (…/T), no trailing slash.
    static let tmp: String = {
        var t = realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        return t
    }()
    /// /private/var/folders/xx/yyyy, or nil if the temp dir is somewhere else.
    static let varFolders: String? = tmp.hasPrefix("/private/var/folders/") ? (tmp as NSString).deletingLastPathComponent : nil
}

private let appSupport = "~/Library/Application Support"
private let electronDirs = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
                            "DawnWebGPUCache", "CachedData", "CachedExtensionVSIXs",
                            "Service Worker/CacheStorage", "Service Worker/ScriptCache", "Crashpad/completed"]
private let chromium = ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Chromium"]

let categoryDefs: [CatDef] = {
    var appCacheGlobs = electronDirs.map { "\(appSupport)/*/\($0)" }
    for b in chromium { for d in electronDirs { appCacheGlobs.append("\(appSupport)/\(b)/*/\(d)") } }
    for b in chromium { for d in ["GrShaderCache", "ShaderCache", "component_crx_cache"] { appCacheGlobs.append("\(appSupport)/\(b)/\(d)") } }

    var tempGlobs = [Roots.tmp + "/*", "/private/tmp/*"]
    if let v = Roots.varFolders { tempGlobs.append(v + "/C/*") }

    return [
        CatDef(id: "caches", name: "User caches", detail: "Rebuilt automatically by apps (includes Homebrew, pip, Go build, Playwright, browsers)",
               level: .safe, symbol: "folder", globs: ["~/Library/Caches/*"]),
        CatDef(id: "logs", name: "User logs & crash reports", detail: "Old log and crash report files; apps write new ones",
               level: .safe, symbol: "doc.text", globs: ["~/Library/Logs/*", "\(appSupport)/CrashReporter/*"]),
        CatDef(id: "temp", name: "Temp files older than 7 days", detail: "Leftovers in temporary folders that nothing has touched for a week",
               level: .safe, symbol: "clock", globs: tempGlobs, minAgeDays: 7),
        CatDef(id: "app-caches", name: "App caches (VS Code, Slack, Chrome, Electron…)", detail: "Web and shader caches inside app data; quit the apps first for a clean result",
               level: .safe, symbol: "app.dashed", globs: appCacheGlobs),
        CatDef(id: "xcode-derived", name: "Xcode DerivedData", detail: "Build products; the next build is a full rebuild",
               level: .safe, symbol: "hammer", globs: ["~/Library/Developer/Xcode/DerivedData/*"]),
        CatDef(id: "xcode-support", name: "Xcode device support files", detail: "Symbols copied from devices; re-created when a device is plugged in",
               level: .safe, symbol: "iphone", globs: ["iOS", "watchOS", "tvOS", "visionOS"].map { "~/Library/Developer/Xcode/\($0) DeviceSupport/*" }),
        CatDef(id: "sim-caches", name: "Simulator caches", detail: "Rebuilt automatically by the iOS Simulator",
               level: .safe, symbol: "ipad.and.iphone", globs: ["~/Library/Developer/CoreSimulator/Caches/*"]),
        CatDef(id: "sim-unavailable", name: "Simulators for runtimes no longer installed", detail: "Removes simulator devices whose runtime was deleted (xcrun simctl delete unavailable)",
               level: .safe, symbol: "iphone.slash", cmds: [["xcrun", "simctl", "delete", "unavailable"]], needs: "xcrun"),
        CatDef(id: "npm", name: "npm / npx cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "shippingbox", globs: ["~/.npm/_cacache", "~/.npm/_npx", "~/.npm/_logs"]),
        CatDef(id: "bun", name: "Bun install cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "bolt", globs: ["~/.bun/install/cache"]),
        CatDef(id: "yarn", name: "Yarn cache", detail: "Re-downloaded on the next install",
               level: .safe, symbol: "shippingbox", globs: ["~/.yarn/berry/cache", "~/.yarn/cache"]),
        CatDef(id: "pnpm", name: "pnpm store (unreferenced packages)", detail: "Size is the whole store; only packages no project uses are removed",
               level: .safe, symbol: "shippingbox", cmds: [["pnpm", "store", "prune"]], needs: "pnpm", measure: ["~/Library/pnpm/store"]),
        CatDef(id: "cargo", name: "Cargo registry cache", detail: "Re-downloaded on the next build",
               level: .safe, symbol: "gearshape.2", globs: ["~/.cargo/registry/cache", "~/.cargo/registry/src"]),
        CatDef(id: "gradle", name: "Gradle caches", detail: "Re-downloaded on the next build",
               level: .safe, symbol: "gearshape", globs: ["~/.gradle/caches", "~/.gradle/daemon"]),
        CatDef(id: "xdg-cache", name: "~/.cache (misc CLI tools)", detail: "Rebuilt automatically by command-line tools",
               level: .safe, symbol: "terminal", globs: ["~/.cache/*"], exclude: ["huggingface"]),
        CatDef(id: "brew", name: "Homebrew old versions", detail: "Removes outdated formula versions and downloads (brew cleanup)",
               level: .safe, symbol: "mug", cmds: [["brew", "cleanup", "-s", "--prune=all"]], needs: "brew"),
        CatDef(id: "snapshots", name: "Time Machine local snapshots", detail: "Deleted data stays on disk until these go",
               level: .safe, symbol: "clock.arrow.circlepath", needs: "tmutil"),
        CatDef(id: "trash", name: "Trash", detail: "Permanent: emptied items cannot be recovered",
               level: .caution, symbol: "trash", globs: ["~/.Trash/*"]),
        CatDef(id: "xcode-archives", name: "Xcode archives", detail: "Needed to symbolicate crashes of builds you shipped",
               level: .caution, symbol: "archivebox", globs: ["~/Library/Developer/Xcode/Archives/*"]),
        CatDef(id: "ios-backups", name: "iPhone/iPad local backups", detail: "Your only copy if you do not back up to iCloud",
               level: .caution, symbol: "iphone.gen3", globs: ["\(appSupport)/MobileSync/Backup/*"]),
        CatDef(id: "go-mod", name: "Go module cache", detail: "Re-downloaded on next build; size shown is the whole cache",
               level: .caution, symbol: "chevron.left.forwardslash.chevron.right", cmds: [["go", "clean", "-modcache"]], needs: "go",
               measure: ["~/go/pkg/mod"]),
        CatDef(id: "hf-models", name: "Hugging Face downloaded models", detail: "Large model files; re-downloaded when needed",
               level: .caution, symbol: "brain", globs: ["~/.cache/huggingface/hub/*"]),
        CatDef(id: "docker", name: "Docker unused images, containers, build cache", detail: "Size shown is the whole Docker disk; volumes are kept",
               level: .caution, symbol: "shippingbox.circle",
               cmds: [["docker", "system", "prune", "-af"], ["docker", "builder", "prune", "-af"]], needs: "docker",
               measure: ["~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw"]),
    ]
}()
