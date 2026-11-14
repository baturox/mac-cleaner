// Cache locations taken from environment variables.
//
// Tools let the user move their caches (PLAYWRIGHT_BROWSERS_PATH, UV_CACHE_DIR, CCACHE_DIR, …). The engine
// honors that, but an environment variable is just a string somebody set: it may be stale, mistyped, or
// planted, and it may point at a folder full of documents. So for every such override:
//  * the folder is used only if its content has the shape the tool produces,
//  * only the entries that match that shape become items (never "everything in the folder"),
//  * the items are never labelled "safe", and the category says which variable named the folder.
// When the check fails the variable is ignored and only the tool's default location is scanned.
import Foundation

enum EnvOverride {
    /// The real path of the directory named by the first of `names` that is set, plus that variable's name.
    /// nil when unset, relative, not a directory, or so broad that it contains the home folder.
    static func directory(_ names: [String], env: EngineEnvironment, subpath: String = "") -> (path: String, variable: String)? {
        for name in names {
            guard let raw = env.variable(name) else { continue }
            let expanded = env.expand(raw.trimmingCharacters(in: .whitespaces)) + subpath
            guard expanded.hasPrefix("/"), let real = realPath(expanded), env.isDirectory(real), real != "/" else { return nil }
            if real == env.home || env.home.hasPrefix(real + "/") { return nil }
            return (real, name)
        }
        return nil
    }

    static func matches(_ name: String, _ pattern: String) -> Bool {
        name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Sentence added to a category's detail.
    static func note(_ variable: String, _ path: String, home: String) -> String {
        let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return "Location set by the environment variable \(variable) (\(shown)); only entries that look like this tool's data are listed."
    }
}

struct OverrideSpec: Sendable {
    var id: String
    var name: String
    var variable: String
    /// Appended to the variable's value (COMPOSER_HOME -> "<value>/cache").
    var subpath = ""
    /// The tool's default location; an override that resolves to it is left to the regular category.
    var defaultPath: String
    /// With a pattern here, items are looked for one level down, inside folders matching it (Puppeteer).
    var folderPattern: String? = nil
    /// An entry becomes an item only if its name matches.
    var entryPattern: String
    /// Any one of these directly inside the folder also proves the shape.
    var markers: [String] = []
    /// Without a marker, at least this many entries must match.
    var minMatches = 1
    /// With true a marker is required; matching entries alone are not enough.
    var requireMarker = false
    var regenerate: String
    var symbol = "shippingbox"
    var group: CategoryGroup = .packageManagers
}

enum OverrideScanner {
    static func specs(home: String) -> [OverrideSpec] {
        [
            OverrideSpec(id: "playwright-env", name: "Playwright browsers (custom location)", variable: "PLAYWRIGHT_BROWSERS_PATH",
                         defaultPath: home + "/Library/Caches/ms-playwright",
                         entryPattern: BrowserDownloadsScanner.playwrightEntry,
                         regenerate: "`npx playwright install` fetches them again", symbol: "safari", group: .aiTools),
            OverrideSpec(id: "puppeteer-env", name: "Puppeteer browsers (custom location)", variable: "PUPPETEER_CACHE_DIR",
                         defaultPath: home + "/.cache/puppeteer",
                         folderPattern: BrowserDownloadsScanner.puppeteerBrowser, entryPattern: BrowserDownloadsScanner.puppeteerBuild,
                         regenerate: "Puppeteer downloads them again on install", symbol: "safari", group: .aiTools),
            OverrideSpec(id: "uv-env", name: "uv cache (custom location)", variable: "UV_CACHE_DIR",
                         defaultPath: home + "/.cache/uv", entryPattern: "^[a-z]+-v[0-9]+$", markers: ["CACHEDIR.TAG"], minMatches: 2,
                         regenerate: "re-downloaded on the next install", symbol: "bolt.horizontal"),
            OverrideSpec(id: "composer-env", name: "Composer cache (custom location)", variable: "COMPOSER_HOME", subpath: "/cache",
                         defaultPath: home + "/.composer/cache", entryPattern: "^(files|repo|vcs)$",
                         regenerate: "re-downloaded on the next install"),
            OverrideSpec(id: "terraform-env", name: "Terraform plugin cache (custom location)", variable: "TF_PLUGIN_CACHE_DIR",
                         defaultPath: home + "/.terraform.d/plugin-cache", entryPattern: "^[a-z0-9-]+(\\.[a-z0-9-]+)+$",
                         markers: ["registry.terraform.io", "registry.opentofu.org"], requireMarker: true,
                         regenerate: "providers are downloaded again by `terraform init`", symbol: "cube"),
            OverrideSpec(id: "ccache-env", name: "ccache (custom location)", variable: "CCACHE_DIR",
                         defaultPath: home + "/.ccache", entryPattern: "^[0-9a-f]$", markers: ["ccache.conf", "CACHEDIR.TAG"], minMatches: 8,
                         regenerate: "the next build is slower once", symbol: "hammer"),
        ]
    }

    /// The entries of an override folder that have the expected shape; empty when the folder as a whole
    /// does not look like the tool's data.
    static func items(for spec: OverrideSpec, env: EngineEnvironment) -> (dir: String, paths: [String])? {
        guard let (dir, _) = EnvOverride.directory([spec.variable], env: env, subpath: spec.subpath) else { return nil }
        if dir == (realPath(spec.defaultPath) ?? spec.defaultPath) { return nil }
        guard let entries = readDir(dir) else { return nil }
        var paths: [String] = []
        if let folderPattern = spec.folderPattern {
            for folder in entries where folder.isDir && !folder.isLink && EnvOverride.matches(folder.name, folderPattern) {
                for e in readDir(dir + "/" + folder.name) ?? [] where e.isDir && !e.isLink && EnvOverride.matches(e.name, spec.entryPattern) {
                    paths.append(dir + "/" + folder.name + "/" + e.name)
                }
            }
        } else {
            paths = entries.filter { $0.isDir && !$0.isLink && EnvOverride.matches($0.name, spec.entryPattern) }.map { dir + "/" + $0.name }
        }
        let names = Set(entries.map(\.name))
        let hasMarker = spec.markers.contains { names.contains($0) }
        let shaped = hasMarker || (!spec.requireMarker && paths.count >= spec.minMatches)
        guard shaped, !paths.isEmpty else { return nil }
        return (dir, paths.filter { SafeGlob.accepts($0, realAnchor: dir, env: env) })
    }

    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        var out: [CleanCategory] = []
        for spec in specs(home: ctx.home) {
            guard let found = await onBackground({ items(for: spec, env: ctx.env) }) else { continue }
            ctx.progress("Measuring \(spec.name)…")
            // Not named `items`: older compilers report a circular reference with `items(for:env:)` above.
            let measured = await ctx.items(found.paths)
            let detail = "Rebuildable: \(spec.regenerate). " + EnvOverride.note(spec.variable, found.dir, home: ctx.home)
            if let c = ctx.category(id: spec.id, name: spec.name, detail: detail, level: .caution, symbol: spec.symbol,
                                    group: spec.group, items: measured, selectable: true) { out.append(c) }
        }
        return out
    }
}
