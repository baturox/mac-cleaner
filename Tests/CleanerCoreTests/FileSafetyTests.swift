import XCTest
@testable import CleanerCore

/// Findings 2, 3, 8 and 9: symlinks in shared temp folders, races during the recursive delete,
/// letter-case aliases of protected paths, and mode changes on folders that survive.
final class FileSafetyTests: EngineTestCase {
    private func def(_ f: Fixture, _ id: String) -> CatDef { makeCategoryDefs(env: f.env).first { $0.id == id }! }

    private func ageTree(_ path: String, days: Double) {
        let date = Date().addingTimeInterval(-days * 86400)
        var stack = [path]
        while let p = stack.popLast() {
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR { for c in readDir(p) ?? [] { stack.append(p + "/" + c.name) } }
            if (st.st_mode & S_IFMT) != S_IFLNK { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: p) }
        }
    }

    // MARK: Finding 2 — symlinks and ownership in shared temp areas

    /// The exact exploit: /private/tmp/claude-evil -> ~/Documents made the safe category list (and delete)
    /// the user's documents.
    func testSymlinkedClaudeScratchFolderNeverListsOrDeletesHomeData() async throws {
        let f = try Fixture()
        try f.file("Documents/Thesis/chapter1.docx", bytes: 3 << 20)
        try f.file("Documents/Taxes-2025/return.pdf", bytes: 2 << 20)
        ageTree(f.path("Documents"), days: 10)
        try FileManager.default.createSymbolicLink(atPath: f.root + "/private-tmp/claude-evil", withDestinationPath: f.path("Documents"))
        // An honest scratch folder next to it still works.
        try f.file(f.root + "/private-tmp/claude-501/run/old.log", bytes: 5000)
        ageTree(f.root + "/private-tmp/claude-501", days: 10)

        let scratch = def(f, "claude-scratch")
        XCTAssertEqual(scratch.level, .safe)
        let paths = GenericScanner.itemPaths(of: scratch, globs: scratch.globs, ctx: f.context())
        XCTAssertEqual(paths, [f.root + "/private-tmp/claude-501/run"], "nothing may be listed through the symlink")

        // Even if a caller hands the engine the through-the-symlink paths directly, they are refused.
        let engine = f.engine()
        let forged = CleanCategory(id: "claude-scratch", name: "x", detail: "", level: .safe, symbol: "x",
                                   items: ["Thesis", "Taxes-2025"].map { CleanItem(url: URL(fileURLWithPath: f.root + "/private-tmp/claude-evil/" + $0), sizeBytes: 1) },
                                   sizeBytes: 2)
        let r = await engine.clean(categories: [forged], mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 2)
        XCTAssertTrue(f.exists("Documents/Thesis/chapter1.docx"))
        XCTAssertTrue(f.exists("Documents/Taxes-2025/return.pdf"))
        XCTAssertFalse(f.deleter().isAllowed(f.root + "/private-tmp/claude-evil/Thesis"))
        // The link itself is just an entry in /private/tmp and may go; its target is untouched.
        XCTAssertEqual(f.deleter().remove([f.root + "/private-tmp/claude-evil"]).failed, 0)
        XCTAssertTrue(f.exists("Documents/Thesis/chapter1.docx"))
    }

    func testFolderSwappedForSymlinkBetweenScanAndCleanIsRefused() async throws {
        let f = try Fixture()
        try f.file("Documents/Thesis/chapter1.docx", bytes: 4096)
        try f.file(f.root + "/private-tmp/claude-501/Thesis/junk", bytes: 4096)
        ageTree(f.root + "/private-tmp/claude-501", days: 10)
        let scratch = def(f, "claude-scratch")
        let listed = GenericScanner.itemPaths(of: scratch, globs: scratch.globs, ctx: f.context())
        XCTAssertEqual(listed, [f.root + "/private-tmp/claude-501/Thesis"])
        let cat = CleanCategory(id: scratch.id, name: scratch.name, detail: "", level: .safe, symbol: "x",
                                items: listed.map { CleanItem(url: URL(fileURLWithPath: $0), sizeBytes: 4096) }, sizeBytes: 4096)
        // After the scan the folder is replaced by a link to ~/Documents: the same item path now means the thesis.
        try FileManager.default.moveItem(atPath: f.root + "/private-tmp/claude-501", toPath: f.root + "/private-tmp/moved-away")
        try FileManager.default.createSymbolicLink(atPath: f.root + "/private-tmp/claude-501", withDestinationPath: f.path("Documents"))
        let r = await f.engine().clean(categories: [cat], mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertTrue(f.exists("Documents/Thesis/chapter1.docx"))
    }

    func testGlobNeverTraversesASymlinkedComponent() throws {
        let f = try Fixture()
        try f.file("real-data/keep/a.txt", bytes: 5000)
        try f.symlink("stuff", to: f.path("real-data"))                     // parent of the wildcard
        try f.file("caches/real/x", bytes: 5000)
        try f.symlink("caches/link", to: f.path("real-data"))               // a matched item that is a link
        try f.symlink("mid", to: f.path("caches"))                          // middle component
        XCTAssertEqual(f.env.expandPattern("~/stuff/*"), [], "listing through a symlinked folder")
        XCTAssertEqual(f.env.expandPattern("~/stuff/keep"), [], "exact path through a symlinked folder")
        XCTAssertEqual(f.env.expandPattern("~/mid/*/x"), [])
        XCTAssertEqual(f.env.expandPattern("~/*/keep").sorted(), [f.path("real-data/keep")], "only the real route is returned")
        // A link that is itself the item is listed (it would be unlinked, not followed)…
        XCTAssertEqual(Set(f.env.expandPattern("~/caches/*")), [f.path("caches/real"), f.path("caches/link")])
        // …and removing it leaves the target alone.
        XCTAssertEqual(f.deleter().remove([f.path("caches/link")]).failed, 0)
        XCTAssertTrue(f.exists("real-data/keep/a.txt"))
    }

    func testSharedTempAreasOnlyListAndRemoveWhatTheUserOwns() throws {
        let f = try Fixture()
        let pt = f.root + "/private-tmp"
        try f.file(pt + "/claude-501/run/old.log", bytes: 5000)
        try f.file(pt + "/old-file.bin", bytes: 5000)
        try f.file(f.root + "/tmp/T/old-temp/x", bytes: 5000)
        try f.file(f.root + "/tmp/C/old-cache/x", bytes: 5000)
        for p in [pt + "/claude-501", pt + "/old-file.bin", f.root + "/tmp/T/old-temp", f.root + "/tmp/C/old-cache"] { ageTree(p, days: 30) }
        let scratch = def(f, "claude-scratch"), temp = def(f, "temp")
        XCTAssertTrue(temp.deepAge, "the temp category judges age by the newest change inside each item")
        XCTAssertEqual(GenericScanner.itemPaths(of: scratch, globs: scratch.globs, ctx: f.context()), [pt + "/claude-501/run"])
        XCTAssertEqual(Set(GenericScanner.itemPaths(of: temp, globs: temp.globs, ctx: f.context())),
                       [pt + "/old-file.bin", f.root + "/tmp/T/old-temp", f.root + "/tmp/C/old-cache"])

        // Now the same tree as seen by a different account: everything in it belongs to "someone else".
        f.env.uid = getuid() &+ 1
        XCTAssertEqual(GenericScanner.itemPaths(of: scratch, globs: scratch.globs, ctx: f.context()), [])
        XCTAssertEqual(GenericScanner.itemPaths(of: temp, globs: temp.globs, ctx: f.context()), [])
        let r = f.deleter().remove([pt + "/old-file.bin", pt + "/claude-501/run", f.root + "/tmp/T/old-temp"])
        XCTAssertEqual(r.failed, 3, r.messages.joined(separator: "; "))
        XCTAssertTrue(f.exists(pt + "/old-file.bin"))
        XCTAssertTrue(f.exists(pt + "/claude-501/run/old.log"))
        XCTAssertTrue(f.exists(f.root + "/tmp/T/old-temp/x"))
        // Home is not a shared area: ownership is not what protects it, and nothing changes there.
        try f.file("Library/Caches/app/blob", bytes: 5000)
        XCTAssertEqual(f.env.expandPattern("~/Library/Caches/*"), [f.path("Library/Caches/app")])
    }

    func testTempCategoryKeepsSocketsFifosAndFoldersWithRecentActivityInside() throws {
        let f = try Fixture()
        let t = f.root + "/tmp/T"
        try f.file(t + "/idle/a/b.txt", bytes: 5000)
        try f.file(t + "/busy/deep/down/fresh.txt", bytes: 5000)
        try f.file(t + "/with-socket/data.txt", bytes: 5000)
        XCTAssertEqual(mkfifo(t + "/old.fifo", 0o600), 0)
        XCTAssertEqual(mkfifo(t + "/with-socket/agent.sock", 0o600), 0)      // stands in for a socket
        for p in [t + "/idle", t + "/busy", t + "/with-socket", t + "/old.fifo"] { ageTree(p, days: 30) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: t + "/busy/deep/down/fresh.txt")
        let temp = def(f, "temp")
        XCTAssertEqual(GenericScanner.itemPaths(of: temp, globs: temp.globs, ctx: f.context()), [t + "/idle"])
    }

    func testActivityCheckFailsClosed() throws {
        let f = try Fixture()
        for i in 0..<30 { try f.file("big/f\(i)", "x") }
        try f.file("locked/inner/x", "x")
        ageTree(f.path("big"), days: 10); ageTree(f.path("locked"), days: 10)
        let cutoff = Date().addingTimeInterval(-86400)
        XCTAssertFalse(hasActivity(since: cutoff, at: f.path("big")), "an old, fully walked folder is idle")
        XCTAssertTrue(hasActivity(since: cutoff, at: f.path("big"), maxEntries: 10), "hitting the entry cap means unknown, so: active")
        chmod(f.path("locked/inner"), 0o000)
        defer { chmod(f.path("locked/inner"), 0o700) }
        XCTAssertTrue(hasActivity(since: cutoff, at: f.path("locked")), "an unreadable folder means unknown, so: active")
        XCTAssertTrue(hasActivity(since: cutoff, at: f.path("does-not-exist")))
    }

    // MARK: Finding 3 — the walk cannot be redirected

    /// An attacker who can write inside the tree being deleted swaps a folder for a symlink to the victim's
    /// home while the deleter is busy. With a path-based walk the victim's `Documents` was emptied every time.
    func testDeleterRaceAgainstFolderToSymlinkSwapNeverLeavesTheTree() throws {
        let f = try Fixture()
        let stage = f.root + "/stage"
        try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: true)
        var damaged = 0
        let iterations = 30
        for round in 0..<iterations {
            for i in 0..<25 { try f.file("Documents/file\(i).txt", "precious") }
            let old = f.root + "/private-tmp/olddir-\(round)"
            for k in 0..<4 {
                try FileManager.default.createDirectory(atPath: old + "/sub/slow\(k)", withIntermediateDirectories: true)
                for i in 0..<200 { FileManager.default.createFile(atPath: old + "/sub/slow\(k)/f\(i)", contents: nil) }
            }
            // An entry named like the victim's folder: after the swap, "sub/Documents" would mean ~/Documents.
            try f.file(old + "/sub/Documents/decoy", "x")
            let link = stage + "/lnk-\(round)"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: f.home)
            let deleter = f.deleter()
            XCTAssertTrue(deleter.isAllowed(old))

            let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            // Vary the moment of the swap from "immediately" to "well into the walk".
            let delay = UInt32(round % 8) * 400
            let attacker = Thread {
                started.signal()
                var spins = 0
                while spins < 2_000_000 {
                    spins += 1
                    var st = stat()
                    if lstat(old + "/sub/slow0/f0", &st) != 0 || lstat(old + "/sub/slow3/f199", &st) != 0 { break }
                }
                usleep(delay)
                _ = renamex_np(old + "/sub", link, UInt32(RENAME_SWAP))
                finished.signal()
            }
            attacker.start()
            started.wait()
            _ = deleter.remove([old])
            finished.wait()

            let left = (try? FileManager.default.contentsOfDirectory(atPath: f.path("Documents")))?.count ?? 0
            if left != 25 { damaged += 1 }
            // Tidy up whatever the race left behind (the swapped-out folder, the link, the old tree).
            for p in [link, old] {
                var st = stat()
                if lstat(p, &st) == 0 {
                    if (st.st_mode & S_IFMT) == S_IFLNK { unlink(p) } else { try? FileManager.default.removeItem(atPath: p) }
                }
            }
        }
        XCTAssertEqual(damaged, 0, "the victim's folder lost files in \(damaged) of \(iterations) rounds")
    }

    func testDeleterDoesNotCrossIntoAFolderThatReplacedTheOneItChecked() throws {
        // Deterministic version of the race: the walk is given a parent that is a symlink.
        let f = try Fixture()
        try f.file("Documents/keep.txt")
        try f.file(f.root + "/private-tmp/work/victim/x")
        let d = f.deleter()
        XCTAssertNotNil(d.openDirectory(f.root + "/private-tmp/work"))
        try FileManager.default.removeItem(atPath: f.root + "/private-tmp/work")
        try FileManager.default.createSymbolicLink(atPath: f.root + "/private-tmp/work", withDestinationPath: f.home)
        XCTAssertNil(d.openDirectory(f.root + "/private-tmp/work"), "O_NOFOLLOW at every component")
        XCTAssertNil(d.openDirectory(f.root + "/private-tmp/work/Documents"))
        XCTAssertEqual(d.remove([f.root + "/private-tmp/work/Documents"]).failed, 1)
        XCTAssertTrue(f.exists("Documents/keep.txt"))
    }

    func testDeleterStaysOnOneVolumeAndRemovesNestedSymlinksAsLinks() throws {
        let f = try Fixture()
        let outside = try f.dir(f.root + "/outside")
        try f.file(f.root + "/outside/secret.txt")
        try f.file("proj/build/a/b/c.txt")
        try f.symlink("proj/build/a/escape", to: outside)
        try f.symlink("proj/build/a/b/loop", to: f.path("proj/build"))
        let r = f.deleter().remove([f.path("proj/build")])
        XCTAssertEqual(r.failed, 0, r.messages.joined())
        XCTAssertFalse(f.exists("proj/build"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside + "/secret.txt"))
    }

    // MARK: Finding 9 — permissions of folders that survive

    func testFailedRemovalLeavesFolderModesUnchanged() throws {
        let f = try Fixture()
        func mode(_ p: String) -> mode_t { var st = stat(); lstat(p, &st); return st.st_mode & 0o7777 }
        let pt = f.root + "/private-tmp"
        chmod(pt, 0o1777)
        // 1. An undeletable entry directly in a shared folder and one in ~/Public: the parents are not ours to change.
        try f.file(pt + "/locked.txt"); chflags(pt + "/locked.txt", UInt32(UF_IMMUTABLE))
        try f.file("Public/locked.txt"); chmod(f.path("Public"), 0o755); chflags(f.path("Public/locked.txt"), UInt32(UF_IMMUTABLE))
        // 2. A tree with a read-only folder that holds an undeletable file: the folder survives, so does its mode.
        try f.file("work/tree/ro/locked.txt"); try f.file("work/tree/ro/removable.txt"); try f.file("work/tree/other/x.txt")
        chflags(f.path("work/tree/ro/locked.txt"), UInt32(UF_IMMUTABLE))
        chmod(f.path("work/tree/ro"), 0o555); chmod(f.path("work/tree"), 0o755); chmod(f.path("work"), 0o750)
        defer {
            for p in [pt + "/locked.txt", f.path("Public/locked.txt"), f.path("work/tree/ro/locked.txt")] { chflags(p, 0) }
            chmod(f.path("work/tree/ro"), 0o755)
        }
        let r = f.deleter().remove([pt + "/locked.txt", f.path("Public/locked.txt"), f.path("work/tree")])
        XCTAssertEqual(r.failed, 3, r.messages.joined(separator: "; "))
        XCTAssertEqual(mode(pt), 0o1777, "shared temp folder")
        XCTAssertEqual(mode(f.path("Public")), 0o755, "~/Public")
        XCTAssertEqual(mode(pt + "/locked.txt"), 0o644)
        XCTAssertEqual(mode(f.path("work")), 0o750, "the parent of the tree is never touched")
        XCTAssertEqual(mode(f.path("work/tree/ro")), 0o555, "a folder that survives gets its original mode back")
        XCTAssertEqual(mode(f.path("work/tree")), 0o755)
        XCTAssertTrue(f.exists("work/tree/ro/locked.txt"))
        XCTAssertFalse(f.exists("work/tree/other"), "everything that could be removed was removed")
        XCTAssertFalse(f.exists("work/tree/ro/removable.txt"), "made writable through its descriptor for the removal")
    }

    func testUnreadableAndReadOnlyFoldersInsideTheTreeAreStillRemoved() throws {
        let f = try Fixture()
        try f.file("build/out/pkg/noaccess/deep/x.txt")
        try f.file("build/out/pkg/readonly/y.txt")
        chmod(f.path("build/out/pkg/noaccess/deep"), 0o000)
        chmod(f.path("build/out/pkg/noaccess"), 0o000)
        chmod(f.path("build/out/pkg/readonly"), 0o500)
        chmod(f.path("build/out/pkg"), 0o500)
        let r = f.deleter().remove([f.path("build/out")])
        XCTAssertEqual(r.failed, 0, r.messages.joined(separator: "; "))
        XCTAssertFalse(f.exists("build/out"))
    }

    func testSymlinkToAFolderIsNeverChmoddedThrough() throws {
        let f = try Fixture()
        let target = try f.dir("data/target")
        chmod(target, 0o500)
        defer { chmod(target, 0o700) }
        try f.file("proj/tree/x.txt")
        try f.symlink("proj/tree/link", to: target)
        chmod(f.path("proj/tree"), 0o500)
        XCTAssertEqual(f.deleter().remove([f.path("proj/tree")]).failed, 0)
        var st = stat(); lstat(target, &st)
        XCTAssertEqual(st.st_mode & 0o7777, 0o500, "the link's target keeps its mode")
    }

    // MARK: Finding 8 — protected paths under another spelling

    private func isCaseInsensitive(_ f: Fixture) throws -> Bool {
        try f.file("CaseProbe")
        return f.exists("caseprobe")
    }

    func testProtectedPathsCannotBeReachedThroughDifferentLetterCase() throws {
        let f = try Fixture()
        try f.file("Library/Keychains/login.keychain-db")
        try f.file(".config/gh/hosts.yml")
        try f.file(".docker/config.json")
        try f.file(".ssh/id_ed25519")
        try f.file(".aws/credentials")
        let d = f.deleter(), g = PathGuard(env: f.env, settings: EngineSettings())
        for rel in ["Library/keychains", "Library/KEYCHAINS/login.keychain-db", ".config/GH", ".Config/gh/hosts.yml", ".docker/CONFIG.JSON",
                    ".SSH/id_ed25519", ".ssh/ID_ED25519", ".AWS/credentials", ".aws/Credentials", ".CONFIG"] {
            XCTAssertTrue(g.blocks(f.path(rel)), "\(rel) names protected data")
            XCTAssertFalse(d.isAllowed(f.path(rel)), "\(rel) must not be deletable")
        }
        let r = d.remove([f.path("Library/keychains"), f.path(".config/GH"), f.path(".docker/CONFIG.JSON")])
        XCTAssertEqual(r.failed, 3)
        for rel in ["Library/Keychains/login.keychain-db", ".config/gh/hosts.yml", ".docker/config.json"] { XCTAssertTrue(f.exists(rel), rel) }
        // Normalization: "é" precomposed vs decomposed is the same name on APFS.
        try f.file("Caf\u{00E9}/secret/notes.txt")
        let g2 = PathGuard(env: f.env, settings: EngineSettings(protectedPaths: ["~/Cafe\u{0301}/secret"]))
        XCTAssertTrue(g2.blocks(f.path("Caf\u{00E9}/secret/notes.txt")))
    }

    func testProtectedPathsAreRecognizedByFileIdentity() throws {
        let f = try Fixture()
        try f.file(".npmrc", "//registry.npmjs.org/:_authToken=secret")
        try f.file("vault/keys/master.key")
        // A hard link is the same file under an unrelated name; a protected folder reached via a symlinked
        // user setting; both are caught by device+inode, which no spelling can change.
        XCTAssertEqual(link(f.path(".npmrc"), f.path("work-copy-of-key")), 0)
        try f.dir("work")
        XCTAssertEqual(rename(f.path("work-copy-of-key"), f.path("work/innocent-name")), 0)
        let g = PathGuard(env: f.env, settings: EngineSettings(protectedPaths: ["~/vault/keys"]))
        XCTAssertTrue(g.isProtected(f.path("work/innocent-name")), "same inode as ~/.npmrc")
        XCTAssertTrue(g.isProtectedID(FileID.of(f.path("vault/keys"))!))
        XCTAssertFalse(Deleter(env: f.env, guardian: g).isAllowed(f.path("work/innocent-name")))
        // While walking a tree, a protected object found inside it is left alone (and counted).
        try f.dir("proj/build")
        XCTAssertEqual(link(f.path("vault/keys/master.key"), f.path("proj/build/cache.bin")), 0)
        let g3 = PathGuard(env: f.env, settings: EngineSettings(protectedPaths: ["~/vault/keys/master.key"]))
        let r = Deleter(env: f.env, guardian: g3).remove([f.path("proj/build")])
        XCTAssertEqual(r.failed, 1)
        XCTAssertTrue(f.exists("proj/build/cache.bin"))
        if try isCaseInsensitive(f) {
            XCTAssertTrue(g.isProtected(f.path("VAULT/KEYS/master.key")))
            let g4 = PathGuard(env: f.env, settings: EngineSettings(protectedPaths: ["~/Vault/Keys"]))
            XCTAssertTrue(g4.blocks(f.path("vault/keys/master.key")), "a protected path typed in another case still protects")
            XCTAssertTrue(g4.blocks(f.path("vault")))
        }
    }

    func testNonCanonicalPathsAreRefusedRatherThanRedirected() throws {
        let f = try Fixture()
        try f.file("Documents/Thesis/x")
        try FileManager.default.createSymbolicLink(atPath: f.root + "/private-tmp/direct-link", withDestinationPath: f.path("Documents"))
        try f.symlink("alias", to: f.path("Documents"))
        let d = f.deleter()
        XCTAssertFalse(d.isAllowed(f.root + "/private-tmp/direct-link/Thesis"), "through a link in /private/tmp")
        XCTAssertFalse(d.isAllowed(f.path("alias/Thesis")), "through a link inside home")
        XCTAssertFalse(d.isAllowed(f.root + "/private-tmp/../home/Documents/Thesis"))
        XCTAssertTrue(d.isAllowed(f.path("Documents/Thesis")), "the canonical spelling is fine")
        XCTAssertTrue(d.isAllowed(f.root + "/private-tmp/direct-link"), "the link itself, as an entry of /private/tmp")
    }
}
