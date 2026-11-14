// Language toolchain versions installed by version managers. The default/active version of each manager is
// never offered; the rest are listed per version with a friendly label.
import Foundation

enum ToolchainScanner {
    struct Version: Equatable {
        var path: String
        var label: String
        /// Set when the manager's folder was named by an environment variable.
        var variable: String? = nil
    }

    /// A version manager's folder: the default, or the one an environment variable names.
    struct Root { var path: String; var variable: String? }

    static func root(_ ctx: ScanContext, _ names: [String], default def: String) -> Root {
        if let o = EnvOverride.directory(names, env: ctx.env) { return Root(path: o.path, variable: o.variable) }
        return Root(path: def, variable: nil)
    }

    /// A version folder is listed as-is in a default location. In a location that comes from an environment
    /// variable it must also contain something only a real installation has (`bin/node`, `bin/rustc`, …), so
    /// a variable pointing at an unrelated folder yields nothing.
    static func accepts(_ root: Root, _ versionPath: String, markers: [String], ctx: ScanContext) -> Bool {
        root.variable == nil || markers.contains { ctx.env.exists(versionPath + "/" + $0) }
    }

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
        let nvmRoot = root(ctx, ["NVM_DIR"], default: h + "/.nvm")
        let nvm = nvmRoot.path
        let nvmVersions = nvm + "/versions/node"
        let installed = versionDirs(nvmVersions).filter { accepts(nvmRoot, nvmVersions + "/" + $0, markers: ["bin/node"], ctx: ctx) }
        if !installed.isEmpty {
            let keep = nvmDefault(nvmDir: nvm, installed: installed)
            for v in installed where v != keep {
                out.append(Version(path: nvmVersions + "/" + v, label: "Node \(stripV(v)) (nvm)", variable: nvmRoot.variable))
            }
        }
        // fnm: the `default` alias is a symlink into node-versions/<v>/installation
        var fnmRoots = [h + "/Library/Application Support/fnm", h + "/.local/share/fnm", h + "/.fnm"].map { Root(path: $0, variable: nil) }
        if let o = EnvOverride.directory(["FNM_DIR"], env: ctx.env), !fnmRoots.contains(where: { $0.path == o.path }) {
            fnmRoots.insert(Root(path: o.path, variable: o.variable), at: 0)
        }
        for fnmRoot in fnmRoots {
            let fnm = fnmRoot.path
            let versions = fnm + "/node-versions"
            var keep: String?
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: fnm + "/aliases/default") {
                keep = dest.components(separatedBy: "/node-versions/").last?.components(separatedBy: "/").first
            }
            for v in versionDirs(versions) where v != keep && accepts(fnmRoot, versions + "/" + v, markers: ["installation/bin/node"], ctx: ctx) {
                out.append(Version(path: versions + "/" + v, label: "Node \(stripV(v)) (fnm)", variable: fnmRoot.variable))
            }
        }
        // Volta: platform.json names the default runtime and package managers
        let voltaRoot = root(ctx, ["VOLTA_HOME"], default: h + "/.volta")
        let volta = voltaRoot.path
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
            for v in versionDirs(volta + "/tools/image/" + tool) where !kept.contains("\(tool)/\(v)")
                && accepts(voltaRoot, volta + "/tools/image/\(tool)/\(v)", markers: ["bin/node", "bin", "package.json"], ctx: ctx) {
                out.append(Version(path: volta + "/tools/image/\(tool)/\(v)", label: "\(tool == "node" ? "Node" : tool) \(v) (Volta)",
                                   variable: voltaRoot.variable))
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
        let rustup = root(ctx, ["RUSTUP_HOME"], default: ctx.home + "/.rustup")
        let home = rustup.path
        let installed = versionDirs(home + "/toolchains").filter { accepts(rustup, home + "/toolchains/" + $0, markers: ["bin/rustc", "lib/rustlib"], ctx: ctx) }
        guard !installed.isEmpty else { return [] }
        let settings = readText(home + "/settings.toml")
        // Without a readable settings file nothing is known to be the default: offer nothing.
        guard let settings else { return [] }
        let kept = rustKept(settings: settings, installed: installed)
        return installed.filter { !kept.contains($0) }.map { Version(path: home + "/toolchains/" + $0, label: "Rust \($0)", variable: rustup.variable) }
    }

    // MARK: Python / Ruby

    static func pyenvVersions(_ ctx: ScanContext) -> [Version] {
        let pyenv = self.root(ctx, ["PYENV_ROOT"], default: ctx.home + "/.pyenv")
        let root = pyenv.path
        let installed = versionDirs(root + "/versions").filter { accepts(pyenv, root + "/versions/" + $0, markers: ["bin/python", "bin/python3"], ctx: ctx) }
        let requested = (readText(root + "/version") ?? "").split(whereSeparator: { $0 == ":" || $0.isNewline }).map(String.init)
        return installed.filter { name in !requested.contains { matches(name, requested: $0) } }
            .map { Version(path: root + "/versions/" + $0, label: "Python \($0) (pyenv)", variable: pyenv.variable) }
    }

    static func rbenvVersions(_ ctx: ScanContext) -> [Version] {
        let rbenv = self.root(ctx, ["RBENV_ROOT"], default: ctx.home + "/.rbenv")
        let root = rbenv.path
        let installed = versionDirs(root + "/versions").filter { accepts(rbenv, root + "/versions/" + $0, markers: ["bin/ruby"], ctx: ctx) }
        let requested = (readText(root + "/version") ?? "").split(whereSeparator: { $0 == ":" || $0.isNewline }).map(String.init)
        return installed.filter { name in !requested.contains { matches(name, requested: $0) } }
            .map { Version(path: root + "/versions/" + $0, label: "Ruby \($0) (rbenv)", variable: rbenv.variable) }
    }

    /// uv-managed interpreters: "cpython-3.12.1-macos-aarch64-none" -> "Python 3.12.1 (uv)".
    static func uvPythons(_ ctx: ScanContext) -> [Version] {
        let uv = root(ctx, ["UV_PYTHON_INSTALL_DIR"], default: ctx.home + "/.local/share/uv/python")
        let dir = uv.path
        return versionDirs(dir).filter { accepts(uv, dir + "/" + $0, markers: ["bin/python", "bin/python3"], ctx: ctx) }.map { name in
            let parts = name.split(separator: "-").map(String.init)
            let impl = parts.first == "cpython" ? "Python" : (parts.first ?? name).capitalized
            let version = parts.count > 1 ? parts[1] : name
            return Version(path: dir + "/" + name, label: "\(impl) \(version) (uv)", variable: uv.variable)
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
        func collect(_ base: Root, label: String) {
            // Custom locations: the folder must be laid out like the manager's data directory.
            if base.variable != nil && !(ctx.env.isDirectory(base.path + "/plugins") || ctx.env.isDirectory(base.path + "/shims")) { return }
            let installs = base.path + "/installs"
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
                    if base.variable != nil && v.first?.isNumber != true { continue }
                    out.append(Version(path: toolDir + "/" + v, label: "\(tool) \(v) (\(label))", variable: base.variable))
                }
            }
        }
        collect(root(ctx, ["ASDF_DATA_DIR"], default: h + "/.asdf"), label: "asdf")
        collect(root(ctx, ["MISE_DATA_DIR"], default: h + "/.local/share/mise"), label: "mise")
        return out
    }

    // MARK: Flutter / Android

    static func fvmVersions(_ ctx: ScanContext) -> [Version] {
        let fvm = root(ctx, ["FVM_CACHE_PATH"], default: ctx.home + "/fvm")
        let dir = fvm.path + "/versions"
        return versionDirs(dir).filter { accepts(fvm, dir + "/" + $0, markers: ["bin/flutter"], ctx: ctx) }
            .map { Version(path: dir + "/" + $0, label: "Flutter \($0) (FVM)", variable: fvm.variable) }
    }

    static func androidSDK(_ ctx: ScanContext) -> [Version] {
        let sdkRoot = root(ctx, ["ANDROID_HOME", "ANDROID_SDK_ROOT"], default: ctx.home + "/Library/Android/sdk")
        let sdk = sdkRoot.path
        // Every SDK package carries a source.properties file.
        func ok(_ path: String) -> Bool { accepts(sdkRoot, path, markers: ["source.properties"], ctx: ctx) }
        var out: [Version] = []
        for v in versionDirs(sdk + "/ndk") where ok(sdk + "/ndk/" + v) {
            out.append(Version(path: sdk + "/ndk/" + v, label: "Android NDK \(v)", variable: sdkRoot.variable))
        }
        // Keep the newest build-tools; older ones are rarely needed.
        let tools = versionDirs(sdk + "/build-tools").filter { ok(sdk + "/build-tools/" + $0) }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in tools.dropFirst() {
            out.append(Version(path: sdk + "/build-tools/" + v, label: "Android build-tools \(v)", variable: sdkRoot.variable))
        }
        for api in versionDirs(sdk + "/system-images") {
            for tag in versionDirs(sdk + "/system-images/" + api) {
                for abi in versionDirs(sdk + "/system-images/\(api)/\(tag)") where ok(sdk + "/system-images/\(api)/\(tag)/\(abi)") {
                    let level = api.replacingOccurrences(of: "android-", with: "")
                    out.append(Version(path: sdk + "/system-images/\(api)/\(tag)/\(abi)", label: "Android \(level) emulator image (\(tag), \(abi))",
                                       variable: sdkRoot.variable))
                }
            }
        }
        return out
    }

    static func androidAVDs(_ ctx: ScanContext) -> [Version] {
        let avd = root(ctx, ["ANDROID_AVD_HOME"], default: ctx.home + "/.android/avd")
        let dir = avd.path
        return (readDir(dir) ?? []).filter { $0.isDir && !$0.isLink && $0.name.hasSuffix(".avd") }
            .filter { accepts(avd, dir + "/" + $0.name, markers: ["config.ini"], ctx: ctx) }
            .map { Version(path: dir + "/" + $0.name, label: "Emulator " + String($0.name.dropLast(4)), variable: avd.variable) }
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
            var detail = g.detail
            let variables = Set(visible.compactMap(\.variable)).sorted()
            if !variables.isEmpty {
                detail += ". Some locations were set by the environment variable\(variables.count == 1 ? "" : "s") \(variables.joined(separator: ", ")); only folders that contain a real installation are listed"
            }
            if let c = ctx.category(id: g.id, name: g.name, detail: detail, level: .caution, symbol: "wrench.and.screwdriver",
                                    group: .toolchains, items: items, selectable: true) { out.append(c) }
        }
        return out
    }
}
