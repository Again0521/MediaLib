import AppKit
import Darwin
import Foundation

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

@MainActor
final class LibMpvClient {
    private enum Format {
        static let string: Int32 = 1
        static let flag: Int32 = 3
        static let int64: Int32 = 4
        static let double: Int32 = 5
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
    private typealias GetProperty = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias SetProperty = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeRawPointer?) -> Int32
    private typealias SetOptionString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias RenderContextCreate = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias RenderContextSetUpdateCallback = @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    private typealias RenderContextRender = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    private typealias RenderContextReportSwap = @convention(c) (OpaquePointer?) -> Void
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
    private var onRenderUpdate: (() -> Void)?

    init(
        openGLContext: NSOpenGLContext,
        startTime: Double,
        volume: Float,
        speed: Float,
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
        self.onRenderUpdate = onRenderUpdate

        try setOptionString("config", "no")
        try setOptionString("terminal", "no")
        try setOptionString("osc", "no")
        try setOptionString("force-window", "no")
        try setOptionString("input-default-bindings", "yes")
        try setOptionString("input-vo-keyboard", "no")
        try setOptionString("keep-open", "no")
        try setOptionString("keepaspect", "yes")
        try setOptionString("keepaspect-window", "yes")
        try setOptionString("audio-display", "no")
        try setOptionString("sub-auto", "fuzzy")
        try setOptionString("hwdec", "auto-safe")
        try setOptionString("vo", "libmpv")
        try setOptionString("start", "\(max(startTime, 0))")
        try setOptionString("volume", "\(Int(volume * 100))")
        try setOptionString("speed", "\(speed)")

        try check(initializeFunction(handle))
        try createRenderContext(openGLContext: openGLContext)
    }

    deinit {
        if let renderContext {
            renderContextSetUpdateCallbackFunction(renderContext, nil, nil)
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

    func stopPlayback() {
        onRenderUpdate = nil
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
                setPropertyFunction(handle, namePointer, Format.string, valuePointer)
            }
        }
    }

    func render(width: Int, height: Int) {
        guard let renderContext, width > 0, height > 0 else { return }
        var fbo = MpvOpenGLFBO(fbo: 0, width: Int32(width), height: Int32(height), internalFormat: 0)
        var flipY: Int32 = 1
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
        renderContextSetUpdateCallbackFunction(
            context,
            Self.renderUpdateCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func setOptionString(_ name: String, _ value: String) throws {
        try name.withCString { namePointer in
            try value.withCString { valuePointer in
                try check(setOptionStringFunction(handle, namePointer, valuePointer))
            }
        }
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
        let client = Unmanaged<LibMpvClient>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            client.onRenderUpdate?()
        }
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
            return "未找到 libmpv 播放核心。请重新打包应用，或临时安装 mpv。"
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
