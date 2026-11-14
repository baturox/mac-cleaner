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

    /// A repo cloned from a bare repository (so the remote-tracking refs are real) whose `origin` is then
    /// pointed at a network URL: only a network remote counts as a backup.
    private func cloneWithRemote(_ f: Fixture, remote: String, to rel: String, network: Bool = true) throws {
        let seed = "seed-" + rel.replacingOccurrences(of: "/", with: "-")
        try f.bareRemote(remote)
        try f.repo(seed, files: ["README.md": "hello", ".gitignore": ".env\n"])
        try f.git(seed, "remote", "add", "origin", f.path(remote))
        try f.git(seed, "push", "-q", "origin", "main")
        _ = try f.runGitSync(f.home, ["clone", "-q", f.path(remote), f.path(rel)])
        if network {
            let name = (remote as NSString).lastPathComponent
            try f.git(rel, "remote", "set-url", "origin", "https://example.invalid/acme/" + name)
        }
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

    // MARK: "Fully backed up" must mean nothing exists only here (finding 4)

    func testDetachedHeadWithLocalOnlyCommitIsNotBackedUp() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/d.git", to: "code/detached")
        try f.git("code/detached", "checkout", "-q", "--detach")
        try f.file("code/detached/work.txt", "work")
        try f.git("code/detached", "add", "-A"); try f.git("code/detached", "commit", "-q", "-m", "detached work")
        let scanned1 = await scan(f, root: f.path("code"))
        let c = try XCTUnwrap(clone(scanned1, "code/detached", f))
        XCTAssertNil(c.branch)
        XCTAssertEqual(c.unpushedCount, 1, "a commit reachable only from a detached HEAD is on no branch and no remote")
        XCTAssertFalse(c.isFullyBackedUp)
        let r = await f.engine().removeClones([c], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("code/detached/work.txt"))
    }

    func testDetachedLinkedWorktreeWithItsOwnCommitIsNotBackedUp() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/w.git", to: "code/main")
        try f.git("code/main", "worktree", "add", "-q", "--detach", f.path("code/wt-detached"))
        try f.git("code/main", "worktree", "add", "-q", "--detach", f.path("code/wt-at-remote"))
        try f.file("code/wt-detached/w.txt", "w")
        try f.git("code/wt-detached", "add", "-A"); try f.git("code/wt-detached", "commit", "-q", "-m", "worktree-only commit")
        let groups = await scan(f, root: f.path("code"))
        let wt = try XCTUnwrap(clone(groups, "code/wt-detached", f))
        XCTAssertTrue(wt.isLinkedWorktree)
        XCTAssertNil(wt.branch)
        XCTAssertEqual(wt.unpushedCount, 1)
        XCTAssertFalse(wt.isFullyBackedUp, "removing it would leave the commit unreachable")
        let atRemote = try XCTUnwrap(clone(groups, "code/wt-at-remote", f))
        XCTAssertEqual(atRemote.unpushedCount, 0)
        XCTAssertTrue(atRemote.isFullyBackedUp, "detached at a commit the remote has")
        let r = await f.engine().removeClones([wt, atRemote], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1, r.messages.joined(separator: "; "))
        XCTAssertTrue(r.messages.joined().contains("detached HEAD"))
        XCTAssertTrue(f.exists("code/wt-detached/w.txt"))
        XCTAssertFalse(f.exists("code/wt-at-remote"))
    }

    func testDetachedWorktreeWithoutNetworkRemoteIsNotBackedUp() async throws {
        let f = try Fixture()
        try f.repo("code/main")
        try f.git("code/main", "worktree", "add", "-q", "--detach", f.path("code/wt"))
        let scanned2 = await scan(f, root: f.path("code"))
        let wt = try XCTUnwrap(clone(scanned2, "code/wt", f))
        XCTAssertNil(wt.unpushedCount)
        XCTAssertFalse(wt.isFullyBackedUp)
    }

    func testIgnoredFilesThatExistOnlyHereBlockBackedUp() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/i.git", to: "code/app")            // .gitignore has ".env"
        try f.file("code/app/.git/info/exclude", "node_modules/\nbuild/\n.venv/\nsecrets/\n*.log\n.DS_Store\n__pycache__/\n")
        // Rebuildable or droppings: do not count.
        try f.file("code/app/node_modules/dep/index.js", "x")
        try f.file("code/app/build/out.o", "x")
        try f.file("code/app/.venv/pyvenv.cfg", "home = /usr/bin")
        try f.file("code/app/debug.log", "x")
        try f.file("code/app/.DS_Store", "x")
        try f.file("code/app/pkg/__pycache__/m.pyc", "x")
        let scanned3 = await scan(f, root: f.path("code"))
        var c = try XCTUnwrap(clone(scanned3, "code/app", f))
        XCTAssertEqual(c.uncommittedCount, 0)
        XCTAssertEqual(c.ignoredFileCount, 0, "build output and OS droppings are not unique data")
        XCTAssertTrue(c.isFullyBackedUp)
        // The only copy of a secrets file, and an ignored folder of data.
        try f.file("code/app/.env", "API_KEY=only-copy")
        try f.file("code/app/secrets/prod.pem", "x"); try f.file("code/app/secrets/staging.pem", "x")
        let scanned4 = await scan(f, root: f.path("code"))
        c = try XCTUnwrap(clone(scanned4, "code/app", f))
        XCTAssertEqual(c.uncommittedCount, 0, "git status alone still calls it clean")
        XCTAssertEqual(c.ignoredFileCount, 2, ".env and the secrets folder (a folder counts once)")
        XCTAssertFalse(c.isFullyBackedUp)
        let r = await f.engine().removeClones([c], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(r.messages.joined().contains("ignored"), r.messages.joined())
        XCTAssertTrue(f.exists("code/app/.env"))
    }

    func testIgnoredEntryClassification() {
        let repo = "/nowhere"
        for e in ["node_modules/", "dist/", "build/", ".next/", "target/", "sub/dir/node_modules/", "__pycache__/", "a/b/.DS_Store",
                  "x.pyc", "npm-debug.log", "xcuserdata/", "App.xcodeproj/xcuserdata/", "coverage/", ".build/", "cmake-build-debug/",
                  "node_modules", "packages/web/node_modules", "test-results/", "playwright-report/"] {
            XCTAssertTrue(RepoInspector.isRebuildable(ignored: e, repo: repo), e)
        }
        for e in [".env", ".env.local", "config/local.yml", "data/", "db.sqlite3", ".idea/", "notes.txt", "secrets/", "env/", ".venv/",
                  ".wrangler/", "terraform.tfstate"] {
            XCTAssertFalse(RepoInspector.isRebuildable(ignored: e, repo: repo), e)
        }
    }

    func testRemoteThatIsALocalPathIsNotABackup() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/local.git", to: "code/second-copy", network: false)
        try cloneWithRemote(f, remote: "remotes/fileurl.git", to: "code/file-url", network: false)
        try f.git("code/file-url", "remote", "set-url", "origin", "file://" + f.path("remotes/fileurl.git"))
        try cloneWithRemote(f, remote: "remotes/rel.git", to: "code/relative", network: false)
        try f.git("code/relative", "remote", "set-url", "origin", "../../remotes/rel.git")
        let groups = await scan(f, root: f.path("code"))
        for rel in ["code/second-copy", "code/file-url", "code/relative"] {
            let c = try XCTUnwrap(clone(groups, rel, f))
            XCTAssertNil(c.unpushedCount, "\(rel): a folder on this disk is not a remote")
            XCTAssertFalse(c.isFullyBackedUp, rel)
        }
        XCTAssertTrue(groups.allSatisfy { $0.remote == nil })
        // A network remote next to a local one still counts, and only its refs do.
        try f.git("code/second-copy", "remote", "add", "backup", "git@github.com:acme/widget.git")
        let scanned5 = await scan(f, root: f.path("code"))
        let again = try XCTUnwrap(clone(scanned5, "code/second-copy", f))
        XCTAssertNotNil(again.unpushedCount)
        XCTAssertGreaterThan(again.unpushedCount ?? 0, 0, "nothing was ever pushed to the network remote; origin's refs are local-only")
    }

    func testUnpushedTagsAreCounted() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/t.git", to: "code/tagged")
        try f.file("code/tagged/release.txt", "x")
        try f.git("code/tagged", "add", "-A"); try f.git("code/tagged", "commit", "-q", "-m", "release")
        try f.git("code/tagged", "tag", "v1.0.0")
        try f.git("code/tagged", "reset", "-q", "--hard", "HEAD~1")       // the commit is now reachable only from the tag
        let scanned6 = await scan(f, root: f.path("code"))
        let c = try XCTUnwrap(clone(scanned6, "code/tagged", f))
        XCTAssertEqual(c.uncommittedCount, 0)
        XCTAssertEqual(c.unpushedCount, 1)
        XCTAssertFalse(c.isFullyBackedUp)
    }

    func testForceIsLimitedToAcknowledgedClones() async throws {
        let f = try Fixture()
        try cloneWithRemote(f, remote: "remotes/a.git", to: "code/acknowledged")
        try f.file("code/acknowledged/unsaved.txt", "the user saw the warning for this one")
        try cloneWithRemote(f, remote: "remotes/b.git", to: "code/clean-at-scan")
        try cloneWithRemote(f, remote: "remotes/c.git", to: "code/clean")
        let groups = await scan(f, root: f.path("code"))
        let ack = try XCTUnwrap(clone(groups, "code/acknowledged", f))
        let stale = try XCTUnwrap(clone(groups, "code/clean-at-scan", f)), clean = try XCTUnwrap(clone(groups, "code/clean", f))
        XCTAssertTrue(stale.isFullyBackedUp)
        try f.file("code/clean-at-scan/late.txt", "work done after the scan; nobody acknowledged losing it")

        let plan = RepoRemovalPlan(clones: [ack, stale, clean], acknowledged: [ack.id])
        XCTAssertEqual(plan.forced.map(\.id), [ack.id])
        XCTAssertEqual(Set(plan.unforced.map(\.id)), [stale.id, clean.id], "force never covers a clone the user did not acknowledge")
        XCTAssertEqual(RepoRemovalPlan(clones: [ack, clean], acknowledged: []).forced, [], "an unacknowledged risky clone is not forced")
        XCTAssertEqual(RepoRemovalPlan(clones: [clean], acknowledged: [clean.id]).forced, [], "a backed-up clone never needs force")

        let engine = f.engine()
        let unforced = await engine.removeClones(plan.unforced, force: false, mode: .permanent, progress: { _ in })
        let forced = await engine.removeClones(plan.forced, force: true, mode: .permanent, progress: { _ in })
        XCTAssertEqual(unforced.failedCount, 1, "the engine's re-check still protects the one that changed")
        XCTAssertEqual(forced.failedCount, 0)
        XCTAssertTrue(f.exists("code/clean-at-scan/late.txt"))
        XCTAssertFalse(f.exists("code/clean"))
        XCTAssertFalse(f.exists("code/acknowledged"))
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
        // An ignored build folder keeps the parent itself clean; the nested clone inside it is still found.
        try f.file("code/parent/.git/info/exclude", "build/\n")
        try f.repo("code/parent/build/inner")
        try f.file("code/parent/build/inner/unsaved.txt", "x")
        let groups = await scan(f, root: f.path("code"))
        let parent = try XCTUnwrap(clone(groups, "code/parent", f))
        let r = await f.engine().removeClones([parent], force: false, mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(r.messages.joined().contains("nested repository inner"), r.messages.joined())
        XCTAssertTrue(f.exists("code/parent/build/inner/unsaved.txt"))
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
