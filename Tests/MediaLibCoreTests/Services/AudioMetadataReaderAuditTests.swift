import XCTest
import AVFoundation
@testable import MediaLibCore

/// 【白盒审计测试 - P2级音频元数据解析与容错专项】
/// 审计目标：验证 `AudioMetadataReader` 在处理不存在的文件路径、
/// 非法格式音频或高频并发请求时，能够安全兜底并返回干净的默认元数据，绝不阻塞线程或触发异常。
/// 对应报告问题 ID：TC-SCAN-003 / RISK-07
final class AudioMetadataReaderAuditTests: XCTestCase {

    /// 测试针对不存在的物理路径读取时，解析器安全返回空结构体而非抛错
    func testMetadataReaderSurvivesNonExistentURL() async {
        let reader = AudioMetadataReader()
        let fakeURL = URL(fileURLWithPath: "/non_existent_folder/ghost_track.mp3")
        
        let meta = await reader.metadata(for: fakeURL)
        
        XCTAssertNil(meta.title)
        XCTAssertNil(meta.artist)
        XCTAssertNil(meta.duration)
        XCTAssertFalse(meta.hasEmbeddedMetadata, "不存在的文件不应被判定为带有嵌入元数据")
    }

    /// 测试高频并发请求下读取实例的线程安全性
    func testConcurrentMetadataReaderCallsDoNotCrash() async {
        let reader = AudioMetadataReader()
        let urls = (0..<20).map { URL(fileURLWithPath: "/tmp/fake_audio_\($0).flac") }
        
        await withTaskGroup(of: AudioMetadata.self) { group in
            for url in urls {
                group.addTask {
                    await reader.metadata(for: url)
                }
            }
            
            var count = 0
            for await _ in group {
                count += 1
            }
            XCTAssertEqual(count, 20, "高频并发对多个路径进行元数据提取时，必须全部安全响应完成")
        }
    }
}
