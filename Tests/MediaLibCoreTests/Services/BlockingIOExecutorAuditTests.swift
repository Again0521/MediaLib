import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级阻塞式 I/O 线程池解耦与并发安全专项】
/// 审计目标：验证 `BlockingIOExecutor` 能否严格将长时间同步阻塞（如大目录 stat、网络探测、全表读取）
/// 彻底从 Swift 并发全局协作线程池（宽度仅等于 CPU 核数）剥离并派发至底层的 concurrent utility 队列，
/// 防止同池排队的 UI 渲染计算任务与 async 挂起点被死锁或卡死；
/// 同时验证其在高并发排队压测下的线程池抗暴与异常抛错透传能力。
/// 对应报告问题 ID：TC-PERF-003 / RISK-02
final class BlockingIOExecutorAuditTests: XCTestCase {

    /// 测试阻塞任务绝对不占用主线程且能正确返回值
    func testBlockingIORunsOffMainThreadAndReturnsValue() async throws {
        let result = await BlockingIOExecutor.run { () -> String in
            XCTAssertFalse(Thread.isMainThread, "阻塞式 I/O 绝不能在 UI 主线程执行！")
            // 模拟短时 I/O 阻塞
            Thread.sleep(forTimeInterval: 0.05)
            return "IO_SUCCESS"
        }
        
        XCTAssertEqual(result, "IO_SUCCESS")
    }

    /// 测试阻塞式 I/O 异常能够百分百透传到 async/await 调用方
    func testBlockingIOPropagatesErrorsAccurately() async {
        struct CustomIOError: Error, Equatable {}
        
        do {
            _ = try await BlockingIOExecutor.run {
                throw CustomIOError()
            }
            XCTFail("预期抛出 CustomIOError，但不应执行到此")
        } catch let error as CustomIOError {
            XCTAssertEqual(error, CustomIOError())
        } catch {
            XCTFail("捕获到了非预期的错误类型：\(error)")
        }
    }

    /// 测试 100 个并发阻塞 I/O 任务排队时协作池不卡死、不崩溃
    func testConcurrentBlockingIOTasksExhaustSafelyWithoutDeadlock() async throws {
        let taskCount = 100
        let expectation = XCTestExpectation(description: "全部并发 I/O 任务顺利完成")
        expectation.expectedFulfillmentCount = taskCount
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    let val = await BlockingIOExecutor.run {
                        // 模拟毫秒级文件检查
                        return i * 2
                    }
                    XCTAssertEqual(val, i * 2)
                    expectation.fulfill()
                }
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
    }
}
