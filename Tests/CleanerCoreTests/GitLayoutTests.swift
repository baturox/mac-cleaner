import XCTest
@testable import CleanerCore

/// The engine must read a working copy's layout (`.git` file, `commondir`, `gitdir` back-pointer) exactly the
/// way git does. Wherever the two could disagree, git would read a configuration file the audit never saw.
final class GitLayoutTests: EngineTestCase {
    private struct Rig {
        let f: Fixture
        let marker: String
        let script: String
        var fired: Bool { FileManager.default.fileExists(atPath: marker) }
        func reset() { try? FileManager.default.removeItem(atPath: marker) }
    }

    /// `code/main` with a linked worktree `code/wt`, a committed `.gitattributes` that routes every file through
    /// the filter "evil", and a payload script that only creates a marker file inside the fixture.
    private func makeRig() throws -> Rig {
        let f = try Fixture()
        let marker = f.root + "/PAYLOAD-RAN"
        let script = f.root + "/payload.sh"
        try f.file(script, "#!/bin/sh\n/usr/bin/touch '\(marker)'\n/bin/cat\nexit 0\n")
        chmod(script, 0o755)
        try f.repo("code/main", files: ["a.txt": "hello\n", ".gitattributes": "* filter=evil\n"])
        try f.git("code/main", "worktree", "add", "-q", "-b", "side", f.path("code/wt"))
        return Rig(f: f, marker: marker, script: script)
    }

    /// Makes git re-read tracked files (so content filters run) without waiting for the clock.
    private func touch(_ f: Fixture, _ rel: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: f.path(rel))
    }

    /// A second "common directory" whose name differs from a clean one only by a trailing space, holding the
    /// hostile configuration; `commondir` of the worktree is rewritten to `raw`.
    private func plantLookalike(_ r: Rig, commondir raw: Data) throws {
        let f = r.f
        let clean = f.path("code/main/.gitx")
        let hostile = f.path("code/main/.gitx ")
        try FileManager.default.copyItem(atPath: f.path("code/main/.git"), toPath: hostile)
        try FileManager.default.createDirectory(atPath: clean, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: f.path("code/main/.git/config"), toPath: clean + "/config")
        _ = try f.runGitSync(f.home, ["config", "--file", hostile + "/config", "filter.evil.clean", r.script])
        try raw.write(to: URL(fileURLWithPath: f.path("code/main/.git/worktrees/wt/commondir")))
        try touch(f, "code/wt/a.txt")
    }

    private func isTrusted(_ audit: GitAudit) -> Bool { if case .trusted = audit { return true }; return false }

    // MARK: H1

    func testCommondirWithTrailingSpaceIsNotTrustedAndNothingRuns() async throws {
        let r = try makeRig()
        try plantLookalike(r, commondir: Data("../../../.gitx \n".utf8))
        // Positive control: git itself reads the directory WITH the space, and plain git runs the filter.
        r.reset()
        _ = try? r.f.git("code/wt", "status", "--porcelain=v1", "-uall")
        XCTAssertTrue(r.fired, "fixture is not exploitable; the test would prove nothing")
        let seen = try r.f.git("code/wt", "config", "--local", "--list")
        XCTAssertTrue(seen.contains("filter.evil.clean"), "git must be reading the look-alike directory")
        r.reset()
        try touch(r.f, "code/wt/a.txt")

        for sandbox in [false, true] {
            var env = r.f.env
            env.sandboxGit = sandbox
            let audit = await Git.open(r.f.path("code/wt"), env: env)
            XCTAssertFalse(isTrusted(audit), "sandbox=\(sandbox)")
            let state = await RepoInspector.inspect(path: r.f.path("code/wt"), isLinkedWorktree: true, env: env)
            XCTAssertNotNil(state.untrustedKeys, "sandbox=\(sandbox): must be reported as not inspected")
            XCTAssertFalse(r.fired, "sandbox=\(sandbox): the payload ran")
        }
        // The walker still lists the folder (as not inspected) instead of silently dropping it.
        let groups = await r.f.engine().scanRepos(root: URL(fileURLWithPath: r.f.path("code")), progress: { _ in })
        let wt = try XCTUnwrap(groups.flatMap(\.clones).first { $0.url.path == r.f.path("code/wt") })
        XCTAssertFalse(wt.wasInspected)
        XCTAssertFalse(wt.isFullyBackedUp)
        XCTAssertFalse(r.fired)
    }

    func testCommondirWithLeadingSpaceTabOrControlCharacterIsNotTrusted() async throws {
        for raw in [" ../..\n", "../.. \n", "\t../..\n", "../..\u{01}\n", "../..\n\n ", "\u{00A0}../..\n", "../..\u{2028}\n"] {
            let r = try makeRig()
            try Data(raw.utf8).write(to: URL(fileURLWithPath: r.f.path("code/main/.git/worktrees/wt/commondir")))
            let audit = await Git.open(r.f.path("code/wt"), env: r.f.env)
            XCTAssertFalse(isTrusted(audit), "commondir \(raw.debugDescription)")
            XCTAssertNil(GitLayout.of(workTree: r.f.path("code/wt")), raw.debugDescription)
        }
    }

    func testCommondirWithCRLFIsReadLikeGitAndStaysTrusted() async throws {
        let r = try makeRig()
        try Data("../..\r\n".utf8).write(to: URL(fileURLWithPath: r.f.path("code/main/.git/worktrees/wt/commondir")))
        // Positive control: git accepts this file (it strips trailing CR and LF).
        XCTAssertEqual(try r.f.git("code/wt", "rev-parse", "--abbrev-ref", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), "side")
        let layout = try XCTUnwrap(GitLayout.of(workTree: r.f.path("code/wt")))
        XCTAssertEqual(layout.commonDir, r.f.path("code/main/.git"))
        XCTAssertEqual(layout.gitDir, r.f.path("code/main/.git/worktrees/wt"))
        let audit = await Git.open(r.f.path("code/wt"), env: r.f.env)
        XCTAssertTrue(isTrusted(audit))
    }

    func testNonUTF8OrDanglingCommondirIsNotTrusted() async throws {
        for raw in [Data([0x2E, 0x2E, 0x2F, 0xFF, 0xFE, 0x0A]), Data("../../does-not-exist\n".utf8), Data(), Data("\n".utf8)] {
            let r = try makeRig()
            try raw.write(to: URL(fileURLWithPath: r.f.path("code/main/.git/worktrees/wt/commondir")))
            let audit = await Git.open(r.f.path("code/wt"), env: r.f.env)
            XCTAssertFalse(isTrusted(audit), "commondir bytes \(Array(raw))")
            if case .notARepository = audit { XCTFail("a malformed layout must be reported as untrusted, not silently skipped: \(Array(raw))") }
        }
    }

    func testGitFileAndBackPointerWithOddContentAreNotTrusted() async throws {
        // The `.git` file of the worktree.
        for mutate in [{ (s: String) in s.replacingOccurrences(of: "gitdir: ", with: "gitdir:  ") },
                       { (s: String) in s.trimmingCharacters(in: .newlines) + " \n" },
                       { (s: String) in s.replacingOccurrences(of: "gitdir: ", with: "gitdir:") },
                       { (s: String) in s.trimmingCharacters(in: .newlines) + "\u{07}\n" },
                       { (s: String) in s.trimmingCharacters(in: .newlines) + "/nowhere\n" }] {
            let r = try makeRig()
            let dotGit = r.f.path("code/wt/.git")
            let old = try String(contentsOfFile: dotGit, encoding: .utf8)
            try mutate(old).write(toFile: dotGit, atomically: true, encoding: .utf8)
            let audit = await Git.open(r.f.path("code/wt"), env: r.f.env)
            XCTAssertFalse(isTrusted(audit), mutate(old).debugDescription)
            if case .notARepository = audit { XCTFail("must be untrusted, not skipped: \(mutate(old).debugDescription)") }
        }
        // The `gitdir` back-pointer inside the main repository.
        for raw in [" /somewhere/.git\n", "/somewhere/.git \n", "\u{1B}[2J\n", "/does/not/exist/.git\n"] {
            let r = try makeRig()
            try raw.write(toFile: r.f.path("code/main/.git/worktrees/wt/gitdir"), atomically: true, encoding: .utf8)
            let audit = await Git.open(r.f.path("code/wt"), env: r.f.env)
            XCTAssertFalse(isTrusted(audit), "gitdir \(raw.debugDescription)")
        }
        // A `.git` that is a symlink is not followed.
        let r = try makeRig()
        try FileManager.default.removeItem(atPath: r.f.path("code/wt/.git"))
        try FileManager.default.createSymbolicLink(atPath: r.f.path("code/wt/.git"), withDestinationPath: r.f.path("code/main/.git"))
        let linkAudit = await Git.open(r.f.path("code/wt"), env: r.f.env)
        XCTAssertFalse(isTrusted(linkAudit))
    }

    func testOrdinaryCloneAndWorktreeAreTrustedAndAgreeWithGit() async throws {
        // Positive control for every test above: nothing here is refused when the layout is ordinary.
        let r = try makeRig()
        for rel in ["code/main", "code/wt"] {
            guard case .trusted(let repo) = await Git.open(r.f.path(rel), env: r.f.env) else { XCTFail("\(rel) must be trusted"); continue }
            let fromGit = try r.f.git(rel, "rev-parse", "--path-format=absolute", "--git-common-dir", "--absolute-git-dir")
                .split(separator: "\n").map { realPath(String($0)) ?? String($0) }
            XCTAssertEqual([realPath(repo.layout.commonDir), realPath(repo.layout.gitDir)], fromGit.map(Optional.some), rel)
        }
    }

    /// The cross-check asks git itself where the repository lives. That is only acceptable if this particular
    /// command starts nothing the repository's configuration names, even with no hardening at all.
    func testRevParseUsedForTheCrossCheckRunsNoConfiguredProgram() async throws {
        let r = try makeRig()
        let f = r.f
        let keys = ["core.fsmonitor", "core.pager", "core.editor", "core.sshCommand", "core.gitProxy", "core.askPass",
                    "core.alternateRefsCommand", "alias.rev-parse", "pager.rev-parse", "gc.recentObjectsHook", "credential.helper",
                    "diff.external", "filter.evil.clean", "filter.evil.smudge", "filter.evil.process", "uploadpack.packObjectsHook",
                    "gpg.program", "sequence.editor", "trace2.eventTarget"]
        for k in keys { try f.git("code/main", "config", k, r.script) }
        try f.git("code/main", "config", "pager.rev-parse", "true")
        try f.dir(f.root + "/hooks")
        for hook in ["post-index-change", "reference-transaction", "post-checkout", "pre-commit"] {
            try f.file(f.root + "/hooks/" + hook, "#!/bin/sh\n/usr/bin/touch '\(r.marker)'\n")
            chmod(f.root + "/hooks/" + hook, 0o755)
        }
        try f.git("code/main", "config", "core.hooksPath", f.root + "/hooks")
        try touch(f, "code/main/a.txt")
        // Positive control: an ordinary command does run the payload with this configuration.
        r.reset()
        _ = try? f.git("code/main", "status", "--porcelain=v1")
        XCTAssertTrue(r.fired, "fixture is not exploitable; the test would prove nothing")
        r.reset()
        for rel in ["code/main", "code/wt"] {
            let out = try f.git(rel, "--git-dir=" + (rel == "code/main" ? f.path("code/main/.git") : f.path("code/main/.git/worktrees/wt")),
                                "--work-tree=" + f.path(rel), "rev-parse", "--git-common-dir", "--absolute-git-dir")
            XCTAssertEqual(out.split(separator: "\n").count, 2)
        }
        XCTAssertFalse(r.fired, "rev-parse started a program named by the repository's configuration")
    }

    // MARK: L6

    func testCloneWithSeparateGitDirUnderAFolderNamedWorktreesIsAClone() throws {
        let f = try Fixture()
        try f.dir("store/worktrees")
        try f.dir("code/sep")
        _ = try f.runGitSync(f.path("code/sep"), ["init", "-q", "--separate-git-dir", f.path("store/worktrees/sep.git")])
        // Positive control: the `.git` file really points below a folder called "worktrees".
        XCTAssertTrue(try String(contentsOfFile: f.path("code/sep/.git"), encoding: .utf8).contains("/worktrees/"))
        XCTAssertEqual(RepoWalker.classify(f.path("code/sep")), .clone)
        // And a real linked worktree is still recognised, with its main clone.
        try f.repo("code/main")
        try f.git("code/main", "worktree", "add", "-q", "-b", "side", f.path("code/wt"))
        XCTAssertEqual(RepoWalker.classify(f.path("code/wt")), .linked(main: f.path("code/main")))
        XCTAssertEqual(RepoWalker.classify(f.path("code/main")), .clone)
    }
}
