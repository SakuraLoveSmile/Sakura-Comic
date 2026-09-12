import Foundation
import XCTest
import GRDB
import KomgaStore
import KomgaAPI
@testable import KomgaDownloads
@testable import KomgaReader

final class DownloadEngineTests: XCTestCase {
    private var tempDir: URL!
    private var dbQueue: DatabaseQueue!
    private var root: DownloadRoot!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try Schema.migrate(db)
        }
        root = try DownloadRoot.forDatabase(dbURL)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testEnqueueAndPumpDownload() async throws {
        let serverID = "srv-1"
        let bookID = "b-1"

        let transport = ClosureDownloadTransport { bID, pageNum in
            let data = DemoPNG.page(UInt32(pageNum))
            return (data, "image/png")
        }

        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: ConstantNetworkPathProvider(link: .unmetered),
            diskSpaceProvider: ConstantDiskSpaceProvider(freeBytes: 10 * 1024 * 1024 * 1024)
        )

        let page1Data = DemoPNG.page(1)
        let page2Data = DemoPNG.page(2)

        try await engine.enqueue(
            bookID: bookID,
            bookTitle: "Test Book",
            seriesTitle: "Test Series",
            pages: [
                (number: 1, fileName: "0001.png", mediaType: "image/png", sizeBytes: Int64(page1Data.count)),
                (number: 2, fileName: "0002.png", mediaType: "image/png", sizeBytes: Int64(page2Data.count))
            ]
        )

        let initialRow = try await engine.status(bookID: bookID)
        XCTAssertEqual(initialRow?.state, BookState.waiting.rawValue)
        XCTAssertEqual(initialRow?.pagesTotal, 2)
        XCTAssertEqual(initialRow?.pagesDone, 0)

        let report = await engine.pumpOnePass()
        XCTAssertEqual(report.served, 2)
        XCTAssertEqual(report.failedPages, 0)

        let completedRow = try await engine.status(bookID: bookID)
        XCTAssertEqual(completedRow?.state, BookState.completed.rawValue)
        XCTAssertEqual(completedRow?.pagesDone, 2)

        let pages = try await engine.pages(bookID: bookID)
        XCTAssertEqual(pages.count, 2)
        for page in pages {
            XCTAssertEqual(page.state, PageState.complete.rawValue)
            guard let path = page.filePath else {
                XCTFail("filePath was nil for page \(page.number), state=\(page.state), error=\(String(describing: page.lastError))")
                continue
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        let usable = try await dbQueue.read { db in
            try DownloadRecovery.usablePage(db: db, serverID: serverID, bookID: bookID, pageNumber: 1)
        }
        XCTAssertNotNil(usable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: usable!.path))

        // Verify atomic manifest was written and is valid
        let manifestURL = root.bookDirectory(serverId: serverID, bookId: bookID)
            .appendingPathComponent(DownloadRoot.manifestFileName)
        let manifest = try DownloadManifest.read(at: manifestURL)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.serverId, serverID)
        XCTAssertEqual(manifest?.bookId, bookID)
        XCTAssertEqual(manifest?.pagesCount, 2)
        XCTAssertEqual(manifest?.pages.count, 2)
    }

    func testUserPausePreventsPumpFromResuming() async throws {
        let serverID = "srv-1"
        let bookID = "b-2"

        let transport = ClosureDownloadTransport { bID, pageNum in
            return (DemoPNG.page(UInt32(pageNum)), "image/png")
        }

        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: ConstantNetworkPathProvider(link: .unmetered),
            diskSpaceProvider: ConstantDiskSpaceProvider()
        )

        let data = DemoPNG.page(1)
        try await engine.enqueue(
            bookID: bookID,
            bookTitle: "Test Book",
            seriesTitle: "Test Series",
            pages: [
                (number: 1, fileName: "0001.png", mediaType: "image/png", sizeBytes: Int64(data.count))
            ]
        )

        try await engine.pause(bookID: bookID)

        let pausedRow = try await engine.status(bookID: bookID)
        XCTAssertEqual(pausedRow?.state, BookState.paused.rawValue)

        let report = await engine.pumpOnePass()
        XCTAssertEqual(report.served, 0)

        let stillPaused = try await engine.status(bookID: bookID)
        XCTAssertEqual(stillPaused?.state, BookState.paused.rawValue)
    }

    func testRecoverySweepRepairsGhostRowsAndPartFiles() async throws {
        let serverID = "srv-1"
        let bookID = "b-3"

        let transport = ClosureDownloadTransport { bID, pageNum in
            return (DemoPNG.page(UInt32(pageNum)), "image/png")
        }

        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: ConstantNetworkPathProvider(link: .unmetered),
            diskSpaceProvider: ConstantDiskSpaceProvider()
        )

        let data = DemoPNG.page(1)
        try await engine.enqueue(
            bookID: bookID,
            bookTitle: "Test Book",
            seriesTitle: "Test Series",
            pages: [
                (number: 1, fileName: "0001.png", mediaType: "image/png", sizeBytes: Int64(data.count))
            ]
        )

        _ = await engine.pumpOnePass()
        let doneRow = try await engine.status(bookID: bookID)
        XCTAssertEqual(doneRow?.state, BookState.completed.rawValue)

        let pages = try await engine.pages(bookID: bookID)
        let filePath = pages[0].filePath!
        try FileManager.default.removeItem(atPath: filePath)

        let bookDir = root.bookDirectory(serverId: serverID, bookId: bookID)
        let stalePart = bookDir.appendingPathComponent("0002.png.part")
        try Data([1, 2, 3]).write(to: stalePart)

        let sweepReport = try await engine.sweep()
        XCTAssertEqual(sweepReport.stalePartsRemoved, 1)
        XCTAssertEqual(sweepReport.ghostRowsRepaired, 1)

        let reopened = try await engine.status(bookID: bookID)
        XCTAssertEqual(reopened?.state, BookState.waiting.rawValue)
    }

    func testCorruptImageRejectedAndAttemptRecorded() async throws {
        let serverID = "srv-1"
        let bookID = "b-corrupt"

        // Transport returns HTML error text disguised as image
        let transport = ClosureDownloadTransport { bID, pageNum in
            let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
            return (html, "image/png")
        }

        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: ConstantNetworkPathProvider(link: .unmetered),
            diskSpaceProvider: ConstantDiskSpaceProvider()
        )

        try await engine.enqueue(
            bookID: bookID,
            bookTitle: "Corrupt Book",
            seriesTitle: nil,
            pages: [
                (number: 1, fileName: "0001.png", mediaType: "image/png", sizeBytes: 100)
            ]
        )

        let report = await engine.pumpOnePass()
        XCTAssertEqual(report.served, 0)
        XCTAssertNotNil(report.lastError)
        XCTAssertTrue(report.lastError?.contains("容器校验失败") == true)

        let pages = try await engine.pages(bookID: bookID)
        XCTAssertEqual(pages[0].state, PageState.pending.rawValue)
        XCTAssertEqual(pages[0].attempts, 1)
        XCTAssertNil(pages[0].filePath)
    }

    func testTransientNetworkErrorDoesNotConsumePageAttempt() async throws {
        let serverID = "srv-1"
        let bookID = "b-transient"

        let transport = ClosureDownloadTransport { bID, pageNum in
            throw URLError(.notConnectedToInternet)
        }

        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: ConstantNetworkPathProvider(link: .unmetered),
            diskSpaceProvider: ConstantDiskSpaceProvider()
        )

        try await engine.enqueue(
            bookID: bookID,
            bookTitle: "Transient Book",
            seriesTitle: nil,
            pages: [
                (number: 1, fileName: "0001.png", mediaType: "image/png", sizeBytes: 100)
            ]
        )

        let report = await engine.pumpOnePass()
        XCTAssertEqual(report.stop, .linkDown)

        let pages = try await engine.pages(bookID: bookID)
        // Retry count must NOT be incremented for transient link failures!
        XCTAssertEqual(pages[0].attempts, 0)
    }

    func testTransient429ThrottledDoesNotConsumePageAttempt() async throws {
        let serverID = "srv-1"
        let bookID = "b-429"

        let transport = ClosureDownloadTransport { bID, pageNum in
            throw KomgaAPIError.server(statusCode: 429)
        }

        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: ConstantNetworkPathProvider(link: .unmetered),
            diskSpaceProvider: ConstantDiskSpaceProvider()
        )

        try await engine.enqueue(
            bookID: bookID,
            bookTitle: "429 Book",
            seriesTitle: nil,
            pages: [
                (number: 1, fileName: "0001.png", mediaType: "image/png", sizeBytes: 100)
            ]
        )

        let report = await engine.pumpOnePass()
        XCTAssertEqual(report.stop, .throttled)

        let pages = try await engine.pages(bookID: bookID)
        XCTAssertEqual(pages[0].attempts, 0)
    }

    func testMeteredConnectionStopsWhenCellularForbidden() async throws {
        let serverID = "srv-1"
        let bookID = "b-metered"

        let transport = ClosureDownloadTransport { bID, pageNum in
            return (DemoPNG.page(UInt32(pageNum)), "image/png")
        }

        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: ConstantNetworkPathProvider(link: .metered),
            diskSpaceProvider: ConstantDiskSpaceProvider()
        )

        try await engine.enqueue(
            bookID: bookID,
            bookTitle: "Metered Book",
            seriesTitle: nil,
            pages: [
                (number: 1, fileName: "0001.png", mediaType: "image/png", sizeBytes: 100)
            ]
        )

        let report = await engine.pumpOnePass()
        XCTAssertEqual(report.stop, .linkBlocked)
        XCTAssertEqual(report.served, 0)
    }

    func testRecoverySweepProtectsUnknownDirectories() async throws {
        let serverID = "srv-1"
        let engine = DownloadEngine(
            dbQueue: dbQueue,
            root: root,
            transport: ClosureDownloadTransport { _, _ in (Data(), "") },
            serverID: serverID
        )

        let serverDir = root.url.appendingPathComponent(DownloadTree.safeKey(serverID))
        let unknownDir = serverDir.appendingPathComponent("unknown_book_123")
        try FileManager.default.createDirectory(at: unknownDir, withIntermediateDirectories: true)
        let unknownFile = unknownDir.appendingPathComponent("custom_notes.txt")
        try Data("user notes".utf8).write(to: unknownFile)

        let report = try await engine.sweep()
        XCTAssertEqual(report.unknownDirectoriesEncountered, 1)
        XCTAssertEqual(report.filesAdopted, 0)
        // Ensure the unknown directory and its files were NOT deleted
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownFile.path))
    }
}
