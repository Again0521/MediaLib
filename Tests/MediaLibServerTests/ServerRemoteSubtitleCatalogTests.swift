import Foundation
import MediaLibCore
import XCTest
@testable import MediaLibServer

/// 远程来源（Emby / Jellyfin / Plex）的字幕轨发现。
///
/// 这一层的全部风险都在"地址是怎么推出来的"：推错了就没有字幕（和从前一样），
/// 推到别的主机上就成了一个可以被上游返回值驱动的 SSRF。凭据必须留在服务端。
final class ServerRemoteSubtitleCatalogTests: XCTestCase {
    private func fetcher(_ responses: [String: Data]) -> ServerRemoteAssetFetcher {
        ServerRemoteAssetFetcher(responseOverride: { url, _, _ in
            responses.first { url.absoluteString.contains($0.key) }?.value
        })
    }

    private func embyItem(id: String) -> MediaItem {
        MediaItem(
            id: id, type: .movie, title: "影片",
            sourcePath: "emby://media.example/source-1",
            filePath: "https://media.example/Videos/abc123/stream.mkv?Static=true&api_key=SECRET&MediaSourceId=ms-9",
            metadataProvider: "Emby"
        )
    }

    private let embyListing = Data("""
    {"Items":[{"MediaSources":[{"Id":"ms-9","MediaStreams":[
      {"Index":2,"Type":"Subtitle","Codec":"ass","Language":"chi","DisplayTitle":"简体中文"},
      {"Index":3,"Type":"Subtitle","Codec":"pgssub","Language":"eng","DisplayTitle":"English PGS"},
      {"Index":1,"Type":"Audio","Codec":"ac3","Language":"eng"}
    ]}]}]}
    """.utf8)

    func testDerivesEmbySubtitleStreamsAndKeepsCredentialsServerSide() throws {
        let tracks = ServerRemoteSubtitleCatalog.tracks(
            for: embyItem(id: "emby-derive"),
            streamURL: URL(string: "https://media.example/Videos/abc123/stream.mkv?Static=true&api_key=SECRET&MediaSourceId=ms-9")!,
            fetcher: fetcher(["/Items?": embyListing])
        )
        XCTAssertEqual(tracks.count, 1, "图形字幕（PGS）没有文本形态，列出来只会选到一条空轨")
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.label, "简体中文")
        XCTAssertEqual(track.language, "zh")
        XCTAssertEqual(track.downloadURL.host, "media.example")
        XCTAssertTrue(track.downloadURL.path.hasSuffix("/Videos/abc123/ms-9/Subtitles/2/Stream.vtt"))
        // 上游已经转好成 VTT，格式跟着地址走而不是跟着容器里的 `ass` 走。
        XCTAssertEqual(track.format, "vtt")
    }

    /// 上游给的 `DeliveryUrl` 是**数据**，不是指令。一个被改过的返回值不能把服务端
    /// 引到别的主机去取东西。
    func testRejectsDeliveryURLPointingAtAnotherHost() {
        let listing = Data("""
        {"Items":[{"MediaSources":[{"Id":"ms-9","MediaStreams":[
          {"Index":2,"Type":"Subtitle","Codec":"srt","Language":"eng","DeliveryUrl":"https://attacker.example/steal.srt"}
        ]}]}]}
        """.utf8)
        let tracks = ServerRemoteSubtitleCatalog.tracks(
            for: embyItem(id: "emby-offhost"),
            streamURL: URL(string: "https://media.example/Videos/abc123/stream.mkv?api_key=SECRET&MediaSourceId=ms-9")!,
            fetcher: fetcher(["/Items?": listing])
        )
        XCTAssertTrue(tracks.isEmpty)
    }

    /// Emby 可以挂在 `/emby` 这样的子路径下，base 必须从 `Videos` 之前的那一段推。
    func testResolvesServerBaseUnderASubpath() throws {
        let tracks = ServerRemoteSubtitleCatalog.tracks(
            for: MediaItem(
                id: "emby-subpath", type: .movie, title: "影片",
                sourcePath: "jellyfin://media.example/source-1",
                filePath: "https://media.example/emby/Videos/abc123/stream.mkv?api_key=SECRET&MediaSourceId=ms-9",
                metadataProvider: "Jellyfin"
            ),
            streamURL: URL(string: "https://media.example/emby/Videos/abc123/stream.mkv?api_key=SECRET&MediaSourceId=ms-9")!,
            fetcher: fetcher(["/Items?": embyListing])
        )
        let track = try XCTUnwrap(tracks.first)
        XCTAssertTrue(track.downloadURL.path.hasPrefix("/emby/Videos/"))
    }

    func testDerivesPlexSubtitleStreamsFromMetadataXML() throws {
        let xml = Data("""
        <MediaContainer>
          <Video ratingKey="4021"><Media><Part>
            <Stream id="90" streamType="2" codec="ac3" />
            <Stream id="91" streamType="3" codec="ass" languageTag="zh" extendedDisplayTitle="简体中文 (ASS)" />
            <Stream id="92" streamType="3" codec="srt" languageTag="en" key="/library/streams/92" displayTitle="English" />
            <Stream id="93" streamType="3" codec="pgs" languageTag="ja" />
          </Part></Media></Video>
        </MediaContainer>
        """.utf8)
        let tracks = ServerRemoteSubtitleCatalog.tracks(
            for: MediaItem(
                id: "plex-derive", type: .movie, title: "影片",
                sourcePath: "plex://media.example/source-2",
                filePath: "https://media.example/library/parts/771/1700/file.mkv?X-Plex-Token=PLEXSECRET",
                externalID: "4021",
                metadataProvider: "Plex"
            ),
            streamURL: URL(string: "https://media.example/library/parts/771/1700/file.mkv?X-Plex-Token=PLEXSECRET")!,
            fetcher: fetcher(["/library/metadata/4021": xml])
        )
        XCTAssertEqual(tracks.count, 2, "图形字幕（PGS）不进名单")
        XCTAssertEqual(tracks[0].label, "简体中文 (ASS)")
        XCTAssertEqual(tracks[0].format, "ass")
        // 内封轨没有 `key`，走 `/library/streams/<id>`。
        XCTAssertEqual(tracks[0].downloadURL.path, "/library/streams/91")
        XCTAssertEqual(tracks[1].downloadURL.path, "/library/streams/92")
        XCTAssertTrue(tracks.allSatisfy { $0.downloadURL.query?.contains("X-Plex-Token=PLEXSECRET") == true })
    }

    /// 取回来的 ASS 要在服务端转成 WebVTT——`<track>` 不认 ASS，原样交出去浏览器
    /// 会静默丢掉整条轨道。
    func testRemoteASSPayloadIsConvertedToWebVTT() throws {
        let ass = Data("""
        [Script Info]
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,远程字幕
        """.utf8)
        let track = ServerRemoteSubtitleCatalog.Track(
            label: "简体中文", language: "zh", format: "ass",
            downloadURL: URL(string: "https://media.example/library/streams/91?X-Plex-Token=PLEXSECRET")!
        )
        let payload = try XCTUnwrap(
            ServerRemoteSubtitleCatalog.webVTT(for: track, fetcher: fetcher(["/library/streams/91": ass]))
        )
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("WEBVTT"))
        XCTAssertTrue(text.contains("远程字幕"))
    }

    /// 本地来源不会被误当成远程来源去联网。
    func testLocalItemsNeverReachUpstream() {
        let tracks = ServerRemoteSubtitleCatalog.tracks(
            for: MediaItem(id: "local-1", type: .movie, title: "影片", sourcePath: "/Volumes/Media", filePath: "/Volumes/Media/a.mkv"),
            streamURL: URL(string: "https://media.example/Videos/abc/stream.mkv?api_key=SECRET")!,
            fetcher: fetcher(["/Items?": embyListing])
        )
        XCTAssertTrue(tracks.isEmpty)
    }
}

/// Plex 的元数据是 XML，而服务端刻意不依赖 FoundationXML。属性扫描器必须自己站得住。
final class ServerXMLAttributeScannerTests: XCTestCase {
    func testReadsAttributesAndDecodesEntities() throws {
        let elements = ServerXMLAttributeScanner.elements(
            named: "Stream",
            in: #"<Stream id="1" title="A &amp; B" /><Other id="2" /><Stream id='3' title='单引号' />"#
        )
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0]["title"], "A & B")
        XCTAssertEqual(elements[1]["id"], "3")
        XCTAssertEqual(elements[1]["title"], "单引号")
    }

    /// 畸形输入不能让扫描器转不出来。
    func testUnterminatedElementDoesNotHang() {
        XCTAssertTrue(ServerXMLAttributeScanner.elements(named: "Stream", in: "<Stream id=\"1\"").isEmpty)
    }
}
