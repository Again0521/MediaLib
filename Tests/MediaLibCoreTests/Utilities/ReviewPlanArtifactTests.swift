import XCTest

final class ReviewPlanArtifactTests: XCTestCase {
    func testRemediationPlanP0ArtifactsExistAndRemainActionable() throws {
        let root = repositoryRoot()
        let requiredDocuments: [String: [String]] = [
            "doc/PerformanceBaselines/fixtures.md": [
                "F-small",
                "F-poster-1k",
                "F-album-5k",
                "F-lossless",
                "F-nas",
                "Cleanup Rules"
            ],
            "doc/PerformanceBaselines/swiftui-body-baseline.md": [
                "海报墙滚动",
                "相册滚动",
                "音乐库切换",
                "沉浸歌词展开",
                "Measurement Template"
            ],
            "doc/PerformanceBaselines/rendering-baseline.md": [
                "播放器展开",
                "连续切歌",
                "外接显示器",
                "WindowServer",
                "Measurement Template"
            ],
            "doc/QA/MediaLib_Regression_Checklist.md": [
                "Smoke",
                "Playback",
                "Library And Data",
                "Packaging",
                "禁止为了通过 QA 而修改或削减视觉效果"
            ]
        ]

        for (relativePath, requiredTerms) in requiredDocuments {
            let url = root.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Missing remediation artifact: \(relativePath)"
            )
            let content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertGreaterThan(content.count, 400, "\(relativePath) should not be an empty placeholder")
            for term in requiredTerms {
                XCTAssertTrue(content.contains(term), "\(relativePath) should mention \(term)")
            }
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
