import XCTest
@testable import MediaLib

final class MpvTrackTests: XCTestCase {
    func testDisplayNameCombinesMetadataAndExternalMarker() {
        let track = MpvTrack(
            id: 4,
            type: .subtitle,
            title: "Commentary",
            language: "zh-cn",
            codec: "ass",
            isSelected: false,
            isExternal: true,
            externalFilename: "/subs/movie.ass"
        )

        XCTAssertEqual(track.displayName, "ZH-CN · Commentary · ASS · 外挂")
    }

    func testDisplayNameFallsBackByTrackKindWhenMetadataIsMissing() {
        XCTAssertEqual(makeBareTrack(id: 2, type: .audio).displayName, "音轨 2")
        XCTAssertEqual(makeBareTrack(id: 7, type: .subtitle).displayName, "字幕 7")
        XCTAssertEqual(makeBareTrack(id: 9, type: .unknown).displayName, "轨道 9")
    }

    func testWithSelectionOnlyChangesSelectedFlag() {
        let original = MpvTrack(
            id: 3,
            type: .audio,
            title: "Stereo",
            language: "eng",
            codec: "aac",
            isSelected: false,
            isExternal: false,
            externalFilename: nil
        )

        let selected = original.withSelection(true)

        XCTAssertTrue(selected.isSelected)
        XCTAssertEqual(selected.id, original.id)
        XCTAssertEqual(selected.type, original.type)
        XCTAssertEqual(selected.title, original.title)
        XCTAssertEqual(selected.language, original.language)
        XCTAssertEqual(selected.codec, original.codec)
        XCTAssertEqual(selected.isExternal, original.isExternal)
        XCTAssertEqual(selected.externalFilename, original.externalFilename)
    }

    private func makeBareTrack(id: Int, type: MpvTrack.Kind) -> MpvTrack {
        MpvTrack(
            id: id,
            type: type,
            title: nil,
            language: nil,
            codec: nil,
            isSelected: false,
            isExternal: false,
            externalFilename: nil
        )
    }
}
