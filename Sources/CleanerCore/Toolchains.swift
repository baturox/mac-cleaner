// Language toolchain versions installed by version managers. The default/active version of each manager is
// never offered; the rest are listed per version with a friendly label.
import Foundation

enum ToolchainScanner {
    struct Version: Equatable { var path: String; var label: String }

    private static func readText(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripV(_ s: String) -> String { s.hasPrefix("v") ? String(s.dropFirst()) : s }

    /// Version directories (real directories only, never symlinks) directly inside `dir`.
    private static func versionDirs(_ dir: String) -> [String] {
        (readDir(dir) ?? []).filter { $0.isDir && !$0.isLink && !$0.name.hasPrefix(".") }.map(\.name)
    }

    /// Does the installed version `name` satisfy a requested version like "22", "22.1", "v22.1.3"?
    static func matches(_ name: String, requested: String) -> Bool {
        let n = stripV(name), r = stripV(requested)
        return n == r || n.hasPrefix(r + ".")
    }

    // MARK: Node

    /// Resolves nvm's `default` alias to an installed version name (aliases may point at other aliases).
    /// When it cannot be resolved the highest installed version is returned, so something is always kept.
    static func nvmDefault(nvmDir: String, installed: [String]) -> String? {
        let highest = installed.sorted { stripV($0).compare(stripV($1), options: .numeric) == .orderedDescending }.first
        var value = readText(nvmDir + "/alias/default")
        var hops = 0
        while let v = value, hops < 6 {
            hops += 1
            if let hit = installed.filter({ matches($0, requested: v) })
                .sorted(by: { stripV($0).compare(stripV($1), options: .numeric) == .orderedDescending }).first { return hit }
            if v == "node" || v == "stable" { return highest }
            value = readText(nvmDir + "/alias/" + v)
        }
        return highest
    }

    static func nodeVersions(_ ctx: ScanContext) -> [Version] {
        var out: [Version] = []
        let h = ctx.home
        // nvm
        let nvm = ctx.env.variable("NVM_DIR").map(ctx.env.expand) ?? h + "/.nvm"
        let nvmVersions = nvm + "/versions/node"
        let installed = versionDirs(nvmVersions)
        if !installed.isEmpty {
            let keep = nvmDefault(nvmDir: nvm, installed: installed)
            for v in installed where v != keep { out.append(Version(path: nvmVersions + "/" + v, label: "Node \(stripV(v)) (nvm)")) }
        }
        // fnm: the `default` alias is a symlink into node-versions/<v>/installation
        for fnm in [ctx.env.variable("FNM_DIR").map(ctx.env.expand), h + "/Library/Application Support/fnm", h + "/.local/share/fnm", h + "/.fnm"].compactMap({ $0 }) {
            let versions = fnm + "/node-versions"
            var keep: String?
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: fnm + "/aliases/default") {
                keep = dest.components(separatedBy: "/node-versions/").last?.components(separatedBy: "/").first
            }
            for v in versionDirs(versions) where v != keep {
                out.append(Version(path: versions + "/" + v, label: "Node \(stripV(v)) (fnm)"))
            }
        }
        // Volta: platform.json names the default runtime and package managers
        let volta = ctx.env.variable("VOLTA_HOME").map(ctx.env.expand) ?? h + "/.volta"
        var kept = Set<String>()
        if let data = FileManager.default.contents(atPath: volta + "/tools/user/platform.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let node = obj["node"] as? [String: Any] {
                if let r = node["runtime"] as? String { kept.insert("node/" + r) }
                if let n = node["npm"] as? String { kept.insert("npm/" + n) }
            }
            for tool in ["yarn", "pnpm"] { if let v = obj[tool] as? String { kept.insert("\(tool)/\(v)") } }
        }
        for tool in ["node", "npm", "yarn", "pnpm"] {
            for v in versionDirs(volta + "/tools/image/" + tool) where !kept.contains("\(tool)/\(v)") {
                out.append(Version(path: volta + "/tools/image/\(tool)/\(v)", label: "\(tool == "node" ? "Node" : tool) \(v) (Volta)"))
            }
        }
        return out
    }

    // MARK: Rust

    /// Toolchain directory names that rustup's `settings.toml` mentions (default toolchain and overrides).
    static func rustKept(settings: String, installed: [String]) -> Set<String> {
        var quoted: [String] = []
        for line in settings.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            // Odd-indexed parts sit between quotes.
            for (i, p) in parts.enumerated() where i % 2 == 1 { quoted.append(String(p)) }
        }
        var kept = Set<String>()
        for name in installed {
            if quoted.contains(where: { $0 == name || name.hasPrefix($0 + "-") }) { kept.insert(name) }
        }
        return kept
    }

    static func rustToolchains(_ ctx: ScanContext) -> [Version] {
        let home = ctx.env.variable("RUSTUP_HOME").map(ctx.env.expand) ?? ctx.home + "/.rustup"
        let installed = versionDirs(home + "/toolchains")
        guard !installed.isEmpty else { return [] }
        let settings = readText(home + "/settings.toml")
        // Without a readable settings file nothing is known to be the default: offer nothing.
        guard let settings else { return [] }
        let kept = rustKept(settings: settings, installed: installed)
        return installed.filter { !kept.contains($0) }.map { Version(path: home + "/toolchains/" + $0, label: "Rust \($0)") }
    }

    // MARK: Python / Ruby

    static func pyenvVersions(_ ctx: ScanContext) -> [Version] {
        let root = ctx.env.variable("PYENV_ROOT").map(ctx.env.expand) ?? ctx.home + "/.pyenv"
        let installed = versionDirs(root + "/versions")
        let requested = (readText(root + "/version") ?? "").split(whereSeparator: { $0 == ":" || $0.isNewline }).map(String.init)
        return installed.filter { name in !requested.contains { matches(name, requested: $0) } }
            .map { Version(path: root + "/versions/" + $0, label: "Python \($0) (pyenv)") }
    }

    static func rbenvVersions(_ ctx: ScanContext) -> [Version] {
        let root = ctx.env.variable("RBENV_ROOT").map(ctx.env.expand) ?? ctx.home + "/.rbenv"
        let installed = versionDirs(root + "/versions")
        let requested = (readText(root + "/version") ?? "").split(whereSeparator: { $0 == ":" || $0.isNewline }).map(String.init)
        return installed.filter { name in !requested.contains { matches(name, requested: $0) } }
            .map { Version(path: root + "/versions/" + $0, label: "Ruby \($0) (rbenv)") }
    }

    /// uv-managed interpreters: "cpython-3.12.1-macos-aarch64-none" -> "Python 3.12.1 (uv)".
    static func uvPythons(_ ctx: ScanContext) -> [Version] {
        let dir = ctx.env.variable("UV_PYTHON_INSTALL_DIR").map(ctx.env.expand) ?? ctx.home + "/.local/share/uv/python"
        return versionDirs(dir).map { name in
            let parts = name.split(separator: "-").map(String.init)
            let impl = parts.first == "cpython" ? "Python" : (parts.first ?? name).capitalized
            let version = parts.count > 1 ? parts[1] : name
            return Version(path: dir + "/" + name, label: "\(impl) \(version) (uv)")
        }
    }

    // MARK: asdf / mise

    /// Versions named in a `.tool-versions` or mise config (`tool version` / `tool = "version"`).
    static func pinnedVersions(files: [String]) -> [String: [String]] {
        var pins: [String: [String]] = [:]
        for f in files {
            guard let text = readText(f) else { continue }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let cleaned = line.replacingOccurrences(of: "=", with: " ").replacingOccurrences(of: "\"", with: " ")
                    .replacingOccurrences(of: "'", with: " ").replacingOccurrences(of: ",", with: " ")
                    .replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " ")
                let words = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard words.count >= 2 else { continue }
                pins[words[0], default: []] += words.dropFirst().filter { $0.first?.isNumber == true || $0 == "latest" || $0 == "lts" }
            }
        }
        return pins
    }

    static func asdfAndMise(_ ctx: ScanContext) -> [Version] {
        let h = ctx.home
        var out: [Version] = []
        let pins = pinnedVersions(files: [h + "/.tool-versions", h + "/.config/mise/config.toml", h + "/.mise.toml"])
        func collect(_ installs: String, label: String) {
            for tool in versionDirs(installs) {
                let toolDir = installs + "/" + tool
                // mise keeps symlinks like "22" or "latest" pointing at real version folders: those targets are in use.
                var linked = Set<String>()
                for e in readDir(toolDir) ?? [] where e.isLink {
                    if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: toolDir + "/" + e.name) {
                        linked.insert((dest as NSString).lastPathComponent)
                    }
                }
                let requested = (pins[tool] ?? []) + (tool == "nodejs" ? pins["node"] ?? [] : [])
                for v in versionDirs(toolDir) where !linked.contains(v) && !requested.contains(where: { $0 == "latest" || matches(v, requested: $0) }) {
                    out.append(Version(path: toolDir + "/" + v, label: "\(tool) \(v) (\(label))"))
                }
            }
        }
        collect(ctx.env.variable("ASDF_DATA_DIR").map(ctx.env.expand).map { $0 + "/installs" } ?? h + "/.asdf/installs", label: "asdf")
        collect(ctx.env.variable("MISE_DATA_DIR").map(ctx.env.expand).map { $0 + "/installs" } ?? h + "/.local/share/mise/installs", label: "mise")
        return out
    }

    // MARK: Flutter / Android

    static func fvmVersions(_ ctx: ScanContext) -> [Version] {
        let dir = ctx.env.variable("FVM_CACHE_PATH").map(ctx.env.expand).map { $0 + "/versions" } ?? ctx.home + "/fvm/versions"
        return versionDirs(dir).map { Version(path: dir + "/" + $0, label: "Flutter \($0) (FVM)") }
    }

    static func androidSDK(_ ctx: ScanContext) -> [Version] {
        let sdk = (ctx.env.variable("ANDROID_HOME") ?? ctx.env.variable("ANDROID_SDK_ROOT")).map(ctx.env.expand)
            ?? ctx.home + "/Library/Android/sdk"
        var out: [Version] = []
        for v in versionDirs(sdk + "/ndk") { out.append(Version(path: sdk + "/ndk/" + v, label: "Android NDK \(v)")) }
        // Keep the newest build-tools; older ones are rarely needed.
        let tools = versionDirs(sdk + "/build-tools").sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in tools.dropFirst() { out.append(Version(path: sdk + "/build-tools/" + v, label: "Android build-tools \(v)")) }
        for api in versionDirs(sdk + "/system-images") {
            for tag in versionDirs(sdk + "/system-images/" + api) {
                for abi in versionDirs(sdk + "/system-images/\(api)/\(tag)") {
                    let level = api.replacingOccurrences(of: "android-", with: "")
                    out.append(Version(path: sdk + "/system-images/\(api)/\(tag)/\(abi)", label: "Android \(level) emulator image (\(tag), \(abi))"))
                }
            }
        }
        return out
    }

    static func androidAVDs(_ ctx: ScanContext) -> [Version] {
        let dir = ctx.env.variable("ANDROID_AVD_HOME").map(ctx.env.expand) ?? ctx.home + "/.android/avd"
        return (readDir(dir) ?? []).filter { $0.isDir && !$0.isLink && $0.name.hasSuffix(".avd") }.map {
            Version(path: dir + "/" + $0.name, label: "Emulator " + String($0.name.dropLast(4)))
        }
    }

    // MARK: Scan

    static func scan(_ ctx: ScanContext) async -> [CleanCategory] {
        ctx.progress("Measuring language toolchains…")
        struct Group: Sendable { var id: String; var name: String; var detail: String; var versions: [Version] }
        let groups: [Group] = await onBackground {
            [
                Group(id: "toolchain-node", name: "Node.js versions", detail: "Versions installed by nvm, fnm and Volta except the default one; reinstall with the manager", versions: nodeVersions(ctx)),
                Group(id: "toolchain-rust", name: "Rust toolchains", detail: "Toolchains other than the default; reinstall with rustup", versions: rustToolchains(ctx)),
                Group(id: "toolchain-python", name: "Python versions", detail: "pyenv and uv-managed interpreters; virtual environments built on them stop working", versions: pyenvVersions(ctx) + uvPythons(ctx)),
                Group(id: "toolchain-ruby", name: "Ruby versions", detail: "rbenv versions other than the global one", versions: rbenvVersions(ctx)),
                Group(id: "toolchain-asdf", name: "asdf / mise installs", detail: "Tool versions not pinned in .tool-versions or the global mise config", versions: asdfAndMise(ctx)),
                Group(id: "toolchain-flutter", name: "Flutter SDKs (FVM)", detail: "Flutter versions cached by FVM; projects re-download the one they pin", versions: fvmVersions(ctx)),
                Group(id: "toolchain-android-sdk", name: "Android SDK components", detail: "NDKs, older build-tools and emulator system images; reinstall in the SDK Manager", versions: androidSDK(ctx)),
                Group(id: "android-avds", name: "Android emulators (AVDs)", detail: "Virtual devices with their data; Android Studio may show a leftover entry until you remove it", versions: androidAVDs(ctx)),
            ]
        }
        var out: [CleanCategory] = []
        for g in groups where !g.versions.isEmpty {
            let visible = g.versions.filter { ctx.visible($0.path) }
            let labels = Dictionary(visible.map { ($0.path, $0.label) }, uniquingKeysWith: { a, _ in a })
            let items = await ctx.items(visible.map(\.path), labels: labels)
            if let c = ctx.category(id: g.id, name: g.name, detail: g.detail, level: .caution, symbol: "wrench.and.screwdriver",
                                    group: .toolchains, items: items, selectable: true) { out.append(c) }
        }
        return out
    }
}
