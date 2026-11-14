import XCTest
@testable import CleanerCore

final class ScanTests: EngineTestCase {
    // MARK: Glob expansion & age

    func testExpandPatternIncludesDotfilesForTrailingStar() throws {
        let f = try Fixture()
        try f.file("cache/.hidden/a")
        try f.file("cache/visible/b")
        try f.file("cache/.dotfile")
        let names = Set(expandPattern("~/cache/*", home: f.home).map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(names, [".hidden", "visible", ".dotfile"])
    }

    func testExpandPatternExpandsTildeAgainstInjectedHome() throws {
        let f = try Fixture()
        try f.file("a1/x"); try f.file("a2/x"); try f.file("b/x")
        let hits = expandPattern("~/a*", home: f.home).sorted()
        XCTAssertEqual(hits, [f.path("a1"), f.path("a2")])
    }

    func testMinAgeAndExclusionsAndProtection() throws {
        let f = try Fixture()
        try f.file("stuff/old-a/x", bytes: 5000); try f.age("stuff/old-a", days: 40)
        try f.file("stuff/new-b/x", bytes: 5000)
        try f.file("stuff/old-skip/x", bytes: 5000); try f.age("stuff/old-skip", days: 40)
        try f.file("stuff/old-protected/x", bytes: 5000); try f.age("stuff/old-protected", days: 40)
        try f.file("stuff/old-excluded/x", bytes: 5000); try f.age("stuff/old-excluded", days: 40)
        let settings = EngineSettings(protectedPaths: ["~/stuff/old-protected"])
        let ctx = f.context(settings: settings)
        var def = CatDef(id: "t", name: "t", detail: "", level: .safe, symbol: "x")
        def.minAgeDays = 30
        def.globs = ["~/stuff/*"]
        def.exclude = ["old-skip", "*-excluded"]
        let paths = GenericScanner.itemPaths(of: def, globs: def.globs, ctx: ctx)
        XCTAssertEqual(paths, [f.path("stuff/old-a")])
    }

    func testRetentionSettingGatesAgeBasedCategories() throws {
        let f = try Fixture()
        try f.file(".claude/shell-snapshots/old.sh", bytes: 5000); try f.age(".claude/shell-snapshots/old.sh", days: 20)
        try f.file(".claude/shell-snapshots/new.sh", bytes: 5000)
        let def = makeCategoryDefs(env: f.env).first { $0.id == "claude-cache" }!
        XCTAssertTrue(def.useRetention)
        let strict = GenericScanner.itemPaths(of: def, globs: def.globs, ctx: f.context(settings: EngineSettings(sessionRetentionDays: 30)))
        XCTAssertTrue(strict.isEmpty)
        let loose = GenericScanner.itemPaths(of: def, globs: def.globs, ctx: f.context(settings: EngineSettings(sessionRetentionDays: 10)))
        XCTAssertEqual(loose, [f.path(".claude/shell-snapshots/old.sh")])
    }

    func testDeepAgeKeepsFoldersWithRecentNestedActivity() throws {
        let f = try Fixture()
        let base = f.root + "/private-tmp/claude-501"
        try f.file(base + "/busy/sess/log.txt", bytes: 5000)
        try f.file(base + "/idle/sess/log.txt", bytes: 5000)
        for p in [base + "/busy", base + "/busy/sess", base + "/idle/sess/log.txt", base + "/idle/sess", base + "/idle"] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: p)
        }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: base + "/busy/sess/log.txt")
        let def = makeCategoryDefs(env: f.env).first { $0.id == "claude-scratch" }!
        let paths = GenericScanner.itemPaths(of: def, globs: def.globs, ctx: f.context())
        XCTAssertEqual(paths, [base + "/idle"])
    }

    func testCarvedOutCachesAreNotCountedTwice() throws {
        let f = try Fixture()
        try f.file("Library/Caches/pip/x", bytes: 5000)
        try f.file("Library/Caches/ms-playwright/chromium-1/x", bytes: 5000)
        try f.file("Library/Caches/com.example.app/x", bytes: 5000)
        try f.file(".cache/uv/x", bytes: 5000); try f.file(".cache/huggingface/x", bytes: 5000); try f.file(".cache/other/x", bytes: 5000)
        let defs = makeCategoryDefs(env: f.env)
        let ctx = f.context()
        let caches = defs.first { $0.id == "caches" }!
        XCTAssertEqual(GenericScanner.itemPaths(of: caches, globs: caches.globs, ctx: ctx), [f.path("Library/Caches/com.example.app")])
        let xdg = defs.first { $0.id == "xdg-cache" }!
        XCTAssertEqual(GenericScanner.itemPaths(of: xdg, globs: xdg.globs, ctx: ctx), [f.path(".cache/other")])
    }

    func testGenericMeasureBuildsCategoryWithGroupAndSizes() async throws {
        let f = try Fixture()
        try f.file(".npm/_cacache/blob", bytes: 3 << 20)
        let def = makeCategoryDefs(env: f.env).first { $0.id == "npm" }!
        let cat = await GenericScanner.measure(def, ctx: f.context())
        XCTAssertEqual(cat?.group, .packageManagers)
        XCTAssertEqual(cat?.items.count, 1)
        XCTAssertGreaterThanOrEqual(cat?.sizeBytes ?? 0, 3 << 20)
        XCTAssertEqual(cat?.level, .safe)
    }

    func testEveryCategoryDefinitionHasAGroupAndUniqueId() throws {
        let f = try Fixture()
        let defs = makeCategoryDefs(env: f.env)
        XCTAssertEqual(Set(defs.map(\.id)).count, defs.count)
        for d in defs where d.id != "snapshots" { XCTAssertFalse(d.globs.isEmpty && d.cmds.isEmpty, d.id) }
        XCTAssertTrue(Set(defs.map(\.group)).isSuperset(of: [.system, .packageManagers, .xcode, .aiTools, .personal]))
        for d in defs { for c in d.cmds { XCTAssertTrue(CommandPolicy.isAllowed(c), "\(d.id) generates a command the allowlist refuses") } }
    }

    // MARK: Claude Code sessions

    func testClaudeSessionsOldOnlyWithLabelsAndNeverMemory() async throws {
        let f = try Fixture()
        let id1 = "11111111-1111-4111-8111-111111111111", id2 = "22222222-2222-4222-8222-222222222222"
        let proj = ".claude/projects/-Users-me-code-myapp"
        try f.file("\(proj)/\(id1).jsonl", "{\"type\":\"user\",\"cwd\":\"/Users/me/code/myapp\"}\n" + String(repeating: "x", count: 600_000))
        try f.file("\(proj)/\(id1)/subagents/a.jsonl", bytes: 700_000)
        try f.file("\(proj)/\(id2).jsonl", bytes: 5000)
        try f.file("\(proj)/memory/MEMORY.md", bytes: 5000)
        for p in ["\(proj)/\(id1).jsonl", "\(proj)/\(id1)", "\(proj)/memory", "\(proj)/memory/MEMORY.md"] { try f.age(p, days: 90) }
        let ctx = f.context(settings: EngineSettings(sessionRetentionDays: 30))
        let cats = await ClaudeScanner.scan(ctx)
        XCTAssertEqual(cats.count, 1)
        let cat = try XCTUnwrap(cats.first)
        XCTAssertEqual(cat.id, "claude-sessions")
        XCTAssertEqual(cat.group, .aiTools)
        XCTAssertEqual(cat.level, .caution)
        XCTAssertFalse(cat.itemsSelectable)
        let paths = Set(cat.items.map { $0.url.path })
        XCTAssertEqual(paths, [f.path("\(proj)/\(id1).jsonl"), f.path("\(proj)/\(id1)")])
        XCTAssertTrue(cat.items.allSatisfy { $0.label?.hasPrefix("myapp") == true && $0.lastUsed != nil })
        XCTAssertFalse(paths.contains { $0.contains("memory") })
    }

    // MARK: Editors

    private func workspace(_ f: Fixture, _ id: String, _ json: String?) throws {
        let dir = f.path("storage/\(id)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try f.file("storage/\(id)/state.vscdb", bytes: 100)
        if let json { try f.file("storage/\(id)/workspace.json", json) }
    }

    func testOrphanedWorkspaceStorageDetection() throws {
        let f = try Fixture()
        try f.dir("code/alive")
        try f.file("code/space/team.code-workspace", "{}")
        try workspace(f, "alive", "{\"folder\":\"file://\(f.path("code/alive"))\"}")
        try workspace(f, "gone", "{\"folder\":\"file://\(f.home)/code/deleted%20project\"}")
        try workspace(f, "gonews", "{\"workspace\":\"file://\(f.home)/code/old/team.code-workspace\"}")
        try workspace(f, "livews", "{\"workspace\":\"file://\(f.path("code/space/team.code-workspace"))\"}")
        try workspace(f, "remote", "{\"folder\":\"vscode-remote://ssh-remote%2Bhost/home/me/proj\"}")
        try workspace(f, "unmounted", "{\"folder\":\"file:///Volumes/DefinitelyNotMounted-\(UUID().uuidString)/proj\"}")
        try workspace(f, "nojson", nil)
        try workspace(f, "garbage", "not json")
        let orphans = IDEScanner.orphanedWorkspaces(storageDir: f.path("storage"))
        XCTAssertEqual(Set(orphans.map { ($0.path as NSString).lastPathComponent }), ["gone", "gonews"])
        XCTAssertEqual(orphans.first { $0.path.hasSuffix("/gone") }?.folderName, "deleted project")
    }

    func testExtensionDirParsing() {
        XCTAssertEqual(IDEScanner.parseExtensionDir("ms-python.python-2024.1.0")?.version, "2024.1.0")
        XCTAssertEqual(IDEScanner.parseExtensionDir("ms-python.python-2024.1.0")?.key, "ms-python.python|")
        let p = IDEScanner.parseExtensionDir("anthropic.claude-code-2.1.37-darwin-arm64")
        XCTAssertEqual(p?.key, "anthropic.claude-code|darwin-arm64")
        XCTAssertEqual(p?.version, "2.1.37")
        XCTAssertEqual(IDEScanner.parseExtensionDir("vscode-icons-team.vscode-icons-12.0.0")?.key, "vscode-icons-team.vscode-icons|")
        XCTAssertNil(IDEScanner.parseExtensionDir("extensions.json"))
        XCTAssertNil(IDEScanner.parseExtensionDir("noversion"))
    }

    func testStaleExtensionVersionsKeepNewestPerPlatformAndRegistered() throws {
        let f = try Fixture()
        for name in ["a.b-1.0.0", "a.b-1.2.0", "a.b-1.10.0",
                     "c.d-2.0.0-darwin-arm64", "c.d-2.1.0-darwin-arm64", "c.d-2.1.0-linux-x64",
                     "e.f-3.0.0", "e.f-4.0.0", "g.h-1.0.0", ".hidden-1.0.0"] {
            try f.file(".vscode/extensions/\(name)/package.json")
        }
        try f.file(".vscode/extensions/extensions.json",
                   "[{\"identifier\":{\"id\":\"e.f\"},\"version\":\"3.0.0\",\"relativeLocation\":\"e.f-3.0.0\"}]")
        try f.file(".vscode/extensions/.obsolete", "{\"g.h-1.0.0\":true}")
        let stale = IDEScanner.staleExtensionVersions(in: f.path(".vscode/extensions"))
        XCTAssertEqual(Set(stale), ["a.b-1.0.0", "a.b-1.2.0", "c.d-2.0.0-darwin-arm64", "g.h-1.0.0"],
                       "1.10.0 is newer than 1.2.0 (numeric compare); e.f-3.0.0 is registered in extensions.json")
    }

    func testEditorCategoriesEndToEnd() async throws {
        let f = try Fixture()
        let support = "Library/Application Support/Cursor"
        try f.file("\(support)/User/workspaceStorage/dead/workspace.json", "{\"folder\":\"file://\(f.home)/gone-project\"}")
        try f.file("\(support)/User/workspaceStorage/dead/state.vscdb", bytes: 2 << 20)
        try f.file("\(support)/CachedExtensionVSIXs/x.vsix", bytes: 2 << 20)
        try f.file("\(support)/User/History/abc/entries.json", bytes: 2 << 20)
        try f.file(".cursor/extensions/a.b-1.0.0/f", bytes: 2 << 20)
        try f.file(".cursor/extensions/a.b-2.0.0/f", bytes: 2 << 20)
        let cats = await IDEScanner.scan(f.context())
        let byId = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0) })
        XCTAssertEqual(byId["ide-stale-workspaces"]?.level, .safe)
        XCTAssertEqual(byId["ide-stale-workspaces"]?.items.first?.label, "Cursor · gone-project")
        XCTAssertEqual(byId["ide-caches"]?.items.count, 1)
        XCTAssertEqual(byId["ide-history"]?.level, .caution)
        XCTAssertEqual(byId["ide-old-extensions"]?.items.map { $0.url.lastPathComponent }, ["a.b-1.0.0"])
        XCTAssertTrue(cats.allSatisfy { $0.group == .aiTools && $0.itemsSelectable })
    }

    // MARK: Models

    func testHuggingFaceLabels() {
        XCTAssertEqual(ModelsScanner.huggingFaceLabel("models--meta-llama--Llama-3.1-8B"), "meta-llama/Llama-3.1-8B")
        XCTAssertEqual(ModelsScanner.huggingFaceLabel("models--gpt2"), "gpt2")
        XCTAssertEqual(ModelsScanner.huggingFaceLabel("datasets--squad--v2"), "squad/v2 (dataset)")
        XCTAssertNil(ModelsScanner.huggingFaceLabel(".locks"))
    }

    func testHuggingFaceHonorsEnvironment() async throws {
        let f0 = try Fixture()
        let hub = f0.root + "/custom-hub"
        let f = try Fixture(vars: ["HF_HUB_CACHE": hub])
        try f.file(hub + "/models--org--name/blobs/b", bytes: 3 << 20)
        try f.file(hub + "/datasets--org--data/blobs/b", bytes: 2 << 20)
        try f.file(".cache/huggingface/hub/models--ignored--me/blobs/b", bytes: 3 << 20)
        let cats = await ModelsScanner.scan(f.context())
        let hf = try XCTUnwrap(cats.first { $0.id == "hf-models" })
        XCTAssertEqual(Set(hf.items.compactMap(\.label)), ["org/name", "org/data (dataset)"])
        XCTAssertEqual(hf.level, .caution)
        XCTAssertEqual(hf.group, .models)
        XCTAssertTrue(hf.itemsSelectable)
        XCTAssertEqual(ModelsScanner.huggingFaceHub(f.env), hub)
    }

    func testOllamaManifestParsing() throws {
        let f = try Fixture()
        let base = f.path(".ollama/models")
        func blob(_ hex: String, bytes: Int) throws { try f.file(".ollama/models/blobs/sha256-\(hex)", bytes: bytes) }
        try blob("aaa", bytes: 8192); try blob("bbb", bytes: 4096); try blob("ccc", bytes: 12288); try blob("shared", bytes: 4096)
        func manifest(_ rel: String, _ digests: [(String, Int)], config: String) throws {
            let layers = digests.map { "{\"digest\":\"sha256:\($0.0)\",\"size\":\($0.1)}" }.joined(separator: ",")
            try f.file(".ollama/models/manifests/" + rel, "{\"config\":{\"digest\":\"sha256:\(config)\",\"size\":10},\"layers\":[\(layers)]}")
        }
        try manifest("registry.ollama.ai/library/llama3/latest", [("aaa", 8192), ("shared", 4096)], config: "bbb")
        try manifest("registry.ollama.ai/library/llama3/8b-q4", [("ccc", 12288), ("shared", 4096), ("missing-blob", 999)], config: "bbb")
        try manifest("registry.ollama.ai/someone/custom-model/7b", [("ccc", 12288)], config: "bbb")
        try manifest("example.com/team/private/v1", [("aaa", 8192)], config: "bbb")
        try f.file(".ollama/models/manifests/registry.ollama.ai/library/broken/latest", "not json")
        let models = ModelsScanner.ollamaModels(base: base)
        let byLabel = Dictionary(uniqueKeysWithValues: models.map { ($0.label, $0.bytes) })
        XCTAssertEqual(Set(byLabel.keys), ["llama3:latest", "llama3:8b-q4", "someone/custom-model:7b", "example.com/team/private:v1"])
        XCTAssertEqual(byLabel["llama3:latest"], 8192 + 4096 + 4096)               // aaa + shared + config(bbb)
        XCTAssertEqual(byLabel["llama3:8b-q4"], 12288 + 4096 + 4096)               // missing blobs count as 0
        XCTAssertEqual(byLabel["someone/custom-model:7b"], 12288 + 4096)
        XCTAssertTrue(models.first { $0.label == "llama3:latest" }!.manifest.hasSuffix("library/llama3/latest"))
    }

    func testOllamaCategoryUsesDeleteCommandsWhenInstalled() async throws {
        let f = try Fixture()
        try f.file(".ollama/models/blobs/sha256-aaa", bytes: 3 << 20)
        try f.file(".ollama/models/manifests/registry.ollama.ai/library/tiny/latest",
                   "{\"config\":{\"digest\":\"sha256:aaa\"},\"layers\":[]}")
        let cats = await ModelsScanner.scan(f.context())
        let ollama = try XCTUnwrap(cats.first { $0.id == "ollama-models" })
        if ToolPaths.which("ollama") != nil {
            XCTAssertEqual(ollama.items.first?.deleteCommand, ["ollama", "rm", "tiny:latest"])
            XCTAssertEqual(ollama.items.first?.label, "tiny:latest")
            XCTAssertTrue(CommandPolicy.isAllowed(ollama.items[0].deleteCommand!))
        } else {
            XCTAssertNil(ollama.items.first?.deleteCommand, "without ollama the whole models folder is the single item")
            XCTAssertEqual(ollama.items.count, 1)
            XCTAssertEqual(ollama.items.first?.url.path, f.path(".ollama/models"))
        }
        XCTAssertEqual(ollama.level, .caution)
    }

    // MARK: Toolchains

    func testNvmDefaultResolution() throws {
        let f = try Fixture()
        let nvm = f.path(".nvm")
        let installed = ["v18.14.0", "v22.20.0", "v22.23.4", "v25.2.1"]
        try f.file(".nvm/alias/default", "22.20\n")
        XCTAssertEqual(ToolchainScanner.nvmDefault(nvmDir: nvm, installed: installed), "v22.20.0")
        try f.file(".nvm/alias/default", "lts/iron")
        try f.file(".nvm/alias/lts/iron", "v18.14.0")
        XCTAssertEqual(ToolchainScanner.nvmDefault(nvmDir: nvm, installed: installed), "v18.14.0")
        try f.file(".nvm/alias/default", "node")
        XCTAssertEqual(ToolchainScanner.nvmDefault(nvmDir: nvm, installed: installed), "v25.2.1")
        try f.file(".nvm/alias/default", "v99.0.0")
        XCTAssertEqual(ToolchainScanner.nvmDefault(nvmDir: nvm, installed: installed), "v25.2.1", "unresolvable keeps the newest")
    }

    func testToolchainsNeverOfferTheDefault() async throws {
        let f = try Fixture()
        for v in ["v18.14.0", "v22.23.4"] { try f.file(".nvm/versions/node/\(v)/bin/node", bytes: 1_200_000) }
        try f.file(".nvm/alias/default", "22.23.4")
        for t in ["stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin"] { try f.file(".rustup/toolchains/\(t)/bin/rustc", bytes: 1_200_000) }
        try f.file(".rustup/settings.toml", "default_toolchain = \"stable-aarch64-apple-darwin\"\nversion = \"12\"\n")
        for v in ["2.7.18", "3.12.1"] { try f.file(".pyenv/versions/\(v)/bin/python", bytes: 1_200_000) }
        try f.file(".pyenv/version", "3.12.1\n")
        for v in ["3.3.0", "2.7.6"] { try f.file(".rbenv/versions/\(v)/bin/ruby", bytes: 1_200_000) }
        try f.file(".rbenv/version", "3.3.0")
        let cats = await ToolchainScanner.scan(f.context())
        let labels = Set(cats.flatMap { $0.items.compactMap(\.label) })
        XCTAssertEqual(labels, ["Node 18.14.0 (nvm)", "Rust nightly-aarch64-apple-darwin", "Python 2.7.18 (pyenv)", "Ruby 2.7.6 (rbenv)"])
        XCTAssertTrue(cats.allSatisfy { $0.group == .toolchains && $0.level == .caution && $0.itemsSelectable })
    }

    func testRustWithoutSettingsOffersNothing() throws {
        let f = try Fixture()
        try f.file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc", bytes: 100)
        XCTAssertTrue(ToolchainScanner.rustToolchains(f.context()).isEmpty)
    }

    func testAsdfPinsAreKept() throws {
        let f = try Fixture()
        for v in ["20.1.0", "18.0.0"] { try f.file(".asdf/installs/nodejs/\(v)/bin/node", bytes: 100) }
        try f.file(".tool-versions", "nodejs 20.1.0\n# comment\n")
        let found = ToolchainScanner.asdfAndMise(f.context())
        XCTAssertEqual(found.map(\.label), ["nodejs 18.0.0 (asdf)"])
    }

    // MARK: Xcode & Docker parsing

    func testDerivedDataLabel() {
        XCTAssertEqual(XcodeScanner.derivedDataLabel("MyApp-bqkpfnwlbgvbkshgztbpfdcnjzel"), "MyApp")
        XCTAssertEqual(XcodeScanner.derivedDataLabel("My-App-Pro-bqkpfnwlbgvbkshgztbpfdcnjzel"), "My-App-Pro")
        XCTAssertEqual(XcodeScanner.derivedDataLabel("ModuleCache.noindex"), "ModuleCache.noindex")
    }

    func testSimulatorRuntimeParsing() throws {
        let json = """
        {"AAA":{"identifier":"AAA","deletable":true,"version":"26.2","build":"23C54","sizeBytes":8381044573,"platformIdentifier":"com.apple.platform.iphonesimulator",
          "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-2","path":"/System/x.dmg","lastUsedAt":"2026-11-09T11:10:46Z"},
         "BBB":{"identifier":"BBB","deletable":false,"version":"1.0","sizeBytes":1,"platformIdentifier":"com.apple.platform.iphonesimulator"},
         "CCC":{"identifier":"CCC","deletable":true,"version":"27.2","sizeBytes":3856669156,"platformIdentifier":"com.apple.platform.watchsimulator","path":"/System/w"}}
        """
        let r = XcodeScanner.parseRuntimes(Data(json.utf8))
        XCTAssertEqual(r.map(\.label), ["iOS 26.2 Simulator", "watchOS 27.2 Simulator"])
        XCTAssertEqual(r[0].bytes, 8381044573)
        XCTAssertEqual(r[0].identifier, "AAA")
        XCTAssertNotNil(r[0].lastUsed)
        XCTAssertTrue(CommandPolicy.isAllowed(["xcrun", "simctl", "runtime", "delete", r[0].identifier]))
    }

    func testSimulatorDevicesSkipBootedOnes() throws {
        let f = try Fixture()
        func device(_ udid: String, name: String, state: Int) throws {
            let dir = f.path("Library/Developer/CoreSimulator/Devices/\(udid)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let plist: [String: Any] = ["UDID": udid, "name": name, "state": state, "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-4"]
            try (plist as NSDictionary).write(to: URL(fileURLWithPath: dir + "/device.plist"))
        }
        try device("AAAA", name: "iPhone 16", state: 1)
        try device("BBBB", name: "iPad Pro", state: 3)
        let devices = XcodeScanner.simulatorDevices(devicesDir: f.path("Library/Developer/CoreSimulator/Devices"))
        let shutdown = devices.filter { $0.state == 1 }
        XCTAssertEqual(shutdown.map(\.label), ["iPhone 16 — iOS 18.4"])
        XCTAssertEqual(devices.first { $0.udid == "BBBB" }?.state, 3, "the booted device is parsed so the scanner can skip it")
    }

    func testDockerParsing() {
        XCTAssertEqual(ContainerScanner.parseDockerSize("1.2GB (45%)"), 1_200_000_000)
        XCTAssertEqual(ContainerScanner.parseDockerSize("512MB"), 512_000_000)
        XCTAssertEqual(ContainerScanner.parseDockerSize("16.38kB"), 16_380)
        XCTAssertEqual(ContainerScanner.parseDockerSize("0B"), 0)
        XCTAssertEqual(ContainerScanner.parseDockerSize(""), 0)
        let out = """
        {"Active":"3","Reclaimable":"1.2GB (45%)","Size":"2.7GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"500MB","Size":"500MB","TotalCount":"7","Type":"Build Cache"}
        garbage
        """
        let rows = ContainerScanner.parseDf(out)
        XCTAssertEqual(rows, [ContainerScanner.Row(type: "Images", reclaimable: 1_200_000_000, total: 2_700_000_000),
                              ContainerScanner.Row(type: "Build Cache", reclaimable: 500_000_000, total: 500_000_000)])
    }

    // MARK: Personal data

    func testIOSBackupAndArchiveLabels() throws {
        let f = try Fixture()
        let backup = f.path("Library/Application Support/MobileSync/Backup/00008110-ABCDEF")
        try FileManager.default.createDirectory(atPath: backup, withIntermediateDirectories: true)
        let info: [String: Any] = ["Device Name": "Ada's iPhone", "Last Backup Date": Date(timeIntervalSince1970: 1_700_000_000)]
        try (info as NSDictionary).write(to: URL(fileURLWithPath: backup + "/Info.plist"))
        let backups = PersonalScanner.iosBackups(dir: f.path("Library/Application Support/MobileSync/Backup"))
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].label.hasPrefix("Ada's iPhone — 2023-11-1"), backups[0].label)

        let archive = f.path("Library/Developer/Xcode/Archives/2026-01-05/MyApp 1-5-26.xcarchive")
        try FileManager.default.createDirectory(atPath: archive, withIntermediateDirectories: true)
        let arch: [String: Any] = ["Name": "MyApp", "CreationDate": Date(timeIntervalSince1970: 1_767_600_000),
                                   "ApplicationProperties": ["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "42"]]
        try (arch as NSDictionary).write(to: URL(fileURLWithPath: archive + "/Info.plist"))
        let archives = PersonalScanner.xcodeArchives(dir: f.path("Library/Developer/Xcode/Archives"))
        XCTAssertEqual(archives.count, 1)
        XCTAssertTrue(archives[0].label.hasPrefix("MyApp 1.4.0 (42) — 2026-01-0"), archives[0].label)
    }
}
