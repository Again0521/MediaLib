import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级视频色彩与字幕渲染参数钳制专项】
/// 审计目标：验证 `VideoColorAdjustments` 与 `VideoSubtitleStyle` 在接收用户手动调节
/// 画面色彩（亮度/对比度/饱和度/伽马/色相）与字幕描边/底色不透明度时，
/// 能否将非法数值（如 `Double.nan`, `Double.infinity`）、极值负数或溢出值
/// 精准钳制（Clamp）并规并为 libmpv/OpenGL 所兼容的整数范围，防止视频驱动崩溃或黑屏。
/// 对应报告问题 ID：TC-SCAN-012 / RISK-05
final class VideoColorAndSubtitleStyleAuditTests: XCTestCase {

    /// 测试色彩调整对极限越界值与 NaN/Infinity 的安全钳制
    func testVideoColorAdjustmentsClampsExtremeAndNaNValues() {
        let extreme = VideoColorAdjustments(
            brightness: 500.8,
            contrast: -250.2,
            saturation: Double.nan,
            gamma: Double.infinity,
            hue: -100.001
        )
        
        XCTAssertEqual(extreme.brightness, 100.0, "超过 +100 的亮度的值必须被钳制于上限 100")
        XCTAssertEqual(extreme.contrast, -100.0, "低于 -100 的对比度必须被钳制于下限 -100")
        XCTAssertEqual(extreme.saturation, 0.0, "NaN 必须安全归零，不可透传给 OpenGL/MPV 渲染器！")
        XCTAssertEqual(extreme.gamma, 0.0, "Infinity 必须被捕获并降级为 0")
        XCTAssertEqual(extreme.hue, -100.0)
    }

    /// 测试字幕样式描边粗细与背景透明度的边界校验
    func testSubtitleStyleClampsBorderAndBackgroundOpacity() {
        let style = VideoSubtitleStyle(
            borderSize: 99.5,
            backgroundOpacity: -0.5
        )
        
        XCTAssertEqual(style.borderSize, 6.0, "字幕描边粗细上限为 6")
        XCTAssertEqual(style.backgroundOpacity, 0.0, "背景不透明度不能为负数")
        
        let styleMaxBg = VideoSubtitleStyle(backgroundOpacity: 2.5)
        XCTAssertEqual(styleMaxBg.backgroundOpacity, 0.8, "背景不透明度上限限制在 0.8")
    }
}
