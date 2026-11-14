import XCTest
@testable import CleanerCore

private func first(_ e: LiveEngine) async -> AuditRecord? {
    await e.auditLog(limit: 5, before: nil).first
}

final class AuditTests: XCTestCase {
    private func category(_ f: Fixture, id: String = "user-caches", paths: [String]) -> CleanCategory {
        let items = paths.map { CleanItem(url: URL(fileURLWithPath: $0), sizeBytes: 100) }
        return CleanCategory(id: id, name: "Test cache", detail: "d", level: .safe, symbol: "folder", items: items,
                             sizeBytes: 100 * Int64(paths.count))
    }

    private func engine(_ f: Fixture, client: AuditClient = .cli, settings: EngineSettings = EngineSettings()) -> LiveEngine {
        let box = SettingsBox(); box.settings = settings
        return LiveEngine(env: f.env, settings: box, client: client, appVersion: "9.9.9")
    }

    func testCleanWritesOneRecordPerOperation() async throws {
        let f = try Fixture()
        let a = try f.file("Library/Caches/app-one/data.bin", bytes: 5000)
        let b = try f.file("Library/Caches/app-two/data.bin", bytes: 5000)
        let e = engine(f, client: .app)
        let cat = category(f, paths: [(a as NSString).deletingLastPathComponent, (b as NSString).deletingLastPathComponent])
        let r = await e.clean(categories: [cat], mode: .permanent, progress: { _ in })
        XCTAssertEqual(r.failedCount, 0)
        let log = await e.auditLog(limit: 10, before: nil)
        XCTAssertEqual(log.count, 1)
        let rec = try XCTUnwrap(log.first)
        XCTAssertEqual(rec.client, .app)
        XCTAssertEqual(rec.appVersion, "9.9.9")
        XCTAssertEqual(rec.kind, .cleanup)
        XCTAssertEqual(rec.mode, .permanent)
        XCTAssertEqual(rec.items.count, 2)
        XCTAssertEqual(rec.items.map(\.outcome), [.ok, .ok])
        XCTAssertEqual(rec.items[0].categoryID, "user-caches")
        XCTAssertEqual(rec.items[0].action, .deleted)
        XCTAssertEqual(rec.items[0].sizeBytes, 100)
        XCTAssertFalse(f.exists("Library/Caches/app-one"))
        let stats = await e.auditStats(since: nil)
        XCTAssertEqual(stats.operations, 1)
        XCTAssertEqual(stats.itemsRemoved, 2)
    }

    func testTrashModeAndRefusalsAreRecorded() async throws {
        let f = try Fixture()
        let p = try f.dir("Library/Caches/gone-soon")
        let e = engine(f)
        let outside = "/etc/hosts"
        let r = await e.delete(urls: [URL(fileURLWithPath: p), URL(fileURLWithPath: outside)], mode: .trash, purpose: .explorer, progress: { _ in })
        XCTAssertEqual(r.failedCount, 1)
        let maybe = await first(e); let rec = try XCTUnwrap(maybe)
        XCTAssertEqual(rec.kind, .explorerDelete)
        XCTAssertEqual(rec.mode, .trash)
        XCTAssertEqual(rec.items[0].action, .movedToTrash)
        XCTAssertEqual(rec.items[0].outcome, .ok)
        XCTAssertEqual(rec.items[1].outcome, .refused)
        XCTAssertNotNil(rec.items[1].reason)
        XCTAssertEqual(rec.failedItemCount, 1)
    }

    func testProjectArtifactsPurposeAndPlanID() async throws {
        let f = try Fixture()
        let p = try f.dir("code/app/node_modules/x")
        _ = p
        let e = engine(f, client: .mcp)
        let target = f.path("code/app/node_modules")
        await AuditContext.$planID.withValue("plan-123") {
            _ = await e.delete(urls: [URL(fileURLWithPath: target)], mode: .permanent, purpose: .projectArtifacts, progress: { _ in })
        }
        let maybe = await first(e); let rec = try XCTUnwrap(maybe)
        XCTAssertEqual(rec.kind, .projectArtifacts)
        XCTAssertEqual(rec.client, .mcp)
        XCTAssertEqual(rec.planID, "plan-123")
        XCTAssertEqual(rec.items[0].artifactKind, "node_modules")
        XCTAssertEqual(rec.items[0].name, "app/node_modules")
    }

    func testRemoveClonesRecordsRemoteBranchBackupAndForce() async throws {
        let f = try Fixture()
        let path = try f.repo("code/solo")
        try f.file("code/solo/unsaved.txt", "work")
        let clone = RepoClone(url: URL(fileURLWithPath: path), branch: "main", isLinkedWorktree: false, uncommittedCount: 1,
                              unpushedCount: nil, hasStash: false, lastCommit: nil, idleDays: 1, sizeBytes: 1234, artifactBytes: 0)
        let e = engine(f)
        _ = await e.removeClones([clone], force: false, mode: .permanent, progress: { _ in })
        XCTAssertTrue(f.exists("code/solo"))
        _ = await e.removeClones([clone], force: true, mode: .permanent, progress: { _ in })
        XCTAssertFalse(f.exists("code/solo"))
        let log = await e.auditLog(limit: 5, before: nil)
        XCTAssertEqual(log.count, 2)
        let forced = try XCTUnwrap(log.first), refused = try XCTUnwrap(log.last)
        XCTAssertEqual(forced.kind, .removeClones)
        XCTAssertEqual(forced.items[0].forced, true)
        XCTAssertEqual(forced.items[0].fullyBackedUp, false)
        XCTAssertEqual(forced.items[0].branch, "main")
        XCTAssertEqual(forced.items[0].outcome, .ok)
        XCTAssertEqual(refused.items[0].forced, false)
        XCTAssertEqual(refused.items[0].outcome, .refused)
    }

    func testRecordingCanBeTurnedOff() async throws {
        let f = try Fixture()
        let p = try f.dir("Library/Caches/x1")
        let e = engine(f, settings: EngineSettings(recordAuditLog: false))
        _ = await e.delete(urls: [URL(fileURLWithPath: p)], mode: .permanent, progress: { _ in })
        let none = await e.auditLog(limit: 5, before: nil)
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root + "/history/audit.jsonl"))
    }

    func testLogWriteFailureIsReportedAndDoesNotUndoTheDeletion() async throws {
        let f = try Fixture()
        let p = try f.dir("Library/Caches/x2")
        // The log directory cannot be created: its parent is a regular file.
        try Data("x".utf8).write(to: URL(fileURLWithPath: f.root + "/blocker"))
        f.env.historyDir = URL(fileURLWithPath: f.root + "/blocker/audit-dir", isDirectory: true)
        let e = engine(f)
        let r = await e.delete(urls: [URL(fileURLWithPath: p)], mode: .permanent, progress: { _ in })
        XCTAssertFalse(f.exists("Library/Caches/x2"), "the deletion stands")
        XCTAssertTrue(r.messages.contains { $0.contains("audit log") })
    }

    func testClearAuditLog() async throws {
        let f = try Fixture()
        let p = try f.dir("Library/Caches/x3")
        let e = engine(f)
        _ = await e.delete(urls: [URL(fileURLWithPath: p)], mode: .permanent, progress: { _ in })
        let before = await e.auditLog(limit: 5, before: nil)
        XCTAssertEqual(before.count, 1)
        await e.clearAuditLog()
        let after = await e.auditLog(limit: 5, before: nil)
        XCTAssertTrue(after.isEmpty)
    }

    func testPagingNewestFirst() async throws {
        let f = try Fixture()
        let store = AuditStore(directory: f.env.historyDir)
        for i in 0..<5 {
            try store.append(sample(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 100), name: "r\(i)"))
        }
        let e = engine(f)
        let page1 = await e.auditLog(limit: 2, before: nil)
        XCTAssertEqual(page1.map { $0.items[0].name }, ["r4", "r3"])
        let page2 = await e.auditLog(limit: 2, before: page1.last?.startedAt)
        XCTAssertEqual(page2.map { $0.items[0].name }, ["r2", "r1"])
    }

    // MARK: Storage

    private func sample(date: Date = Date(), name: String = "x", items: Int = 1) -> AuditRecord {
        let list = (0..<items).map { AuditItem(path: "/a/\($0)", name: name, sizeBytes: 10, action: .deleted, outcome: .ok) }
        return AuditRecord(startedAt: date, endedAt: date, client: .cli, appVersion: "1", kind: .cleanup, mode: .permanent,
                           freeBytesBefore: 0, freeBytesAfter: 0, freedBytes: 0, itemCount: list.count, failedItemCount: 0, items: list)
    }

    func testFilePermissionsAreOwnerOnly() throws {
        let f = try Fixture()
        let dir = URL(fileURLWithPath: f.root + "/fresh/MacCleaner", isDirectory: true)
        let store = AuditStore(directory: dir)
        try store.append(sample())
        var st = stat()
        XCTAssertEqual(stat(store.fileURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(dir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    func testCorruptAndTruncatedLinesAreSkippedAndCounted() throws {
        let f = try Fixture()
        let store = AuditStore(directory: f.env.historyDir)
        try store.append(sample(name: "first"))
        // Garbage line plus a record cut off mid-line without its newline (a crash while writing).
        let h = try FileHandle(forWritingTo: store.fileURL)
        h.seekToEndOfFile(); h.write(Data("not json at all\n{\"id\":\"cut".utf8)); try h.close()
        try store.append(sample(name: "second"))
        let (records, skipped) = store.readAll()
        XCTAssertEqual(records.map { $0.items[0].name }, ["first", "second"], "the record after a truncated line is not glued to it")
        XCTAssertEqual(skipped, 2)
    }

    func testRotationKeepsTwoFiles() throws {
        let f = try Fixture()
        var store = AuditStore(directory: f.env.historyDir)
        store.maxFileBytes = 2_000
        for i in 0..<20 { try store.append(sample(name: "n\(i)", items: 3)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.rotatedURL.path))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 2_000)
        let (records, skipped) = store.readAll()
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(records.last?.items[0].name, "n19")
        XCTAssertLessThan(records.count, 20, "older rotations are dropped")
    }

    func testConcurrentAppendsStayIntact() throws {
        let f = try Fixture()
        let store = AuditStore(directory: f.env.historyDir)
        let group = DispatchGroup()
        for t in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<25 { try? store.append(self.sample(name: "t\(t)-\(i)", items: 20)) }
                group.leave()
            }
        }
        group.wait()
        let (records, skipped) = store.readAll()
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(skipped, 0)
    }

    // MARK: Several processes (the app, the CLI and an MCP server can run at the same time)

    private static let workerDirKey = "MACCLEANER_TEST_AUDIT_WORKER_DIR"
    private static let workerTagKey = "MACCLEANER_TEST_AUDIT_WORKER_TAG"
    private static let workerRecords = 40

    /// Not a test of its own: the body the multi-process test below runs in separate `xctest` processes.
    /// Without the two environment variables it does nothing.
    func testAppendWorkerForTheMultiProcessTest() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env[Self.workerDirKey], let tag = env[Self.workerTagKey] else { return }
        guard dir.contains("/MacCleanerTests-") else { return XCTFail("refusing to write outside a test fixture") }
        var store = AuditStore(directory: URL(fileURLWithPath: dir, isDirectory: true))
        store.maxFileBytes = 200_000        // small, so that several processes also rotate the log at the same time
        for i in 0..<Self.workerRecords {
            var r = sample(name: "\(tag)-\(i)", items: 15)
            r.appVersion = "pid-\(getpid())"
            try store.append(r)
        }
    }

    func testConcurrentAppendsFromSeveralProcessesStayIntact() throws {
        let f = try Fixture()
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        find.arguments = ["--find", "xctest"]
        let pipe = Pipe()
        find.standardOutput = pipe; find.standardError = FileHandle.nullDevice
        guard (try? find.run()) != nil else { throw XCTSkip("xcrun is not available") }
        let xctest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        find.waitUntilExit()
        guard find.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: xctest) else { throw XCTSkip("the xctest runner was not found") }
        let bundle = Bundle(for: AuditTests.self).bundlePath
        let dir = f.root + "/history"

        var workers: [Process] = []
        for w in 0..<4 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: xctest)
            p.arguments = ["-XCTest", "CleanerCoreTests.AuditTests/testAppendWorkerForTheMultiProcessTest", bundle]
            var env = ProcessInfo.processInfo.environment
            env[Self.workerDirKey] = dir
            env[Self.workerTagKey] = "w\(w)"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run()
            workers.append(p)
        }
        // This process appends at the same time, through the same code.
        var store = AuditStore(directory: f.env.historyDir)
        store.maxFileBytes = 200_000
        for i in 0..<Self.workerRecords {
            var r = sample(name: "main-\(i)", items: 15)
            r.appVersion = "pid-\(getpid())"
            try store.append(r)
        }
        for p in workers { p.waitUntilExit() }
        guard workers.allSatisfy({ $0.terminationStatus == 0 }) else {
            throw XCTSkip("the worker processes could not run the test bundle here (exit \(workers.map(\.terminationStatus)))")
        }
        // Every line that is on disk is a whole record; nothing was interleaved or torn by a concurrent rotation.
        let (records, skipped) = store.readLines()
        XCTAssertEqual(skipped, 0, "a line was damaged by concurrent appends")
        XCTAssertGreaterThanOrEqual(Set(records.map(\.appVersion)).count, 3, "positive control: several processes really wrote")
        XCTAssertEqual(Set(records.map(\.id)).count, records.count, "no record appears twice")
        // Rotation keeps two files, so the oldest records may be gone; the newest of every writer must be there.
        for tag in ["w0", "w1", "w2", "w3", "main"] {
            XCTAssertTrue(records.contains { $0.items.first?.name == "\(tag)-\(Self.workerRecords - 1)" }, "the last record of \(tag) is missing")
        }
        for name in ["audit.jsonl", "audit.1.jsonl"] {
            guard let data = FileManager.default.contents(atPath: dir + "/" + name) else { continue }
            XCTAssertEqual(data.last, 0x0A, "\(name) must end with a complete line")
            XCTAssertLessThan(data.count, 200_000 + 20_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/audit.1.jsonl"), "positive control: the log was rotated while several processes wrote")
    }

    func testItemListIsCappedWithSummarizedRemainder() {
        var draft = AuditDraft(kind: .cleanup, mode: .permanent)
        for i in 0..<(AuditLimits.maxItems + 120) {
            draft.add(AuditItem(path: "/p/\(i)", name: "n", sizeBytes: 7, action: .deleted, outcome: i == 0 ? .failed : .ok))
        }
        let rec = draft.record(client: .cli, appVersion: "1", freeBefore: 10, freeAfter: 50)
        XCTAssertEqual(rec.items.count, AuditLimits.maxItems)
        XCTAssertEqual(rec.itemCount, AuditLimits.maxItems + 120)
        XCTAssertEqual(rec.omittedItemCount, 120)
        XCTAssertEqual(rec.omittedBytes, 840)
        XCTAssertEqual(rec.freedBytes, 40)
        XCTAssertEqual(rec.failedItemCount, 1)
    }

    // MARK: The log is protected from the tool's own deletion

    func testAuditLogCannotBeDeletedByTheTool() throws {
        let f = try Fixture()
        let dir = f.path("Library/Application Support/MacCleaner")
        let store = AuditStore(directory: URL(fileURLWithPath: dir, isDirectory: true))
        try store.append(sample())
        let deleter = f.deleter()
        XCTAssertFalse(deleter.isAllowed(dir + "/audit.jsonl"))
        XCTAssertFalse(deleter.isAllowed(dir))
        let results = deleter.removeEach([dir + "/audit.jsonl", dir], mode: .permanent)
        XCTAssertEqual(results.map(\.outcome), [.refused, .refused])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testSettingsFileKeepsAuditFlagAndStaysReadableForOldFiles() throws {
        let f = try Fixture()
        let store = SettingsStore(directory: URL(fileURLWithPath: f.root + "/s", isDirectory: true))
        XCTAssertTrue(store.save(EngineSettings(protectedPaths: ["~/a"], sessionRetentionDays: 7, recordAuditLog: false)))
        XCTAssertEqual(store.load().settings.recordAuditLog, false)
        try Data(#"{"version":1,"protectedPaths":[],"sessionRetentionDays":30}"#.utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().settings.recordAuditLog, true)
    }
}
