import Foundation
import GRDB

/// Sweep report summarizing actions taken by a recovery pass.
public struct RecoveryReport: Sendable, Equatable {
    public var booksScanned: Int
    public var stalePartsRemoved: Int
    public var ghostRowsRepaired: Int
    public var filesAdopted: Int
    public var corruptFilesDeleted: Int
    public var countersRepaired: Int
    public var freedBytes: Int64
    public var unknownDirectoriesEncountered: Int

    public init(
        booksScanned: Int = 0,
        stalePartsRemoved: Int = 0,
        ghostRowsRepaired: Int = 0,
        filesAdopted: Int = 0,
        corruptFilesDeleted: Int = 0,
        countersRepaired: Int = 0,
        freedBytes: Int64 = 0,
        unknownDirectoriesEncountered: Int = 0
    ) {
        self.booksScanned = booksScanned
        self.stalePartsRemoved = stalePartsRemoved
        self.ghostRowsRepaired = ghostRowsRepaired
        self.filesAdopted = filesAdopted
        self.corruptFilesDeleted = corruptFilesDeleted
        self.countersRepaired = countersRepaired
        self.freedBytes = freedBytes
        self.unknownDirectoriesEncountered = unknownDirectoriesEncountered
    }

    public var totalRepairs: Int {
        stalePartsRemoved + ghostRowsRepaired + filesAdopted + corruptFilesDeleted + countersRepaired
    }
}

/// Download storage reconciliation and offline reader lookup.
public enum DownloadRecovery {
    /// Reconciles the filesystem with the SQLite download tables.
    /// Cleans interrupted `.part` files, re-indexes orphaned page files into SQLite,
    /// and resets ghost database rows for deleted files.
    public static func sweep(
        db: GRDB.Database,
        root: DownloadRoot,
        serverID: String
    ) throws -> RecoveryReport {
        var report = RecoveryReport()
        let fileManager = FileManager.default
        let serverDir = root.url.appendingPathComponent(DownloadTree.safeKey(serverID))
        guard fileManager.fileExists(atPath: serverDir.path) else {
            return report
        }

        let bookDirs = (try? fileManager.contentsOfDirectory(
            at: serverDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let now = ISO8601DateFormatter().string(from: Date())

        for bookDir in bookDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: bookDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let bookID = bookDir.lastPathComponent
            let manifestURL = bookDir.appendingPathComponent(DownloadRoot.manifestFileName)
            let manifest = try? DownloadManifest.read(at: manifestURL)
            let dbBook = try? DownloadStore.get(db: db, serverId: serverID, bookId: bookID)

            // Book identity verification:
            // If manifest exists, verify serverId and bookId match
            if let manifest {
                if manifest.serverId != serverID || manifest.bookId != bookID {
                    // Mismatched identity: do NOT touch this directory
                    report.unknownDirectoriesEncountered += 1
                    continue
                }
            } else if dbBook == nil {
                // Neither manifest nor SQLite row knows about this directory: unknown directory
                report.unknownDirectoriesEncountered += 1
                continue
            }

            report.booksScanned += 1

            let files = (try? fileManager.contentsOfDirectory(
                at: bookDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var onDiskPages: [Int: (url: URL, size: Int64)] = [:]

            for file in files {
                let name = file.lastPathComponent
                if name.hasSuffix(DownloadRoot.partSuffix) {
                    // Interrupted partial write
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    try? fileManager.removeItem(at: file)
                    report.stalePartsRemoved += 1
                    report.freedBytes += Int64(size)
                    continue
                }

                if name == DownloadRoot.manifestFileName {
                    continue
                }

                // Page filename format: 0001.png, 0002.jpg, etc.
                let baseName = file.deletingPathExtension().lastPathComponent
                if let pageNumber = Int(baseName), pageNumber > 0 {
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    let check = ImageIntegrity.quickCheckFile(at: file, declaredSize: size)
                    if case .corrupt = check {
                        // Corrupt / damaged image file
                        try? fileManager.removeItem(at: file)
                        report.corruptFilesDeleted += 1
                    } else if size > 0 {
                        onDiskPages[pageNumber] = (url: file, size: size)
                    }
                }
            }

            // Cross-check with DB rows
            let existingPages = (try? DownloadStore.pages(db: db, serverId: serverID, bookId: bookID)) ?? []
            var existingByNumber: [Int: DownloadPageRow] = [:]
            for p in existingPages {
                existingByNumber[p.number] = p
            }

            // Adopt files on disk that DB doesn't have as complete
            for (pageNum, fileInfo) in onDiskPages {
                let existing = existingByNumber[pageNum]
                if existing == nil || existing?.state != PageState.complete.rawValue || existing?.filePath != fileInfo.url.path {
                    let ext = fileInfo.url.pathExtension.lowercased()
                    let mediaType = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : (ext == "png" ? "image/png" : "image/\(ext)")
                    try DownloadStore.adoptPage(
                        db: db,
                        serverId: serverID,
                        bookId: bookID,
                        number: pageNum,
                        path: fileInfo.url.path,
                        sizeBytes: fileInfo.size,
                        mediaType: mediaType,
                        now: now
                    )
                    report.filesAdopted += 1
                }
            }

            // Heal DB rows that claim to be complete but file is missing
            for p in existingPages where p.state == PageState.complete.rawValue {
                if let path = p.filePath, !fileManager.fileExists(atPath: path) {
                    try DownloadStore.healPage(
                        db: db,
                        serverId: serverID,
                        bookId: bookID,
                        number: p.number,
                        now: now
                    )
                    report.ghostRowsRepaired += 1
                }
            }

            // Recompute counters & settle book
            _ = try DownloadStore.recomputeCounters(db: db, serverId: serverID, bookId: bookID, now: now)
            _ = try DownloadStore.settleBook(db: db, serverId: serverID, bookId: bookID, now: now, mode: .sweep)
            report.countersRepaired += 1

            // Sync manifest after sweep
            if let row = try? DownloadStore.get(db: db, serverId: serverID, bookId: bookID) {
                let pages = (try? DownloadStore.pages(db: db, serverId: serverID, bookId: bookID)) ?? []
                let completedPages = pages.filter { $0.state == PageState.complete.rawValue && $0.filePath != nil }
                let manifestPages = completedPages.map { p in
                    ManifestPage(
                        number: p.number,
                        fileName: URL(fileURLWithPath: p.filePath!).lastPathComponent,
                        mediaType: p.mediaType,
                        sizeBytes: p.sizeBytes,
                        width: nil,
                        height: nil
                    )
                }
                let updatedManifest = DownloadManifest(
                    serverId: serverID,
                    bookId: bookID,
                    pagesCount: Int(row.pagesTotal),
                    downloadedAt: row.createdAt,
                    remoteLastModified: row.remoteLastModified,
                    pages: manifestPages
                )
                try? updatedManifest.write(to: manifestURL)
            }
        }

        return report
    }

    /// Reader helper: resolves a page to a local offline download file URL if available and complete.
    public static func usablePage(
        db: GRDB.Database,
        serverID: String,
        bookID: String,
        pageNumber: Int
    ) throws -> URL? {
        guard let page = try DownloadStore.page(db: db, serverId: serverID, bookId: bookID, number: pageNumber) else {
            return nil
        }
        guard page.state == PageState.complete.rawValue, let path = page.filePath else {
            return nil
        }
        if FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if ImageIntegrity.quickCheckFile(at: url, declaredSize: page.sizeBytes).isUsable {
                return url
            }
        }
        return nil
    }
}
