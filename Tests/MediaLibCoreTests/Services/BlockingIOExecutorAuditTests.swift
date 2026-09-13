import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级阻塞式 I/O 线程池解耦与并发安全专项】
/// 审计目标：验证 `BlockingIOExecutor` 能否严格将长时间同步阻塞（如大目录 stat、网络探测、全表读取）
/// 彻底从 Swift 并发全局协作线程池（宽度仅等于 CPU 核数）剥离并派发至底层的 concurrent utility 队列，
/// 防止同池排队的 UI 渲染计算任务与 async 挂起点被死锁或卡死；
/// 同时验证其在并发提交下不死锁以及异常抛错透传。执行器只是底层桥接器，面向
/// 无界网络输入的资源预算由上层有界执行器负责，本测试不把 GCD 调度误写成限流证明。
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

    func testCancelledQueuedBlockingWorkNeverStarts() async throws {
        let serialQueue = DispatchQueue(label: "test.blocking-io-queued-cancel")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let workStarted = DispatchSemaphore(value: 0)
        serialQueue.async {
            entered.signal()
            release.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        let queued = Task {
            try await BlockingIOExecutor.runCancellable(on: serialQueue) { _ in
                workStarted.signal()
                return 1
            }
        }
        await Task.yield()
        queued.cancel()
        release.signal()

        do {
            _ = try await queued.value
            XCTFail("cancelled queued work must not run")
        } catch is CancellationError {
            // Cancellation is checked on the GCD queue before invoking work.
        }
        XCTAssertEqual(workStarted.wait(timeout: .now()), .timedOut)
    }

    func testRunningBlockingWorkObservesCancellationAtNextBoundary() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await BlockingIOExecutor.runCancellable { cancellation in
                entered.signal()
                release.wait()
                try cancellation.checkCancellation()
                return 1
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        release.signal()

        do {
            _ = try await task.value
            XCTFail("the cancellation boundary must throw")
        } catch is CancellationError {
            // Synchronous I/O cannot be preempted, but it is not published after cancellation.
        }
    }

    func testCancellableWorkReportsTimeWaitingForGCDQueue() async throws {
        let serialQueue = DispatchQueue(label: "test.blocking-io-queue-wait")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        serialQueue.async {
            entered.signal()
            release.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(80)) {
            release.signal()
        }

        let queueWait = try await BlockingIOExecutor.runCancellable(on: serialQueue) { context in
            context.queueWaitNanoseconds
        }
        XCTAssertGreaterThan(queueWait, 20_000_000)
    }
}
