import Foundation

// Standalone deterministic executable. No network, Keychain access, camera or PhotoKit operation.
// Fixture payloads are deliberately synthetic; this suite does not validate real JPEG/MPF decoding.
private enum ArchiveTestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ArchiveTestFailure.assertion(message) }
}
private func expectError(_ expected: SessionArchiveError, _ work: () throws -> Void) throws {
    do { try work() }
    catch let error as SessionArchiveError {
        try expect(error == expected, "Expected \(expected), got \(error)")
        return
    }
    throw ArchiveTestFailure.assertion("Expected error \(expected)")
}
private struct LegacyFixture: Codable {
    let sessionId: String
    let autoUpload: Bool
    let photos: [ReceivedJPEG]
}

@main
private struct SessionArchiveTests {
    static let start = Date(timeIntervalSince1970: 1_783_000_000)
    static let payload = Data([0xFF, 0xD8, 0x41, 0x42, 0xFF, 0xD9, 0x4D, 0x50, 0x46, 0x00, 0xFF])

    static func makePhoto(directory: URL, id: String = "photo-a", filename: String = "a.jpg",
                          date: Date = start, uploaded: Bool = false) throws -> ReceivedJPEG {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try payload.write(to: url)
        return ReceivedJPEG(id: id, name: filename, url: url, bytes: Int64(payload.count),
            sha256: String(repeating: "a", count: 64), createdAt: date, uploaded: uploaded)
    }
    static func subdirectory(_ root: URL, _ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    static func migration(_ root: URL) throws {
        let directory = subdirectory(root, "migration")
        let photo = try makePhoto(directory: directory, uploaded: true)
        let legacy = LegacyFixture(sessionId: "20260702-123456", autoUpload: false, photos: [photo])
        let bytes = try JSONEncoder().encode(legacy)
        let store = SessionArchiveStore(directoryURL: directory)
        try bytes.write(to: store.legacyURL, options: .atomic)
        let loaded = try store.loadOrCreate(at: start)
        try expect(loaded.schemaVersion == 2, "Legacy migrates to schema 2")
        try expect(loaded.currentSessionID == legacy.sessionId, "Must retain exact legacy ID/PC prefix")
        try expect(loaded.currentAlbum?.photos == [photo], "Must retain URL, all metadata and PC flag")
        try expect(!loaded.autoUpload, "Must preserve autoUpload false")
        let legacyAfter = try Data(contentsOf: store.legacyURL)
        let originalAfter = try Data(contentsOf: photo.url)
        try expect(legacyAfter == bytes, "Migration must never rewrite legacy backup")
        try expect(originalAfter == payload, "Migration must never trim/re-encode trailing bytes")
        let reloaded = try store.loadOrCreate(at: start.addingTimeInterval(10_000))
        try expect(loaded == reloaded, "Published archive reload must match exactly")
        try Data("corrupt legacy after successful migration".utf8).write(to: store.legacyURL)
        let stillPublished = try store.loadOrCreate()
        try expect(stillPublished == loaded, "Published v2 must take precedence over stale legacy")
    }

    static func ownershipAndPersistence(_ root: URL) throws {
        let directory = subdirectory(root, "ownership")
        let store = SessionArchiveStore(directoryURL: directory)
        var snapshot = try store.loadOrCreate(at: start)
        let firstID = snapshot.currentSessionID
        let first = try makePhoto(directory: directory, id: "first", filename: "first.jpg")
        try snapshot.ingest(first)
        let secondID = try snapshot.startNewActivity(eventName: "  晚宴／第二場  ", isReceiving: false,
            at: start.addingTimeInterval(60))
        try expect(firstID != secondID, "New activities have distinct stable IDs")
        try expect(snapshot.album(id: firstID)?.archivedAt != nil, "Previous capture album archived")
        try snapshot.selectAlbum(id: firstID)
        let second = try makePhoto(directory: directory, id: "second", filename: "second.jpg",
            date: start.addingTimeInterval(90))
        let owner = try snapshot.ingest(second)
        try expect(owner == secondID, "Capture never routes into a selected old album")
        try expect(snapshot.selectedAlbumID == firstID, "New receive must not steal history selection")
        try expect(snapshot.album(id: firstID)?.photos == [first], "Old album remains unchanged")
        try expect(snapshot.currentAlbum?.photos == [second], "New album owns new photo")
        try snapshot.updateAlbum(id: firstID) { album in
            album.eventName = "週年晚宴"
            album.operatorNotes = "黃昏，港島"
            album.coverPhotoID = first.id
        }
        try store.save(snapshot)
        let reloaded = try store.loadOrCreate()
        try expect(snapshot == reloaded, "All albums, selection, covers and notes survive reload")
        try expect(reloaded.history(matching: "週年").map(\.id) == [firstID], "Search user event name")
        try expect(reloaded.history(matching: "港島").map(\.id) == [firstID], "Search operator notes")
        try expect(reloaded.history().first?.id == secondID, "Newest activity first")
        let secondBytes = try Data(contentsOf: second.url)
        try expect(secondBytes == payload, "Archive switch must preserve original bytes")
        let allURLs = reloaded.albums.flatMap(\.photos).map(\.url)
        try expect(Set(allURLs) == Set([first.url, second.url]), "All landed original URLs survive")
    }

    static func guardsAndDuplicates(_ root: URL) throws {
        let directory = subdirectory(root, "guards")
        var snapshot = SessionArchiveSnapshot(current: SessionAlbumRecord(id: "current", startedAt: start))
        let before = snapshot
        try expectError(.receivingActive) {
            _ = try snapshot.startNewActivity(eventName: "blocked", isReceiving: true)
        }
        try expect(snapshot == before, "Blocked activity creation is non-mutating")
        try expectError(.missingAlbum) { try snapshot.selectAlbum(id: "missing") }
        let first = try makePhoto(directory: directory)
        let firstOwner = try snapshot.ingest(first)
        let secondOwner = try snapshot.ingest(first)
        try expect(firstOwner == secondOwner && snapshot.currentAlbum?.photos.count == 1,
            "Repeated same URL reference must not duplicate")
        let sameIDOtherURL = try makePhoto(directory: directory, id: first.id, filename: "separate.jpg")
        try snapshot.ingest(sameIDOtherURL)
        try expect(snapshot.currentAlbum?.photos.count == 2, "ID collision must not hide distinct original")
        try expect(Set(snapshot.currentAlbum!.photos.map(\.id)).count == 2, "Collision gets unique record ID")
        try expect(Set(snapshot.currentAlbum!.photos.map(\.url)) == Set([first.url, sameIDOtherURL.url]),
            "Identical content at separate URLs must remain addressable")
        let idA = try snapshot.startNewActivity(eventName: "same-second", isReceiving: false, at: start)
        let idB = try snapshot.startNewActivity(eventName: "same-second", isReceiving: false, at: start)
        try expect(idA != idB, "Same second must still create distinct IDs")
        try snapshot.validate()
    }

    static func failClosed(_ root: URL) throws {
        let corruptedDirectory = subdirectory(root, "corrupt")
        try FileManager.default.createDirectory(at: corruptedDirectory, withIntermediateDirectories: true)
        let store = SessionArchiveStore(directoryURL: corruptedDirectory)
        let garbage = Data("{incomplete".utf8)
        try garbage.write(to: store.archiveURL)
        try expectError(.corruptedArchive) { _ = try store.loadOrCreate() }
        let retained = try Data(contentsOf: store.archiveURL)
        try expect(retained == garbage, "Unreadable published archive must not be replaced")

        let oldDirectory = subdirectory(root, "corrupt-legacy")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldStore = SessionArchiveStore(directoryURL: oldDirectory)
        try garbage.write(to: oldStore.legacyURL)
        try expectError(.corruptedArchive) { _ = try oldStore.loadOrCreate() }
        try expect(!FileManager.default.fileExists(atPath: oldStore.archiveURL.path),
            "Cannot publish blank index over malformed legacy")

        var future = SessionArchiveSnapshot(current: SessionAlbumRecord(id: "future", startedAt: start))
        future.schemaVersion = 999
        let futureData = try JSONEncoder().encode(future)
        try futureData.write(to: store.archiveURL)
        try expectError(.unsupportedVersion) { _ = try store.loadOrCreate() }
        let after = try Data(contentsOf: store.archiveURL)
        try expect(after == futureData, "Future version must not be downgraded/overwritten")

        var invalid = SessionArchiveSnapshot(current: SessionAlbumRecord(id: "duplicate", startedAt: start))
        invalid.albums.append(invalid.albums[0])
        try expectError(.corruptedArchive) { try invalid.validate() }
        try expectError(.corruptedArchive) { try store.save(invalid) }
        let afterInvalidSave = try Data(contentsOf: store.archiveURL)
        try expect(afterInvalidSave == futureData, "Invalid transaction cannot alter existing archive")

        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocker)
        let blockedStore = SessionArchiveStore(directoryURL: blocker)
        let valid = SessionArchiveSnapshot(current: SessionAlbumRecord(id: "ok", startedAt: start))
        try expectError(.storageFailure) { try blockedStore.save(valid) }
    }

    static func sortingAndNames(_ root: URL) throws {
        let directory = subdirectory(root, "sort")
        let a = try makePhoto(directory: directory, id: "a", filename: "Z.jpg")
        let b = try makePhoto(directory: directory, id: "b", filename: "A.jpg")
        let later = try makePhoto(directory: directory, id: "later", filename: "later.jpg", date: start.addingTimeInterval(1))
        var album = SessionAlbumRecord(id: "20260702-123456-abcdefgh", eventName: "E\u{301}VÉNT", startedAt: start,
            photos: [b, a, later])
        try expect(album.sortedPhotos.map(\.id) == ["later", "a", "b"], "Date first, stable ID tie-break; not filename")
        try expect(album.coverPhoto?.id == later.id, "Newest photo is default cover")
        album.coverPhotoID = b.id
        try expect(album.coverPhoto?.id == b.id, "Explicit cover selected without touching bytes")
        let snapshot = SessionArchiveSnapshot(current: album)
        try expect(snapshot.history(matching: "event").count == 1, "Case/diacritic-insensitive search")
        try expect(SessionArchiveSnapshot.cleanName(" \n晚宴\t\u{0000} ") == "晚宴", "Names strip controls")
        try expect(SessionArchiveSnapshot.cleanName(String(repeating: "宴", count: 110)).count == 100,
            "Name length bounded by characters, never truncated UTF-8")
        for name in ["../../danger/活動\u{0000}", "..", "", "=1+1", "\\photo\n.jpg"] {
            let safe = SessionExport.safeFilename(name)
            try expect(!safe.isEmpty && !safe.contains("/") && !safe.contains("\\") && !safe.contains("..")
                && safe.utf8.allSatisfy { $0 < 128 && $0 >= 32 }, "Safe standalone export filename")
        }
        try expect(SessionExport.safeFilename("", fallback: "../../") == "CamLink", "Fallback is also sanitized")
        try expect(SessionExport.filename(album: album, format: .csv) == "20260702-123456-abcdefgh-delivery.csv",
            "Export filename deterministic; event rename must not change identity")
        try expect(SessionExport.isoDate(start).hasSuffix("Z"), "Export dates explicitly UTC")
        try expect(SessionExport.duration(nil) == "—" && SessionExport.duration(-1) == "—", "No invented stage timing")
        try expect(SessionExport.duration(12.5) == "12.500", "Duration format locale independent")
    }

    static func receiptsAndReports(_ root: URL) throws {
        let photo = try makePhoto(directory: subdirectory(root, "reports"), filename: "=formula,\"活動\".jpg", uploaded: true)
        var album = SessionAlbumRecord(id: "report", eventName: "@晚宴\n第二行", startedAt: start, photos: [photo])
        album.operatorNotes = "繁體中文，原樣 JSON\n沒有憑證"
        album.photoTimings[photo.id] = SessionPhotoTiming(receiveMilliseconds: 123.5)
        album.receipts = [SessionPhotoReceipt(photoID: photo.id, provider: .computer, destinationKey: "pc-primary",
            state: .verified, verification: .receiverSHA256, updatedAt: start)]
        let drive = SessionDeliverySummary(provider: .googleDrive, destinationKey: "local-slot", total: 1,
            verified: 1, updatedAt: start, verification: .driveIDSizeMD5Parent)
        let document = try SessionExport.report(album: album, summaries: [drive])
        try expect(document.photos[0].legacyPCUploaded, "Keep existing legacy PC status")
        try expect(document.deliverySummaries == [drive], "External worker summaries included exactly")
        try expect(document.photos[0].receipts.count == 1, "No unmeasured provider receipts fabricated")
        try expect(document.photos[0].receiveTiming?.queueMilliseconds == nil, "Missing timings remain nil")
        try expect(document.photos[0].originalAvailable, "Readable source is reported available")
        let json = try SessionExport.data(album: album, format: .json, summaries: [drive])
        let decoded = try JSONDecoder.isoDateDecoder.decode(SessionReportDocument.self, from: json)
        try expect(decoded.eventName == album.eventName && decoded.operatorNotes == album.operatorNotes,
            "JSON must preserve quotes, newlines and Traditional Chinese")
        try expect(decoded.photos[0].filename == photo.name, "JSON filename text remains exact")
        let text = try SessionExport.text(album: album, summaries: [drive])
        try expect(text.contains("Google Drive") && text.contains("driveIDSizeMD5Parent"), "Text exposes exact verify scope")
        try expect(text.contains("NOT_MEASURED"), "Report cannot imply measured card comparison/timing")
        let csv = try SessionExport.csv(album: album, summaries: [drive])
        let rows = try parseCSV(csv)
        try expect(rows.count == 3 && Set(rows.map(\.count)).count == 1, "CSV rectangular across photo/summary rows")
        try expect(rows[0].count == 27, "CSV complete header width")
        try expect(rows[1][2].hasPrefix("'="), "Formula-like filename protected in spreadsheets")
        try expect(rows[1][1].hasPrefix("'@"), "Formula-like event name protected")
        try expect(rows[1][13] == "NOT_RECORDED", "No Drive per-photo record invented from totals")
        try expect(rows[2][16] == "summary" && rows[2][17] == "googleDrive", "CSV contains supplied totals")
        try expect(rows[2][20] == "1", "CSV summary verified count")
        try expect(SessionExport.csvCell(" \t+cmd") == "\"' \t+cmd\"", "Leading whitespace formula guard")
        let export = try SessionExport.write(album: album, format: .json, summaries: [drive], directory: root)
        let second = try SessionExport.write(album: album, format: .json, summaries: [drive], directory: root)
        try expect(export != second && export.lastPathComponent == second.lastPathComponent,
            "Repeat export must never overwrite previous user-selected file")
        let sourceAfter = try Data(contentsOf: photo.url)
        try expect(sourceAfter == payload, "Report generation never rewrites source")

        let urls = try SessionExport.originalURLs(album: album, selectedIDs: [photo.id])
        try expect(urls == [photo.url], "Original export passes exact URL, not a transcoded copy")
        try expectError(.invalidOriginal) { _ = try SessionExport.originalURLs(album: album, selectedIDs: []) }
        try expectError(.invalidOriginal) { _ = try SessionExport.originalURLs(album: album, selectedIDs: ["missing"]) }
        let missing = ReceivedJPEG(id: "missing", name: "missing.jpg", url: root.appendingPathComponent("absent.jpg"),
            bytes: 1, sha256: "not-read", createdAt: start, uploaded: false)
        let missingAlbum = SessionAlbumRecord(id: "missing", startedAt: start, photos: [missing])
        try expectError(.invalidOriginal) { _ = try SessionExport.originalURLs(album: missingAlbum) }
        let missingReport = try SessionExport.report(album: missingAlbum)
        try expect(!missingReport.photos[0].originalAvailable, "Missing original is explicit, not silently discarded")
    }

    static func validation(_ root: URL) throws {
        try expectError(.invalidReceipt) {
            try SessionExport.validateReceipt(SessionPhotoReceipt(photoID: "p", provider: .googleDrive,
                destinationKey: "https://secret.example/path?token=x", state: .waiting))
        }
        try expectError(.invalidReceipt) {
            try SessionExport.validateReceipt(SessionPhotoReceipt(photoID: "p", provider: .computer,
                state: .verified, verification: .none))
        }
        try expectError(.invalidReceipt) {
            try SessionExport.validateReceipt(SessionPhotoReceipt(photoID: "p", provider: .oneDrive,
                state: .verified, verification: .receiverSHA256))
        }
        try expectError(.invalidReceipt) {
            try SessionExport.validateSummary(SessionDeliverySummary(provider: .oneDrive, total: 1,
                verified: 1, waiting: 1, verification: .oneDriveSizeOnly))
        }
        try expectError(.invalidReceipt) {
            try SessionExport.validateSummary(SessionDeliverySummary(provider: .googleDrive, total: 1, verified: 1))
        }
        try expectError(.invalidReceipt) {
            try SessionExport.validateSummary(SessionDeliverySummary(provider: .webDAV, total: -1))
        }
        try SessionExport.validateReceipt(SessionPhotoReceipt(photoID: "p", provider: .oneDrive,
            state: .verified, verification: .oneDriveSizeOnly))
        let photo = try makePhoto(directory: subdirectory(root, "invalid-reference"))
        var album = SessionAlbumRecord(id: "a", startedAt: start, photos: [photo])
        album.receipts = [SessionPhotoReceipt(photoID: "other-photo", provider: .webDAV,
            state: .verified, verification: .downloadedSizeSHA256)]
        let invalid = SessionArchiveSnapshot(current: album)
        try expectError(.corruptedArchive) { try invalid.validate() }
    }

    // RFC4180 parser used only by assertions. Handles embedded comma/newline/quotes; no line splitting.
    static func parseCSV(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = ""
        let characters = Array(text)
        var quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    cell.append("\""); index += 1
                } else { quoted.toggle() }
            } else if !quoted && character == "," {
                row.append(cell); cell = ""
            } else if !quoted && (character == "\r" || character == "\n" || character == "\r\n") {
                row.append(cell); cell = ""; rows.append(row); row = []
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else { cell.append(character) }
            index += 1
        }
        try expect(!quoted, "CSV has unterminated quote")
        if !row.isEmpty || !cell.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    #if SESSION_MODEL_TESTS
    @MainActor static func model(_ root: URL) throws {
        let directory = subdirectory(root, "model")
        let session = ShootSession(archiveDirectory: directory, now: start)
        let firstID = session.sessionId
        let photo = try makePhoto(directory: directory, id: "model-a", filename: "model-a.jpg")
        var events: [SessionEvent] = []
        session.onEvent = { events.append($0) }
        session.receivingDidStart(at: start)
        session.ingest(photo)
        try expect(session.photos == [photo], "Public compatibility photo list")
        try expect(events.contains(.firstPhoto(albumID: firstID, photoID: photo.id)), "Actual first ingest event")
        try expectError(.receivingActive) { _ = try session.startNewActivity(isReceiving: false) }
        session.receivingDidFinish(failedCount: 1, at: start.addingTimeInterval(1))
        try expect(events.contains(.receivingCompleted(albumID: firstID, received: 1, failed: 1)),
            "Receiving completion is not all-provider delivery completion")
        try session.setAlbumMetadata(eventName: "第一場", operatorNotes: "真實量度留空", albumID: firstID)
        let nameBefore = session.remoteName(for: photo)
        try expect(nameBefore == "\(firstID)_model-a.jpg", "Keep original PC naming")
        let nextID = try session.startNewActivity(eventName: "第二場", isReceiving: false, at: start.addingTimeInterval(60))
        try session.selectAlbum(id: firstID)
        let newPhoto = try makePhoto(directory: directory, id: "model-b", filename: "model-b.jpg")
        session.ingest(newPhoto)
        try expect(session.sessionId == nextID && session.photos == [newPhoto], "Viewed old album cannot capture")
        try expect(session.selectedAlbumID == firstID && session.selectedAlbum?.photos == [photo], "Selection remains independent")
        try expect(session.albumName == "第二場", "albumName alias is current capture display name")
        try expect(session.remoteName(for: photo) == nameBefore, "Historical remote filename stable")
        session.photos = []
        try expect(session.photos == [newPhoto], "Partial public assignment must never discard old original reference")
        try session.setPCUploaded(true, photoID: photo.id, albumID: firstID)
        try expect(session.album(id: firstID)?.legacyPCVerifiedCount == 1, "Archived PC result updatable by stable ID")
        try expect(session.verifiedCount == 0, "Legacy count still means current capture only")
        session.uploading = true
        try expectError(.transferActive) { _ = try session.startNewActivity(isReceiving: false) }
        session.uploading = false
        let restored = ShootSession(archiveDirectory: directory, now: start.addingTimeInterval(300))
        try expect(restored.sessionId == nextID && restored.selectedAlbumID == firstID, "Model reload retains IDs and history selection")
        try expect(restored.albums.count == 2 && restored.photos == [newPhoto], "Model reload retains all originals")
        let sourceAfter = try Data(contentsOf: photo.url)
        try expect(sourceAfter == payload, "Model APIs cannot trim/rewrite originals")
        // No uploadPending/resumeUpload call: those perform a real network transfer.
    }
    #endif

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CamLink-SessionArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Only the freshly created test-owned directory is removed, never an existing user photo/index.
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, (URL) throws -> Void)] = [
            ("legacy migration and exact original preservation", migration),
            ("stable capture ownership, selection and reload", ownershipAndPersistence),
            ("explicit new activity guards and duplicate references", guardsAndDuplicates),
            ("fail-closed JSON persistence and I/O failure", failClosed),
            ("deterministic date/filename sort and Unicode names", sortingAndNames),
            ("CSV/JSON/text, original URLs and supplied provider receipts", receiptsAndReports),
            ("verification levels and safe local receipt identities", validation)
        ]
        for (name, test) in cases { try test(root); print("PASS: \(name)") }
        #if SESSION_MODEL_TESTS
        try model(root)
        print("PASS: MainActor ShootSession compatibility and real model events")
        #endif
        print("SessionArchiveTests completed; no live provider/camera operation was performed.")
    }
}

private extension JSONDecoder {
    static var isoDateDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
