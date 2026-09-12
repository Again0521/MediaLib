import XCTest
@testable import MediaLibCore

final class VideoMetadataSidecarWriterTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testXMLContentEscapesFieldsAndUsesMovieRoot() {
        let item = MediaItem(id: "movie-1", type: .movie, title: "A & B")
        let update = MediaMetadataUpdate(
            title: "New <Title>",
            originalTitle: "Original \"Quoted\"",
            year: 2026,
            overview: "Plot with 'quotes' & symbols",
            rating: 8.5,
            externalID: "123&456",
            genre: "Drama > Action"
        )

        let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: update)

        XCTAssertTrue(xml.contains("<movie>"))
        XCTAssertTrue(xml.contains("<title>New &lt;Title&gt;</title>"))
        XCTAssertTrue(xml.contains("<originaltitle>Original \"Quoted\"</originaltitle>"))
        XCTAssertTrue(xml.contains("<plot>Plot with 'quotes' &amp; symbols</plot>"))
        XCTAssertTrue(xml.contains("<uniqueid type=\"tmdb\">123&amp;456</uniqueid>"))
        XCTAssertTrue(xml.contains("<genre>Drama &gt; Action</genre>"))
    }

    func testXMLContentUsesTVShowRootForSeriesItemsAndFallsBackToItemTitle() {
        let item = MediaItem(id: "show-1", type: .anime, title: "Fallback Title")
        let update = MediaMetadataUpdate(year: 2025)

        let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: update)

        XCTAssertTrue(xml.contains("<tvshow>"))
        XCTAssertTrue(xml.contains("<title>Fallback Title</title>"))
        XCTAssertTrue(xml.contains("<year>2025</year>"))
    }

    func testXMLContentEscapesFallbackTitleAndOmitsNilOptionalTags() {
        let item = MediaItem(id: "movie-fallback", type: .movie, title: "Fallback & <Title>")

        let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: MediaMetadataUpdate())

        XCTAssertTrue(xml.contains("<title>Fallback &amp; &lt;Title&gt;</title>"))
        XCTAssertFalse(xml.contains("<originaltitle>"))
        XCTAssertFalse(xml.contains("<year>"))
        XCTAssertFalse(xml.contains("<plot>"))
        XCTAssertFalse(xml.contains("<rating>"))
        XCTAssertFalse(xml.contains("<genre>"))
        XCTAssertFalse(xml.contains("<uniqueid"))
    }

    func testXMLContentOmitsNonFiniteAndOutOfRangeRatings() {
        let item = MediaItem(id: "movie-rating", type: .movie, title: "Rating")
        for rating in [Double.nan, .infinity, -.infinity, -1, 0, 10.1] {
            let xml = VideoMetadataSidecarWriter.xmlContent(
                for: item,
                update: MediaMetadataUpdate(rating: rating)
            )

            XCTAssertFalse(xml.contains("<rating>"), "rating \(rating) should not be exported to sidecar XML")
        }

        let lowBoundary = VideoMetadataSidecarWriter.xmlContent(
            for: item,
            update: MediaMetadataUpdate(rating: 0.1)
        )
        XCTAssertTrue(lowBoundary.contains("<rating>0.1</rating>"))

        let highBoundary = VideoMetadataSidecarWriter.xmlContent(
            for: item,
            update: MediaMetadataUpdate(rating: 10)
        )
        XCTAssertTrue(highBoundary.contains("<rating>10.0</rating>"))
    }

    func testXMLContentUsesTVShowRootForCollectionsWithoutAFile() {
        for type in [MediaType.tvShow, .anime, .documentary, .variety, .episode] {
            let item = MediaItem(id: "item-\(type.rawValue)", type: type, title: "Collection")

            let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: MediaMetadataUpdate())

            XCTAssertTrue(xml.contains("<tvshow>"), "Expected \(type) to use the tvshow root")
            XCTAssertTrue(xml.contains("</tvshow>"), "Expected \(type) to close the tvshow root")
        }
    }

    func testXMLContentUsesMovieRootForFileBackedVideoCategories() {
        for type in [MediaType.documentary, .variety, .homeVideo, .privateCollection] {
            let item = MediaItem(
                id: "item-\(type.rawValue)",
                type: type,
                title: "File Backed",
                filePath: "/tmp/file-backed.mkv"
            )

            let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: MediaMetadataUpdate())

            XCTAssertTrue(xml.contains("<movie>"), "Expected file-backed \(type) to use the movie root")
            XCTAssertTrue(xml.contains("</movie>"), "Expected file-backed \(type) to close the movie root")
        }
    }

    func testWritePersistsUTF8XML() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("movie.nfo")
        let item = MediaItem(id: "movie-2", type: .movie, title: "海边电影")
        let update = MediaMetadataUpdate(overview: "中文简介")

        let wrote = try await VideoMetadataSidecarWriter.write(item: item, update: update, to: targetURL)

        XCTAssertTrue(wrote)
        let xml = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(xml.contains("<title>海边电影</title>"))
        XCTAssertTrue(xml.contains("<plot>中文简介</plot>"))
    }

    func testWriteMergesSupportedFieldsAndPreservesUnknownContent() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("movie.nfo")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <movie custom="keep">
          <title language="zh">Old Title</title>
          <studio id="42">Keep Studio</studio>
          <uniqueid type="imdb" default="true">tt123</uniqueid>
          <rating source="legacy">4.0</rating>
        </movie>
        """.write(to: targetURL, atomically: true, encoding: .utf8)
        let item = MediaItem(id: "movie-4", type: .movie, title: "Replacement")

        let wrote = try await VideoMetadataSidecarWriter.write(
            item: item,
            update: MediaMetadataUpdate(rating: 9.25),
            to: targetURL
        )

        XCTAssertTrue(wrote)
        let xml = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(xml.contains("<title language=\"zh\">Old Title</title>"))
        XCTAssertTrue(xml.contains("<rating source=\"legacy\">9.25</rating>"))
        XCTAssertTrue(xml.contains("custom=\"keep\""))
        XCTAssertTrue(xml.contains("<studio id=\"42\">Keep Studio</studio>"))
        XCTAssertTrue(xml.contains("<uniqueid type=\"imdb\" default=\"true\">tt123</uniqueid>"))
    }

    func testMalformedAndUnsafeExistingDocumentsAreNeverOverwritten() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("unsafe.nfo")
        let item = MediaItem(id: "unsafe", type: .movie, title: "Safe")
        let inputs: [(String, VideoMetadataSidecarWriteError)] = [
            ("<movie><title>broken", .malformedExistingDocument),
            ("<!DOCTYPE movie [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><movie><title>&xxe;</title></movie>", .unsafeDocumentType),
            ("<tvshow><title>Wrong Root</title></tvshow>", .incompatibleRoot(expected: "movie", found: "tvshow"))
        ]

        for (original, expectedError) in inputs {
            try original.write(to: targetURL, atomically: true, encoding: .utf8)
            do {
                _ = try await VideoMetadataSidecarWriter.writeSafely(
                    item: item,
                    update: MediaMetadataUpdate(title: "Must Not Replace"),
                    to: targetURL
                )
                XCTFail("expected unsafe existing NFO to be rejected")
            } catch let error as VideoMetadataSidecarWriteError {
                XCTAssertEqual(error, expectedError)
            }
            XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), original)
        }
    }

    func testSymbolicLinkTargetIsRejectedWithoutChangingDestination() async throws {
        let directory = try temporaryDirectory()
        let destinationURL = directory.appendingPathComponent("destination.nfo")
        let targetURL = directory.appendingPathComponent("linked.nfo")
        let original = "<movie><title>Destination</title></movie>"
        try original.write(to: destinationURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: destinationURL)

        do {
            _ = try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "linked", type: .movie, title: "Linked"),
                update: MediaMetadataUpdate(title: "Must Not Write"),
                to: targetURL
            )
            XCTFail("expected symbolic-link target rejection")
        } catch let error as VideoMetadataSidecarWriteError {
            XCTAssertEqual(error, .symbolicLinkTarget)
        }
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), original)
    }

    func testConcurrentExternalModificationWinsAndLeavesNoTemporaryFiles() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("concurrent.nfo")
        try "<movie><title>Original</title></movie>".write(to: targetURL, atomically: true, encoding: .utf8)
        let externallyModified = "<movie><title>External Edit</title><custom>keep</custom></movie>"
        let hooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {
                try externallyModified.write(to: targetURL, atomically: true, encoding: .utf8)
            },
            replaceExisting: VideoMetadataSidecarWriteHooks.live.replaceExisting
        )

        do {
            _ = try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "concurrent", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "MediaLIB Edit"),
                to: targetURL,
                hooks: hooks
            )
            XCTFail("expected concurrent modification rejection")
        } catch let error as VideoMetadataSidecarWriteError {
            XCTAssertEqual(error, .concurrentModification)
        }
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), externallyModified)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("medialib-nfo-") })
    }

    func testTargetRemovedBeforeCommitIsTreatedAsConcurrentModification() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("removed-before-commit.nfo")
        try Data("<movie><title>Original</title></movie>".utf8).write(to: targetURL)
        let hooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {
                try FileManager.default.removeItem(at: targetURL)
            },
            replaceExisting: VideoMetadataSidecarWriteHooks.live.replaceExisting
        )

        do {
            _ = try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "removed", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "MediaLIB Edit"),
                to: targetURL,
                hooks: hooks
            )
            XCTFail("expected missing target to reject the commit")
        } catch let error as VideoMetadataSidecarWriteError {
            XCTAssertEqual(error, .concurrentModification)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("medialib-nfo-") })
    }

    func testExternalEditAfterReplacementWinsAndRetainsOriginalBackup() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("edited-after-replace.nfo")
        let original = Data("<movie><title>Original</title><custom>old</custom></movie>".utf8)
        let external = Data("<movie><title>External After Replace</title><custom>new</custom></movie>".utf8)
        try original.write(to: targetURL)
        let hooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {},
            replaceExisting: { targetURL, temporaryURL, backupName in
                let result = try VideoMetadataSidecarWriteHooks.live.replaceExisting(
                    targetURL,
                    temporaryURL,
                    backupName
                )
                try external.write(to: targetURL, options: [.atomic])
                return result
            }
        )

        do {
            _ = try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "post-replace", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "MediaLIB Edit"),
                to: targetURL,
                hooks: hooks
            )
            XCTFail("expected the post-replacement edit to win")
        } catch let error as VideoMetadataSidecarWriteError {
            XCTAssertEqual(error, .concurrentModification)
        }

        XCTAssertEqual(try Data(contentsOf: targetURL), external)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("medialib-nfo-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), original)
    }

    func testTwoInternalWritesToSameTargetAreSerialized() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("serialized.nfo")
        try Data("<movie><title>Original</title></movie>".utf8).write(to: targetURL)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let firstHooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {
                firstEntered.signal()
                releaseFirst.wait()
            },
            replaceExisting: VideoMetadataSidecarWriteHooks.live.replaceExisting
        )
        let secondHooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: { secondEntered.signal() },
            replaceExisting: VideoMetadataSidecarWriteHooks.live.replaceExisting
        )

        let first = Task {
            try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "serialized", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "First"),
                to: targetURL,
                hooks: firstHooks
            )
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        let second = Task {
            try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "serialized", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "Second"),
                to: targetURL,
                hooks: secondHooks
            )
        }

        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        _ = try await first.value
        _ = try await second.value

        let final = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(final.contains("<title>Second</title>"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("medialib-nfo-") })
    }

    func testCancelledInternalWriteLeavesCoordinatorUsable() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("cancelled-waiter.nfo")
        try Data("<movie><title>Original</title></movie>".utf8).write(to: targetURL)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let cancelledWriterEntered = DispatchSemaphore(value: 0)
        let firstHooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {
                firstEntered.signal()
                releaseFirst.wait()
            },
            replaceExisting: VideoMetadataSidecarWriteHooks.live.replaceExisting
        )
        let cancelledHooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: { cancelledWriterEntered.signal() },
            replaceExisting: VideoMetadataSidecarWriteHooks.live.replaceExisting
        )

        let first = Task {
            try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "cancelled-waiter", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "First"),
                to: targetURL,
                hooks: firstHooks
            )
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        let cancelled = Task {
            try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "cancelled-waiter", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "Cancelled"),
                to: targetURL,
                hooks: cancelledHooks
            )
        }
        cancelled.cancel()
        releaseFirst.signal()
        _ = try await first.value

        do {
            _ = try await cancelled.value
            XCTFail("expected the queued write to be cancelled")
        } catch is CancellationError {
            // Expected: cancellation removes the waiter without entering file I/O.
        }
        XCTAssertEqual(cancelledWriterEntered.wait(timeout: .now() + 0.1), .timedOut)

        _ = try await VideoMetadataSidecarWriter.writeSafely(
            item: MediaItem(id: "cancelled-waiter", type: .movie, title: "First"),
            update: MediaMetadataUpdate(title: "After Cancellation"),
            to: targetURL
        )
        let final = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(final.contains("<title>After Cancellation</title>"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("medialib-nfo-") })
    }

    func testReplacementFailureRestoresOriginalAndLeavesNoBackup() async throws {
        struct InjectedFailure: Error {}
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("replace-failure.nfo")
        let original = Data("<movie><title>Original</title><custom>keep</custom></movie>".utf8)
        try original.write(to: targetURL)
        let hooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {},
            replaceExisting: { targetURL, _, backupName in
                let backupURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
                try FileManager.default.moveItem(at: targetURL, to: backupURL)
                throw InjectedFailure()
            }
        )

        do {
            _ = try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "failure", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "Replacement"),
                to: targetURL,
                hooks: hooks
            )
            XCTFail("expected injected replacement failure")
        } catch let error as VideoMetadataSidecarWriteError {
            XCTAssertEqual(error, .replacementFailed)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("medialib-nfo-") })
    }

    func testReplacementFailureBeforeFilesystemMutationLeavesOriginalUntouched() async throws {
        struct InjectedFailure: Error {}
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("replace-no-mutation.nfo")
        let original = Data("<movie><title>Original</title></movie>".utf8)
        try original.write(to: targetURL)
        let hooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {},
            replaceExisting: { _, _, _ in throw InjectedFailure() }
        )

        do {
            _ = try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "no-mutation", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "Replacement"),
                to: targetURL,
                hooks: hooks
            )
            XCTFail("expected replacement failure")
        } catch let error as VideoMetadataSidecarWriteError {
            XCTAssertEqual(error, .replacementFailed)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("medialib-nfo-") })
    }

    func testFailedBackupRecoveryRetainsBackupAndDoesNotInstallCorruptTarget() async throws {
        struct InjectedFailure: Error {}
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("recovery-failure.nfo")
        let original = Data("<movie><title>Original</title></movie>".utf8)
        let corruptBackup = Data("not-the-original".utf8)
        try original.write(to: targetURL)
        let hooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {},
            replaceExisting: { targetURL, _, backupName in
                let backupURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
                try FileManager.default.moveItem(at: targetURL, to: backupURL)
                try corruptBackup.write(to: backupURL)
                throw InjectedFailure()
            }
        )

        do {
            _ = try await VideoMetadataSidecarWriter.writeSafely(
                item: MediaItem(id: "recovery", type: .movie, title: "Original"),
                update: MediaMetadataUpdate(title: "Replacement"),
                to: targetURL,
                hooks: hooks
            )
            XCTFail("expected recovery failure")
        } catch let error as VideoMetadataSidecarWriteError {
            XCTAssertEqual(error, .recoveryFailed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("medialib-nfo-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), corruptBackup)
    }

    func testBackupCleanupFailureReturnsWarningAndKeepsWrittenTarget() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("cleanup-warning.nfo")
        try Data("<movie><title>Original</title></movie>".utf8).write(to: targetURL)
        let hooks = VideoMetadataSidecarWriteHooks(
            beforeCommit: {},
            replaceExisting: { targetURL, temporaryURL, backupName in
                let result = try VideoMetadataSidecarWriteHooks.live.replaceExisting(
                    targetURL,
                    temporaryURL,
                    backupName
                )
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                return result
            }
        )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let outcome = try await VideoMetadataSidecarWriter.writeSafely(
            item: MediaItem(id: "cleanup", type: .movie, title: "Original"),
            update: MediaMetadataUpdate(title: "Replacement"),
            to: targetURL,
            hooks: hooks
        )

        guard case let .written(report) = outcome else {
            return XCTFail("expected a successful write with cleanup warning")
        }
        XCTAssertNotNil(report.warning)
        XCTAssertTrue(try String(contentsOf: targetURL, encoding: .utf8).contains("<title>Replacement</title>"))
    }

    func testReadOnlyExistingTargetReturnsDistinctNotWritableResult() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("read-only.nfo")
        let original = Data("<movie><title>Read Only</title></movie>".utf8)
        try original.write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: targetURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path) }

        let outcome = try await VideoMetadataSidecarWriter.writeSafely(
            item: MediaItem(id: "read-only", type: .movie, title: "Read Only"),
            update: MediaMetadataUpdate(title: "Must Not Write"),
            to: targetURL
        )

        XCTAssertEqual(outcome, .skipped(.notWritable))
        XCTAssertEqual(try Data(contentsOf: targetURL), original)
    }

    func testWriteReturnsFalseWhenDirectoryIsNotWritableTarget() async throws {
        let targetURL = try temporaryDirectory()
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("movie.nfo")
        let item = MediaItem(id: "movie-3", type: .movie, title: "Missing")

        let wrote = try await VideoMetadataSidecarWriter.write(
            item: item,
            update: MediaMetadataUpdate(),
            to: targetURL
        )

        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    private func temporaryDirectory() throws -> URL {
        if let tempDirectory {
            return tempDirectory
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoMetadataSidecarWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectory = root
        return root
    }
}
