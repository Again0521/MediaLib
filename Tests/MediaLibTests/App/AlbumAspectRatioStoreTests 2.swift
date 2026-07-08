import AppKit
import MediaLibCore
import XCTest
@testable import MediaLib

final class AlbumAspectRatioStoreTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testReadAspectsReturnsImageMetadataRatiosAndSkipsMissingFiles() async throws {
        let imageURL = try temporaryFileURL("wide.png")
        let missingURL = try temporaryFileURL("missing.png")
        try writePNG(width: 80, height: 40, to: imageURL)

        let ratios = await AlbumAspectRatioStore.readAspects(paths: [imageURL.path, missingURL.path])
        let ratio = try XCTUnwrap(ratios[imageURL.path])

        XCTAssertEqual(ratio, 2.0, accuracy: 0.0001)
        XCTAssertNil(ratios[missingURL.path])
    }

    @MainActor
    func testEnsureLoadedPublishesCachedRatioForPhotoWithoutResolution() async throws {
        let imageURL = try temporaryFileURL("portrait.png")
        try writePNG(width: 30, height: 60, to: imageURL)
        let item = photoItem(id: "portrait", filePath: imageURL.path)
        let store = AlbumAspectRatioStore()

        XCTAssertEqual(store.ratio(for: item), 1.0, accuracy: 0.0001)
        store.ensureLoaded([item])

        try await waitForRatio(0.5, item: item, store: store)
    }

    @MainActor
    func testRatioPrefersExistingResolutionOverFileMetadata() async throws {
        let imageURL = try temporaryFileURL("square.png")
        try writePNG(width: 40, height: 40, to: imageURL)
        let item = photoItem(id: "parsed", filePath: imageURL.path, resolution: "400x100")
        let store = AlbumAspectRatioStore()

        store.ensureLoaded([item])

        XCTAssertEqual(store.ratio(for: item), 4.0, accuracy: 0.0001)
    }

    @MainActor
    func testEnsureLoadedClearsInFlightAfterFailedReadSoPathCanRetry() async throws {
        let imageURL = try temporaryFileURL("retry.png")
        try Data("not an image".utf8).write(to: imageURL)
        let item = photoItem(id: "retry", filePath: imageURL.path)
        let store = AlbumAspectRatioStore()

        store.ensureLoaded([item])
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(store.ratio(for: item), 1.0, accuracy: 0.0001)

        try writePNG(width: 90, height: 30, to: imageURL)
        store.ensureLoaded([item])

        try await waitForRatio(3.0, item: item, store: store)
    }

    private func photoItem(id: String, filePath: String, resolution: String? = nil) -> MediaItem {
        MediaItem(
            id: id,
            type: .photo,
            title: "Photo \(id)",
            filePath: filePath,
            resolution: resolution
        )
    }

    private func temporaryFileURL(_ name: String) throws -> URL {
        if tempDirectory == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AlbumAspectRatioStoreTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tempDirectory = root
        }
        return tempDirectory!.appendingPathComponent(name)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    @MainActor
    private func waitForRatio(
        _ expected: Double,
        item: MediaItem,
        store: AlbumAspectRatioStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<40 {
            let ratio = store.ratio(for: item)
            if abs(ratio - expected) < 0.0001 {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for album aspect ratio \(expected)", file: file, line: line)
    }
}
