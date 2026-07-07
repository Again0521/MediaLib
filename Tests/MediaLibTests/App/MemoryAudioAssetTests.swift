import AVFoundation
import XCTest
@testable import MediaLib

final class MemoryAudioAssetTests: XCTestCase {
    func testContentTypePolicyPrefersDetectedTypeWhenAllowedTypesAreMissingOrContainIt() {
        XCTAssertEqual(
            MemoryAudioResourceLoadingPolicy.contentType(preferred: "public.mp3", allowedTypes: nil),
            "public.mp3"
        )
        XCTAssertEqual(
            MemoryAudioResourceLoadingPolicy.contentType(preferred: "public.flac", allowedTypes: []),
            "public.flac"
        )
        XCTAssertEqual(
            MemoryAudioResourceLoadingPolicy.contentType(
                preferred: "org.xiph.flac",
                allowedTypes: ["public.audio", "org.xiph.flac"]
            ),
            "org.xiph.flac"
        )
    }

    func testContentTypePolicyFallsBackToFirstAllowedTypeWhenPreferredTypeIsUnsupported() {
        XCTAssertEqual(
            MemoryAudioResourceLoadingPolicy.contentType(
                preferred: "org.xiph.flac",
                allowedTypes: ["public.audio", "public.data"]
            ),
            "public.audio"
        )
    }

    func testResponseRangePolicyClampsOffsetsAndLengthsToAvailableData() {
        XCTAssertEqual(
            MemoryAudioResourceLoadingPolicy.responseRange(
                dataCount: 10,
                requestedOffset: 2,
                currentOffset: 5,
                requestedLength: 3,
                requestsAllDataToEndOfResource: false
            ),
            5..<8
        )
        XCTAssertEqual(
            MemoryAudioResourceLoadingPolicy.responseRange(
                dataCount: 10,
                requestedOffset: -4,
                currentOffset: -1,
                requestedLength: 4,
                requestsAllDataToEndOfResource: false
            ),
            0..<4
        )
        XCTAssertEqual(
            MemoryAudioResourceLoadingPolicy.responseRange(
                dataCount: 10,
                requestedOffset: 7,
                currentOffset: 7,
                requestedLength: 99,
                requestsAllDataToEndOfResource: true
            ),
            7..<10
        )
    }

    func testResponseRangePolicyReturnsNilForEmptyOrOutOfBoundsResponses() {
        XCTAssertNil(
            MemoryAudioResourceLoadingPolicy.responseRange(
                dataCount: 10,
                requestedOffset: 10,
                currentOffset: 10,
                requestedLength: 1,
                requestsAllDataToEndOfResource: false
            )
        )
        XCTAssertNil(
            MemoryAudioResourceLoadingPolicy.responseRange(
                dataCount: 10,
                requestedOffset: 3,
                currentOffset: 3,
                requestedLength: 0,
                requestsAllDataToEndOfResource: false
            )
        )
        XCTAssertNil(
            MemoryAudioResourceLoadingPolicy.responseRange(
                dataCount: 0,
                requestedOffset: 0,
                currentOffset: 0,
                requestedLength: 1,
                requestsAllDataToEndOfResource: true
            )
        )
    }

    func testMemoryAudioAssetUsesCustomSchemeExtensionFallbackAndStableLoaderQueue() {
        let flacAsset = MemoryAudioAsset(fileURL: URL(fileURLWithPath: "/tmp/song.flac"), data: Data("audio".utf8))
        let fallbackAsset = MemoryAudioAsset(fileURL: URL(fileURLWithPath: "/tmp/song"), data: Data("audio".utf8))

        XCTAssertEqual(flacAsset.asset.url.scheme, "medialib-memory-audio")
        XCTAssertEqual(flacAsset.asset.url.pathExtension, "flac")
        XCTAssertEqual(fallbackAsset.asset.url.pathExtension, "audio")
        XCTAssertNotEqual(flacAsset.asset.url, fallbackAsset.asset.url)
        XCTAssertEqual(flacAsset.loader.queue.label, "MediaLIB.memory-audio-resource-loader")
    }
}
