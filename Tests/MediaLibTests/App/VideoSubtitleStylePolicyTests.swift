import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class VideoSubtitleStylePolicyTests: XCTestCase {
    func testStandardStyleMatchesExistingMpvDefaults() {
        XCTAssertEqual(
            VideoSubtitleStylePolicy.properties(for: .standard),
            VideoSubtitleStyleProperties(
                fontName: "sans-serif",
                bold: false,
                color: "#FFFFFF",
                borderSize: 3,
                backgroundColor: "#00000000"
            )
        )
    }

    func testCustomStyleMapsToExistingMpvProperties() {
        let style = VideoSubtitleStyle(
            fontName: "Helvetica Neue",
            bold: true,
            colorPreset: .cyan,
            borderSize: 4.5,
            backgroundOpacity: 0.5
        )

        XCTAssertEqual(
            VideoSubtitleStylePolicy.properties(for: style),
            VideoSubtitleStyleProperties(
                fontName: "Helvetica Neue",
                bold: true,
                color: "#7FE3E8",
                borderSize: 4.5,
                backgroundColor: "#80000000"
            )
        )
    }

    func testPlaybackPropertiesMatchExistingMpvPropertyOrderNamesAndValues() {
        let style = VideoSubtitleStyle(
            fontName: "Helvetica Neue",
            bold: true,
            colorPreset: .orange,
            borderSize: 4.5,
            backgroundOpacity: 0.8
        )

        XCTAssertEqual(
            VideoSubtitleStylePolicy.playbackProperties(for: style),
            [
                .string(name: "sub-font", value: "Helvetica Neue"),
                .flag(name: "sub-bold", value: true),
                .string(name: "sub-color", value: "#F5A14B"),
                .double(name: "sub-border-size", value: 4.5),
                .string(name: "sub-back-color", value: "#CC000000"),
            ]
        )
    }

    func testEmptyFontNameIsPreservedLikeExistingControllerBehavior() {
        let style = VideoSubtitleStyle(fontName: "")

        XCTAssertEqual(VideoSubtitleStylePolicy.properties(for: style).fontName, "")
    }

    func testBackgroundOpacityUpperBoundMapsToExistingAlpha() {
        let style = VideoSubtitleStyle(backgroundOpacity: 0.8)

        XCTAssertEqual(VideoSubtitleStylePolicy.properties(for: style).backgroundColor, "#CC000000")
        XCTAssertEqual(
            VideoSubtitleStylePolicy.playbackProperties(for: style).last,
            .string(name: "sub-back-color", value: "#CC000000")
        )
    }

    func testUnsafeMutatedBackgroundOpacityIsClampedBeforeMpvFormatting() {
        var style = VideoSubtitleStyle(backgroundOpacity: 0.25)
        style.backgroundOpacity = Double.nan

        XCTAssertEqual(VideoSubtitleStylePolicy.properties(for: style).backgroundColor, "#00000000")
    }

    func testAllColorPresetsKeepExistingMpvHexValues() {
        let expectedColors: [VideoSubtitleColorPreset: String] = [
            .white: "#FFFFFF",
            .yellow: "#F5D547",
            .cyan: "#7FE3E8",
            .green: "#8FE388",
            .orange: "#F5A14B",
        ]

        for preset in VideoSubtitleColorPreset.allCases {
            let style = VideoSubtitleStyle(colorPreset: preset)

            XCTAssertEqual(VideoSubtitleStylePolicy.colorValue(for: preset), expectedColors[preset])
            XCTAssertEqual(
                VideoSubtitleStylePolicy.properties(for: style).color,
                expectedColors[preset],
                "Unexpected mpv subtitle color for \(preset.rawValue)"
            )
        }
    }
}
