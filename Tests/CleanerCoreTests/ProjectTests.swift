import XCTest
@testable import CleanerCore

final class ProjectTests: EngineTestCase {
    /// Runs the project scan over the fixture home and returns artifact paths relative to home.
    private func scan(_ f: Fixture, settings: EngineSettings = EngineSettings()) async throws -> Set<String> {
        let found = await f.engine(settings: settings).scanProjects(root: URL(fileURLWithPath: f.home), minBytes: 1, progress: { _ in })
        return Set(found.map { String($0.url.path.dropFirst(f.home.count + 1)) })
    }

    // MARK: Marker rules

    func testMarkerGatedFolders() async throws {
        let f = try Fixture()
        // Reported: marker present
        let positives: [(marker: String, folder: String)] = [
            ("package.json", ".next"), ("package.json", ".nuxt"), ("package.json", ".turbo"), ("package.json", ".svelte-kit"),
            ("package.json", ".output"), ("package.json", ".vite"), ("package.json", ".angular"), ("package.json", ".astro"),
            ("package.json", ".wrangler"), ("package.json", ".vercel"), ("package.json", ".open-next"),
            ("package.json", "storybook-static"), ("package.json", ".expo"),
            ("Cargo.toml", "target"), ("pom.xml", "target"), ("Podfile", "Pods"), ("Package.swift", ".build"),
            ("App.xcodeproj", "DerivedData"), ("main.tf", ".terraform"), ("build.zig", "zig-cache"), ("build.zig", ".zig-cache"),
            ("build.zig", "zig-out"), ("mix.exs", "_build"), ("build.gradle", ".cxx"), ("CMakeLists.txt", "cmake-build-debug"),
            ("stack.yaml", ".stack-work"), ("pubspec.yaml", ".dart_tool"), ("settings.gradle.kts", ".gradle"),
            ("Cartfile", "Carthage"), ("tox.ini", ".tox"),
        ]
        for (i, p) in positives.enumerated() {
            try f.file("pos/\(i)-\(p.folder)/\(p.marker)", "m")
            try f.file("pos/\(i)-\(p.folder)/\(p.folder)/blob", bytes: 5000)
        }
        // Not reported: same folder names without their marker
        for (i, folder) in [".next", "target", "Pods", ".build", ".terraform", "_build", ".dart_tool", ".tox", "cmake-build-debug"].enumerated() {
            try f.file("neg/\(i)-\(folder)/README.md", "m")
            try f.file("neg/\(i)-\(folder)/\(folder)/blob", bytes: 5000)
        }
        let found = try await scan(f)
        for (i, p) in positives.enumerated() {
            XCTAssertTrue(found.contains("pos/\(i)-\(p.folder)/\(p.folder)"), "\(p.folder) next to \(p.marker)")
        }
        XCTAssertFalse(found.contains { $0.hasPrefix("neg/") }, "generic names without a marker must never match: \(found.filter { $0.hasPrefix("neg/") })")
    }

    func testAlwaysAndNameOnlyArtifacts() async throws {
        let f = try Fixture()
        try f.file("a/node_modules/x/index.js", bytes: 5000)
        try f.file("b/pkg/__pycache__/m.pyc", bytes: 5000)
        try f.file("b/.pytest_cache/v", bytes: 5000)
        try f.file("b/.mypy_cache/v", bytes: 5000)
        try f.file("b/.ruff_cache/v", bytes: 5000)
        try f.file("c/.venv/pyvenv.cfg", "home = /usr/bin"); try f.file("c/.venv/lib/x", bytes: 5000)
        try f.file("c/venv/lib/x", bytes: 5000)    // no pyvenv.cfg: not a virtualenv
        let found = try await scan(f)
        XCTAssertEqual(found, ["a/node_modules", "b/pkg/__pycache__", "b/.pytest_cache", "b/.mypy_cache", "b/.ruff_cache", "c/.venv"])
    }

    func testNeverDescendsIntoArtifactsHiddenFoldersOrGitDir() async throws {
        let f = try Fixture()
        try f.repo("p", files: ["package.json": "{}", ".gitignore": "node_modules/\n"])
        try f.file("p/node_modules/dep/node_modules/inner/x", bytes: 5000)
        try f.file("p/node_modules/dep/package.json", "{}")
        try f.file("p/.hidden/proj/node_modules/x", bytes: 5000)
        try f.file("p/.git/objects/node_modules/x", bytes: 5000)
        let found = try await scan(f)
        XCTAssertEqual(found, ["p/node_modules"])
    }

    func testSkipsLibraryAtHomeTopLevelOnly() async throws {
        let f = try Fixture()
        try f.file("Library/thing/node_modules/x", bytes: 5000)
        try f.file("work/Library/node_modules/x", bytes: 5000)
        let found = try await scan(f)
        XCTAssertEqual(found, ["work/Library/node_modules"])
    }

    func testProtectedPathsAreNeverReported() async throws {
        let f = try Fixture()
        try f.file("keep/app/node_modules/x", bytes: 5000)
        try f.file("keep/app/package.json", "{}"); try f.file("keep/app/.next/x", bytes: 5000)
        try f.file("other/node_modules/x", bytes: 5000)
        try f.file("mixed/node_modules/a", bytes: 5000)
        try f.file("mixed/package.json", "{}")
        let found = try await scan(f, settings: EngineSettings(protectedPaths: ["~/keep", "~/mixed/node_modules/a"]))
        XCTAssertEqual(found, ["other/node_modules"], "a folder that contains a protected path is not offered either")
    }

    func testMinBytesAndSortingAndIdleDays() async throws {
        let f = try Fixture()
        try f.file("small/node_modules/x", bytes: 5000)
        try f.file("big/node_modules/x", bytes: 3 << 20)
        try f.age("big", days: 40)
        try f.age("big/node_modules", days: 40)
        let result = await f.engine().scanProjects(root: URL(fileURLWithPath: f.home), minBytes: 1 << 20, progress: { _ in })
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, "node_modules")
        XCTAssertEqual(result[0].projectURL.path, f.path("big"))
        XCTAssertGreaterThanOrEqual(result[0].idleDays, 39)
    }

    // MARK: Git hard rule

    func testNeverReportsFoldersContainingTrackedFiles() async throws {
        let f = try Fixture()
        try f.repo("r1", files: ["Cargo.toml": "m", "target/committed.txt": "tracked", ".gitignore": ""])
        try f.file("r1/target/also-untracked.bin", bytes: 5000)
        try f.repo("r2", files: ["package.json": "{}", "node_modules/pkg/index.js": "tracked on purpose"])
        try f.repo("r3", files: ["Cargo.toml": "m", ".gitignore": "target/\n"])
        try f.file("r3/target/debug/x", bytes: 5000)
        let found = try await scan(f)
        XCTAssertEqual(found, ["r3/target"])
    }

    func testRiskyNamesNeedGitRepoAndIgnore() async throws {
        let f = try Fixture()
        // Outside git: dist, out, build, bin, obj, coverage, deps, vendor/bundle are never matched.
        try f.file("nogit/package.json", "{}")
        for d in ["dist", "out", "build", "coverage"] { try f.file("nogit/\(d)/x", bytes: 5000) }
        try f.file("nogit-dotnet/App.csproj", "m"); try f.file("nogit-dotnet/bin/x", bytes: 5000); try f.file("nogit-dotnet/obj/x", bytes: 5000)
        try f.file("nogit-ruby/Gemfile", "m"); try f.file("nogit-ruby/vendor/bundle/x", bytes: 5000)
        try f.file("nogit-elixir/mix.exs", "m"); try f.file("nogit-elixir/deps/x", bytes: 5000)
        // Inside git and ignored: reported.
        try f.repo("ignored", files: ["package.json": "{}", ".gitignore": "dist/\ncoverage/\nout/\nbuild/\n"])
        for d in ["dist", "out", "build", "coverage"] { try f.file("ignored/\(d)/x", bytes: 5000) }
        try f.repo("dotnet", files: ["App.csproj": "m", ".gitignore": "bin/\nobj/\n"])
        try f.file("dotnet/bin/x", bytes: 5000); try f.file("dotnet/obj/x", bytes: 5000)
        try f.repo("ruby", files: ["Gemfile": "m", ".gitignore": "vendor/bundle\n"])
        try f.file("ruby/vendor/bundle/x", bytes: 5000)
        try f.repo("elixir", files: ["mix.exs": "m", ".gitignore": "deps/\n_build/\n"])
        try f.file("elixir/deps/x", bytes: 5000); try f.file("elixir/_build/x", bytes: 5000)
        // Inside git but untracked and NOT ignored: not reported (could be hand-made content).
        try f.repo("unignored", files: ["package.json": "{}"])
        try f.file("unignored/dist/x", bytes: 5000)
        // Inside git and tracked: not reported.
        try f.repo("tracked", files: ["package.json": "{}", "dist/bundle.js": "committed"])
        let found = try await scan(f)
        XCTAssertEqual(found, ["ignored/dist", "ignored/out", "ignored/build", "ignored/coverage", "dotnet/bin", "dotnet/obj",
                               "ruby/vendor/bundle", "elixir/deps", "elixir/_build"])
    }

    func testNestedRepoUsesItsOwnGitRoot() async throws {
        let f = try Fixture()
        try f.repo("outer", files: ["package.json": "{}", ".gitignore": ""])
        try f.repo("outer/inner", files: ["package.json": "{}", ".gitignore": "dist/\n"])
        try f.file("outer/inner/dist/x", bytes: 5000)
        try f.file("outer/dist/y", bytes: 5000)    // outer repo does not ignore dist
        let found = try await scan(f)
        XCTAssertEqual(found, ["outer/inner/dist"])
    }

    func testGitFilterFailsClosedWhenGitCannotAnswer() async throws {
        let f = try Fixture()
        // A ".git" folder that is not a repository: git fails, so nothing in it may be offered.
        try f.file("broken/.git/HEAD", "garbage")
        try f.file("broken/package.json", "{}")
        try f.file("broken/.next/x", bytes: 5000)
        let found = try await scan(f)
        XCTAssertFalse(found.contains("broken/.next"))
    }

    func testArtifactRuleMatching() {
        XCTAssertNotNil(ArtifactRules.match(name: "node_modules", parent: "/nowhere", siblings: []))
        XCTAssertNil(ArtifactRules.match(name: "dist", parent: "/nowhere", siblings: ["README.md"]))
        XCTAssertEqual(ArtifactRules.match(name: "dist", parent: "/nowhere", siblings: ["package.json"])?.risky, true)
        XCTAssertEqual(ArtifactRules.match(name: ".next", parent: "/nowhere", siblings: ["package.json"])?.risky, false)
        XCTAssertNil(ArtifactRules.match(name: "DerivedData", parent: "/nowhere", siblings: ["x.xcodeproj.bak"]))
        XCTAssertNotNil(ArtifactRules.match(name: "DerivedData", parent: "/nowhere", siblings: ["Foo.xcworkspace"]))
        XCTAssertNil(ArtifactRules.match(name: "obj", parent: "/nowhere", siblings: [".csproj"]), "a bare '.csproj' is not a project file")
    }
}
