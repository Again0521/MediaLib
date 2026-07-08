import AppKit
import Darwin
import Foundation
import MediaLibCore

private struct MpvRenderParam {
    var type: Int32
    var data: UnsafeMutableRawPointer?
}

private struct MpvOpenGLInitParams {
    var getProcAddress: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var getProcAddressContext: UnsafeMutableRawPointer?
    var extraExtensions: UnsafePointer<CChar>?
}

private struct MpvOpenGLFBO {
    var fbo: Int32
    var width: Int32
    var height: Int32
    var internalFormat: Int32
}

/// 渲染更新回调的上下文载体（见 `LibMpvClient.renderSink` 注释）。
/// 不持有对 `LibMpvClient` 的引用，故被 C 回调 `passRetained` 不会形成保留环。
/// `onUpdate` 仅在 MainActor 上读写；mpv 线程只负责合并并投递一次 MainActor 回调。
private final class RenderUpdateSink {
    private let lock = NSLock()
    private var updateEnqueued = false
    var onUpdate: (() -> Void)?

    init(onUpdate: (() -> Void)?) {
        self.onUpdate = onUpdate
    }

    func enqueueUpdate() {
        lock.lock()
        if updateEnqueued {
            lock.unlock()
            return
        }
        updateEnqueued = true
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.markUpdateDequeued()
            self.onUpdate?()
        }
    }

    private func markUpdateDequeued() {
        lock.lock()
        updateEnqueued = false
        lock.unlock()
    }
}

@MainActor
final class LibMpvClient {
    private enum Format {
        static let string: Int32 = 1
        static let flag: Int32 = 3
        static let int64: Int32 = 4
        static let double: Int32 = 5
    }

    private enum NetworkMemoryBuffer {
        static let cacheSeconds = 90.0
        static let maxBytes = "256MiB"
        static let maxBackBytes = "96MiB"
        static let fallbackCacheSeconds = 20.0
        static let fallbackMaxBytes = "96MiB"
        static let fallbackMaxBackBytes = "24MiB"
    }

    private enum RenderParam {
        static let invalid: Int32 = 0
        static let apiType: Int32 = 1
        static let openGLInitParams: Int32 = 2
        static let openGLFBO: Int32 = 3
        static let flipY: Int32 = 4
    }

    private typealias Create = @convention(c) () -> OpaquePointer?
    private typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
    private typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    private typealias TerminateDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias Command = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    fileprivate typealias GetProperty = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias SetProperty = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeRawPointer?) -> Int32
    private typealias SetOptionString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    fileprivate typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias RenderContextCreate = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias RenderContextSetUpdateCallback = @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    /// fileprivate（非 private）：`RenderCallHandle.renderFunction`/`reportSwapFunction`
    /// 需要用这两个类型作 `fileprivate` 属性，属性可见性不能超过其类型可见性。
    fileprivate typealias RenderContextRender = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    fileprivate typealias RenderContextReportSwap = @convention(c) (OpaquePointer?) -> Void
    private typealias RenderContextFree = @convention(c) (OpaquePointer?) -> Void

    private let libraryHandle: UnsafeMutableRawPointer
    private let handle: OpaquePointer
    private let initializeFunction: Initialize
    private let destroyFunction: Destroy
    private let terminateDestroyFunction: TerminateDestroy?
    private let commandFunction: Command
    private let getPropertyFunction: GetProperty
    private let setPropertyFunction: SetProperty
    private let setOptionStringFunction: SetOptionString
    private let freeFunction: Free
    private let renderContextCreateFunction: RenderContextCreate
    private let renderContextSetUpdateCallbackFunction: RenderContextSetUpdateCallback
    private let renderContextRenderFunction: RenderContextRender
    private let renderContextReportSwapFunction: RenderContextReportSwap?
    private let renderContextFreeFunction: RenderContextFree
    private var renderContext: OpaquePointer?

    /// 渲染调用的可跨线程句柄：只含裸函数指针与 mpv 渲染上下文指针，不持有 `LibMpvClient`
    /// 本身、不触发其 `@MainActor` 隔离。mpv 文档保证 `mpv_render_context_render` 可以在
    /// 持有对应 GL 上下文 current 的任意线程调用，与其他 client API（get/set_property 等）
    /// 线程安全、互不冲突——真正需要小心的只是「渲染上下文本身的生命周期」：
    /// 调用方必须保证 `LibMpvClient` 释放渲染上下文（`deinit`）之前，通过某种同步点确认所有
    /// 已派发到独立渲染队列的调用均已完成（见 `MpvMetalRenderer.installRenderHandle`，
    /// 传 `nil` 时用 `renderQueue.sync` 排空）。此类型的存在就是为了把 `mpv_render_context_render`
    /// 这个同步阻塞调用从主线程搬走（Metal 路径专用，见 `project_player_popover_scroll_stutter`
    /// 记忆：主线程被 draw() 同步占用 95-98%，是弹窗滚动几乎卡死的第一性根因）。
    struct RenderCallHandle: @unchecked Sendable {
        fileprivate let renderContext: OpaquePointer
        fileprivate let renderFunction: RenderContextRender
        fileprivate let reportSwapFunction: RenderContextReportSwap?

        func render(fbo fboID: Int, width: Int, height: Int, flipY flipYEnabled: Bool) {
            var fbo = MpvOpenGLFBO(fbo: Int32(fboID), width: Int32(width), height: Int32(height), internalFormat: 0)
            var flipY: Int32 = flipYEnabled ? 1 : 0
            withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flipY) { flipPointer in
                    var params = [
                        MpvRenderParam(type: RenderParam.openGLFBO, data: UnsafeMutableRawPointer(fboPointer)),
                        MpvRenderParam(type: RenderParam.flipY, data: UnsafeMutableRawPointer(flipPointer)),
                        MpvRenderParam(type: RenderParam.invalid, data: nil)
                    ]
                    params.withUnsafeMutableBufferPointer { buffer in
                        renderFunction(renderContext, UnsafeMutableRawPointer(buffer.baseAddress))
                    }
                }
            }
            reportSwapFunction?(renderContext)
        }
    }

    /// 供后台状态轮询队列使用；只读 mpv 属性，不持有 `LibMpvClient` 本身。
    /// 控制器必须在释放 `LibMpvClient` 前排空对应队列，保证裸 `handle` 不会越过生命周期。
    struct PropertyReadHandle: @unchecked Sendable {
        fileprivate let handle: OpaquePointer
        fileprivate let getPropertyFunction: GetProperty
        fileprivate let freeFunction: Free

        func getDouble(_ name: String) -> Double? {
            var value = 0.0
            let result = name.withCString { pointer in
                getPropertyFunction(handle, pointer, Format.double, &value)
            }
            return result >= 0 && value.isFinite ? value : nil
        }

        func getFlag(_ name: String) -> Bool? {
            var value: Int32 = 0
            let result = name.withCString { pointer in
                getPropertyFunction(handle, pointer, Format.flag, &value)
            }
            return result >= 0 ? value != 0 : nil
        }

        func getInt64(_ name: String) -> Int64? {
            var value: Int64 = 0
            let result = name.withCString { pointer in
                getPropertyFunction(handle, pointer, Format.int64, &value)
            }
            return result >= 0 ? value : nil
        }

        func getString(_ name: String) -> String? {
            var value: UnsafeMutablePointer<CChar>?
            let result = name.withCString { pointer in
                getPropertyFunction(handle, pointer, Format.string, &value)
            }
            guard result >= 0, let value else { return nil }
            defer { freeFunction(UnsafeMutableRawPointer(value)) }
            return String(cString: value)
        }
    }

    /// 供 Metal 离屏渲染队列使用；OpenGL 屏上路径不需要（仍走 `render(width:height:fbo:flipY:)`）。
    func makeRenderCallHandle() -> RenderCallHandle? {
        guard let renderContext else { return nil }
        return RenderCallHandle(
            renderContext: renderContext,
            renderFunction: renderContextRenderFunction,
            reportSwapFunction: renderContextReportSwapFunction
        )
    }

    func makePropertyReadHandle() -> PropertyReadHandle {
        PropertyReadHandle(
            handle: handle,
            getPropertyFunction: getPropertyFunction,
            freeFunction: freeFunction
        )
    }
    /// 渲染更新回调的上下文载体。mpv 在其内部线程触发回调；为避免「正在回调」与「对象释放」
    /// 交错导致的 use-after-free，回调上下文持有的是这个独立 sink（而非 `self`）：
    /// C 侧对 sink 做 `passRetained` +1，sink 不反向引用 `LibMpvClient`（不构成保留环），
    /// `deinit` 先注销回调、再 `release` 这个 +1，确保任何在途回调期间 sink 始终存活。
    private let renderSink: RenderUpdateSink

    init(
        openGLContext: NSOpenGLContext,
        startTime: Double,
        volume: Float,
        speed: Float,
        hardwareDecodingMode: VideoHardwareDecodingMode,
        networkMemoryBufferingEnabled: Bool,
        onRenderUpdate: @escaping () -> Void
    ) throws {
        libraryHandle = try Self.openLibrary()
        let create: Create = try Self.symbol("mpv_create", in: libraryHandle)
        initializeFunction = try Self.symbol("mpv_initialize", in: libraryHandle)
        destroyFunction = try Self.symbol("mpv_destroy", in: libraryHandle)
        terminateDestroyFunction = Self.optionalSymbol("mpv_terminate_destroy", in: libraryHandle)
        commandFunction = try Self.symbol("mpv_command", in: libraryHandle)
        getPropertyFunction = try Self.symbol("mpv_get_property", in: libraryHandle)
        setPropertyFunction = try Self.symbol("mpv_set_property", in: libraryHandle)
        setOptionStringFunction = try Self.symbol("mpv_set_option_string", in: libraryHandle)
        freeFunction = try Self.symbol("mpv_free", in: libraryHandle)
        renderContextCreateFunction = try Self.symbol("mpv_render_context_create", in: libraryHandle)
        renderContextSetUpdateCallbackFunction = try Self.symbol("mpv_render_context_set_update_callback", in: libraryHandle)
        renderContextRenderFunction = try Self.symbol("mpv_render_context_render", in: libraryHandle)
        renderContextReportSwapFunction = Self.optionalSymbol("mpv_render_context_report_swap", in: libraryHandle)
        renderContextFreeFunction = try Self.symbol("mpv_render_context_free", in: libraryHandle)

        guard let created = create() else {
            throw LibMpvError.createFailed
        }
        handle = created
        self.renderSink = RenderUpdateSink(onUpdate: onRenderUpdate)

        try setOptionString("config", "no")
        try setOptionString("terminal", "no")
        try setOptionString("osc", "no")
        try setOptionString("force-window", "no")
        try setOptionString("input-default-bindings", "yes")
        try setOptionString("input-vo-keyboard", "no")
        // EOF 后暂停在最后一帧而不是卸载文件：播放结束行为（下一集/停留/关窗）
        // 由控制器读取 eof-reached 后决定，卸载会让 time-pos 丢失、无法标记已看。
        try setOptionString("keep-open", "yes")
        try setOptionString("keepaspect", "yes")
        try setOptionString("keepaspect-window", "yes")
        try setOptionString("audio-display", "no")
        try setOptionString("sub-auto", "fuzzy")
        let hardwareDecodingProperty = VideoPlaybackPropertyPolicy.hardwareDecodingProperty(for: hardwareDecodingMode)
        try setOptionString(hardwareDecodingProperty.name, hardwareDecodingProperty.value)
        try setOptionString("vo", "libmpv")
        if networkMemoryBufferingEnabled {
            applyNetworkMemoryBufferingOptions()
        }
        try setOptionString("start", "\(max(startTime, 0))")
        // 音量增强上限 200%：实际是否超过 100% 由控制器的 volumeBoost 决定。
        try? setOptionString("volume-max", "200")
        try setOptionString("volume", "\(Int(volume * 100))")
        try setOptionString("speed", "\(speed)")

        try check(initializeFunction(handle))
        try createRenderContext(openGLContext: openGLContext)
    }

    deinit {
        if let renderContext {
            // 先注销回调（注销返回后 mpv 不再发起新回调），再释放 sink 的 +1：
            // 任何已在途的回调期间 sink 仍被 +1 持有，故不会 use-after-free。
            renderContextSetUpdateCallbackFunction(renderContext, nil, nil)
            Unmanaged.passUnretained(renderSink).release()
            renderContextFreeFunction(renderContext)
        }
        if let terminateDestroyFunction {
            terminateDestroyFunction(handle)
        } else {
            destroyFunction(handle)
        }
        dlclose(libraryHandle)
    }

    func loadFile(_ path: String) throws {
        try command(["loadfile", path])
    }

    func setNetworkMemoryBufferingEnabled(_ enabled: Bool) {
        if enabled {
            setString("cache", "yes")
            setDouble("cache-secs", NetworkMemoryBuffer.cacheSeconds)
            setDouble("demuxer-readahead-secs", NetworkMemoryBuffer.cacheSeconds)
            setString("demuxer-max-bytes", NetworkMemoryBuffer.maxBytes)
            setString("demuxer-max-back-bytes", NetworkMemoryBuffer.maxBackBytes)
            setString("cache-pause", "yes")
        } else {
            setString("cache", "auto")
            setDouble("cache-secs", NetworkMemoryBuffer.fallbackCacheSeconds)
            setDouble("demuxer-readahead-secs", NetworkMemoryBuffer.fallbackCacheSeconds)
            setString("demuxer-max-bytes", NetworkMemoryBuffer.fallbackMaxBytes)
            setString("demuxer-max-back-bytes", NetworkMemoryBuffer.fallbackMaxBackBytes)
            setString("cache-pause", "no")
        }
    }

    func stopPlayback() {
        renderSink.onUpdate = nil
        try? command(["set", "volume", "0"])
        try? command(["set", "pause", "yes"])
        try? command(["stop"])
    }

    func command(_ arguments: [String]) throws {
        let cStrings = arguments.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings.map { UnsafePointer<CChar>($0) }
        pointers.append(nil)
        try pointers.withUnsafeMutableBufferPointer { buffer in
            try check(commandFunction(handle, buffer.baseAddress))
        }
    }

    func getDouble(_ name: String) -> Double? {
        var value = 0.0
        let result = name.withCString { pointer in
            getPropertyFunction(handle, pointer, Format.double, &value)
        }
        return result >= 0 && value.isFinite ? value : nil
    }

    func getFlag(_ name: String) -> Bool? {
        var value: Int32 = 0
        let result = name.withCString { pointer in
            getPropertyFunction(handle, pointer, Format.flag, &value)
        }
        return result >= 0 ? value != 0 : nil
    }

    func getInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        let result = name.withCString { pointer in
            getPropertyFunction(handle, pointer, Format.int64, &value)
        }
        return result >= 0 ? value : nil
    }

    func getString(_ name: String) -> String? {
        var value: UnsafeMutablePointer<CChar>?
        let result = name.withCString { pointer in
            getPropertyFunction(handle, pointer, Format.string, &value)
        }
        guard result >= 0, let value else { return nil }
        defer { freeFunction(UnsafeMutableRawPointer(value)) }
        return String(cString: value)
    }

    func setFlag(_ name: String, _ value: Bool) {
        var flag: Int32 = value ? 1 : 0
        _ = name.withCString { pointer in
            setPropertyFunction(handle, pointer, Format.flag, &flag)
        }
    }

    func setDouble(_ name: String, _ value: Double) {
        var double = value
        _ = name.withCString { pointer in
            setPropertyFunction(handle, pointer, Format.double, &double)
        }
    }

    func setString(_ name: String, _ value: String) {
        _ = name.withCString { namePointer in
            value.withCString { valuePointer in
                var propertyValue: UnsafePointer<CChar>? = valuePointer
                return withUnsafePointer(to: &propertyValue) { propertyPointer in
                    setPropertyFunction(handle, namePointer, Format.string, UnsafeRawPointer(propertyPointer))
                }
            }
        }
    }

    func render(width: Int, height: Int, fbo fboID: Int = 0, flipY flipYEnabled: Bool = true) {
        guard let renderContext, width > 0, height > 0 else { return }
        var fbo = MpvOpenGLFBO(fbo: Int32(fboID), width: Int32(width), height: Int32(height), internalFormat: 0)
        var flipY: Int32 = flipYEnabled ? 1 : 0
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var params = [
                    MpvRenderParam(type: RenderParam.openGLFBO, data: UnsafeMutableRawPointer(fboPointer)),
                    MpvRenderParam(type: RenderParam.flipY, data: UnsafeMutableRawPointer(flipPointer)),
                    MpvRenderParam(type: RenderParam.invalid, data: nil)
                ]
                params.withUnsafeMutableBufferPointer { buffer in
                    renderContextRenderFunction(renderContext, UnsafeMutableRawPointer(buffer.baseAddress))
                }
            }
        }
        renderContextReportSwapFunction?(renderContext)
    }

    private func createRenderContext(openGLContext: NSOpenGLContext) throws {
        openGLContext.makeCurrentContext()
        var context: OpaquePointer?
        var initParams = MpvOpenGLInitParams(
            getProcAddress: Self.getOpenGLProcAddress,
            getProcAddressContext: nil,
            extraExtensions: nil
        )
        try "opengl".withCString { apiPointer in
            try withUnsafeMutablePointer(to: &initParams) { initPointer in
                var params = [
                    MpvRenderParam(type: RenderParam.apiType, data: UnsafeMutableRawPointer(mutating: apiPointer)),
                    MpvRenderParam(type: RenderParam.openGLInitParams, data: UnsafeMutableRawPointer(initPointer)),
                    MpvRenderParam(type: RenderParam.invalid, data: nil)
                ]
                try params.withUnsafeMutableBufferPointer { buffer in
                    try check(renderContextCreateFunction(&context, handle, UnsafeMutableRawPointer(buffer.baseAddress)))
                }
            }
        }
        guard let context else {
            throw LibMpvError.renderContextFailed
        }
        renderContext = context
        // 传 sink 的 passRetained(+1)；该 +1 在 deinit 注销回调后释放（见 deinit）。
        renderContextSetUpdateCallbackFunction(
            context,
            Self.renderUpdateCallback,
            Unmanaged.passRetained(renderSink).toOpaque()
        )
    }

    private func setOptionString(_ name: String, _ value: String) throws {
        try name.withCString { namePointer in
            try value.withCString { valuePointer in
                try check(setOptionStringFunction(handle, namePointer, valuePointer))
            }
        }
    }

    private func applyNetworkMemoryBufferingOptions() {
        // libmpv 不同构建可用选项略有差异；缓存是弱网增强项，失败时保持默认播放路径。
        try? setOptionString("cache", "yes")
        try? setOptionString("cache-secs", "\(Int(NetworkMemoryBuffer.cacheSeconds))")
        try? setOptionString("demuxer-readahead-secs", "\(Int(NetworkMemoryBuffer.cacheSeconds))")
        try? setOptionString("demuxer-max-bytes", NetworkMemoryBuffer.maxBytes)
        try? setOptionString("demuxer-max-back-bytes", NetworkMemoryBuffer.maxBackBytes)
        try? setOptionString("cache-pause", "yes")
    }

    private func check(_ code: Int32) throws {
        guard code >= 0 else {
            throw LibMpvError.apiFailed(Int(code))
        }
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw LibMpvError.missingSymbol(name)
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func optionalSymbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let renderUpdateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
        guard let context else { return }
        // 在 mpv 线程仅做指针 +0 取值（sink 由 C 侧 +1 持有，存活有保证），
        // 再由 sink 合并重复信号并 hop 到 MainActor。
        let sink = Unmanaged<RenderUpdateSink>.fromOpaque(context).takeUnretainedValue()
        sink.enqueueUpdate()
    }

    private static let getOpenGLProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
        guard let name else { return nil }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
            return symbol
        }
        guard let handle = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY) else {
            return nil
        }
        return dlsym(handle, name)
    }

    private static func openLibrary() throws -> UnsafeMutableRawPointer {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Frameworks")
                .appendingPathComponent("libmpv.2.dylib"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Frameworks")
                .appendingPathComponent("libmpv.dylib"),
            URL(fileURLWithPath: "/opt/homebrew/lib/libmpv.2.dylib"),
            URL(fileURLWithPath: "/opt/homebrew/lib/libmpv.dylib"),
            URL(fileURLWithPath: "/usr/local/lib/libmpv.2.dylib"),
            URL(fileURLWithPath: "/usr/local/lib/libmpv.dylib")
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let handle = dlopen(candidate.path, RTLD_NOW | RTLD_LOCAL) {
                return handle
            }
        }
        throw LibMpvError.libraryMissing
    }
}

private enum LibMpvError: LocalizedError {
    case libraryMissing
    case missingSymbol(String)
    case createFailed
    case renderContextFailed
    case apiFailed(Int)

    var errorDescription: String? {
        switch self {
        case .libraryMissing:
            return "未找到视频播放核心。请重新安装 MediaLIB，或联系维护者获取完整安装包。"
        case .missingSymbol(let name):
            return "libmpv 缺少符号：\(name)"
        case .createFailed:
            return "libmpv 播放核心创建失败。"
        case .renderContextFailed:
            return "libmpv 渲染上下文创建失败。"
        case .apiFailed(let code):
            return "libmpv 调用失败：\(code)"
        }
    }
}
