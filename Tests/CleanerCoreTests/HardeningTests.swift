import XCTest
@testable import CleanerCore

/// Findings 5, 6, 7, 10, 11 and 12.
final class HardeningTests: EngineTestCase {
    private let MB = 1 << 20

    // MARK: Finding 6 — environment variables cannot turn arbitrary folders into items

    private func documents(_ f: Fixture) throws {
        try f.file("Documents/Thesis/chapter1.docx", bytes: 3 * MB)
        try f.file("Documents/Taxes-2025/return.pdf", bytes: 2 * MB)
        try f.file("Projects/client-a/src/main.c", bytes: 2 * MB)
    }

    private func allItemPaths(_ f: Fixture) async -> [String] {
        let ctx = f.context()
        var cats = await OverrideScanner.scan(ctx)
        cats += await BrowserDownloadsScanner.scan(ctx)
        cats += await ModelsScanner.scan(ctx)
        cats += await ToolchainScanner.scan(ctx)
        for def in makeCategoryDefs(env: f.env) where ["uv", "composer", "terraform", "ccache"].contains(def.id) {
            if let c = await GenericScanner.measure(def, ctx: ctx) { cats.append(c) }
        }
        return cats.flatMap { $0.items.map(\.url.path) }
    }

    /// The exact exploit: PLAYWRIGHT_BROWSERS_PATH=~/Documents produced "safe" items for the user's documents.
    func testEnvironmentOverridesPointingAtDocumentsYieldNothing() async throws {
        let probe = try Fixture()
        let docs = probe.home + "/Documents", project = probe.home + "/Projects/client-a"
        // Every override variable the engine knows, all aimed at folders of the user's own files.
        var vars: [String: String] = [:]
        for v in ["PLAYWRIGHT_BROWSERS_PATH", "PUPPETEER_CACHE_DIR", "UV_CACHE_DIR", "CCACHE_DIR", "HF_HOME", "HF_HUB_CACHE",
                  "OLLAMA_MODELS", "NVM_DIR", "FNM_DIR", "VOLTA_HOME", "RUSTUP_HOME", "PYENV_ROOT", "RBENV_ROOT", "UV_PYTHON_INSTALL_DIR",
                  "ASDF_DATA_DIR", "MISE_DATA_DIR", "FVM_CACHE_PATH", "ANDROID_HOME", "ANDROID_AVD_HOME"] { vars[v] = docs }
        vars["TF_PLUGIN_CACHE_DIR"] = project
        vars["COMPOSER_HOME"] = probe.home + "/Projects"
        probe.env.vars = vars
        try documents(probe)
        // Folders whose names resemble what the managers keep, but which are the user's.
        for rel in ["Documents/versions/2019/report.docx", "Documents/versions/node/v1/notes.txt", "Documents/toolchains/drafts/a.txt",
                    "Documents/installs/python/3.12/budget.xlsx", "Documents/ndk/old/x", "Documents/hub/readme.txt", "Documents/cache/x",
                    "Documents/Holiday.avd/photo.jpg", "Projects/cache/notes/x"] {
            try probe.file(rel, bytes: MB)
        }
        try probe.file("Documents/settings.toml", "default_toolchain = \"x\"")
        let paths = await allItemPaths(probe)
        XCTAssertEqual(paths.filter { $0.hasPrefix(probe.home + "/Documents") || $0.hasPrefix(probe.home + "/Projects") }, [],
                       "an environment variable must never make the user's files look like cache")
    }

    func testValidPlaywrightOverrideListsOnlyBrowserBuildsAsCaution() async throws {
        let f = try Fixture()
        let custom = f.home + "/tools/pw"
        f.env.vars = ["PLAYWRIGHT_BROWSERS_PATH": custom]
        try f.file("tools/pw/chromium-1200/chrome", bytes: 2 * MB)
        try f.file("tools/pw/chromium_headless_shell-1200/x", bytes: 2 * MB)
        try f.file("tools/pw/firefox-1490/x", bytes: 2 * MB)
        try f.file("tools/pw/My Notes/todo.txt", bytes: 2 * MB)          // not Playwright's
        try f.file("tools/pw/chromium-backup/x", bytes: 2 * MB)          // no revision number
        try f.file("tools/pw/.links/x", "x")
        let cats = await OverrideScanner.scan(f.context())
        XCTAssertEqual(cats.map(\.id), ["playwright-env"])
        let c = cats[0]
        XCTAssertEqual(c.level, .caution, "items from an override are never 'safe'")
        XCTAssertTrue(c.itemsSelectable)
        XCTAssertTrue(c.detail.contains("PLAYWRIGHT_BROWSERS_PATH"), c.detail)
        XCTAssertEqual(Set(c.items.map { $0.url.lastPathComponent }), ["chromium-1200", "chromium_headless_shell-1200", "firefox-1490"])
        // The default-location category does not pick the override up as "safe".
        let regular = await BrowserDownloadsScanner.scan(f.context())
        XCTAssertTrue(regular.flatMap(\.items).isEmpty)
        // "0" means "inside node_modules": no folder at all.
        f.env.vars = ["PLAYWRIGHT_BROWSERS_PATH": "0"]
        let none = await OverrideScanner.scan(f.context())
        XCTAssertTrue(none.isEmpty)
    }

    func testOtherOverridesNeedTheirToolsShape() async throws {
        let f = try Fixture()
        f.env.vars = ["PUPPETEER_CACHE_DIR": "~/c/pptr", "UV_CACHE_DIR": f.home + "/c/uv", "TF_PLUGIN_CACHE_DIR": f.home + "/c/tf",
                      "CCACHE_DIR": f.home + "/c/ccache", "COMPOSER_HOME": f.home + "/c/composer"]
        try f.file("c/pptr/chrome/mac_arm-121.0.6167.85/x", bytes: 2 * MB); try f.file("c/pptr/chrome/readme/x", bytes: 2 * MB)
        try f.file("c/pptr/holiday-photos/2024/x", bytes: 2 * MB)
        try f.file("c/uv/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55")
        try f.file("c/uv/archive-v0/x", bytes: 2 * MB); try f.file("c/uv/wheels-v5/x", bytes: 2 * MB); try f.file("c/uv/drafts/x", bytes: 2 * MB)
        try f.file("c/tf/registry.terraform.io/hashicorp/aws/x", bytes: 2 * MB); try f.file("c/tf/notes/x", bytes: 2 * MB)
        try f.file("c/ccache/ccache.conf", "max_size = 5G"); try f.file("c/ccache/a/x", bytes: 2 * MB); try f.file("c/ccache/tmp/x", bytes: 2 * MB)
        try f.file("c/composer/cache/files/x", bytes: 2 * MB); try f.file("c/composer/cache/mine/x", bytes: 2 * MB)
        try f.file("c/composer/auth.json", "{}")
        let cats = await OverrideScanner.scan(f.context())
        let byId = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0) })
        func names(_ id: String) -> Set<String> { Set((byId[id]?.items ?? []).map { $0.url.lastPathComponent }) }
        XCTAssertEqual(names("puppeteer-env"), ["mac_arm-121.0.6167.85"])
        XCTAssertEqual(names("uv-env"), ["archive-v0", "wheels-v5"])
        XCTAssertEqual(names("terraform-env"), ["registry.terraform.io"])
        XCTAssertEqual(names("ccache-env"), ["a"])
        XCTAssertEqual(names("composer-env"), ["files"])
        XCTAssertTrue(cats.allSatisfy { $0.level == .caution && $0.detail.contains("environment variable") })
        XCTAssertTrue(byId["uv-env"]!.detail.contains("UV_CACHE_DIR"))
        XCTAssertTrue(cats.allSatisfy { $0.commands.isEmpty }, "an override never comes with a tool command")
    }

    func testOverrideSpecRejections() throws {
        let f = try Fixture()
        let spec = OverrideScanner.specs(home: f.home).first { $0.id == "uv-env" }!
        try f.file("x/uv/archive-v0/x", "x")                                                   // one bucket, no marker
        f.env.vars = ["UV_CACHE_DIR": f.home + "/x/uv"]
        XCTAssertNil(OverrideScanner.items(for: spec, env: f.env), "one matching name is not enough without the marker file")
        f.env.vars = ["UV_CACHE_DIR": "relative/path"]
        XCTAssertNil(OverrideScanner.items(for: spec, env: f.env))
        f.env.vars = ["UV_CACHE_DIR": f.home]
        XCTAssertNil(OverrideScanner.items(for: spec, env: f.env), "the home folder itself")
        f.env.vars = ["UV_CACHE_DIR": "/"]
        XCTAssertNil(OverrideScanner.items(for: spec, env: f.env))
        f.env.vars = ["UV_CACHE_DIR": (f.home as NSString).deletingLastPathComponent]
        XCTAssertNil(OverrideScanner.items(for: spec, env: f.env), "a folder that contains home")
        try f.file(".cache/uv/CACHEDIR.TAG", "x"); try f.file(".cache/uv/archive-v0/x", "x")
        f.env.vars = ["UV_CACHE_DIR": "~/.cache/uv"]
        XCTAssertNil(OverrideScanner.items(for: spec, env: f.env), "the default location is the regular category's business")
        // A symlink as the override resolves to its target, and matching entries that are links are skipped.
        try f.file("real/uv/CACHEDIR.TAG", "x"); try f.file("real/uv/archive-v0/x", "x")
        try f.symlink("real/uv/wheels-v5", to: f.home)
        try f.symlink("uvlink", to: f.path("real/uv"))
        f.env.vars = ["UV_CACHE_DIR": "~/uvlink"]
        XCTAssertEqual(OverrideScanner.items(for: spec, env: f.env)?.paths, [f.path("real/uv/archive-v0")])
    }

    func testToolchainOverrideNeedsRealInstallationsAndNamesTheVariable() async throws {
        let f = try Fixture()
        f.env.vars = ["PYENV_ROOT": f.home + "/py", "HF_HOME": "~/hf", "OLLAMA_MODELS": "~/Documents"]
        try f.file("py/versions/3.11.0/bin/python", bytes: 2 * MB)
        try f.file("py/versions/3.12.1/bin/python", bytes: 2 * MB)
        try f.file("py/versions/old-notes/readme.txt", bytes: 2 * MB)
        try f.file("py/version", "3.12.1")
        try f.file("hf/hub/models--org--name/blobs/b", bytes: 3 * MB)
        try f.file("hf/hub/My Photos/x.jpg", bytes: 3 * MB)
        try f.file("Documents/a.txt", bytes: MB)
        let ctx = f.context()
        let toolchains = await ToolchainScanner.scan(ctx)
        let python = try XCTUnwrap(toolchains.first { $0.id == "toolchain-python" })
        XCTAssertEqual(python.items.compactMap(\.label), ["Python 3.11.0 (pyenv)"])
        XCTAssertTrue(python.detail.contains("PYENV_ROOT"), python.detail)
        let models = await ModelsScanner.scan(ctx)
        let hf = try XCTUnwrap(models.first { $0.id == "hf-models" })
        XCTAssertEqual(hf.items.compactMap(\.label), ["org/name"])
        XCTAssertTrue(hf.detail.contains("HF_HOME"))
        XCTAssertNil(models.first { $0.id == "ollama-models" }, "OLLAMA_MODELS without Ollama's layout is ignored")
    }

    // MARK: Finding 7 — where tools come from

    private func tool(_ f: Fixture, _ rel: String, mode: mode_t = 0o755) throws -> String {
        let p = try f.file(rel, "#!/bin/sh\nexit 0\n")
        chmod(p, mode)
        chmod((p as NSString).deletingLastPathComponent, 0o755)
        return p
    }

    func testSystemToolsResolveOnlyFromSystemDirectories() throws {
        let f = try Fixture()
        let sys = f.path("sys/bin"), brew = f.path("brew/bin"), user = f.path("user/bin")
        _ = try tool(f, "brew/bin/git"); _ = try tool(f, "user/bin/git"); _ = try tool(f, "brew/bin/xcrun")
        try f.dir("sys/bin"); chmod(sys, 0o755)
        XCTAssertNil(ToolResolver.resolve("git", systemDirs: [sys], otherDirs: [brew, user]),
                     "a git in Homebrew or the home folder is never used")
        XCTAssertNil(ToolResolver.resolve("xcrun", systemDirs: [sys], otherDirs: [brew, user]))
        let real = try tool(f, "sys/bin/git")
        XCTAssertEqual(ToolResolver.resolve("git", systemDirs: [sys], otherDirs: [brew, user]), real)
        for t in ["git", "xcrun", "tmutil", "du", "diskutil", "sandbox-exec"] {
            XCTAssertTrue(ToolResolver.systemTools.contains(t), t)
            if let p = ToolResolver.resolve(t, otherDirs: ["/opt/homebrew/bin", "/usr/local/bin"]) {
                XCTAssertTrue(ToolResolver.systemDirs.contains((p as NSString).deletingLastPathComponent), p)
            }
        }
        XCTAssertEqual(ToolResolver.resolve("git", otherDirs: []), "/usr/bin/git")
        XCTAssertEqual(Git.executable, "/usr/bin/git")
    }

    func testThirdPartyToolsSearchSystemThenHomebrewThenHome() throws {
        let f = try Fixture()
        let sys = f.path("sys/bin"), brew = f.path("brew/bin"), user = f.path("user/bin")
        let inUser = try tool(f, "user/bin/pnpm")
        try f.dir("sys/bin"); try f.dir("brew/bin")
        XCTAssertEqual(ToolResolver.resolve("pnpm", systemDirs: [sys], otherDirs: [brew, user]), inUser)
        let inBrew = try tool(f, "brew/bin/pnpm")
        XCTAssertEqual(ToolResolver.resolve("pnpm", systemDirs: [sys], otherDirs: [brew, user]), inBrew)
        let inSys = try tool(f, "sys/bin/pnpm")
        XCTAssertEqual(ToolResolver.resolve("pnpm", systemDirs: [sys], otherDirs: [brew, user]), inSys)
        XCTAssertNil(ToolResolver.resolve("../pnpm", systemDirs: [sys], otherDirs: [brew]))
        XCTAssertNil(ToolResolver.resolve(inSys, systemDirs: [sys], otherDirs: [brew]), "absolute paths are never accepted")
        XCTAssertNil(ToolResolver.resolve("", systemDirs: [sys], otherDirs: [brew]))
        // The live search order: system directories are not in the third-party list, home folders come last.
        let dirs = ToolResolver.thirdPartyDirs(home: "/Users/x")
        XCTAssertEqual(Array(dirs.prefix(2)), ["/opt/homebrew/bin", "/usr/local/bin"])
        let firstHome = dirs.firstIndex { $0.hasPrefix("/Users/x/") }!
        XCTAssertTrue(dirs[firstHome...].allSatisfy { $0.hasPrefix("/Users/x/") }, "everything after the first home folder is a home folder")
    }

    func testToolsThatSomeoneElseCouldHaveWrittenAreRefused() throws {
        let f = try Fixture()
        let dir = f.path("t/bin")
        var st = stat()
        // Group write access is tolerated only for the admin group; fixtures are created with the user's group.
        func groupIsAdmin(_ p: String) -> Bool { lstat(p, &st) == 0 && st.st_gid == ToolResolver.adminGroup }
        let good = try tool(f, "t/bin/good")
        XCTAssertEqual(ToolResolver.resolve("good", systemDirs: [], otherDirs: [dir]), good)

        let worldWritable = try tool(f, "t/bin/ww", mode: 0o757)
        XCTAssertFalse(ToolResolver.isTrusted(worldWritable))
        XCTAssertNil(ToolResolver.resolve("ww", systemDirs: [], otherDirs: [dir]))
        let groupWritable = try tool(f, "t/bin/gw", mode: 0o775)
        if !groupIsAdmin(groupWritable) { XCTAssertNil(ToolResolver.resolve("gw", systemDirs: [], otherDirs: [dir])) }
        let notExecutable = try tool(f, "t/bin/noexec", mode: 0o644)
        XCTAssertFalse(ToolResolver.isTrusted(notExecutable))
        try f.dir("t/bin/adir")
        XCTAssertNil(ToolResolver.resolve("adir", systemDirs: [], otherDirs: [dir]), "a folder is not a program")

        // Wrong owner (simulated by asking on behalf of another account).
        XCTAssertFalse(ToolResolver.isTrusted(good, uid: getuid() &+ 1))
        XCTAssertNil(ToolResolver.resolve("good", systemDirs: [], otherDirs: [dir], uid: getuid() &+ 1))

        // A good file in a directory anyone can write to (the file could be swapped at any time).
        let open = f.path("open/bin")
        let inOpen = try tool(f, "open/bin/x")
        chmod(open, 0o777)
        XCTAssertFalse(ToolResolver.isTrusted(inOpen))
        XCTAssertFalse(ToolResolver.isTrustedDirectory(open))
        chmod(open, 0o775)
        if !groupIsAdmin(open) { XCTAssertFalse(ToolResolver.isTrustedDirectory(open)) }
        chmod(open, 0o755)
        XCTAssertTrue(ToolResolver.isTrusted(inOpen))

        // A symlink in a good directory whose target lives in a writable one.
        chmod(open, 0o777)
        try f.symlink("t/bin/linked", to: inOpen)
        XCTAssertNil(ToolResolver.resolve("linked", systemDirs: [], otherDirs: [dir]), "judged by where the file really is")
        chmod(open, 0o755)
        XCTAssertEqual(ToolResolver.resolve("linked", systemDirs: [], otherDirs: [dir]), dir + "/linked")
        try f.symlink("t/bin/dangling", to: f.path("nowhere"))
        XCTAssertNil(ToolResolver.resolve("dangling", systemDirs: [], otherDirs: [dir]))

        // An untrusted first hit means "not available"; the search does not quietly fall through.
        let second = f.path("second/bin")
        _ = try tool(f, "second/bin/ww")
        XCTAssertNil(ToolResolver.resolve("ww", systemDirs: [], otherDirs: [dir, second]))
    }

    // MARK: Finding 10 — data that becomes command arguments

    func testSimulatorDeviceIdentifiersMustBeUUIDsNamingTheirOwnFolder() throws {
        let f = try Fixture()
        let devices = "Library/Developer/CoreSimulator/Devices"
        func device(folder: String, udid: Any?) throws {
            let dir = try f.dir(devices + "/" + folder)
            var plist: [String: Any] = ["name": "iPhone 15", "state": 1, "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-4"]
            if let udid { plist["UDID"] = udid }
            try (plist as NSDictionary).write(to: URL(fileURLWithPath: dir + "/device.plist"))
        }
        let good = "11111111-2222-3333-4444-555555555555", other = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        try device(folder: good, udid: good)
        try device(folder: "22222222-2222-3333-4444-555555555555", udid: "all")             // the review's example
        try device(folder: "33333333-2222-3333-4444-555555555555", udid: "booted")
        try device(folder: "44444444-2222-3333-4444-555555555555", udid: other)             // another device's id
        try device(folder: "55555555-2222-3333-4444-555555555555", udid: nil)
        try device(folder: "66666666-2222-3333-4444-555555555555", udid: "-h")
        try device(folder: "not-a-uuid", udid: "not-a-uuid")
        let found = XcodeScanner.simulatorDevices(devicesDir: f.path(devices))
        XCTAssertEqual(found.map(\.udid), [good])
        XCTAssertTrue(CommandPolicy.isAllowed(["xcrun", "simctl", "delete", found[0].udid]))
    }

    func testOllamaManifestNamesThatAreNotModelReferencesAreSkipped() throws {
        let f = try Fixture()
        try f.file(".ollama/models/blobs/sha256-aaa", bytes: 8192)
        func manifest(_ rel: String) throws {
            try f.file(".ollama/models/manifests/" + rel, "{\"config\":{\"digest\":\"sha256:aaa\"},\"layers\":[]}")
        }
        try manifest("registry.ollama.ai/library/llama3/latest")
        try manifest("registry.ollama.ai/library/--help/latest")
        try manifest("registry.ollama.ai/library/-f/latest")
        try manifest("registry.ollama.ai/library/model/-tag")
        try manifest("registry.ollama.ai/library/has space/latest")
        try manifest("registry.ollama.ai/library/semi;colon/latest")
        try manifest("-host/ns/name/latest")
        let models = ModelsScanner.ollamaModels(base: f.path(".ollama/models"))
        // "model:-tag" stays: the argument starts with a letter, so no tool reads it as an option.
        XCTAssertEqual(Set(models.map(\.label)), ["llama3:latest", "model:-tag"])
        XCTAssertTrue(models.allSatisfy { CommandPolicy.isAllowed(["ollama", "rm", $0.label]) })
    }

    // MARK: Finding 11 — Docker only on this machine

    func testDockerEndpointParser() {
        XCTAssertEqual(ContainerScanner.parseLocalEndpoint("\"unix:///Users/me/.docker/run/docker.sock\"\n"), "unix:///Users/me/.docker/run/docker.sock")
        XCTAssertEqual(ContainerScanner.parseLocalEndpoint("unix:///var/run/docker.sock"), "unix:///var/run/docker.sock")
        XCTAssertEqual(ContainerScanner.parseLocalEndpoint("\"unix:///Users/me/.colima/default/docker.sock\""), "unix:///Users/me/.colima/default/docker.sock")
        for remote in ["\"tcp://10.0.0.5:2375\"", "\"tcp://localhost:2375\"", "\"ssh://root@prod.example.com\"", "\"npipe:////./pipe/docker_engine\"",
                       "\"https://docker.example.com\"", "", "\n", "\"\"", "null", "{}", "\"unix://relative.sock\"", "\"unix:///a/../../etc/x.sock\"",
                       "\"unix:///tmp/a.sock --tlsverify=false\"", "\"unix:///tmp/a.sock\nextra\"", "not json \"unix:///x\"", "\"fd://3\""] {
            XCTAssertNil(ContainerScanner.parseLocalEndpoint(remote), remote)
        }
    }

    func testDockerCategoriesOnlyForALocalDaemonAndCommandsNameIt() async throws {
        let df = """
        {"Active":"3","Reclaimable":"1.2GB (45%)","Size":"2.7GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"500MB","Size":"500MB","TotalCount":"7","Type":"Build Cache"}
        {"Active":"0","Reclaimable":"300MB","Size":"300MB","TotalCount":"2","Type":"Local Volumes"}
        """
        func scan(endpoint: String) async throws -> (cats: [CleanCategory], calls: [[String]]) {
            let tools = FakeTools(installed: ["docker"]) { argv in
                if argv.contains("context") { return FakeTools.ok("\"\(endpoint)\"\n") }
                if argv.contains("df") { return FakeTools.ok(df) }
                return FakeTools.fail("unexpected")
            }
            let f = try Fixture(tools: tools.box)
            return (await ContainerScanner.scan(f.context()), tools.calls)
        }
        let remote = try await scan(endpoint: "tcp://build-server.example.com:2376")
        XCTAssertTrue(remote.cats.isEmpty, "a remote daemon gets no cleanup categories")
        XCTAssertEqual(remote.calls.count, 1, "and is not even asked for its disk usage")
        let viaSSH = try await scan(endpoint: "ssh://root@prod")
        XCTAssertTrue(viaSSH.cats.isEmpty)

        let sock = "unix:///Users/me/.docker/run/docker.sock"
        let local = try await scan(endpoint: sock)
        XCTAssertEqual(Set(local.cats.map(\.id)), ["docker-images", "docker-build-cache", "docker-volumes"])
        XCTAssertEqual(local.calls.last, ["docker", "--host", sock, "system", "df", "--format", "{{json .}}"])
        for c in local.cats {
            XCTAssertTrue(c.detail.contains(sock), "the category shows which daemon it acts on")
            XCTAssertEqual(Array(c.commands[0].prefix(3)), ["docker", "--host", sock])
            XCTAssertTrue(CommandPolicy.isAllowed(c.commands[0]), c.commands[0].joined(separator: " "))
        }
        XCTAssertEqual(local.cats.first { $0.id == "docker-volumes" }?.level, .caution)
    }

    // MARK: Finding 12 — what "safe" may mean

    func testCategoriesHoldingDataThatDoesNotComeBackAreNotSafe() throws {
        let f = try Fixture()
        let defs = Dictionary(uniqueKeysWithValues: makeCategoryDefs(env: f.env).map { ($0.id, $0) })
        XCTAssertEqual(defs["maven"]?.level, .caution, "~/.m2/repository also holds locally installed artifacts")
        XCTAssertEqual(defs["poetry"]?.level, .safe)
        XCTAssertEqual(defs["poetry"]?.globs, ["~/Library/Caches/pypoetry/cache", "~/Library/Caches/pypoetry/artifacts"])
        XCTAssertEqual(defs["poetry-venvs"]?.level, .caution)
        XCTAssertEqual(defs["poetry-venvs"]?.selectable, true)
        XCTAssertEqual(defs["temp"]?.deepAge, true)
        // No category definition reads its location from the environment any more.
        let hostile = try Fixture(vars: ["UV_CACHE_DIR": "/Users/x/Documents", "COMPOSER_HOME": "/Users/x/Documents",
                                         "TF_PLUGIN_CACHE_DIR": "/Users/x/Documents", "CCACHE_DIR": "/Users/x/Documents"])
        for d in makeCategoryDefs(env: hostile.env) {
            XCTAssertFalse((d.globs + d.measure + d.fallbackGlobs).contains { $0.contains("Documents") }, d.id)
        }
    }

    func testPoetryVirtualenvsAreASeparateCautionCategory() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/pypoetry/cache/repositories/x", bytes: 2 * MB)
        try f.file("Library/Caches/pypoetry/artifacts/y", bytes: 2 * MB)
        try f.file("Library/Caches/pypoetry/virtualenvs/app-abc-py3.12/bin/python", bytes: 2 * MB)
        try f.file("Library/Caches/pypoetry/virtualenvs/api-def-py3.11/bin/python", bytes: 2 * MB)
        let defs = makeCategoryDefs(env: f.env)
        let measuredCache = await GenericScanner.measure(defs.first { $0.id == "poetry" }!, ctx: f.context())
        let cache = try XCTUnwrap(measuredCache)
        XCTAssertEqual(Set(cache.items.map { $0.url.lastPathComponent }), ["cache", "artifacts"])
        let measuredVenvs = await GenericScanner.measure(defs.first { $0.id == "poetry-venvs" }!, ctx: f.context())
        let venvs = try XCTUnwrap(measuredVenvs)
        XCTAssertEqual(venvs.level, .caution)
        XCTAssertTrue(venvs.itemsSelectable)
        XCTAssertEqual(Set(venvs.items.map { $0.url.lastPathComponent }), ["app-abc-py3.12", "api-def-py3.11"])
        let caches = defs.first { $0.id == "caches" }!
        XCTAssertFalse(GenericScanner.itemPaths(of: caches, globs: caches.globs, ctx: f.context()).contains { $0.contains("pypoetry") })
    }

    func testWorkspaceIsOrphanedOnlyWhenMissingOnTheLocalDisk() throws {
        let f = try Fixture()
        try f.dir("code/alive")
        XCTAssertTrue(IDEScanner.isMissingOnLocalDisk(f.path("code/deleted"), home: f.home))
        XCTAssertTrue(IDEScanner.isMissingOnLocalDisk(f.path("gone/deeper/still"), home: f.home))
        XCTAssertFalse(IDEScanner.isMissingOnLocalDisk(f.path("code/alive"), home: f.home), "it exists")
        XCTAssertFalse(IDEScanner.isMissingOnLocalDisk("/Volumes/Backup/proj", home: f.home), "an external volume, mounted or not")
        XCTAssertFalse(IDEScanner.isMissingOnLocalDisk("/Volumes/NotMounted-\(UUID().uuidString)/proj", home: f.home))
        XCTAssertFalse(IDEScanner.isMissingOnLocalDisk("/Volumes", home: f.home))
        // A folder below a mount point on another device (here: /dev, a different file system) is not "local".
        XCTAssertFalse(IDEScanner.isMissingOnLocalDisk("/dev/definitely-missing/proj", home: f.home))
    }

    // MARK: Finding 5 — one settings file for the app and the command line tool

    func testSettingsStoreRoundTripMissingAndCorrupt() throws {
        let f = try Fixture()
        let store = SettingsStore(directory: URL(fileURLWithPath: f.root + "/history"))
        XCTAssertEqual(store.load(), .missing)
        XCTAssertEqual(store.load().settings, EngineSettings(), "defaults when there is no file")
        let s = EngineSettings(protectedPaths: ["~/Work/Client", "/Volumes/Photos"], sessionRetentionDays: 14)
        XCTAssertTrue(store.save(s))
        XCTAssertEqual(store.load(), .loaded(s))
        XCTAssertNil(store.load().problem)
        var st = stat(); lstat(store.fileURL.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root + "/history"), ["settings.json"], "atomic write leaves no temp file")

        for bad in ["{ not json", "", "[]", "{\"version\":1}", "{\"version\":1,\"protectedPaths\":\"~/x\",\"sessionRetentionDays\":30}",
                    "{\"version\":2,\"protectedPaths\":[],\"sessionRetentionDays\":30}",
                    "{\"version\":1,\"protectedPaths\":[],\"sessionRetentionDays\":-5}"] {
            try bad.write(to: store.fileURL, atomically: true, encoding: .utf8)
            let r = store.load()
            XCTAssertNotNil(r.problem, bad)
            XCTAssertEqual(r.settings, EngineSettings(), "a corrupt file never yields half-read settings")
        }
        // Unknown keys are tolerated (forward compatibility); a later save repairs a corrupt file.
        try "{\"version\":1,\"protectedPaths\":[\"~/a\"],\"sessionRetentionDays\":7,\"future\":true}".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), .loaded(EngineSettings(protectedPaths: ["~/a"], sessionRetentionDays: 7)))
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertNotNil(store.load().problem, "a folder where the file should be")
    }

    func testSettingsFileLocationIsProtected() throws {
        let f = try Fixture()
        try f.file("Library/Application Support/MacCleaner/settings.json", "{}")
        let d = f.deleter()
        XCTAssertFalse(d.isAllowed(f.path("Library/Application Support/MacCleaner/settings.json")))
        XCTAssertFalse(d.isAllowed(f.path("Library/Application Support/MacCleaner")))
        XCTAssertEqual(SettingsStore.standard.fileURL.path, EngineEnvironment.live.home + "/Library/Application Support/MacCleaner/settings.json")
        XCTAssertTrue(ProtectedLocations.builtIn().contains("~/Library/Application Support/MacCleaner"))
        XCTAssertTrue(ProtectedLocations.builtIn().contains("~/.ssh"))
    }

    func testSettingsFromTheStoreProtectScansAndDeletion() async throws {
        let f = try Fixture()
        let store = SettingsStore(directory: f.env.historyDir)
        store.save(EngineSettings(protectedPaths: ["~/work/keep"], sessionRetentionDays: 30))
        try f.file("work/keep/node_modules/x", bytes: 5000)
        try f.file("work/drop/node_modules/x", bytes: 5000)
        let engine = f.engine()
        await engine.configure(store.load().settings)
        let found = await engine.scanProjects(root: URL(fileURLWithPath: f.home), minBytes: 1, progress: { _ in })
        XCTAssertEqual(found.map(\.url.path), [f.path("work/drop/node_modules")])
        let r = await engine.delete(urls: [URL(fileURLWithPath: f.path("work/keep/node_modules"))], progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("work/keep/node_modules/x"))
    }
}
