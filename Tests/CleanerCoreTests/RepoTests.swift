import XCTest
@testable import CleanerCore

final class RepoTests: EngineTestCase {
    private func scan(_ f: Fixture, root: String? = nil) async -> [RepoGroup] {
        await f.engine().scanRepos(root: URL(fileURLWithPath: root ?? f.home), progress: { _ in })
    }

    private func allClones(_ groups: [RepoGroup]) -> [RepoClone] { groups.flatMap(\.clones) }

    private func clone(_ groups: [RepoGroup], _ rel: String, _ f: Fixture) -> RepoClone? {
        allClones(groups).first { $0.url.path == f.path(rel) }
    }

    /// A repo cloned from a local bare remote, so push state is real.
    private func cloneWithRemote(_ f: Fixture, remote: String, to rel: String) throws {
        let seed = "seed-" + rel.replacingOccurrences(of: "/", with: "-")
        try f.bareRemote(remote)
        try f.repo(seed)
        try f.git(seed, "remote", "add", "origin", f.path(remote))
        try f.git(seed, "push", "-q", "origin", "main")
        _ = try f.runGitSync(f.home, ["clone", "-q", f.path(remote), f.path(rel)])
        try FileManager.default.removeItem(atPath: f.path(seed))
    }

    // MARK: URL normalization

    func testRemoteURLNormalization() {
        let expected = "github.com/Owner/Repo"
        for raw in ["git@github.com:Owner/Repo.git", "https://github.com/Owner/Repo.git", "https://GitHub.com/Owner/Repo/",
                    "https://user:s3cret-token@github.com/Owner/Repo.git", "ssh://git@github.com:22/Owner/Repo.git",
                    "git://github.com/Owner/Repo", "ssh://git@GITHUB.COM/Owner/Repo.git/", "github.com:Owner/Repo"] {
            XCTAssertEqual(RemoteURL.normalize(raw), expected, raw)
        }
        XCTAssertEqual(RemoteURL.normalize("git@gitlab.com:group/sub/proj.git"), "gitlab.com/group/sub/proj")
        XCTAssertNil(RemoteURL.normalize("/Users/me/remotes/repo.git"))
        XCTAssertNil(RemoteURL.normalize("../relative/repo.git"))
        XCTAssertNil(RemoteURL.normalize("file:///tmp/repo.git"))
        XCTAssertNil(RemoteURL.normalize(""))
        XCTAssertEqual(RemoteURL.displayName("github.com/Owner/Repo"), "Owner/Repo")
        XCTAssertFalse((RemoteURL.normalize("https://user:s3cret-token@github.com/o/r") ?? "").contains("s3cret"))
    }

    // MARK: Scanning

    func testCleanClonePushedAndBackedUp() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/app.git", to: "code/app")
        let groups = await scan(f, root: f.path("code"))
        let c = try XCTUnwrap(clone(groups, "code/app", f))
        XCTAssertEqual(c.branch, "main")
        XCTAssertEqual(c.uncommittedCount, 0)
        XCTAssertEqual(c.unpushedCount, 0)
        XCTAssertFalse(c.hasStash)
        XCTAssertFalse(c.isLinkedWorktree)
        XCTAssertNotNil(c.lastCommit)
        XCTAssertTrue(c.isFullyBackedUp)
        XCTAssertGreaterThan(c.sizeBytes, 0)
    }

    func testDirtyUnpushedAndStashedClones() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/a.git", to: "code/dirty")
        try f.file("code/dirty/new.txt", "untracked")
        try f.file("code/dirty/README.md", "modified")
        try cloneWithRemote(f, remote: "remotes/b.git", to: "code/ahead")
        try f.file("code/ahead/x.txt", "x")
        try f.git("code/ahead", "add", "-A"); try f.git("code/ahead", "commit", "-q", "-m", "local only")
        try f.git("code/ahead", "checkout", "-q", "-b", "feature")
        try f.file("code/ahead/y.txt", "y")
        try f.git("code/ahead", "add", "-A"); try f.git("code/ahead", "commit", "-q", "-m", "feature work")
        try cloneWithRemote(f, remote: "remotes/c.git", to: "code/stashed")
        try f.file("code/stashed/README.md", "changed")
        try f.git("code/stashed", "stash", "-q")
        let groups = await scan(f, root: f.path("code"))
        let dirty = try XCTUnwrap(clone(groups, "code/dirty", f))
        XCTAssertEqual(dirty.uncommittedCount, 2)
        XCTAssertFalse(dirty.isFullyBackedUp)
        let ahead = try XCTUnwrap(clone(groups, "code/ahead", f))
        XCTAssertEqual(ahead.unpushedCount, 2, "commits on every local branch that no remote has")
        XCTAssertEqual(ahead.branch, "feature")
        XCTAssertFalse(ahead.isFullyBackedUp)
        let stashed = try XCTUnwrap(clone(groups, "code/stashed", f))
        XCTAssertTrue(stashed.hasStash)
        XCTAssertEqual(stashed.uncommittedCount, 0)
        XCTAssertFalse(stashed.isFullyBackedUp)
    }

    func testRepoWithoutRemoteIsNotBackedUp() async throws {
        let f = try Fixture()
        try f.repo("code/local")
        let groups = await scan(f, root: f.path("code"))
        let c = try XCTUnwrap(clone(groups, "code/local", f))
        XCTAssertNil(c.unpushedCount)
        XCTAssertFalse(c.isFullyBackedUp)
        XCTAssertNil(groups.first?.remote)
        XCTAssertEqual(groups.first?.name, "local")
    }

    func testLinkedWorktreeIsGroupedWithItsMainCloneAndBackedUpWhenClean() async throws {
        let f = try Fixture()
        try f.repo("code/main")
        try f.git("code/main", "worktree", "add", "-q", f.path("code/main-feature"), "-b", "feature")
        try f.file("code/main-feature/work.txt", "committed on the branch")
        try f.git("code/main-feature", "add", "-A"); try f.git("code/main-feature", "commit", "-q", "-m", "wip")
        let groups = await scan(f, root: f.path("code"))
        XCTAssertEqual(groups.count, 1, "the worktree belongs to its main clone's group")
        XCTAssertEqual(groups[0].clones.count, 2)
        let wt = try XCTUnwrap(clone(groups, "code/main-feature", f))
        XCTAssertTrue(wt.isLinkedWorktree)
        XCTAssertFalse(wt.hasStash)
        XCTAssertEqual(wt.branch, "feature")
        XCTAssertTrue(wt.isFullyBackedUp, "commits live in the main clone, so only uncommitted work could be lost")
        try f.file("code/main-feature/dirty.txt", "x")
        let again = await scan(f, root: f.path("code"))
        XCTAssertFalse(try XCTUnwrap(clone(again, "code/main-feature", f)).isFullyBackedUp)
        XCTAssertFalse(try XCTUnwrap(clone(again, "code/main", f)).isLinkedWorktree)
    }

    func testSubmodulesAreSkipped() async throws {
        let f = try Fixture()
        let sub = try f.bareRemote("remotes/sub.git")
        try f.repo("seed-sub")
        try f.git("seed-sub", "remote", "add", "origin", sub)
        try f.git("seed-sub", "push", "-q", "origin", "main")
        try f.repo("code/parent")
        try f.git("code/parent", "submodule", "add", "-q", sub, "vendor-sub")
        try f.git("code/parent", "commit", "-q", "-m", "add submodule")
        XCTAssertTrue(f.exists("code/parent/vendor-sub/.git"))
        let groups = await scan(f, root: f.path("code"))
        XCTAssertEqual(allClones(groups).map { $0.url.lastPathComponent }, ["parent"])
    }

    func testClonesOfTheSameRemoteAreGroupedByNormalizedURL() async throws {
        let f = try Fixture()
        try f.repo("code/one"); try f.git("code/one", "remote", "add", "origin", "git@github.com:Acme/Widget.git")
        try f.repo("elsewhere/two"); try f.git("elsewhere/two", "remote", "add", "origin", "https://user:token@GitHub.com/acme/widget")
        try f.repo("code/three"); try f.git("code/three", "remote", "add", "origin", "https://github.com/acme/other.git")
        let groups = await scan(f)
        XCTAssertEqual(groups.count, 2)
        let widget = try XCTUnwrap(groups.first { $0.clones.count == 2 })
        XCTAssertEqual(widget.name.lowercased(), "acme/widget")
        XCTAssertEqual(widget.remote?.lowercased(), "github.com/acme/widget")
        XCTAssertFalse(widget.remote?.contains("token") ?? true)
        XCTAssertEqual(Set(widget.clones.map { $0.url.lastPathComponent }), ["one", "two"])
        XCTAssertTrue(widget.clones[0].sizeBytes >= widget.clones[1].sizeBytes, "largest first")
        XCTAssertTrue(groups[0].totalBytes >= groups[1].totalBytes)
    }

    func testNestedReposAreFoundAndArtifactsCounted() async throws {
        let f = try Fixture()
        try f.repo("code/outer", files: ["package.json": "{}", ".gitignore": "node_modules/\n"])
        try f.file("code/outer/node_modules/dep/index.js", bytes: 2 << 20)
        try f.repo("code/outer/tools/inner")
        try f.repo("code/outer/node_modules/dep/vendored", files: ["x": "y"])   // inside an artifact folder: not descended
        let groups = await scan(f, root: f.path("code"))
        XCTAssertEqual(Set(allClones(groups).map { $0.url.lastPathComponent }), ["outer", "inner"])
        let outer = try XCTUnwrap(clone(groups, "code/outer", f))
        XCTAssertGreaterThanOrEqual(outer.artifactBytes, 2 << 20)
        XCTAssertGreaterThanOrEqual(outer.sizeBytes, outer.artifactBytes)
    }

    func testProtectedReposAreNotListed() async throws {
        let f = try Fixture()
        try f.repo("code/secret"); try f.repo("code/open")
        let engine = f.engine(settings: EngineSettings(protectedPaths: ["~/code/secret"]))
        let groups = await engine.scanRepos(root: URL(fileURLWithPath: f.path("code")), progress: { _ in })
        XCTAssertEqual(allClones(groups).map { $0.url.lastPathComponent }, ["open"])
    }

    // MARK: Removal

    func testRemoveRefusesUnbackedUpUnlessForced() async throws {
        let f = try Fixture()
        try f.repo("code/work")
        try f.file("code/work/unsaved.txt", "precious")
        var groups = await scan(f, root: f.path("code"))
        let c = try XCTUnwrap(clone(groups, "code/work", f))
        let engine = f.engine()
        var r = await engine.removeClones([c], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("code/work/unsaved.txt"), "nothing is removed")
        XCTAssertTrue(r.messages.joined().contains("uncommitted"))
        r = await engine.removeClones([c], force: true, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        XCTAssertFalse(f.exists("code/work"))
        groups = await scan(f, root: f.path("code"))
        XCTAssertTrue(groups.isEmpty)
    }

    func testRemoveRereadsStateInsteadOfTrustingTheCaller() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/r.git", to: "code/app")
        let groups = await scan(f, root: f.path("code"))
        let stale = try XCTUnwrap(clone(groups, "code/app", f))
        XCTAssertTrue(stale.isFullyBackedUp)
        try f.file("code/app/late-change.txt", "made after the scan")     // the user keeps working
        let r = await f.engine().removeClones([stale], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("code/app/late-change.txt"))
    }

    func testRemoveBackedUpCloneAndTrashMode() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/a.git", to: "code/a")
        try cloneWithRemote(f, remote: "remotes/b.git", to: "code/b")
        let groups = await scan(f, root: f.path("code"))
        let a = try XCTUnwrap(clone(groups, "code/a", f)), b = try XCTUnwrap(clone(groups, "code/b", f))
        let engine = f.engine()
        var r = await engine.removeClones([a], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0, r.messages.joined(separator: ";"))
        XCTAssertFalse(f.exists("code/a"))
        r = await engine.removeClones([b], force: false, mode: .trash, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        XCTAssertFalse(f.exists("code/b"))
        XCTAssertEqual(f.trashedPaths, [f.path("code/b")])
    }

    func testRemoveLinkedWorktreeUsesGitAndPrunes() async throws {
        let f = try Fixture()
        try f.repo("code/main")
        try f.git("code/main", "worktree", "add", "-q", f.path("code/wt-one"), "-b", "one")
        try f.git("code/main", "worktree", "add", "-q", f.path("code/wt-two"), "-b", "two")
        let groups = await scan(f, root: f.path("code"))
        let one = try XCTUnwrap(clone(groups, "code/wt-one", f)), two = try XCTUnwrap(clone(groups, "code/wt-two", f))
        let engine = f.engine()
        var r = await engine.removeClones([one], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0, r.messages.joined(separator: ";"))
        XCTAssertFalse(f.exists("code/wt-one"))
        var list = try f.git("code/main", "worktree", "list", "--porcelain")
        XCTAssertFalse(list.contains("wt-one"))
        XCTAssertTrue(list.contains("wt-two"))
        // Trash mode: folder goes to the (fake) Trash, then the stale registration is pruned.
        r = await engine.removeClones([two], force: false, mode: .trash, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0, r.messages.joined(separator: ";"))
        XCTAssertEqual(f.trashedPaths, [f.path("code/wt-two")])
        list = try f.git("code/main", "worktree", "list", "--porcelain")
        XCTAssertFalse(list.contains("wt-two"))
        XCTAssertTrue(f.exists("code/main/.git"))
    }

    func testDirtyWorktreeNeedsForce() async throws {
        let f = try Fixture()
        try f.repo("code/main")
        try f.git("code/main", "worktree", "add", "-q", f.path("code/wt"), "-b", "x")
        try f.file("code/wt/dirty.txt", "x")
        let groups = await scan(f, root: f.path("code"))
        let wt = try XCTUnwrap(clone(groups, "code/wt", f))
        let engine = f.engine()
        var r = await engine.removeClones([wt], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("code/wt/dirty.txt"))
        r = await engine.removeClones([wt], force: true, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0, r.messages.joined(separator: ";"))
        XCTAssertFalse(f.exists("code/wt"))
    }

    func testMainCloneWithLinkedWorktreesIsRefused() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/m.git", to: "code/main")
        try f.git("code/main", "worktree", "add", "-q", f.path("code/wt"), "-b", "x")
        let groups = await scan(f, root: f.path("code"))
        let main = try XCTUnwrap(clone(groups, "code/main", f))
        let r = await f.engine().removeClones([main], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(r.messages.joined().contains("worktree"))
        XCTAssertTrue(f.exists("code/main/.git"))
    }

    func testNestedUnsavedRepoBlocksRemovalOfParent() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/p.git", to: "code/parent")
        try f.file("code/parent/.git/info/exclude", "tools/\n")      // keep the parent itself clean
        try f.repo("code/parent/tools/inner")
        try f.file("code/parent/tools/inner/unsaved.txt", "x")
        let groups = await scan(f, root: f.path("code"))
        let parent = try XCTUnwrap(clone(groups, "code/parent", f))
        let r = await f.engine().removeClones([parent], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(r.messages.joined().contains("nested repository inner"), r.messages.joined())
        XCTAssertTrue(f.exists("code/parent/tools/inner/unsaved.txt"))
    }

    func testRemoveRefusesNonReposProtectedAndOutOfAreaPaths() async throws {
        let f = try Fixture()
        try f.file("code/plain/file.txt")
        try f.repo("code/guarded")
        func fake(_ rel: String) -> RepoClone {
            RepoClone(url: URL(fileURLWithPath: f.path(rel)), branch: nil, isLinkedWorktree: false, uncommittedCount: 0,
                      unpushedCount: 0, hasStash: false, lastCommit: nil, idleDays: 0, sizeBytes: 0, artifactBytes: 0)
        }
        let engine = f.engine(settings: EngineSettings(protectedPaths: ["~/code/guarded"]))
        let r = await engine.removeClones([fake("code/plain"), fake("code/guarded"), fake("code"), fake(".ssh")], force: true,
                                          mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 4)
        XCTAssertTrue(f.exists("code/plain/file.txt"))
        XCTAssertTrue(f.exists("code/guarded/.git"))
    }
}
