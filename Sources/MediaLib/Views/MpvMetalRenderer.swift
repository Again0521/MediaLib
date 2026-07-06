import AppKit
import IOSurface
import Metal
import MetalKit
import OpenGL
import OpenGL.GL3
import QuartzCore
import SwiftUI

/// 视频渲染后端开关（分阶段迁移，见计划 `metal-jolly-globe.md`）。
///
/// 现状：libmpv 的公开渲染 API 只有 OpenGL 与软件两种后端，没有原生 Metal 后端。
/// 本文件实现「零拷贝 GL→Metal IOSurface 互操作」：mpv 仍用 OpenGL 渲染进离屏
/// IOSurface-backed FBO，Metal 把同一张 IOSurface 包成纹理后经 `CAMetalLayer` 呈现。
///
/// 默认走 Metal 路径，避免旧屏上 `NSOpenGLView` 在播放期把 mpv render 同步压到主线程；
/// 如需回归对照，可加 `--video-opengl` 强制走旧路径，`--video-metal` 继续作为显式启用别名。
enum VideoRenderBackend {
    static let useMetal: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--video-opengl") {
            return false
        }
        if arguments.contains("--video-metal") {
            return MpvMetalRenderer.isBackendAvailable()
        }
        return MpvMetalRenderer.isBackendAvailable()
    }()
}

/// 控制器（`MpvPlayerController`）与承载视图之间的抽象：
/// 让 `renderView` 既可以是屏上 `MpvOpenGLView`，也可以是 Metal 路径的 `MpvMetalView`。
/// class-bound 以便 `weak` 持有。
protocol MpvRenderSurface: AnyObject {
    /// 交给 `LibMpvClient` 创建 mpv 渲染上下文用的 GL 上下文。
    /// OpenGL 路径 = 视图自身的 `openGLContext`；Metal 路径 = 渲染器持有的无屏上下文。
    var mpvGLContext: NSOpenGLContext? { get }
    /// 承载视图是否已加入窗口层级（`startMpv` 就绪判断）。
    var isSurfaceInWindow: Bool { get }
    /// 请求重绘一帧（mpv render-update 回调 / 首帧巡检触发）。
    func requestRedraw()
    /// 把当前已渲染的一帧读成 PNG（含字幕），screenshot 命令不可用时兜底。
    func captureFramePNGData() -> Data?
    /// 装载/卸载渲染句柄。仅 Metal 路径使用：真正的 `mpv_render_context_render` 调用被
    /// 挪到独立渲染队列（见 `MpvMetalRenderer`），装载时把句柄交给队列；卸载（传 `nil`）
    /// 时同步排空队列，调用方必须在释放对应 `LibMpvClient`（进而释放渲染上下文）之前调用，
    /// 避免队列里还在跑的渲染调用访问已释放的上下文。OpenGL 路径空实现（仍走同步屏上渲染）。
    func installRenderHandle(_ handle: LibMpvClient.RenderCallHandle?)
}

// MARK: - Metal 承载视图

/// Metal 路径的视频承载视图。自身是 `MTKView`，按需重绘（`enableSetNeedsDisplay`），
/// 每次 `draw(in:)` 让 mpv 渲染进离屏 IOSurface，再由 Metal blit 到 drawable。
final class MpvMetalView: MTKView, MpvRenderSurface {
    weak var controller: MpvPlayerController?
    private var mpvRenderer: MpvMetalRenderer?

    init(controller: MpvPlayerController) {
        self.controller = controller
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        (layer as? CAMetalLayer)?.maximumDrawableCount = 3
        layer?.backgroundColor = NSColor.black.cgColor
        if let device {
            mpvRenderer = MpvMetalRenderer(device: device, pixelFormat: colorPixelFormat)
        }
        delegate = renderDelegate
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: MpvRenderSurface

    var mpvGLContext: NSOpenGLContext? { mpvRenderer?.glContext }
    var isSurfaceInWindow: Bool { window != nil && mpvRenderer != nil }
    func captureFramePNGData() -> Data? { mpvRenderer?.captureFramePNGData() }
    func installRenderHandle(_ handle: LibMpvClient.RenderCallHandle?) {
        mpvRenderer?.installRenderHandle(handle)
    }

    /// 主线程独占：是否已有一次渲染在路上（渲染队列正在跑，或结果还没被 blit）。
    /// mpv render-update 回调触发频率可能明显高于源视频真实帧率（实测约 2-3 倍，
    /// 猜测与显示刷新/drawable 节奏耦合有关，未定位到确切源头）；不加合并的话，
    /// 每次信号都会派发一次「渲染队列 -> 主线程 setNeedsDisplay -> drawable 等待」的完整
    /// 往返，往返本身的 drawable 获取仍然会占用主线程时间。合并成"同一时刻只有一次在途请求"；
    /// 若忙时又收到新信号，记录为尾随刷新，当前帧完成后再补排一次，避免节奏性漏帧。
    private var isRenderPending = false
    /// 渲染队列忙时又收到新的 mpv update，不能只丢弃：忙完后补排一次，
    /// 否则在高码率/高分辨率下容易形成“每忙一次就漏一帧”的节奏性卡顿。
    private var needsRenderAfterPending = false

    /// mpv render-update 回调（每有一帧新画面就触发一次）。真正的 `mpv_render_context_render`
    /// 调用被派发到 `mpvRenderer` 的独立渲染队列（不阻塞主线程）；渲染完成后队列在主线程
    /// 回调里把结果面交给渲染器再 `needsDisplay = true`，触发一次仅做 Metal blit 的 `draw(in:)`。
    func requestRedraw() {
        guard let mpvRenderer else { return }
        guard !isRenderPending else {
            needsRenderAfterPending = true
            return
        }
        let size = drawableSize
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return }
        isRenderPending = true
        needsRenderAfterPending = false
        mpvRenderer.scheduleOffscreenRender(width: width, height: height) { [weak self] in
            guard let self else { return }
            self.isRenderPending = false
            self.needsDisplay = true
            if self.needsRenderAfterPending {
                self.requestRedraw()
            }
        }
    }

    // MARK: 渲染

    private lazy var renderDelegate = RenderDelegate(view: self)

    /// 主线程侧唯一的每帧工作：把渲染队列已经产出的最新一张 IOSurface blit 到 drawable。
    /// 不再在这里调用 mpv——那是主线程曾经 95%+ 时间被同步占用的根因（弹窗滚动卡死）。
    /// 实测（临时插桩后已移除，见 `project_player_popover_scroll_stutter_2026_07_05` 记忆）：
    /// 改造前主线程 95-98% 时间被同步 `mpv_render_context_render`+`flushBuffer` 占用；
    /// 改造后（渲染搬到独立队列 + `isRenderPending` 合并冗余重绘请求）降到约 5%。
    fileprivate func performDraw() {
        mpvRenderer?.blit(drawable: currentDrawable, passDescriptor: currentRenderPassDescriptor)
    }

    /// `MTKViewDelegate` 拆出成独立对象，避免 `MTKView` 强引用自身 delegate 造成的告警。
    private final class RenderDelegate: NSObject, MTKViewDelegate {
        weak var view: MpvMetalView?
        init(view: MpvMetalView) { self.view = view }
        /// 尺寸变化时即使没有新解码帧也要重绘（用 mpv 缓存的最后一帧按新尺寸重渲染），
        /// 与旧 `MpvOpenGLView.reshape()` 的行为对齐。
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            (view as? MpvMetalView)?.requestRedraw()
        }
        func draw(in view: MTKView) { (view as? MpvMetalView)?.performDraw() }
    }
}

/// SwiftUI 包装（Metal 路径）。与旧 `MpvPlayerView` 并存，由 body 按 `VideoRenderBackend` 选路。
struct MpvMetalPlayerView: NSViewRepresentable {
    let controller: MpvPlayerController

    func makeNSView(context: Context) -> MpvMetalView {
        let view = MpvMetalView(controller: controller)
        DispatchQueue.main.async {
            controller.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: MpvMetalView, context: Context) {
        nsView.controller = controller
        DispatchQueue.main.async {
            controller.attach(to: nsView)
        }
    }
}

// MARK: - GL→Metal 互操作渲染器

/// 持有无屏 GL 上下文、IOSurface 环形池（GL 纹理 + 离屏 FBO + Metal 纹理）与 Metal blit 管线。
///
/// ★线程模型（2026-07-05 架构改动，根治弹窗滚动卡死）：
/// - `renderQueue`（独立串行队列）：真正的 `mpv_render_context_render` 调用 + `ensureSurfaces`
///   等一切 GL 工作。这是曾经同步阻塞主线程 95-98% 时间的那部分（见
///   `project_player_popover_scroll_stutter_2026_07_05` 记忆的插桩实测），现在完全搬离主线程。
/// - 主线程：只做 `scheduleOffscreenRender` 的发起（读 drawableSize，零 GL 工作）+ `blit`
///   （采样渲染队列已经产出的 Metal 纹理画一个全屏三角形，一次 draw call，代价可忽略）。
/// - `surfaces`/`writeIndex`/`pixelSize`/`renderHandle` 只在 `renderQueue` 上读写；
///   `latestReadySurface`/`lastPresentedSurface` 只在主线程读写（通过 completion 闭包传递
///   而非共享锁——两组状态各自单线程独占，之间只靠值传递交接，不需要额外加锁）。
final class MpvMetalRenderer {
    let glContext: NSOpenGLContext
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let renderQueue = DispatchQueue(label: "com.local.MediaLib.mpv-metal-render")

    /// 环形池深度：Metal 采样第 N-1 张时 GL 写第 N 张，规避 GL 写 / Metal 读撕裂。
    private static let surfaceCount = 3
    /// 以下四个字段仅在 `renderQueue` 上访问。
    private var surfaces: [InteropSurface] = []
    private var writeIndex = 0
    private var pixelSize = CGSize.zero
    private var renderHandle: LibMpvClient.RenderCallHandle?
    /// 以下两个字段仅在主线程访问（渲染队列通过 completion 闭包把结果值传过来，不直接碰它们）。
    private var latestReadySurface: InteropSurface?
    private var lastPresentedSurface: InteropSurface?

    /// mpv flipY：GL 原点左下，采样到 Metal（原点左上）需竖直翻转。
    /// 若真机上下颠倒，把此常量取反即可（见计划验证项）。
    private static let flipVerticalInBlit: Float = 1

    /// 传给 `mpv_render_context_render` 的 flipY 参数（仅本渲染器的离屏 FBO 路径可调，
    /// 不影响旧 `MpvOpenGLView` 屏上 FBO=0 路径的既有正确行为）。
    /// 实测：真机字幕在离屏矩形纹理 FBO 上出现颠倒而视频画面本身方向正确
    /// （两者应共享同一份 flipY 语义，出现不一致大概率是 mpv 内部 OSD/字幕合成通路
    /// 对非 GL_TEXTURE_2D 目标处理有别）；此处置 0 让 mpv 不做内部翻转，
    /// 依赖 blit shader 的 `flipVerticalInBlit` 统一承担唯一一次翻转。
    private static let mpvFlipY = false

    static func isBackendAvailable() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return makeHeadlessGLContext() != nil &&
            makeBlitPipeline(device: device, pixelFormat: .bgra8Unorm) != nil
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let context = Self.makeHeadlessGLContext(),
              let queue = device.makeCommandQueue(),
              let pipeline = Self.makeBlitPipeline(device: device, pixelFormat: pixelFormat) else {
            return nil
        }
        self.glContext = context
        self.commandQueue = queue
        self.pipelineState = pipeline
    }

    deinit {
        // 先同步排空渲染队列，确保没有在途/排队中的渲染调用还在用即将被销毁的 GL 对象；
        // 排空后再在（调用 deinit 的）当前线程上安全地做 GL 清理。
        renderQueue.sync {}
        glContext.makeCurrentContext()
        for surface in surfaces {
            surface.destroyGLObjects()
        }
        NSOpenGLContext.clearCurrentContext()
    }

    /// 装载/卸载渲染句柄。传 `nil` 会同步排空渲染队列再清空——调用方（`MpvPlayerController`）
    /// 必须在释放对应 `LibMpvClient`（进而释放渲染上下文）之前调用，避免队列里还在跑的
    /// 渲染调用访问已释放的上下文。`renderQueue.sync` 是这里唯一需要的同步原语：串行队列
    /// 保证这个块只会在它之前所有已派发的渲染块跑完之后才执行。
    func installRenderHandle(_ handle: LibMpvClient.RenderCallHandle?) {
        renderQueue.sync {
            self.renderHandle = handle
        }
    }

    /// 请求渲染一帧：真正的 mpv 调用被派发到 `renderQueue`（不阻塞调用者所在的主线程）。
    /// 完成后跳回主线程，把产出的 surface 记为“最新可显示”并回调（通常用来 `needsDisplay = true`）。
    func scheduleOffscreenRender(width: Int, height: Int, completion: @escaping () -> Void) {
        renderQueue.async { [weak self] in
            // ★所有提前退出路径都必须仍然调用 completion（跳到主线程）：调用方
            // （`MpvMetalView.requestRedraw`）用 completion 来复位 `isRenderPending` 门闩，
            // 一旦这里 return 却不调用 completion，门闩永久卡在 true、往后所有
            // requestRedraw 都会被自己挡掉——真实出现过的 bug：渲染句柄还没装载好时
            // （`installRenderHandle` 在 `startMpv()` 里比 mpv 首次 render-update 回调晚一点点
            // 才执行）第一次调度必然落进这个分支，若不补 completion 就会直接黑屏到底。
            guard let self, let handle = self.renderHandle else {
                DispatchQueue.main.async { completion() }
                return
            }
            self.ensureSurfaces(width: width, height: height)
            guard !self.surfaces.isEmpty else {
                DispatchQueue.main.async { completion() }
                return
            }
            let index = self.writeIndex
            let surface = self.surfaces[index]

            self.glContext.makeCurrentContext()
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), surface.framebuffer)
            glViewport(0, 0, GLsizei(width), GLsizei(height))
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            handle.render(fbo: Int(surface.framebuffer), width: width, height: height, flipY: Self.mpvFlipY)
            glFlush()
            self.writeIndex = (self.writeIndex + 1) % self.surfaces.count

            DispatchQueue.main.async { [weak self] in
                self?.latestReadySurface = surface
                completion()
            }
        }
    }

    /// 主线程侧唯一的每帧 GPU 工作：把渲染队列已产出的最新纹理 blit 到 drawable。
    /// 不含任何 mpv/GL 调用，只有一次 Metal 全屏三角形绘制，main-thread 代价可忽略。
    func blit(drawable: CAMetalDrawable?, passDescriptor: MTLRenderPassDescriptor?) {
        guard let surface = latestReadySurface,
              let drawable,
              let passDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        var flip = Self.flipVerticalInBlit
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&flip, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(surface.metalTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastPresentedSurface = surface
    }

    /// 读最近呈现的一帧（IOSurface 直接 CPU 映射，含字幕）→ PNG。
    func captureFramePNGData() -> Data? {
        guard let surface = lastPresentedSurface else { return nil }
        let io = surface.ioSurface
        let width = IOSurfaceGetWidth(io)
        let height = IOSurfaceGetHeight(io)
        guard width > 0, height > 0 else { return nil }
        IOSurfaceLock(io, .readOnly, nil)
        defer { IOSurfaceUnlock(io, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(io)
        let stride = IOSurfaceGetBytesPerRow(io)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let dest = rep.bitmapData else { return nil }
        // IOSurface 是 BGRA；转成 RGBA 写入 rep，并按需竖直翻转以匹配呈现朝向。
        let src = base.assumingMemoryBound(to: UInt8.self)
        let flip = Self.flipVerticalInBlit > 0.5
        for row in 0..<height {
            let srcRow = src + row * stride
            let destRow = dest + (flip ? (height - 1 - row) : row) * width * 4
            for col in 0..<width {
                let s = srcRow + col * 4
                let d = destRow + col * 4
                d[0] = s[2] // R <- B
                d[1] = s[1] // G
                d[2] = s[0] // B <- R
                d[3] = s[3] // A
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: 环形池管理

    private func ensureSurfaces(width: Int, height: Int) {
        let newSize = CGSize(width: width, height: height)
        if newSize == pixelSize, surfaces.count == Self.surfaceCount {
            return
        }
        glContext.makeCurrentContext()
        for surface in surfaces {
            surface.destroyGLObjects()
        }
        surfaces.removeAll(keepingCapacity: true)
        writeIndex = 0
        pixelSize = newSize
        guard let cglContext = glContext.cglContextObj else { return }
        for _ in 0..<Self.surfaceCount {
            if let surface = InteropSurface(
                width: width,
                height: height,
                device: device,
                cglContext: cglContext
            ) {
                surfaces.append(surface)
            }
        }
    }

    // MARK: 构造

    private static func makeHeadlessGLContext() -> NSOpenGLContext? {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize),
            24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize),
            8,
            0
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes),
              let context = NSOpenGLContext(format: format, share: nil) else {
            return nil
        }
        return context
    }

    private static func makeBlitPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: blitShaderSource, options: nil),
              let vertex = library.makeFunction(name: "mpvBlitVertex"),
              let fragment = library.makeFunction(name: "mpvBlitFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static let blitShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BlitVSOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex BlitVSOut mpvBlitVertex(uint vid [[vertex_id]],
                                   constant float &flipY [[buffer(0)]]) {
        float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        float2 p = corners[vid];
        BlitVSOut out;
        out.position = float4(p, 0.0, 1.0);
        float2 uv = (p + 1.0) * 0.5;
        if (flipY > 0.5) { uv.y = 1.0 - uv.y; }
        out.uv = uv;
        return out;
    }

    fragment float4 mpvBlitFragment(BlitVSOut in [[stage_in]],
                                    texture2d<float> videoTexture [[texture(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
        return videoTexture.sample(s, in.uv);
    }
    """
}

/// 单张互操作面：一张 IOSurface + 绑定它的 GL 矩形纹理 + 离屏 FBO + 包同一 IOSurface 的 Metal 纹理。
private final class InteropSurface {
    let ioSurface: IOSurfaceRef
    let metalTexture: MTLTexture
    private(set) var texture: GLuint = 0
    private(set) var framebuffer: GLuint = 0
    private var destroyed = false

    init?(width: Int, height: Int, device: MTLDevice, cglContext: CGLContextObj) {
        // BGRA 32bpp，与 Metal .bgra8Unorm 对齐。
        let bytesPerElement = 4
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfacePixelFormat: Int(0x42475241) // 'BGRA'
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        self.ioSurface = surface

        // Metal 侧：把同一张 IOSurface 包成 2D 纹理。
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let metalTexture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            return nil
        }
        self.metalTexture = metalTexture

        // GL 侧：矩形纹理绑定 IOSurface + 离屏 FBO（当前上下文须为传入的无屏上下文）。
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), texture)
        let result = CGLTexImageIOSurface2D(
            cglContext,
            GLenum(GL_TEXTURE_RECTANGLE),
            GLenum(GL_RGBA),
            GLsizei(width),
            GLsizei(height),
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
            surface,
            0
        )
        guard result == kCGLNoError else {
            glDeleteTextures(1, &texture)
            return nil
        }
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))

        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER),
            GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_RECTANGLE),
            texture,
            0
        )
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), 0)
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            destroyGLObjects()
            return nil
        }
    }

    /// 必须在无屏 GL 上下文 current 时调用。
    func destroyGLObjects() {
        guard !destroyed else { return }
        destroyed = true
        if framebuffer != 0 {
            glDeleteFramebuffers(1, &framebuffer)
            framebuffer = 0
        }
        if texture != 0 {
            glDeleteTextures(1, &texture)
            texture = 0
        }
    }
}
