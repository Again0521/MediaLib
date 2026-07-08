import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoFilterChainPolicyTests: XCTestCase {
    func testFilterIsEmptyWhenAllInputsAreDisabled() {
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: nil,
                flipMode: .none,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            ""
        )
    }

    func testEmptyBaseFilterIsIgnored() {
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: "",
                flipMode: .horizontal,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            "hflip"
        )
    }

    func testWhitespaceBaseFilterIsPreservedLikeExistingControllerBehavior() {
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: " ",
                flipMode: .none,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            " "
        )
    }

    func testBaseFilterStaysFirst() {
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: "scale=1280:-2",
                flipMode: .none,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            "scale=1280:-2"
        )
    }

    func testFlipFiltersMatchExistingMpvOrder() {
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: nil,
                flipMode: .horizontal,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            "hflip"
        )
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: nil,
                flipMode: .vertical,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            "vflip"
        )
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: nil,
                flipMode: .both,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            "hflip,vflip"
        )
    }

    func testSharpenFiltersMatchExistingMpvValues() {
        XCTAssertEqual(filter(sharpenMode: .light), "unsharp=la=0.4")
        XCTAssertEqual(filter(sharpenMode: .medium), "unsharp=la=0.8")
        XCTAssertEqual(filter(sharpenMode: .strong), "unsharp=la=1.2")
    }

    func testDenoiseFiltersMatchExistingMpvValues() {
        XCTAssertEqual(filter(denoiseMode: .light), "hqdn3d=2:1.5:3:2.25")
        XCTAssertEqual(filter(denoiseMode: .medium), "hqdn3d=4:3:6:4.5")
        XCTAssertEqual(filter(denoiseMode: .strong), "hqdn3d=7:5:10:7.5")
    }

    func testCombinedFiltersPreserveExistingOrder() {
        XCTAssertEqual(
            VideoFilterChainPolicy.filter(
                baseVideoFilter: "scale=1280:-2",
                flipMode: .both,
                sharpenMode: .medium,
                denoiseMode: .light
            ),
            "scale=1280:-2,hflip,vflip,unsharp=la=0.8,hqdn3d=2:1.5:3:2.25"
        )
    }

    func testPropertyUsesExistingVfNameAndCombinedFilterValue() {
        XCTAssertEqual(
            VideoFilterChainPolicy.property(
                baseVideoFilter: "scale=1280:-2",
                flipMode: .both,
                sharpenMode: .medium,
                denoiseMode: .light
            ),
            VideoFilterChainProperty(
                name: "vf",
                value: "scale=1280:-2,hflip,vflip,unsharp=la=0.8,hqdn3d=2:1.5:3:2.25"
            )
        )
    }

    func testPropertyWritesEmptyStringWhenAllFiltersDisabled() {
        XCTAssertEqual(
            VideoFilterChainPolicy.property(
                baseVideoFilter: nil,
                flipMode: .none,
                sharpenMode: .off,
                denoiseMode: .off
            ),
            VideoFilterChainProperty(name: "vf", value: "")
        )
    }

    private func filter(
        sharpenMode: VideoSharpenMode = .off,
        denoiseMode: VideoDenoiseMode = .off
    ) -> String {
        VideoFilterChainPolicy.filter(
            baseVideoFilter: nil,
            flipMode: .none,
            sharpenMode: sharpenMode,
            denoiseMode: denoiseMode
        )
    }
}
