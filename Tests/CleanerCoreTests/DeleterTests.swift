import XCTest
@testable import CleanerCore

final class DeleterTests: EngineTestCase {
    func testAllowRuleHomeDepth() throws {
        let f = try Fixture()
        let d = f.deleter()
        XCTAssertFalse(d.isAllowed(f.home), "home itself")
        XCTAssertFalse(d.isAllowed(f.path("Projects")), "one level below home")
        try f.dir("Projects/app")
        XCTAssertTrue(d.isAllowed(f.path("Projects/app")), "two levels below home")
        XCTAssertTrue(d.isAllowed(f.path("Projects/app/leaf-not-created-yet")), "the leaf need not exist")
        XCTAssertFalse(d.isAllowed(f.path("Projects/not-created-yet/x")), "the parent must exist so it can be resolved")
        XCTAssertFalse(d.isAllowed(f.path("Nope/missing/x")), "unresolvable parent is refused")
    }

    func testAllowRuleRejectsRelativeAndDotDot() throws {
        let f = try Fixture()
        let d = f.deleter()
        try f.dir("a/b")
        XCTAssertFalse(d.isAllowed("a/b"))
        XCTAssertFalse(d.isAllowed(f.path("a/b/../b")))
        XCTAssertFalse(d.isAllowed(f.path("a/b/..")))
        XCTAssertFalse(d.isAllowed(f.path("a/./b")))
        XCTAssertFalse(d.isAllowed("/"))
        XCTAssertFalse(d.isAllowed("/usr/local/bin"))
        XCTAssertFalse(d.isAllowed("/private/var/db/anything"))
    }

    func testAllowRuleResolvesSymlinkedParents() throws {
        let f = try Fixture()
        let outside = try f.dir(f.root + "/outside/deep")
        try f.file(f.root + "/outside/deep/secret.txt")
        try f.dir("work")
        try f.symlink("work/escape", to: outside)
        let d = f.deleter()
        XCTAssertFalse(d.isAllowed(f.path("work/escape/secret.txt")), "a symlinked parent that leaves the home area")
        // The link itself is a normal item below home and may be removed (as a link).
        XCTAssertTrue(d.isAllowed(f.path("work/escape")))
        let r = d.remove([f.path("work/escape/secret.txt")])
        XCTAssertEqual(r.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside + "/secret.txt"))
    }

    func testAllowRuleTempAreas() throws {
        let f = try Fixture()
        let d = f.deleter()
        try f.dir(f.root + "/private-tmp/claude-501/proj")
        try f.dir(f.root + "/private-tmp/other/proj")
        try f.dir(f.root + "/tmp/T/one")
        XCTAssertTrue(d.isAllowed(f.root + "/private-tmp/something"))
        XCTAssertFalse(d.isAllowed(f.root + "/private-tmp"))
        XCTAssertTrue(d.isAllowed(f.root + "/private-tmp/claude-501/proj"))
        XCTAssertFalse(d.isAllowed(f.root + "/private-tmp/other/proj"), "only claude-* scratch folders may be entered")
        XCTAssertFalse(d.isAllowed(f.root + "/tmp/T"), "temp root itself")
        XCTAssertTrue(d.isAllowed(f.root + "/tmp/T/one"))
        XCTAssertFalse(d.isAllowed(f.root + "/tmp/other"))
    }

    func testBuiltInProtectedList() throws {
        let f = try Fixture()
        let d = f.deleter()
        for rel in [".ssh/id_ed25519", ".gnupg/pubring.kbx", ".aws/credentials", ".kube/config", ".config/gh/hosts.yml",
                    "Library/Keychains/login.keychain-db", ".claude/settings.json", ".claude/CLAUDE.md",
                    ".claude/agents/reviewer.md", ".claude/skills/x/SKILL.md", ".claude/plugins/p/plugin.json",
                    ".codex/auth.json", ".npmrc", ".docker/config.json"] {
            try f.file(rel)
            XCTAssertFalse(d.isAllowed(f.path(rel)), "\(rel) must be protected")
        }
        // Descendants of the user's own folders stay deletable; the folders themselves do not.
        for name in ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"] {
            try f.dir(name + "/sub/deeper")
            XCTAssertFalse(d.isAllowed(f.path(name)), "\(name) itself")
            XCTAssertTrue(d.isAllowed(f.path(name + "/sub")), "\(name)/sub is an explicit selection")
        }
        // Ordinary things next to protected ones are fine.
        try f.file(".cache/tool/blob")
        XCTAssertTrue(d.isAllowed(f.path(".cache/tool")))
    }

    /// The user's own top-level folders are refused by two independent rules: the depth rule (one level below
    /// home) and the protected list. This isolates the second: the list belongs to an account whose home is
    /// `~/nested`, so its Documents folder sits at a depth the deleter's own depth rule allows.
    func testUsersTopLevelFoldersAreRefusedByTheProtectedListAtAnAllowedDepth() throws {
        let f = try Fixture()
        var inner = f.env
        inner.home = try f.dir("nested")
        for name in ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Applications", "Public"] {
            let path = try f.dir("nested/" + name)
            try f.file("nested/" + name + "/sub/x")
            // Positive control: for the fixture's own account this is an ordinary folder two levels down.
            XCTAssertTrue(f.deleter().isAllowed(path), "\(name): the depth rule alone allows it")
            let guarded = Deleter(env: f.env, guardian: PathGuard(env: inner, settings: EngineSettings()))
            XCTAssertFalse(guarded.isAllowed(path), "\(name): refused by the protected list, not by depth")
            XCTAssertFalse(guarded.isAllowed(f.path("nested/" + name.uppercased())), "\(name): also under another letter case")
            XCTAssertEqual(guarded.remove([path]).failed, 1)
            XCTAssertTrue(f.exists("nested/" + name + "/sub/x"))
            XCTAssertTrue(guarded.isAllowed(path + "/sub"), "\(name)/sub stays an explicit selection")
            // The identity check that runs inside a walk knows the folder too.
            let guardian = PathGuard(env: inner, settings: EngineSettings())
            XCTAssertTrue(guardian.isProtectedID(try XCTUnwrap(FileID.of(path))))
            XCTAssertFalse(guardian.isHidden(path), "\(name) is not hidden from scans, only undeletable")
        }
        try f.dir("nested/Other")
        XCTAssertTrue(Deleter(env: f.env, guardian: PathGuard(env: inner, settings: EngineSettings())).isAllowed(f.path("nested/Other")))
    }

    func testProtectedClaudeMemoryAndAncestors() throws {
        let f = try Fixture()
        try f.file(".claude/projects/-proj/memory/notes.md")
        try f.file(".claude/projects/-proj/abc.jsonl")
        let d = f.deleter()
        XCTAssertFalse(d.isAllowed(f.path(".claude/projects/-proj/memory")))
        XCTAssertFalse(d.isAllowed(f.path(".claude/projects/-proj/memory/notes.md")))
        XCTAssertFalse(d.isAllowed(f.path(".claude/projects/-proj")), "removing the project folder would remove memory")
        XCTAssertTrue(d.isAllowed(f.path(".claude/projects/-proj/abc.jsonl")))
    }

    func testUserProtectedPathsAreHonoredAfterExpansionAndRealpath() throws {
        let f = try Fixture()
        try f.file("real/keep/data.bin")
        try f.symlink("alias", to: f.path("real"))
        try f.file("work/app/src/main.swift")
        try f.dir("real/other")
        let settings = EngineSettings(protectedPaths: ["~/alias/keep", "~/work/app/src", "  ", "relative/path"])
        let d = f.deleter(settings: settings)
        XCTAssertFalse(d.isAllowed(f.path("real/keep/data.bin")), "symlinked protection resolves to the real folder")
        XCTAssertFalse(d.isAllowed(f.path("real/keep")))
        XCTAssertFalse(d.isAllowed(f.path("work/app/src/main.swift")))
        XCTAssertFalse(d.isAllowed(f.path("work/app")), "parent of a protected folder")
        XCTAssertTrue(d.isAllowed(f.path("work/app/other")))
        XCTAssertTrue(d.isAllowed(f.path("real/other/x")))
    }

    func testRemovalSkipsProtectedAndReportsIt() throws {
        let f = try Fixture()
        try f.file(".ssh/id_rsa")
        try f.file("scratch/junk/a.txt")
        let r = f.deleter().remove([f.path(".ssh/id_rsa"), f.path("scratch/junk")])
        XCTAssertEqual(r.failed, 1)
        XCTAssertTrue(f.exists(".ssh/id_rsa"))
        XCTAssertFalse(f.exists("scratch/junk"))
        XCTAssertTrue(r.messages.first?.contains("Refused") ?? false)
    }

    func testSymlinkItemIsUnlinkedAndTargetSurvives() throws {
        let f = try Fixture()
        let target = try f.dir("data/target")
        try f.file("data/target/keep.txt")
        try f.symlink("proj/link", to: target)
        let r = f.deleter().remove([f.path("proj/link")])
        XCTAssertEqual(r.failed, 0)
        XCTAssertFalse(f.exists("proj/link"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "/keep.txt"))
    }

    func testReadOnlyTreeIsRemoved() throws {
        let f = try Fixture()
        try f.file("build/out/pkg/readonly.txt")
        try f.file("build/out/pkg/nested/deep.txt")
        chmod(f.path("build/out/pkg/readonly.txt"), 0o400)
        chmod(f.path("build/out/pkg/nested"), 0o500)
        chmod(f.path("build/out/pkg"), 0o500)
        let r = f.deleter().remove([f.path("build/out")])
        XCTAssertEqual(r.failed, 0, r.messages.joined(separator: "; "))
        XCTAssertFalse(f.exists("build/out"))
    }

    func testTrashModeMovesInsteadOfDeleting() throws {
        let f = try Fixture()
        try f.file("proj/old/a.txt")
        try f.file("proj/other/b.txt")
        let r = f.deleter().remove([f.path("proj/old")], mode: .trash)
        XCTAssertEqual(r.failed, 0)
        XCTAssertFalse(f.exists("proj/old"))
        XCTAssertEqual(f.trashedPaths, [f.path("proj/old")])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root + "/trashbin").count, 1)
        XCTAssertTrue(f.exists("proj/other/b.txt"))
    }

    func testTrashModeStillHonorsTheAllowRule() throws {
        let f = try Fixture()
        try f.file(".ssh/id_rsa")
        let r = f.deleter().remove([f.path(".ssh/id_rsa"), f.path("Projects")], mode: .trash)
        XCTAssertEqual(r.failed, 2)
        XCTAssertTrue(f.trashedPaths.isEmpty)
        XCTAssertTrue(f.exists(".ssh/id_rsa"))
    }

    func testItemsAlreadyInTrashAreDeletedPermanentlyEvenInTrashMode() throws {
        let f = try Fixture()
        try f.file(".Trash/old.dmg")
        let r = f.deleter().remove([f.path(".Trash/old.dmg")], mode: .trash)
        XCTAssertEqual(r.failed, 0)
        XCTAssertFalse(f.exists(".Trash/old.dmg"))
        XCTAssertTrue(f.trashedPaths.isEmpty)
    }

    func testEngineDeleteHonorsConfiguredProtectedPaths() async throws {
        let f = try Fixture()
        try f.file("work/keep/x.txt")
        try f.file("work/drop/y.txt")
        let engine = f.engine()
        await engine.configure(EngineSettings(protectedPaths: ["~/work/keep"]))
        let r = await engine.delete(urls: [URL(fileURLWithPath: f.path("work/keep/x.txt")), URL(fileURLWithPath: f.path("work/drop"))], progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("work/keep/x.txt"))
        XCTAssertFalse(f.exists("work/drop"))
    }

    func testEngineDeleteTrashMode() async throws {
        let f = try Fixture()
        try f.file("work/drop/y.txt")
        let r = await f.engine().delete(urls: [URL(fileURLWithPath: f.path("work/drop"))], mode: .trash, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        XCTAssertEqual(f.trashedPaths.count, 1)
    }
}
