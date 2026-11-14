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
            ("package.json", ".vercel"), ("package.json", ".open-next"),
            ("package.json", "storybook-static"), ("package.json", ".expo"),
            ("Cargo.toml", "target"), ("pom.xml", "target"), ("Podfile", "Pods"), ("Package.swift", ".build"),
            ("App.xcodeproj", "DerivedData"), ("build.zig", "zig-cache"), ("build.zig", ".zig-cache"),
            ("build.zig", "zig-out"), ("mix.exs", "_build"), ("build.gradle", ".cxx"), ("CMakeLists.txt", "cmake-build-debug"),
            ("stack.yaml", ".stack-work"), ("pubspec.yaml", ".dart_tool"), ("settings.gradle.kts", ".gradle"),
            ("Cartfile", "Carthage"), ("tox.ini", ".tox"),
        ]
        for (i, p) in positives.enumerated() {
            try f.file("pos/\(i)-\(p.folder)/\(p.marker)", "m")
            try f.file("pos/\(i)-\(p.folder)/\(p.folder)/blob", bytes: 5000)
        }
        // Not reported: same folder names without their marker
        for (i, folder) in [".next", "target", "Pods", ".build", "_build", ".dart_tool", ".tox", "cmake-build-debug"].enumerated() {
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

    func testProjectsInsideTheUsersOwnTopLevelFoldersAreFound() async throws {
        // ~/Documents, ~/Desktop and ~/Downloads cannot be deleted themselves, but they are where projects live.
        let f = try Fixture()
        for top in ["Documents", "Desktop", "Downloads"] { try f.file("\(top)/proj/node_modules/x", bytes: 5000) }
        let found = try await scan(f)
        XCTAssertEqual(found, ["Documents/proj/node_modules", "Desktop/proj/node_modules", "Downloads/proj/node_modules"])
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

    func testWranglerStateAndUnignoredTerraformAreNeverOffered() async throws {
        let f = try Fixture()
        // `.wrangler/state` is the local development database: `.wrangler` is not an artifact at all.
        try f.repo("worker", files: ["package.json": "{}", ".gitignore": ".wrangler/\n"])
        try f.file("worker/.wrangler/state/v3/d1/db.sqlite", bytes: 5000)
        try f.file("plain-worker/package.json", "{}"); try f.file("plain-worker/.wrangler/state/x", bytes: 5000)
        // `.terraform` holds the workspace selection: only when git ignores it.
        try f.file("nogit-infra/main.tf", "m"); try f.file("nogit-infra/.terraform/providers/x", bytes: 5000)
        try f.repo("infra-unignored", files: ["main.tf": "m"]); try f.file("infra-unignored/.terraform/providers/x", bytes: 5000)
        try f.repo("infra", files: ["main.tf": "m", ".gitignore": ".terraform/\n"]); try f.file("infra/.terraform/providers/x", bytes: 5000)
        let found = try await scan(f)
        XCTAssertEqual(found, ["infra/.terraform"])
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

    func testFolderWithAGitDirThatIsNotARepositoryIsNeverOffered() async throws {
        let f = try Fixture()
        // A ".git" folder that is not a repository: the audit already refuses it, so nothing in it may be offered.
        try f.file("broken/.git/HEAD", "garbage")
        try f.file("broken/package.json", "{}")
        try f.file("broken/.next/x", bytes: 5000)
        let found = try await scan(f)
        XCTAssertFalse(found.contains("broken/.next"))
    }

    func testGitFilterFailsClosedWhenGitCannotAnswer() async throws {
        let f = try Fixture()
        // A real repository whose index is corrupt: the configuration audit passes, `git ls-files` then fails.
        try f.repo("corrupt", files: ["package.json": "{}", ".gitignore": ".next/\nnode_modules/\n"])
        try f.file("corrupt/.next/x", bytes: 5000)
        try f.file("corrupt/node_modules/x", bytes: 5000)
        // Positive control 1: while git can answer, both folders are offered.
        var found = try await scan(f)
        XCTAssertEqual(found, ["corrupt/.next", "corrupt/node_modules"])
        try Data("this is not an index".utf8).write(to: URL(fileURLWithPath: f.path("corrupt/.git/index")))
        // Positive control 2: the repository still passes the audit, and git itself is what fails.
        guard case .trusted(let repo) = await Git.open(f.path("corrupt"), env: f.env) else { return XCTFail("the audit must pass, or git is never reached") }
        let r = await Git.run(repo, ["ls-files", "-z"], env: f.env)
        XCTAssertTrue(r.launched)
        XCTAssertFalse(r.ok, "git must fail on the corrupt index")
        let tracked = await GitArtifactFilter.trackedPaths(repo: repo, rels: [".next"], env: f.env)
        XCTAssertNil(tracked)
        found = try await scan(f)
        XCTAssertEqual(found, [], "nothing may be offered when git cannot say what is tracked")
    }

    // MARK: Scan root below the repository root (H2)

    private func scan(_ f: Fixture, root rel: String) async -> Set<String> {
        let found = await f.engine().scanProjects(root: URL(fileURLWithPath: f.path(rel)), minBytes: 1, progress: { _ in })
        return Set(found.map { String($0.url.path.dropFirst(f.home.count + 1)) })
    }

    func testTrackedBuildFolderIsNotReportedWhenScanningBelowTheRepositoryRoot() async throws {
        let f = try Fixture()
        try f.repo("app", files: ["ios/Podfile": "pod 'X'", "ios/Pods/Lib/blob": String(repeating: "x", count: 5000),
                                  "web/package.json": "{}", "web/node_modules/pkg/index.js": "committed on purpose"])
        // Positive control: the walker does find both folders from the sub-roots; only git knows they are tracked.
        let guardian = PathGuard(env: f.env, settings: EngineSettings())
        let raw = ProjectWalker.find(root: f.path("app/ios"), home: f.home, guardian: guardian, flag: CancelFlag())
        XCTAssertEqual(raw.map(\.path), [f.path("app/ios/Pods")])
        XCTAssertEqual(raw.first?.repoRoot, f.path("app"), "the walker must know the repository above its root")
        for root in ["app", "app/ios", "app/web", "app/ios/Pods/..", "app/web/node_modules/pkg/../.."] {
            let found = await scan(f, root: root)
            XCTAssertEqual(found, [], "scan root \(root)")
        }
    }

    func testIgnoredBuildFolderIsStillReportedWhenScanningBelowTheRepositoryRoot() async throws {
        let f = try Fixture()
        try f.repo("app", files: ["web/package.json": "{}", ".gitignore": "node_modules/\ndist/\n", "ios/Podfile": "pod 'X'"])
        try f.file("app/web/node_modules/pkg/index.js", bytes: 5000)
        try f.file("app/web/dist/bundle.js", bytes: 5000)       // risky name: needs the repository AND the ignore rule
        try f.file("app/ios/Pods/Lib/blob", bytes: 5000)        // untracked, not ignored, not a risky name
        var found = await scan(f, root: "app/web")
        XCTAssertEqual(found, ["app/web/node_modules", "app/web/dist"])
        found = await scan(f, root: "app/ios")
        XCTAssertEqual(found, ["app/ios/Pods"])
        // Outside any repository nothing changes: plain folders are still found, risky names still are not.
        try f.file("plain/sub/package.json", "{}")
        try f.file("plain/sub/node_modules/x", bytes: 5000)
        try f.file("plain/sub/dist/x", bytes: 5000)
        found = await scan(f, root: "plain/sub")
        XCTAssertEqual(found, ["plain/sub/node_modules"])
    }

    func testNothingIsReportedBelowTheRootOfAnUntrustedOrUnreadableRepository() async throws {
        let f = try Fixture()
        try f.repo("evil", files: ["web/package.json": "{}", ".gitignore": "node_modules/\n"])
        try f.file("evil/web/node_modules/pkg/index.js", bytes: 5000)
        // Positive control: reported while the repository is trusted.
        var found = await scan(f, root: "evil/web")
        XCTAssertEqual(found, ["evil/web/node_modules"])
        try f.git("evil", "config", "core.fsmonitor", "/nonexistent/program")
        found = await scan(f, root: "evil/web")
        XCTAssertEqual(found, [], "untrusted repository above the scan root")
        // A `.git` entry above the root that is not a repository at all.
        try f.file("fake/.git/HEAD", "garbage")
        try f.file("fake/web/node_modules/pkg/index.js", bytes: 5000)
        found = await scan(f, root: "fake/web")
        XCTAssertEqual(found, [], "an enclosing repository that cannot be inspected")
    }

    // MARK: Idle time (L2)

    func testIdleDaysSeeAChangeDeepInsideTheProject() async throws {
        let f = try Fixture()
        try f.file("web/package.json", "{}")
        try f.file("web/node_modules/pkg/blob", bytes: 5000)
        try f.file("web/src/deep/er/x.js", "1")
        try f.file("web/.hidden/y", "1")
        for rel in ["web/src/deep/er/x.js", "web/src/deep/er", "web/src/deep", "web/src", "web/.hidden/y", "web/.hidden",
                    "web/package.json", "web/node_modules/pkg/blob", "web/node_modules/pkg", "web/node_modules", "web"] {
            try f.age(rel, days: 300)
        }
        func idle() async -> Int? {
            await f.engine().scanProjects(root: URL(fileURLWithPath: f.home), minBytes: 1, progress: { _ in }).first?.idleDays
        }
        // Positive control: everything is old, so the project is idle.
        let first = await idle()
        let before = try XCTUnwrap(first)
        XCTAssertGreaterThanOrEqual(before, 299)
        // A change inside the artifact folder itself does not count as project activity…
        try f.age("web/node_modules/pkg/blob", days: 0)
        let second = await idle()
        let stillIdle = try XCTUnwrap(second)
        XCTAssertGreaterThanOrEqual(stillIdle, 299)
        // …an edit three levels down does (a file's change does not touch its grand-parents' timestamps).
        try f.age("web/src/deep/er/x.js", days: 0)
        let third = await idle()
        let after = try XCTUnwrap(third)
        XCTAssertEqual(after, 0, "a project edited today is not idle")
    }

    func testIdleDaysFailClosedWhenTheProjectIsTooBigOrUnreadable() throws {
        let f = try Fixture()
        try f.file("p/package.json", "{}")
        for i in 0..<30 { try f.file("p/src/f\(i).js", "1") }
        try f.dir("p/locked")
        for rel in (0..<30).map({ "p/src/f\($0).js" }) + ["p/src", "p/package.json", "p/locked", "p"] { try f.age(rel, days: 100) }
        let old = Date().timeIntervalSince1970 - 99 * 86400
        // Positive control: within the bound the real (old) time is found.
        XCTAssertLessThan(ProjectWalker.lastTouched(project: f.path("p"), skipping: []), old)
        // Bound hit: counts as touched just now.
        XCTAssertGreaterThan(ProjectWalker.lastTouched(project: f.path("p"), skipping: [], maxEntries: 10), Date().timeIntervalSince1970 - 60)
        // A folder that cannot be read: same.
        chmod(f.path("p/locked"), 0)
        defer { chmod(f.path("p/locked"), 0o700) }
        XCTAssertGreaterThan(ProjectWalker.lastTouched(project: f.path("p"), skipping: []), Date().timeIntervalSince1970 - 60)
    }

    func testArtifactRuleMatching() {
        XCTAssertNotNil(ArtifactRules.match(name: "node_modules", parent: "/nowhere", siblings: []))
        XCTAssertNil(ArtifactRules.match(name: "dist", parent: "/nowhere", siblings: ["README.md"]))
        XCTAssertEqual(ArtifactRules.match(name: "dist", parent: "/nowhere", siblings: ["package.json"])?.risky, true)
        XCTAssertEqual(ArtifactRules.match(name: ".next", parent: "/nowhere", siblings: ["package.json"])?.risky, false)
        XCTAssertNil(ArtifactRules.match(name: ".wrangler", parent: "/nowhere", siblings: ["package.json"]))
        XCTAssertEqual(ArtifactRules.match(name: ".terraform", parent: "/nowhere", siblings: ["main.tf"])?.risky, true)
        XCTAssertNil(ArtifactRules.match(name: "DerivedData", parent: "/nowhere", siblings: ["x.xcodeproj.bak"]))
        XCTAssertNotNil(ArtifactRules.match(name: "DerivedData", parent: "/nowhere", siblings: ["Foo.xcworkspace"]))
        XCTAssertNil(ArtifactRules.match(name: "obj", parent: "/nowhere", siblings: [".csproj"]), "a bare '.csproj' is not a project file")
    }
}
