import XCTest
@testable import MediaLibCore

final class MusicPlaylistM3UPolicyTests: XCTestCase {
    func testM3UContentFormatsHeaderExtinfAndSkipsTracksWithoutPaths() {
        let tracks = [
            track(id: "intro", title: "Intro", artist: "  Alice  ", path: "/Music/intro.flac", duration: 3.6),
            track(id: "missing", title: "Missing", artist: "Bob", path: nil, duration: 9),
            track(id: "empty", title: "Empty", artist: "Bob", path: "", duration: 9),
            track(id: "solo", title: "Solo", artist: nil, path: "/Music/solo.mp3", duration: nil)
        ]

        XCTAssertEqual(
            MusicPlaylistM3UPolicy.m3uContent(for: tracks),
            """
            #EXTM3U
            #EXTINF:4,Alice - Intro
            /Music/intro.flac
            #EXTINF:0,Solo
            /Music/solo.mp3

            """
        )
    }

    func testM3UContentTrimsArtistNewlinesAndSkipsWhitespaceOnlyPaths() {
        let tracks = [
            track(id: "clean", title: "Clean", artist: "\n\tAlice  ", path: "/Music/clean.flac", duration: 1.2),
            track(id: "blank-path", title: "Blank", artist: "Bob", path: " \n\t ", duration: 2)
        ]

        XCTAssertEqual(
            MusicPlaylistM3UPolicy.m3uContent(for: tracks),
            """
            #EXTM3U
            #EXTINF:1,Alice - Clean
            /Music/clean.flac

            """
        )
    }

    func testM3UContentUsesZeroForNonFiniteAndUnrepresentableDurations() {
        let tracks = [
            track(id: "nan", title: "NaN", path: "/Music/nan.flac", duration: .nan),
            track(id: "inf", title: "Inf", path: "/Music/inf.flac", duration: .infinity),
            track(id: "neg-inf", title: "NegInf", path: "/Music/neg-inf.flac", duration: -.infinity),
            track(id: "huge", title: "Huge", path: "/Music/huge.flac", duration: .greatestFiniteMagnitude)
        ]

        XCTAssertEqual(
            MusicPlaylistM3UPolicy.m3uContent(for: tracks),
            """
            #EXTM3U
            #EXTINF:0,NaN
            /Music/nan.flac
            #EXTINF:0,Inf
            /Music/inf.flac
            #EXTINF:0,NegInf
            /Music/neg-inf.flac
            #EXTINF:0,Huge
            /Music/huge.flac

            """
        )
    }

    func testExtinfSecondsKeepsFiniteRepresentableDurations() {
        XCTAssertEqual(MusicPlaylistM3UPolicy.extinfSeconds(for: 3.6), 4)
        XCTAssertEqual(MusicPlaylistM3UPolicy.extinfSeconds(for: nil), 0)
        XCTAssertEqual(MusicPlaylistM3UPolicy.extinfSeconds(for: -1), -1)
    }

    func testDecodedTextReadsUTF8AndFallsBackToLatin1() throws {
        let utf8 = try XCTUnwrap("音乐/海边.m3u".data(using: .utf8))
        XCTAssertEqual(MusicPlaylistM3UPolicy.decodedText(from: utf8), "音乐/海边.m3u")

        let latin1 = Data([0x43, 0x61, 0x66, 0xE9, 0x2E, 0x6D, 0x70, 0x33])
        XCTAssertEqual(MusicPlaylistM3UPolicy.decodedText(from: latin1), "Café.mp3")
    }

    func testCandidatePathsSkipsCommentsAndNormalizesRelativeEntries() {
        let baseDirectory = URL(fileURLWithPath: "/Volumes/Media/Playlists", isDirectory: true)
        let content = """
        #EXTM3U

        #EXTINF:10,Absolute
        /Volumes/Music/A.mp3
           relative/../Track B.flac
        https://example.test/stream/C.mp3
          # still a comment after trimming
          nested/Track D.aac  
        """

        XCTAssertEqual(
            MusicPlaylistM3UPolicy.candidatePaths(from: content, baseDirectory: baseDirectory),
            [
                "/Volumes/Music/A.mp3",
                "/Volumes/Media/Playlists/Track B.flac",
                "https://example.test/stream/C.mp3",
                "/Volumes/Media/Playlists/nested/Track D.aac"
            ]
        )
    }

    func testCandidatePathsPreservesWindowsAndUNCAbsoluteEntries() {
        let baseDirectory = URL(fileURLWithPath: "/Volumes/Media/Playlists", isDirectory: true)
        let content = #"""
        #EXTM3U
        C:\Users\again\Music\Drive Song.flac
        Z:/Shared/Forward Slash Song.mp3
        \\NAS\Music\UNC Song.aac
        nested\Relative Windows Separator.m4a
        """#

        XCTAssertEqual(
            MusicPlaylistM3UPolicy.candidatePaths(from: content, baseDirectory: baseDirectory),
            [
                #"C:\Users\again\Music\Drive Song.flac"#,
                "Z:/Shared/Forward Slash Song.mp3",
                #"\\NAS\Music\UNC Song.aac"#,
                #"/Volumes/Media/Playlists/nested\Relative Windows Separator.m4a"#
            ]
        )
    }

    func testMatchedTracksUsesPathThenFilenameFallbackAndDeduplicatesIDs() {
        let tracks = [
            track(id: "exact", title: "Exact", path: "/Library/Exact.flac"),
            track(id: "filename-first", title: "Shared A", path: "/Library/A/Shared.mp3"),
            track(id: "filename-second", title: "Shared B", path: "/Library/B/Shared.mp3"),
            track(id: "remote", title: "Remote", path: "https://example.test/audio/Stream.mp3"),
            track(id: "no-path", title: "No Path", path: nil)
        ]

        let matched = MusicPlaylistM3UPolicy.matchedTracks(
            for: [
                "/Library/Exact.flac",
                "/External/Shared.mp3",
                "/External/Shared.mp3",
                "https://example.test/audio/Stream.mp3",
                "/External/Missing.mp3"
            ],
            in: tracks
        )

        XCTAssertEqual(matched.map(\.id), ["exact", "filename-first", "remote"])
    }

    func testMatchedTracksPrefersExactPathOverEarlierFilenameMatch() {
        let tracks = [
            track(id: "filename-only", title: "Filename", path: "/Library/Other/Collision.mp3"),
            track(id: "exact-path", title: "Exact", path: "/External/Collision.mp3")
        ]

        let matched = MusicPlaylistM3UPolicy.matchedTracks(
            for: ["/External/Collision.mp3"],
            in: tracks
        )

        XCTAssertEqual(matched.map(\.id), ["exact-path"])
    }

    func testMatchedTracksFallsBackToFilenameForWindowsAndURLPaths() {
        let tracks = [
            track(id: "drive", title: "Drive", path: "/Library/Drive Song.flac"),
            track(id: "unc", title: "UNC", path: "/Library/UNC Song.aac"),
            track(id: "relative", title: "Relative", path: "/Library/Relative Windows Separator.m4a"),
            track(id: "stream", title: "Stream", path: "/Library/Stream.mp3")
        ]

        let matched = MusicPlaylistM3UPolicy.matchedTracks(
            for: [
                #"C:\Users\again\Music\Drive Song.flac"#,
                #"\\NAS\Music\UNC Song.aac"#,
                #"/Volumes/Media/Playlists/nested\Relative Windows Separator.m4a"#,
                "https://example.test/audio/Stream.mp3?token=abc"
            ],
            in: tracks
        )

        XCTAssertEqual(matched.map(\.id), ["drive", "unc", "relative", "stream"])
    }

    private func track(
        id: String,
        title: String,
        artist: String? = nil,
        path: String?,
        duration: Double? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: .music,
            title: title,
            artist: artist,
            filePath: path,
            duration: duration,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
