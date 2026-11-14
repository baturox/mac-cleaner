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
    /// A different timestamp on every call: with one fixed value git may see nothing to refresh, and the
    /// positive controls (which need git to rewrite its index) then fail now and then.
    private var touchCount = 0.0
    private func touch(_ f: Fixture, _ rel: String) throws {
        touchCount += 1
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000 + touchCount * 60)], ofItemAtPath: f.path(rel))
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
        // The submodule is clean and "pushed": its origin is a network URL and the remote-tracking refs from
        // the clone are there. So the only thing that can make the parent not backed up is the audit below.
        try f.git("code/parent/sub", "remote", "set-url", "origin", "https://example.invalid/acme/sub.git")
        func parent() async throws -> RepoClone {
            let groups = await f.engine().scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
            return try XCTUnwrap(groups.flatMap(\.clones).first { $0.url.path == f.path("code/parent") })
        }
        // Positive control 1: with an honest submodule the parent has nothing uncommitted. If submodules were
        // never looked at, this would hold as well, which is why the next step must change it.
        let honest = try await parent()
        XCTAssertTrue(honest.wasInspected)
        XCTAssertEqual(honest.uncommittedCount, 0, "an inspected, clean, pushed submodule adds nothing")

        try appendConfig(f.path("code/parent/.git/modules/sub/config"), "[core]\n\tfsmonitor = \(h.script)")
        // Positive control 2: plain git inside the submodule runs the payload.
        try assertExploitable(h, in: "code/parent/sub")
        // So does a plain status of the PARENT that looks into submodules (what the engine must never do).
        h.reset()
        _ = try? f.git("code/parent", "status", "--porcelain=v1")
        XCTAssertTrue(h.fired, "git recursing into the submodule from the parent is exploitable; the test would prove nothing")
        h.reset()

        let hostile = try await parent()
        XCTAssertTrue(hostile.wasInspected, "the parent's own configuration is fine")
        XCTAssertEqual(hostile.uncommittedCount, 1, "the submodule was audited, found untrusted, and counts as work that cannot be verified")
        XCTAssertFalse(hostile.isFullyBackedUp)
        XCTAssertFalse(h.fired, "git must not have been run inside the submodule, directly or through the parent")
        // The submodule itself is reported as untrusted when asked directly.
        let sub = await RepoInspector.inspect(path: f.path("code/parent/sub"), isLinkedWorktree: false, env: f.env)
        XCTAssertEqual(sub.untrustedKeys, ["core.fsmonitor"])
        XCTAssertFalse(h.fired)
    }

    // MARK: Layers 2 and 3 on their own (configuration turns hostile AFTER the audit)

    /// Runs plain `/usr/bin/git` (optionally on a pseudo-terminal, which is the only place git starts a pager)
    /// with exactly the given extra options, in the fixture's clean environment.
    private func plainGit(_ h: Hostile, tty: Bool = false, _ args: [String]) {
        let p = Process()
        let git = ["/usr/bin/git", "-C", h.f.path(h.rel)] + args
        p.executableURL = URL(fileURLWithPath: tty ? "/usr/bin/script" : git[0])
        p.arguments = tty ? ["-q", "/dev/null"] + git : Array(git.dropFirst())
        var env = ChildEnvironment.base(home: h.f.home, tmp: h.f.env.tmp)
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"; env["TERM"] = "xterm"
        p.environment = env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    func testHardenedInvocationStopsFsmonitorHooksAndPagerEachOnItsOwnAndTogether() async throws {
        let f = try Fixture()
        let h = try makeRepo(f)
        guard case .trusted(let repo) = await Git.open(f.path(h.rel), env: f.env) else { return XCTFail("clean repo must be trusted") }
        let hooks = try f.dir(f.root + "/hooks")
        for hook in ["post-index-change", "reference-transaction", "post-checkout", "pre-commit"] {
            try f.file(hooks + "/" + hook, "#!/bin/sh\n/usr/bin/touch '\(h.marker)'\nexit 0\n")
            chmod(hooks + "/" + hook, 0o755)
        }
        /// One way in at a time: the setting, the plain command that triggers it, and the single override
        /// from `Git.hardening` that must defeat it.
        struct Vector { var name: String; var key: String; var value: String; var command: [String]; var tty: Bool; var override: [String] }
        let vectors = [
            Vector(name: "fsmonitor", key: "core.fsmonitor", value: h.script, command: ["status", "--porcelain=v1"], tty: false,
                   override: ["-c", "core.fsmonitor=false"]),
            Vector(name: "hook", key: "core.hooksPath", value: hooks, command: ["status", "--porcelain=v1"], tty: false,
                   override: ["-c", "core.hooksPath=/dev/null"]),
            Vector(name: "pager (config)", key: "core.pager", value: h.script, command: ["log", "-1"], tty: true,
                   override: ["-c", "core.pager=cat"]),
            Vector(name: "pager (switch)", key: "core.pager", value: h.script, command: ["log", "-1"], tty: true,
                   override: ["--no-pager"]),
        ]
        for v in vectors {
            // The engine really passes this override.
            XCTAssertTrue(Git.hardening.joined(separator: " ").contains(v.override.joined(separator: " ")), "\(v.name): \(v.override) is not in Git.hardening")
            try f.git(h.rel, "config", v.key, v.value)
            // Positive control: without the override the payload runs.
            try touch(f, h.rel + "/a.txt")
            h.reset()
            plainGit(h, tty: v.tty, v.command)
            XCTAssertTrue(h.fired, "\(v.name): the fixture is not exploitable; the test would prove nothing")
            // With only that one override it does not.
            try touch(f, h.rel + "/a.txt")
            h.reset()
            plainGit(h, tty: v.tty, v.override + v.command)
            XCTAssertFalse(h.fired, "\(v.name): \(v.override) did not stop it")
            try f.git(h.rel, "config", "--unset", v.key)
        }
        // All of them at once, through the engine's own entry point, sandbox off, on a pseudo-terminal-free
        // pipe and with every command the engine uses.
        try f.git(h.rel, "config", "core.fsmonitor", h.script)
        try f.git(h.rel, "config", "core.pager", h.script)
        try f.git(h.rel, "config", "core.hooksPath", hooks)
        try touch(f, h.rel + "/a.txt")
        try assertExploitable(h)
        try touch(f, h.rel + "/a.txt")
        var env = f.env
        env.sandboxGit = false
        for args in [["status", "--porcelain=v1", "-uall"], ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored=matching"],
                     ["ls-files", "-z"], ["ls-files", "-v", "-z"], ["ls-files", "-s", "-z"], ["check-ignore", "--", "dist/"],
                     ["log", "-1", "--format=%ct"], ["for-each-ref", "--format=%(refname)", "refs/stash"], ["symbolic-ref", "--short", "-q", "HEAD"],
                     ["rev-list", "--count", "HEAD"], ["rev-parse", "--git-common-dir", "--absolute-git-dir"]] {
            let r = await Git.run(repo, args, env: env)
            XCTAssertTrue(r.launched, "\(args)")
        }
        _ = await Git.run(repo, ["worktree", "prune"], env: env, mutating: true)
        XCTAssertFalse(h.fired, "command-line overrides must beat the repository's settings")
        // And the whole hardened argv on a pseudo-terminal: no pager either.
        plainGit(h, tty: true, Git.hardening + ["log", "-1"])
        XCTAssertFalse(h.fired, "a pager was started although the engine's options were given")
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
        defer { for v in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_DIR"] { unsetenv(v) } }
        // Positive control: a child that simply inherits this process's environment (what `Process` does by
        // default) runs the payload, in a repository whose own configuration is perfectly clean.
        func inherit(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", f.path(h.rel)] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        h.reset()
        XCTAssertEqual(inherit(["status", "--porcelain=v1"]), 0)
        XCTAssertTrue(h.fired, "the inherited variables are not an exploit here; the test would prove nothing")
        h.reset()
        setenv("GIT_DIR", "/nonexistent", 1)
        XCTAssertNotEqual(inherit(["rev-parse", "HEAD"]), 0, "positive control: an inherited GIT_DIR redirects plain git")

        let env = Git.environment(f.env)
        XCTAssertTrue(env.keys.filter { $0.hasPrefix("GIT_") }.allSatisfy {
            ["GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ATTR_NOSYSTEM", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS",
             "GIT_ASKPASS", "GIT_PAGER", "GIT_NO_LAZY_FETCH"].contains($0)
        }, "\(env.keys.sorted())")
        XCTAssertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        // End to end, sandbox off so that only the constructed environment stands between the variables and git.
        var noSandbox = f.env
        noSandbox.sandboxGit = false
        try touch(f, h.rel + "/a.txt")
        let engine = LiveEngine(env: noSandbox, settings: SettingsBox(), client: .cli, appVersion: "t")
        let groups = await engine.scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
        let c = try XCTUnwrap(groups.flatMap(\.clones).first)
        XCTAssertTrue(c.wasInspected)
        XCTAssertEqual(c.branch, "main", "GIT_DIR from the environment must not redirect git")
        XCTAssertEqual(c.uncommittedCount, 0)
        let artifacts = await engine.scanProjects(root: URL(fileURLWithPath: f.path("code")), minBytes: 1, progress: { _ in })
        XCTAssertEqual(Set(artifacts.map(\.kind)), ["node_modules", "dist"], "git answered (through the engine's own environment)")
        XCTAssertFalse(h.fired, "a variable inherited from the parent process reached git")
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
            ("gc.recentobjectshook", "x"), ("core.ignorestat", "true"), ("pull.twohead", "x"), ("init.templatedir", "/tmp/t"),
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
