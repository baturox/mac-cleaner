import XCTest
@testable import CleanerCore

/// Finding 1: a repository's own git configuration must never get a program run.
/// Every fixture carries a harmless payload (a script that creates a marker file inside the fixture).
final class GitSecurityTests: EngineTestCase {
    private struct Hostile {
        let f: Fixture
        let rel: String
        let marker: String
        let script: String
        var fired: Bool { FileManager.default.fileExists(atPath: marker) }
        func reset() { try? FileManager.default.removeItem(atPath: marker) }
    }

    /// A committed project with build folders, plus the payload script. No hostile setting yet.
    private func makeRepo(_ f: Fixture, _ rel: String = "code/evil") throws -> Hostile {
        let marker = f.root + "/PAYLOAD-RAN"
        let script = f.root + "/payload.sh"
        try f.file(script, "#!/bin/sh\n/usr/bin/touch '\(marker)'\nif [ \"$1\" = clean ]; then /bin/cat; fi\nexit 0\n")
        chmod(script, 0o755)
        try f.repo(rel, files: ["package.json": "{}", ".gitignore": "dist/\nnode_modules/\n", "a.txt": "hello\n"])
        try f.file(rel + "/node_modules/x/big", bytes: 2 << 20)
        try f.file(rel + "/dist/big", bytes: 2 << 20)
        return Hostile(f: f, rel: rel, marker: marker, script: script)
    }

    /// Makes git re-read a tracked file (so content filters run) without waiting for the clock.
    private func touch(_ f: Fixture, _ rel: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: f.path(rel))
    }

    private func appendConfig(_ path: String, _ text: String) throws {
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try (old + "\n" + text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Proves the fixture is a working exploit: plain git, as the old engine ran it, starts the payload.
    private func assertExploitable(_ h: Hostile, in rel: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        h.reset()
        _ = try? h.f.git(rel ?? h.rel, "status", "--porcelain=v1", "-uall")
        XCTAssertTrue(h.fired, "fixture is not exploitable; the test would prove nothing", file: file, line: line)
        h.reset()
    }

    /// Scan, project scan and removal must all leave the marker absent and report the repo as untrusted.
    private func assertNeutralized(_ h: Hostile, clones rels: [String], expecting key: String,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let f = h.f
        let engine = f.engine()
        let groups = await engine.scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
        let clones = groups.flatMap(\.clones)
        for rel in rels {
            let c = try XCTUnwrap(clones.first { $0.url.path == f.path(rel) }, "\(rel) is still listed", file: file, line: line)
            XCTAssertFalse(c.wasInspected, rel, file: file, line: line)
            XCTAssertTrue(c.untrustedConfigKeys?.contains(key) ?? false, "\(rel): \(c.untrustedConfigKeys ?? [])", file: file, line: line)
            XCTAssertFalse(c.isFullyBackedUp, file: file, line: line)
            XCTAssertNil(c.branch, "git was not asked anything", file: file, line: line)
            XCTAssertGreaterThan(c.sizeBytes, 0, "size is still measured (du, not git)", file: file, line: line)
        }
        XCTAssertFalse(h.fired, "payload ran during scanRepos", file: file, line: line)

        let artifacts = await engine.scanProjects(root: URL(fileURLWithPath: f.path("code")), minBytes: 1, progress: { _ in })
        for rel in rels {
            XCTAssertFalse(artifacts.contains { $0.url.path.hasPrefix(f.path(rel) + "/") },
                           "build folders of an untrusted repo are dropped", file: file, line: line)
        }
        XCTAssertFalse(h.fired, "payload ran during scanProjects", file: file, line: line)

        let targets = clones.filter { c in rels.contains { f.path($0) == c.url.path } }
        for force in [false, true] {
            let r = await engine.removeClones(targets, force: force, mode: .permanent, progress: { _ in })
            XCTAssertEqual(r.failedCount, targets.count, "force=\(force): \(r.messages)", file: file, line: line)
            XCTAssertTrue(r.messages.joined().contains(key), file: file, line: line)
        }
        for rel in rels { XCTAssertTrue(f.exists(rel + "/.git"), "\(rel) must survive", file: file, line: line) }
        XCTAssertFalse(h.fired, "payload ran during removeClones", file: file, line: line)
    }

    // MARK: The five ways in

    func testFsmonitorInRepositoryConfigNeverRuns() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        try f.git(h.rel, "config", "core.fsmonitor", h.script)
        try assertExploitable(h)
        try await assertNeutralized(h, clones: [h.rel], expecting: "core.fsmonitor")
    }

    func testCleanFilterWithGitattributesNeverRuns() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        try f.file(h.rel + "/.gitattributes", "* filter=x\n")
        try f.git(h.rel, "config", "filter.x.clean", h.script + " clean")
        try f.git(h.rel, "config", "filter.x.smudge", "cat")
        try touch(f, h.rel + "/a.txt")
        try assertExploitable(h)
        try touch(f, h.rel + "/a.txt")
        try await assertNeutralized(h, clones: [h.rel], expecting: "filter.*.clean")
    }

    func testIncludedConfigNeverRuns() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        try f.file(h.rel + "/.git/extra.cfg", "[core]\n\tfsmonitor = \(h.script)\n")
        try f.git(h.rel, "config", "include.path", "extra.cfg")
        try assertExploitable(h)
        try await assertNeutralized(h, clones: [h.rel], expecting: "include.path")
    }

    func testLinkedWorktreeWithHostileMainConfigNeverRuns() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        try f.git(h.rel, "worktree", "add", "-q", f.path("code/evil-wt"), "-b", "side")
        try appendConfig(f.path(h.rel + "/.git/config"), "[core]\n\tfsmonitor = \(h.script)")
        try assertExploitable(h, in: "code/evil-wt")
        // The worktree has no config of its own; what counts is the main repository's.
        try await assertNeutralized(h, clones: [h.rel, "code/evil-wt"], expecting: "core.fsmonitor")
    }

    func testWorktreeConfigExtensionNeverRuns() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        try f.git(h.rel, "config", "extensions.worktreeConfig", "true")
        try f.file(h.rel + "/.git/config.worktree", "[core]\n\tfsmonitor = \(h.script)\n")
        try assertExploitable(h)
        try await assertNeutralized(h, clones: [h.rel], expecting: "core.fsmonitor")
    }

    func testHostileConfigWorktreeIsCaughtEvenWithoutTheExtension() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        try f.file(h.rel + "/.git/config.worktree", "[core]\n\tfsmonitor = \(h.script)\n")
        try await assertNeutralized(h, clones: [h.rel], expecting: "core.fsmonitor")
    }

    // MARK: Fake repositories and discovery

    func testFolderWithBenignLookingGitDirInsideHostileRepoDoesNotReachTheParent() async throws {
        // `inner/.git` has a harmless config but is not a repository. Plain `git -C inner` would walk up and
        // use the hostile parent; the engine pins --git-dir, so git just fails and the folder is dropped.
        let f = try Fixture()
        let h = try makeRepo(f)
        try f.file(h.rel + "/inner/.git/config", "[core]\n\trepositoryformatversion = 0\n")
        try f.file(h.rel + "/inner/package.json", "{}")
        try f.file(h.rel + "/inner/node_modules/x/big", bytes: 2 << 20)
        try f.git(h.rel, "config", "core.fsmonitor", h.script)
        h.reset()
        let engine = f.engine()
        let artifacts = await engine.scanProjects(root: URL(fileURLWithPath: f.path("code")), minBytes: 1, progress: { _ in })
        XCTAssertTrue(artifacts.isEmpty, "\(artifacts.map(\.url.path))")
        _ = await engine.scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
        XCTAssertFalse(h.fired)
    }

    func testHostileSubmoduleMakesTheParentNotBackedUpAndNeverRuns() async throws {
        let f = try Fixture()
        let h = try makeRepo(f, "code/parent")
        try f.repo("seed-sub")
        try f.git("code/parent", "-c", "protocol.file.allow=always", "submodule", "add", "-q", f.path("seed-sub"), "sub")
        try f.git("code/parent", "commit", "-q", "-m", "add submodule")
        try appendConfig(f.path("code/parent/.git/modules/sub/config"), "[core]\n\tfsmonitor = \(h.script)")
        h.reset()
        let groups = await f.engine().scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
        let parent = try XCTUnwrap(groups.flatMap(\.clones).first { $0.url.path == f.path("code/parent") })
        XCTAssertTrue(parent.wasInspected, "the parent's own configuration is fine")
        XCTAssertGreaterThan(parent.uncommittedCount, 0, "a submodule that cannot be inspected counts as unsaved work")
        XCTAssertFalse(parent.isFullyBackedUp)
        XCTAssertFalse(h.fired, "git must not have been run inside the submodule")
    }

    // MARK: Layers 2 and 3 on their own (configuration turns hostile AFTER the audit)

    func testHardenedInvocationStopsFsmonitorHooksAndPagerWithoutTheAudit() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        guard case .trusted(let repo) = await Git.open(f.path(h.rel), env: f.env) else { return XCTFail("clean repo must be trusted") }
        try f.git(h.rel, "config", "core.fsmonitor", h.script)
        try f.git(h.rel, "config", "core.pager", h.script)
        try f.git(h.rel, "config", "core.hooksPath", f.root)
        try assertExploitable(h)
        var env = f.env
        env.sandboxGit = false
        for args in [["status", "--porcelain=v1", "-uall"], ["ls-files", "-z"], ["check-ignore", "--", "dist/"], ["log", "-1", "--format=%ct"]] {
            _ = await Git.run(repo, args, env: env)
        }
        XCTAssertFalse(h.fired, "command-line overrides must beat the repository's settings")
    }

    func testSandboxStopsAFilterEvenWhenTheAuditIsBypassed() async throws {
        guard await GitSandbox.shared.profile(mutating: false) != nil else {
            throw XCTSkip("sandbox-exec is not usable here (already sandboxed?); the config audit is the defense that remains")
        }
        let f = try Fixture()
        let h = try makeRepo(f)
        guard case .trusted(let repo) = await Git.open(f.path(h.rel), env: f.env) else { return XCTFail("clean repo must be trusted") }
        try f.file(h.rel + "/.gitattributes", "* filter=x\n")
        try f.git(h.rel, "config", "filter.x.clean", h.script + " clean")
        try touch(f, h.rel + "/a.txt")
        try assertExploitable(h)
        try touch(f, h.rel + "/a.txt")
        _ = await Git.run(repo, ["status", "--porcelain=v1", "-uall"], env: f.env)
        XCTAssertFalse(h.fired, "the sandbox must refuse to execute the filter program")
        // The sandbox does not get in the way of honest work.
        let clean = try makeRepo(f, "code/honest")
        guard case .trusted(let honest) = await Git.open(f.path(clean.rel), env: f.env) else { return XCTFail() }
        try f.file("code/honest/new.txt", "x")
        let r = await Git.run(honest, ["status", "--porcelain=v1", "-uall"], env: f.env)
        XCTAssertTrue(r.ok, r.stderr)
        XCTAssertTrue(r.stdout.contains("new.txt"))
    }

    func testInheritedGitEnvironmentIsNotPassedOn() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        // What a hostile parent process could set: an fsmonitor through the environment, another git dir.
        setenv("GIT_CONFIG_COUNT", "1", 1); setenv("GIT_CONFIG_KEY_0", "core.fsmonitor", 1); setenv("GIT_CONFIG_VALUE_0", h.script, 1)
        setenv("GIT_DIR", "/nonexistent", 1)
        defer { for v in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_DIR"] { unsetenv(v) } }
        let env = Git.environment(f.env)
        XCTAssertTrue(env.keys.filter { $0.hasPrefix("GIT_") }.allSatisfy {
            ["GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ATTR_NOSYSTEM", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS",
             "GIT_ASKPASS", "GIT_PAGER", "GIT_NO_LAZY_FETCH"].contains($0)
        }, "\(env.keys.sorted())")
        XCTAssertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        let groups = await f.engine().scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
        let c = try XCTUnwrap(groups.flatMap(\.clones).first)
        XCTAssertTrue(c.wasInspected)
        XCTAssertEqual(c.branch, "main", "GIT_DIR from the environment must not redirect git")
        XCTAssertFalse(h.fired)
    }

    // MARK: The allowlist

    func testConfigKeyAllowlist() {
        let harmless: [(String, String?)] = [
            ("core.repositoryformatversion", "0"), ("core.filemode", "true"), ("core.bare", "false"), ("core.logallrefupdates", "true"),
            ("core.ignorecase", "true"), ("core.precomposeunicode", "true"), ("core.worktree", "../../x"), ("core.fsmonitor", "false"),
            ("core.fsmonitor", "true"), ("core.fsmonitor", nil), ("core.autocrlf", "input"),
            ("remote.origin.url", "git@github.com:a/b.git"), ("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"),
            ("remote.up.stream.pushurl", "https://example.com/a/b"), ("remote.origin.gh-resolved", "base"),
            ("branch.main.remote", "origin"), ("branch.main.merge", "refs/heads/main"), ("branch.feat/x.vscode-merge-base", "origin/main"),
            ("branch.main.gk-last-accessed", "x"), ("user.name", "A"), ("user.email", "a@example.com"), ("init.defaultbranch", "main"),
            ("pull.rebase", "true"), ("push.default", "current"), ("fetch.prune", "true"), ("extensions.worktreeconfig", "true"),
            ("submodule.lib.url", "https://example.com/lib"), ("submodule.lib.active", "true"), ("submodule.lib.update", "checkout"),
            ("lfs.repositoryformatversion", "0"), ("lfs.https://example.com/a/b.git/info/lfs.access", "basic"),
            ("commit.gpgsign", "true"), ("merge.ff", "only"), ("diff.renames", "true"), ("diff.swift.xfuncname", "^func"),
        ]
        for (k, v) in harmless { XCTAssertTrue(GitConfigPolicy.isHarmless(key: k, value: v), "\(k)=\(v ?? "(none)")") }
        let dangerous: [(String, String?)] = [
            ("core.fsmonitor", "/tmp/x.sh"), ("core.fsmonitor", ".git/hooks/query-watchman"), ("core.hookspath", "/tmp"),
            ("core.sshcommand", "x"), ("core.gitproxy", "x"), ("core.pager", "x"), ("core.editor", "x"), ("core.askpass", "x"),
            ("core.alternaterefscommand", "x"), ("core.attributesfile", "/tmp/a"), ("core.bare", "true"),
            ("filter.lfs.clean", "git-lfs clean -- %f"), ("filter.lfs.smudge", "x"), ("filter.lfs.process", "x"), ("filter.x.required", "true"),
            ("diff.x.command", "x"), ("diff.x.textconv", "x"), ("diff.external", "x"), ("diff.tool", "x"),
            ("merge.x.driver", "x"), ("merge.tool", "x"), ("mergetool.x.cmd", "x"), ("difftool.x.cmd", "x"),
            ("credential.helper", "x"), ("credential.https://github.com.helper", "x"), ("gpg.program", "x"), ("gpg.ssh.program", "x"),
            ("gpg.x509.program", "x"), ("include.path", "x"), ("includeif.gitdir:/x/.path", "x"), ("alias.st", "!x"),
            ("url.https://evil/.insteadof", "https://github.com/"), ("protocol.ext.allow", "always"), ("protocol.allow", "always"),
            ("uploadpack.packobjectshook", "x"), ("receive.procreceiverefs", "x"), ("sequence.editor", "x"), ("pager.status", "x"),
            ("interactive.difffilter", "x"), ("submodule.lib.update", "!rm -rf x"), ("remote.origin.url", "ext::sh -c x"),
            ("remote.origin.uploadpack", "x"), ("remote.origin.receivepack", "x"), ("remote.origin.vcs", "x"), ("remote.origin.proxy", "x"),
            ("log.showsignature", "true"), ("trace2.eventtarget", "/tmp/x"), ("sendemail.smtpserver", "x"), ("man.x.cmd", "x"),
            ("browser.x.cmd", "x"), ("web.browser", "x"), ("instaweb.httpd", "x"), ("trailer.x.command", "x"), ("lfs.extension.x.clean", "x"),
            ("fsmonitor.socketdir", "x"), ("totallyunknown.key", "x"), ("nodot", "x"),
        ]
        for (k, v) in dangerous { XCTAssertFalse(GitConfigPolicy.isHarmless(key: k, value: v), "\(k)=\(v ?? "(none)")") }
        XCTAssertEqual(GitConfigPolicy.reportName("credential.https://user:secret@host.helper"), "credential.*.helper",
                       "reports carry key names only, never a subsection that may hold a secret")
    }

    func testEveryHardeningFlagIsAcceptedByGitAndOrdinaryReposStayInspectable() async throws {
        let f = try Fixture()
        try f.repo("code/plain")
        try f.git("code/plain", "config", "branch.main.vscode-merge-base", "origin/main")
        try f.git("code/plain", "config", "core.fsmonitor", "false")
        guard case .trusted(let repo) = await Git.open(f.path("code/plain"), env: f.env) else { return XCTFail("ordinary settings must not be flagged") }
        for args in [["status", "--porcelain=v1", "-z", "-uall", "--ignore-submodules=all"], ["rev-parse", "HEAD"],
                     ["ls-files", "-z"], ["log", "-1", "--format=%ct", "--no-show-signature"]] {
            let r = await Git.run(repo, args, env: f.env)
            XCTAssertTrue(r.ok, "\(args): \(r.stderr)")
        }
        // A repository without a config file, or with one git cannot parse, fails closed.
        try f.repo("code/broken")
        try "[core\n\tthis is not config".write(toFile: f.path("code/broken/.git/config"), atomically: true, encoding: .utf8)
        if case .trusted = await Git.open(f.path("code/broken"), env: f.env) { XCTFail("unparsable config must not be trusted") }
        try FileManager.default.removeItem(atPath: f.path("code/broken/.git/config"))
        if case .trusted = await Git.open(f.path("code/broken"), env: f.env) { XCTFail("missing config must not be trusted") }
    }
}
