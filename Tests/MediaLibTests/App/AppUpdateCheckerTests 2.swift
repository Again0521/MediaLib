import XCTest
@testable import MediaLib

final class AppUpdateCheckerTests: XCTestCase {
    func testExtractVersionAcceptsTaggedAndNamedReleaseFormats() {
        XCTAssertEqual(AppVersion.extractVersion(from: "v1.2.3"), "1.2.3")
        XCTAssertEqual(AppVersion.extractVersion(from: "MediaLIB_V1.2.3"), "1.2.3")
        XCTAssertEqual(AppVersion.extractVersion(from: "Release notes for 1.2.3.4"), "1.2.3.4")
        XCTAssertEqual(AppVersion.extractVersion(from: "MediaLIB 01.002.0003"), "01.002.0003")
    }

    func testExtractVersionRejectsNonReleaseNumbers() {
        XCTAssertNil(AppVersion.extractVersion(from: "build 42"))
        XCTAssertNil(AppVersion.extractVersion(from: "v1"))
        XCTAssertNil(AppVersion.extractVersion(from: "MediaLIB latest"))
    }

    func testVersionComparisonUsesNumericComponentsAndMissingComponentsAsZero() {
        XCTAssertTrue(AppVersion.isVersion("1.1.11", newerThan: "1.1.2"))
        XCTAssertTrue(AppVersion.isVersion("1.2.1", newerThan: "1.2"))
        XCTAssertFalse(AppVersion.isVersion("1.2", newerThan: "1.2.0"))
        XCTAssertFalse(AppVersion.isVersion("1.20.01", newerThan: "1.20.10"))
        XCTAssertFalse(AppVersion.isVersion("2.0", newerThan: "10.0"))
    }

    func testReleaseVersionUsesTagNameBeforeTitleBodyAndAssets() {
        let version = AppUpdateChecker.releaseVersion(
            tagName: "v1.4.0",
            name: "MediaLIB 1.5.0",
            body: "Download 1.6.0",
            assetNames: ["MediaLib-1.7.0.dmg"]
        )

        XCTAssertEqual(version, "1.4.0")
    }

    func testReleaseVersionFallsBackThroughTitleBodyAndAssetNames() {
        XCTAssertEqual(
            AppUpdateChecker.releaseVersion(
                tagName: "latest",
                name: "Media_Lib v1.5.0",
                body: nil,
                assetNames: []
            ),
            "1.5.0"
        )
        XCTAssertEqual(
            AppUpdateChecker.releaseVersion(
                tagName: "latest",
                name: nil,
                body: "Maintenance release 1.5.1",
                assetNames: []
            ),
            "1.5.1"
        )
        XCTAssertEqual(
            AppUpdateChecker.releaseVersion(
                tagName: "latest",
                name: nil,
                body: nil,
                assetNames: ["MediaLib-1.5.2.dmg"]
            ),
            "1.5.2"
        )
        XCTAssertNil(
            AppUpdateChecker.releaseVersion(
                tagName: "latest",
                name: "MediaLIB",
                body: "No version",
                assetNames: ["MediaLib.dmg"]
            )
        )
    }

    func testPreferredInstallAssetRanksDMGBeforeZipVariants() {
        let selected = AppUpdateChecker.preferredInstallAsset(from: [
            asset("MediaLib.app.zip", size: 2_000),
            asset("MediaLib-1.5.0.zip", size: 5_000),
            asset("MediaLib-1.5.0.dmg", contentType: "application/octet-stream", size: 1_000)
        ])

        XCTAssertEqual(selected?.name, "MediaLib-1.5.0.dmg")
    }

    func testPreferredInstallAssetTreatsDiskImageContentTypeAsDMG() {
        let selected = AppUpdateChecker.preferredInstallAsset(from: [
            asset("MediaLib.app.zip", size: 4_000),
            asset("MediaLib-installer", contentType: "application/x-apple-diskimage", size: 1_000)
        ])

        XCTAssertEqual(selected?.name, "MediaLib-installer")
    }

    func testPreferredInstallAssetRanksAppZipBeforeGenericZip() {
        let selected = AppUpdateChecker.preferredInstallAsset(from: [
            asset("MediaLib-1.5.0.zip", size: 5_000),
            asset("MediaLib.app.zip", size: 1_000)
        ])

        XCTAssertEqual(selected?.name, "MediaLib.app.zip")
    }

    func testPreferredInstallAssetUsesLargerAssetForSameRank() {
        let selected = AppUpdateChecker.preferredInstallAsset(from: [
            asset("MediaLib-1.5.0.dmg", size: 1_000),
            asset("MediaLib-1.5.0-arm64.dmg", size: 2_000)
        ])

        XCTAssertEqual(selected?.name, "MediaLib-1.5.0-arm64.dmg")
    }

    func testPreferredInstallAssetIgnoresMissingDownloadURLsAndUnsupportedTypes() {
        let selected = AppUpdateChecker.preferredInstallAsset(from: [
            asset("MediaLib-1.5.0.dmg", size: 2_000, browserDownloadURL: ""),
            asset("MediaLib-1.5.1.dmg", size: 3_000, browserDownloadURL: " \n\t "),
            asset("checksums.txt", size: 100),
            asset("MediaLib.pkg", size: 3_000)
        ])

        XCTAssertNil(selected)
    }

    func testCleanedReleaseTitleNormalizesBlankAndMediaLibVersionPrefix() {
        XCTAssertEqual(AppUpdateChecker.cleanedReleaseTitle("", version: "1.5.0"), "MediaLIB 1.5.0")
        XCTAssertEqual(AppUpdateChecker.cleanedReleaseTitle("  Media_Lib v1.5.0  ", version: "1.5.0"), "MediaLIB 1.5.0")
        XCTAssertEqual(AppUpdateChecker.cleanedReleaseTitle("media lib V2.0.0 release", version: "2.0.0"), "MediaLIB 2.0.0 release")
    }

    func testParsedReleaseDateAcceptsFractionalAndWholeSecondISO8601() throws {
        XCTAssertEqual(
            try XCTUnwrap(AppUpdateChecker.parsedReleaseDate("2026-07-01T10:20:30.123Z")),
            try XCTUnwrap(isoDate("2026-07-01T10:20:30.123Z"))
        )
        XCTAssertEqual(
            try XCTUnwrap(AppUpdateChecker.parsedReleaseDate("2026-07-01T10:20:30Z")),
            try XCTUnwrap(isoDate("2026-07-01T10:20:30Z"))
        )
        XCTAssertNil(AppUpdateChecker.parsedReleaseDate("July 1, 2026"))
    }

    func testLatestReleaseInfoChoosesHighestInstallableNonDraftRelease() throws {
        let info = try XCTUnwrap(AppUpdateChecker.latestReleaseInfo(fromGitHubReleasesJSON: jsonData("""
        [
          {
            "tag_name": "v1.4.0",
            "name": "MediaLIB v1.4.0",
            "body": "draft",
            "html_url": "https://github.com/Again0521/MediaLib/releases/tag/v1.4.0",
            "draft": true,
            "prerelease": false,
            "published_at": "2026-07-03T10:20:30Z",
            "assets": [
              {
                "name": "MediaLib-1.4.0.dmg",
                "content_type": "application/x-apple-diskimage",
                "size": 9000,
                "browser_download_url": "https://example.test/MediaLib-1.4.0.dmg"
              }
            ]
          },
          {
            "tag_name": "v1.3.0",
            "name": "Media_Lib v1.3.0",
            "body": "  stable notes\\n",
            "html_url": "https://github.com/Again0521/MediaLib/releases/tag/v1.3.0",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-07-02T10:20:30.123Z",
            "assets": [
              {
                "name": "MediaLib-1.3.0.zip",
                "content_type": "application/zip",
                "size": 5000,
                "browser_download_url": "https://example.test/MediaLib-1.3.0.zip"
              },
              {
                "name": "MediaLib-1.3.0.dmg",
                "content_type": "application/x-apple-diskimage",
                "size": 3000,
                "browser_download_url": "https://example.test/MediaLib-1.3.0.dmg"
              }
            ]
          },
          {
            "tag_name": "v1.9.0",
            "name": "MediaLIB v1.9.0",
            "body": "no installer",
            "html_url": "https://github.com/Again0521/MediaLib/releases/tag/v1.9.0",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-07-04T10:20:30Z",
            "assets": [
              {
                "name": "checksums.txt",
                "content_type": "text/plain",
                "size": 10,
                "browser_download_url": "https://example.test/checksums.txt"
              }
            ]
          }
        ]
        """)))

        XCTAssertEqual(info.version, "1.3.0")
        XCTAssertEqual(info.tagName, "v1.3.0")
        XCTAssertEqual(info.title, "MediaLIB 1.3.0")
        XCTAssertEqual(info.releaseNotes, "stable notes")
        XCTAssertEqual(info.downloadURL?.absoluteString, "https://example.test/MediaLib-1.3.0.dmg")
        XCTAssertEqual(info.assetName, "MediaLib-1.3.0.dmg")
        XCTAssertEqual(info.assetSize, 3_000)
        XCTAssertEqual(info.publishedAt, isoDate("2026-07-02T10:20:30.123Z"))
        XCTAssertFalse(info.prerelease)
    }

    func testLatestReleaseInfoUsesPublishedDateAsTieBreakerForSameVersion() throws {
        let info = try XCTUnwrap(AppUpdateChecker.latestReleaseInfo(fromGitHubReleasesJSON: jsonData("""
        [
          {
            "tag_name": "v1.5.0",
            "name": "MediaLIB v1.5.0",
            "body": "older",
            "html_url": "https://github.com/Again0521/MediaLib/releases/tag/v1.5.0",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-07-01T00:00:00Z",
            "assets": [
              {
                "name": "MediaLib-1.5.0.dmg",
                "content_type": "application/x-apple-diskimage",
                "size": 1000,
                "browser_download_url": "https://example.test/older.dmg"
              }
            ]
          },
          {
            "tag_name": "MediaLIB_V1.5.0",
            "name": "MediaLIB v1.5.0 hotfix",
            "body": "newer",
            "html_url": "https://github.com/Again0521/MediaLib/releases/tag/MediaLIB_V1.5.0",
            "draft": false,
            "prerelease": true,
            "published_at": "2026-07-02T00:00:00Z",
            "assets": [
              {
                "name": "MediaLib-1.5.0.dmg",
                "content_type": "application/x-apple-diskimage",
                "size": 1000,
                "browser_download_url": "https://example.test/newer.dmg"
              }
            ]
          }
        ]
        """)))

        XCTAssertEqual(info.version, "1.5.0")
        XCTAssertEqual(info.tagName, "MediaLIB_V1.5.0")
        XCTAssertEqual(info.downloadURL?.absoluteString, "https://example.test/newer.dmg")
        XCTAssertTrue(info.prerelease)
    }

    func testLatestReleaseInfoFindsVersionFromAssetAndFallsBackToVersionTagWhenTagIsEmpty() throws {
        let info = try XCTUnwrap(AppUpdateChecker.latestReleaseInfo(fromGitHubReleasesJSON: jsonData("""
        [
          {
            "tag_name": "",
            "name": "",
            "body": "",
            "html_url": "https://github.com/Again0521/MediaLib/releases/tag/latest",
            "draft": false,
            "prerelease": false,
            "published_at": null,
            "assets": [
              {
                "name": "MediaLib-1.6.2.dmg",
                "content_type": "application/x-apple-diskimage",
                "size": 1000,
                "browser_download_url": "https://example.test/MediaLib-1.6.2.dmg"
              }
            ]
          }
        ]
        """)))

        XCTAssertEqual(info.version, "1.6.2")
        XCTAssertEqual(info.tagName, "1.6.2")
        XCTAssertEqual(info.title, "MediaLIB 1.6.2")
        XCTAssertNil(info.publishedAt)
    }

    func testLatestReleaseInfoReturnsNilWhenNoReleaseIsInstallable() throws {
        let info = try AppUpdateChecker.latestReleaseInfo(fromGitHubReleasesJSON: jsonData("""
        [
          {
            "tag_name": "v2.0.0",
            "name": "MediaLIB v2.0.0",
            "body": "",
            "html_url": "https://github.com/Again0521/MediaLib/releases/tag/v2.0.0",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-07-01T00:00:00Z",
            "assets": [
              {
                "name": "checksums.txt",
                "content_type": "text/plain",
                "size": 100,
                "browser_download_url": "https://example.test/checksums.txt"
              }
            ]
          }
        ]
        """))

        XCTAssertNil(info)
    }

    func testLatestReleaseInfoThrowsForMalformedGitHubJSON() {
        XCTAssertThrowsError(
            try AppUpdateChecker.latestReleaseInfo(fromGitHubReleasesJSON: Data("{".utf8))
        )
    }

    func testFallbackReleaseInfoParsesFirstUsableReleasePageTagAndAsset() throws {
        let html = """
        <a href="/Again0521/MediaLib/releases/tag/latest">latest</a>
        <a href="/Again0521/MediaLib/releases/tag/v1.7.0">v1.7.0</a>
        <a href="/Again0521/MediaLib/releases/tag/v1.7.0">duplicate</a>
        <a href="/Again0521/MediaLib/releases/download/v1.7.0/MediaLib%201.7.0.dmg">Download</a>
        """

        let info = try XCTUnwrap(AppUpdateChecker.fallbackReleaseInfo(fromReleasePageHTML: html))

        XCTAssertEqual(info.version, "1.7.0")
        XCTAssertEqual(info.tagName, "v1.7.0")
        XCTAssertEqual(info.title, "MediaLIB 1.7.0")
        XCTAssertEqual(info.releaseURL.absoluteString, "https://github.com/Again0521/MediaLib/releases/tag/v1.7.0")
        XCTAssertEqual(info.downloadURL?.absoluteString, "https://github.com/Again0521/MediaLib/releases/download/v1.7.0/MediaLib%201.7.0.dmg")
        XCTAssertEqual(info.assetName, "MediaLib 1.7.0.dmg")
        XCTAssertNil(info.assetSize)
        XCTAssertNil(info.publishedAt)
        XCTAssertFalse(info.prerelease)
    }

    func testFallbackReleaseInfoMarksBetaTagsAsPrereleaseAndAllowsMissingAsset() throws {
        let html = """
        <a href="/Again0521/MediaLib/releases/tag/v1.8.0-beta.1">v1.8.0-beta.1</a>
        """

        let info = try XCTUnwrap(AppUpdateChecker.fallbackReleaseInfo(fromReleasePageHTML: html))

        XCTAssertEqual(info.version, "1.8.0")
        XCTAssertEqual(info.tagName, "v1.8.0-beta.1")
        XCTAssertNil(info.downloadURL)
        XCTAssertNil(info.assetName)
        XCTAssertTrue(info.prerelease)
    }

    func testFallbackReleaseInfoReturnsNilWhenPageHasNoVersionedReleaseLinks() {
        let html = """
        <a href="/Again0521/MediaLib/releases/tag/latest">latest</a>
        <a href="/Other/MediaLib/releases/tag/v9.9.9">wrong repository</a>
        """

        XCTAssertNil(AppUpdateChecker.fallbackReleaseInfo(fromReleasePageHTML: html))
    }

    private func asset(
        _ name: String,
        contentType: String = "application/octet-stream",
        size: Int,
        browserDownloadURL: String = "https://example.test/download"
    ) -> AppUpdateAssetCandidate {
        AppUpdateAssetCandidate(
            name: name,
            contentType: contentType,
            size: size,
            browserDownloadURL: browserDownloadURL
        )
    }

    private func jsonData(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: text)
    }
}
