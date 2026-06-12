import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import QuartzCore
import SwiftUI

/// 音乐展开页 L0 底板（Metal 重写版，2026-06-10）。
///
/// 设计原则（对应用户需求 2/4/5）：
/// - 底板颜色【唯一来源】是封面的低频高斯颜料场纹理（paintPalette），保证色系永远来自封面高斯模糊；
///   palette 三色只用于光池/柔光斑，不再构造与封面无关的合成底色。
/// - 方向解耦：shader 内用三个固定角度的旋转采样 + 大尺度噪声权重混合同一张颜料场，
///   颜色完全同源但空间排布与封面不一致——底板不再像"放大的封面"。
/// - 黑色不发光：近黑像素按 HSV value 门控溶解进干净中性底，不参与色彩贡献。
/// - 舒适带：HSV 饱和/亮度收敛到固定区间（浅色亮而不灰、艳而不扎眼），根治"忽艳忽灰"。
/// - 切歌：保留上一张纹理做 0.8s 交叉淡入，过渡自然不跳变。
struct MetalAlbumBackdropView: NSViewRepresentable {
    let posterPath: String?
    let title: String
    let palette: AlbumColorPalette
    let artworkReady: Bool
    let albumLightCenter: CGPoint
    let glassIntensity: Double
    let reduceMotion: Bool
    let dynamicEffectsEnabled: Bool
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = true
        view.clearColor = palette.backdropBaseNSColor(for: colorScheme).metalClearColor(alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.wantsLayer = true
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.layer?.backgroundColor = palette.backdropBaseNSColor(for: colorScheme).usingColorSpace(.deviceRGB)?.cgColor
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        context.coordinator.attach(to: view)
        context.coordinator.update(
            posterPath: posterPath,
            title: title,
            palette: palette,
            artworkReady: artworkReady,
            albumLightCenter: albumLightCenter,
            glassIntensity: glassIntensity,
            reduceMotion: reduceMotion,
            dynamicEffectsEnabled: dynamicEffectsEnabled,
            colorScheme: colorScheme
        )
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.attach(to: nsView)
        context.coordinator.update(
            posterPath: posterPath,
            title: title,
            palette: palette,
            artworkReady: artworkReady,
            albumLightCenter: albumLightCenter,
            glassIntensity: glassIntensity,
            reduceMotion: reduceMotion,
            dynamicEffectsEnabled: dynamicEffectsEnabled,
            colorScheme: colorScheme
        )
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private weak var view: MTKView?
        private var renderer: MusicAlbumBackdropRenderer?
        private var fallbackCommandQueue: MTLCommandQueue?
        private var posterPath: String?
        private var pendingTexturePath: String?
        private var artworkTexture: MTLTexture?
        private var previousArtworkTexture: MTLTexture?
        private var textureTransitionStart: CFTimeInterval = 0
        private var textureTransitionTask: Task<Void, Never>?
        private var textureLoadTask: Task<Void, Never>?
        private var notificationTokens: [NSObjectProtocol] = []
        private var latestState = MusicAlbumBackdropState(
            title: "",
            palette: .fallback,
            artworkReady: false,
            albumLightCenter: .zero,
            glassIntensity: 1,
            reduceMotion: false,
            dynamicEffectsEnabled: false,
            colorScheme: .light
        )
        private static let textureCrossfadeDuration: CFTimeInterval = 0.8

        func attach(to view: MTKView) {
            guard self.view !== view else { return }
            detach()
            self.view = view
            view.delegate = self
            if let device = view.device {
                fallbackCommandQueue = device.makeCommandQueue()
                renderer = MusicAlbumBackdropRenderer(device: device, pixelFormat: view.colorPixelFormat)
            }
            installNotifications()
            applyPauseState()
            requestDraw()
        }

        func detach() {
            textureLoadTask?.cancel()
            textureLoadTask = nil
            textureTransitionTask?.cancel()
            textureTransitionTask = nil
            if let view {
                view.delegate = nil
            }
            notificationTokens.forEach(NotificationCenter.default.removeObserver)
            notificationTokens.removeAll()
            renderer = nil
            fallbackCommandQueue = nil
            self.view = nil
        }

        func update(
            posterPath: String?,
            title: String,
            palette: AlbumColorPalette,
            artworkReady: Bool,
            albumLightCenter: CGPoint,
            glassIntensity: Double,
            reduceMotion: Bool,
            dynamicEffectsEnabled: Bool,
            colorScheme: ColorScheme
        ) {
            latestState = MusicAlbumBackdropState(
                title: title,
                palette: palette,
                artworkReady: artworkReady,
                albumLightCenter: albumLightCenter,
                glassIntensity: glassIntensity,
                reduceMotion: reduceMotion,
                dynamicEffectsEnabled: dynamicEffectsEnabled,
                colorScheme: colorScheme
            )
            applyFallbackBackdrop(to: view)
            // 切歌期间保留上一张纹理：shader 用 textureMix 做交叉淡入，避免底板硬切。
            loadArtworkTextureIfNeeded(path: posterPath)
            applyPauseState()
            requestDraw()
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            Task { @MainActor [weak self] in
                self?.requestDraw()
            }
        }

        nonisolated func draw(in view: MTKView) {
            guard let view = Optional(view) else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self.drawNow(in: view)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.requestDraw()
                }
            }
        }

        private var textureMix: Double {
            guard previousArtworkTexture != nil else { return 1 }
            let elapsed = CACurrentMediaTime() - textureTransitionStart
            let t = min(max(elapsed / Self.textureCrossfadeDuration, 0), 1)
            return t * t * (3 - 2 * t)
        }

        private func drawNow(in view: MTKView) {
            applyFallbackBackdrop(to: view)
            guard let renderer else {
                drawFallback(in: view)
                applyPauseState()
                return
            }
            let mix = textureMix
            if mix >= 1 {
                previousArtworkTexture = nil
            }
            renderer.draw(
                in: view,
                state: latestState,
                artworkTexture: artworkTexture,
                previousArtworkTexture: previousArtworkTexture,
                textureMix: Float(mix)
            )
            applyPauseState()
        }

        private func applyFallbackBackdrop(to view: MTKView?) {
            guard let view else { return }
            let baseColor = latestState.palette.backdropBaseNSColor(for: latestState.colorScheme)
            view.clearColor = baseColor.metalClearColor(alpha: 1)
            view.layer?.backgroundColor = baseColor.usingColorSpace(.deviceRGB)?.cgColor
        }

        private func drawFallback(in view: MTKView) {
            guard let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = fallbackCommandQueue?.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// 切歌交叉淡入：纹理替换后按 30fps 重绘到淡入完成，然后回到按需绘制暂停。
        private func beginTextureCrossfade() {
            textureTransitionTask?.cancel()
            guard previousArtworkTexture != nil, !latestState.reduceMotion else {
                previousArtworkTexture = nil
                requestDraw()
                return
            }
            textureTransitionStart = CACurrentMediaTime()
            textureTransitionTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.previousArtworkTexture != nil {
                    self.requestDraw()
                    if self.textureMix >= 1 { break }
                    do { try await Task.sleep(nanoseconds: 33_000_000) } catch { return }
                }
                self?.previousArtworkTexture = nil
                self?.requestDraw()
            }
        }

        private func loadArtworkTextureIfNeeded(path: String?) {
            guard posterPath != path else { return }
            posterPath = path
            textureLoadTask?.cancel()
            guard let path else {
                pendingTexturePath = nil
                previousArtworkTexture = artworkTexture
                artworkTexture = nil
                beginTextureCrossfade()
                return
            }
            pendingTexturePath = path
            textureLoadTask = Task { @MainActor [weak self] in
                let textureImage = await Task.detached(priority: .utility) {
                    let base: NSImage?
#if DEBUG
                    if let debugCover = MusicPlayerVisualDebugFixtures.coverImage(forPath: path, size: 192) {
                        base = debugCover
                    } else {
                        base = ArtworkImageCache.image(
                            path: path,
                            targetSize: CGSize(width: 192, height: 192)
                        )
                    }
#else
                    base = ArtworkImageCache.image(
                        path: path,
                        targetSize: CGSize(width: 192, height: 192)
                    )
#endif
                    // 封面 → 低频高斯颜料场：底板颜色的唯一来源。
                    let field = MusicAlbumBackdropImageBlur.paintPalette(base) ?? base
                    return SendableMusicMetalBackdropImage(field?.cgImageForMetalTexture())
                }.value
                guard let self,
                      !Task.isCancelled,
                      self.pendingTexturePath == path,
                      let device = self.view?.device,
                      let cgImage = textureImage.image else { return }
                do {
                    let loader = MTKTextureLoader(device: device)
                    let next = try await loader.newTexture(
                        cgImage: cgImage,
                        options: [
                            .SRGB: false,
                            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
                        ]
                    )
                    self.previousArtworkTexture = self.artworkTexture
                    self.artworkTexture = next
                    self.beginTextureCrossfade()
                } catch {
                    self.requestDraw()
                }
            }
        }

        private func installNotifications() {
            guard notificationTokens.isEmpty else { return }
            let center = NotificationCenter.default
            notificationTokens.append(center.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applyPauseState() }
            })
            notificationTokens.append(center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.applyPauseState()
                    self?.requestDraw()
                }
            })
            notificationTokens.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let self,
                          notification.object as? NSWindow === self.view?.window else { return }
                    self.applyPauseState()
                    self.requestDraw()
                }
            })
        }

        private func applyPauseState() {
            guard let view else { return }
            let windowVisible = view.window?.occlusionState.contains(.visible) ?? true
            let shouldAnimate = latestState.dynamicEffectsEnabled &&
                !latestState.reduceMotion &&
                NSApp.isActive &&
                windowVisible
            view.preferredFramesPerSecond = 30
            view.enableSetNeedsDisplay = !shouldAnimate
            view.isPaused = !shouldAnimate
        }

        private func requestDraw() {
            guard let view else { return }
            if view.isPaused {
                view.setNeedsDisplay(view.bounds)
            } else {
                view.draw()
            }
        }
    }
}

private struct MusicAlbumBackdropState {
    var title: String
    var palette: AlbumColorPalette
    var artworkReady: Bool
    var albumLightCenter: CGPoint
    var glassIntensity: Double
    var reduceMotion: Bool
    var dynamicEffectsEnabled: Bool
    var colorScheme: ColorScheme
}

private final class MusicAlbumBackdropRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var fallbackTexture: MTLTexture?

    // 运行时编译的 shader / pipeline 按 (device, pixelFormat) 缓存：
    // 每次展开音乐播放器都会重建 MTKView 并新建 renderer，若不缓存就会在主线程重复编译
    // shader 字符串，造成每次展开的卡顿。缓存后仅首次编译一次。
    private struct PipelineKey: Hashable {
        let device: ObjectIdentifier
        let pixelFormat: UInt
    }
    private static let cacheLock = NSLock()
    private static var pipelineCache: [PipelineKey: MTLRenderPipelineState] = [:]

    private static func cachedPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = PipelineKey(device: ObjectIdentifier(device), pixelFormat: pixelFormat.rawValue)
        cacheLock.lock()
        let cached = pipelineCache[key]
        cacheLock.unlock()
        if let cached { return cached }

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertex = library.makeFunction(name: "musicAlbumBackdropVertex"),
              let fragment = library.makeFunction(name: "musicAlbumBackdropFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        cacheLock.lock()
        pipelineCache[key] = pipelineState
        cacheLock.unlock()
        return pipelineState
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let commandQueue = device.makeCommandQueue(),
              let pipelineState = Self.cachedPipeline(device: device, pixelFormat: pixelFormat) else {
            return nil
        }
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.fallbackTexture = Self.makeTransparentTexture(device: device)
    }

    func draw(
        in view: MTKView,
        state: MusicAlbumBackdropState,
        artworkTexture: MTLTexture?,
        previousArtworkTexture: MTLTexture?,
        textureMix: Float
    ) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var uniforms = MusicAlbumBackdropUniforms(
            state: state,
            viewportSize: view.drawableSize,
            textureMix: previousArtworkTexture == nil ? 1 : textureMix,
            hasPreviousTexture: previousArtworkTexture != nil
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MusicAlbumBackdropUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MusicAlbumBackdropUniforms>.stride, index: 0)
        encoder.setFragmentTexture(artworkTexture ?? fallbackTexture, index: 0)
        encoder.setFragmentTexture(previousArtworkTexture ?? artworkTexture ?? fallbackTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makeTransparentTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: UInt32 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: MemoryLayout<UInt32>.size
        )
        return texture
    }
}

private struct MusicAlbumBackdropUniforms {
    var viewportSize: SIMD2<Float>
    var albumLightCenter: SIMD2<Float>
    var baseColor: SIMD4<Float>
    var glowPrimary: SIMD4<Float>
    var glowSecondary: SIMD4<Float>
    var glowAccent: SIMD4<Float>
    var glassIntensity: Float
    var artworkOpacity: Float
    var textureMix: Float
    var isDark: Float
    var vibrancy: Float

    init(
        state: MusicAlbumBackdropState,
        viewportSize: CGSize,
        textureMix: Float,
        hasPreviousTexture: Bool
    ) {
        let palette = state.palette
        self.viewportSize = SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1)))
        self.albumLightCenter = SIMD2(Float(state.albumLightCenter.x), Float(state.albumLightCenter.y))
        // 兜底底色（无封面 / 纹理未就绪）：palette 清洁基色。封面就绪后由颜料场完全接管。
        self.baseColor = palette.backdropBaseNSColor(for: state.colorScheme).metalRGBA(alpha: 1)
        // glow* 三色只承担光池与柔光斑（lightenedForGlow 保证亮度下限/保色相），不构成底板主体。
        self.glowPrimary = palette.glowPrimary.nsColor.metalRGBA(alpha: 1)
        self.glowSecondary = palette.glowSecondary.nsColor.metalRGBA(alpha: 1)
        self.glowAccent = palette.glowAccent.nsColor.metalRGBA(alpha: 1)
        self.glassIntensity = Float(min(max(state.glassIntensity, 0), 1))
        self.artworkOpacity = state.artworkReady ? 1 : 0
        self.textureMix = hasPreviousTexture ? min(max(textureMix, 0), 1) : 1
        self.isDark = state.colorScheme == .dark ? 1 : 0
        self.vibrancy = Float(min(max(palette.vibrancy, 0), 1))
    }
}

private extension NSColor {
    func metalRGBA(alpha overrideAlpha: Double? = nil) -> SIMD4<Float> {
        let color = usingColorSpace(.deviceRGB) ?? self
        return SIMD4(
            Float(color.redComponent),
            Float(color.greenComponent),
            Float(color.blueComponent),
            Float(overrideAlpha ?? color.alphaComponent)
        )
    }

    func metalClearColor(alpha overrideAlpha: Double? = nil) -> MTLClearColor {
        let color = usingColorSpace(.deviceRGB) ?? self
        return MTLClearColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: overrideAlpha ?? Double(color.alphaComponent)
        )
    }
}

private enum MusicAlbumBackdropImageBlur {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 提取封面的低频空间色场：约 160px 输入 → 约 40px 网格 → 轻柔化。
    /// ⚠ soften 不能大：40px 网格上 13px 高斯≈把整张封面平均成"全局均值色"，
    /// 对真实封面（黑外套+白底+暖色块）均值必然是脏粉/脏灰——这正是底板取色发脏的根因。
    /// 轻柔化只去锐边，保留色块的空间分离；中性区域由 shader 的角色色场接管。
    static func paintPalette(_ image: NSImage?, grid: Int = 48, soften: Double = 3.6) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        // ① 下采样到低频网格：丢弃文字/锐边/噪点，保留封面的多色区域关系。
        let scale = Double(grid) / Double(max(extent.width, extent.height))
        var working = input
        if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(working, forKey: kCIInputImageKey)
            lanczos.setValue(scale, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            working = lanczos.outputImage ?? working
        }
        let gridExtent = working.extent.isInfinite || working.extent.isEmpty
            ? CGRect(x: 0, y: 0, width: CGFloat(grid), height: CGFloat(grid))
            : working.extent

        // ② 小坐标系里揉开成"被玻璃压住的颜料"，避免 raw cover 大模糊的泥色。
        if soften > 0, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(working.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(soften, forKey: kCIInputRadiusKey)
            working = blur.outputImage ?? working
        }

        guard let outputCG = context.createCGImage(working, from: gridExtent) else { return image }
        return NSImage(cgImage: outputCG, size: gridExtent.size)
    }
}

private struct SendableMusicMetalBackdropImage: @unchecked Sendable {
    let image: CGImage?

    init(_ image: CGImage?) {
        self.image = image
    }
}

private extension NSImage {
    func cgImageForMetalTexture() -> CGImage? {
        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.cgImage
    }
}

private extension MusicAlbumBackdropRenderer {
    static let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewportSize;
    float2 albumLightCenter;
    float4 baseColor;
    float4 glowPrimary;
    float4 glowSecondary;
    float4 glowAccent;
    float glassIntensity;
    float artworkOpacity;
    float textureMix;
    float isDark;
    float vibrancy;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut musicAlbumBackdropVertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 uvs[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

// ───────────────── 底板观感总调参 ─────────────────
// 浅色舒适带：底板"亮而不灰、彩而不扎眼"的硬边界。
constant float kLightValueMin   = 0.675; // 浅色亮度下限：稍微提亮，避免底板发沉
constant float kLightValueMax   = 0.855; // 浅色亮度上限：保留通透感但不把封面色洗白
constant float kLightSatScale   = 0.94;  // 浅色饱和缩放：避免底板比封面本体更艳
constant float kLightSatMax     = 0.355; // 浅色饱和上限（防"比封面还艳"刺眼）
constant float kDarkValueMin    = 0.130;
constant float kDarkValueMax    = 0.310;
constant float kDarkSatScale    = 0.88;
constant float kDarkSatMax      = 0.460;
// 光池 / 柔光斑强度。
constant float kPoolStrength    = 0.31;
constant float kBlobStrength    = 0.19;

static float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// 受控加光：加光量随背景已有亮度衰减（headroom），亮区不会被推白。
static float3 controlledPlus(float3 dst, float3 src, float a) {
    float headroom = clamp(1.0 - luminance(dst), 0.0, 1.0);
    return min(dst + src * clamp(a, 0.0, 1.0) * headroom, float3(1.0));
}

// 受控滤色：背景暗 → 接近 screen（通透发光）；背景亮 → 接近染色 over（不发白）。
static float3 controlledScreen(float3 dst, float3 src, float a) {
    float aa = clamp(a, 0.0, 1.0);
    float3 screened = 1.0 - (1.0 - dst) * (1.0 - src);
    float3 scr = mix(dst, screened, aa);
    float3 ovr = mix(dst, src, aa);
    float headroom = clamp(1.0 - luminance(dst), 0.0, 1.0);
    return mix(ovr, scr, clamp(headroom * 1.2, 0.0, 1.0));
}

static float radialT(float2 point, float2 center, float endRadius) {
    return clamp(length(point - center) / max(endRadius, 0.0001), 0.0, 1.0);
}

static float2 rotateAround(float2 p, float2 pivot, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    float2 d = p - pivot;
    return pivot + float2(d.x * c - d.y * s, d.x * s + d.y * c);
}

// 同一张颜料场的双纹理（切歌交叉淡入）采样。
static float3 fieldSample(
    texture2d<float> current,
    texture2d<float> previous,
    sampler s,
    float2 uv,
    float mixT
) {
    float3 prev = previous.sample(s, uv).rgb;
    float3 cur = current.sample(s, uv).rgb;
    return mix(prev, cur, mixT);
}

fragment float4 musicAlbumBackdropFragment(
    VertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]],
    texture2d<float> artwork [[texture(0)]],
    texture2d<float> previousArtwork [[texture(1)]]
) {
    constexpr sampler fieldSampler(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
    float2 point = uv * u.viewportSize;
    float isDark = step(0.5, u.isDark);
    float isLight = 1.0 - isDark;
    float vibrancy = clamp(u.vibrancy, 0.0, 1.0);
    float span = max(u.viewportSize.x, u.viewportSize.y);

    // ── 1) 角色色底场：底板的颜色身份【直接】由取色三色构成 ──
    // 第二轮收敛：不再按阈值在主/辅/强调三色之间“切块”。切块会在真实窗口里形成大块
    // 低频色面，像裁片而不是高斯颜料。改为连续权重混合：主色占优，辅色/强调色按
    // 大尺度噪声轻微呼吸，三色一直都在，但边界被揉开。
    float nA = valueNoise(uv * float2(1.35, 1.02) + float2(4.21, 1.37));
    float nB = valueNoise(uv * float2(0.92, 1.38) + float2(8.05, 5.62));
    float nC = valueNoise(uv * float2(1.10, 0.86) + float2(1.19, 9.43));
    float secondaryWeight = 0.175 + (nA - 0.5) * 0.030;
    float accentWeight = 0.120 + (nB - 0.5) * 0.026;
    float primaryWeight = 1.0 - secondaryWeight - accentWeight;
    float3 roleField =
        u.glowPrimary.rgb * primaryWeight +
        u.glowSecondary.rgb * secondaryWeight +
        u.glowAccent.rgb * accentWeight;
    float3 harmonicWash =
        u.glowPrimary.rgb * 0.48 +
        u.glowSecondary.rgb * 0.28 +
        u.glowAccent.rgb * 0.24;
    roleField = mix(roleField, harmonicWash, 0.50 + 0.08 * nC);
    // 低彩封面（vibrancy 低）让角色场向中性珍珠/墨色退让，不强行上色。
    float3 pearl = mix(
        float3(0.845, 0.862, 0.878),
        float3(0.085, 0.092, 0.110),
        isDark
    );
    roleField = mix(pearl, roleField, 0.32 + 0.68 * vibrancy);

    // ── 2) 封面颜料注入：只允许"真正有彩度"的封面区域注入局部颜色 ──
    // 旋转/镜像采样保持方向解耦；样本的彩度（s×v）作为发言权——
    // 鲜艳区域（色块/插画主体）把真实封面色画进底板，中性/均值泥（黑、白、灰粉）
    // 一律让位给角色色场，从根上杜绝"底板颜色看起来不来自取色"。
    float2 c0 = uv * 0.74 + 0.13;
    float2 c1 = rotateAround(uv * 0.80 + 0.10, float2(0.5), -0.32);
    float3 s0 = fieldSample(artwork, previousArtwork, fieldSampler, c0, u.textureMix);
    float3 s1 = fieldSample(artwork, previousArtwork, fieldSampler, c1, u.textureMix);
    float n0 = valueNoise(uv * float2(1.45, 1.10) + float2(7.31, 2.17));
    float selectT = smoothstep(0.22, 0.86, n0) * 0.24;
    float3 coverSample = mix(s0, s1, selectT);

    // 色相向最近角色色收拢（旋转量封顶，不凭空造色）：注入的封面色也落在取色身份里。
    float huePrimary = rgb2hsv(u.glowPrimary.rgb).x;
    float hueSecondary = rgb2hsv(u.glowSecondary.rgb).x;
    float hueAccent = rgb2hsv(u.glowAccent.rgb).x;
    float3 hsvSample = rgb2hsv(coverSample);
    float dP = fract(hsvSample.x - huePrimary + 0.5) - 0.5;
    float dS = fract(hsvSample.x - hueSecondary + 0.5) - 0.5;
    float dA = fract(hsvSample.x - hueAccent + 0.5) - 0.5;
    float dNearest = dP;
    if (abs(dS) < abs(dNearest)) { dNearest = dS; }
    if (abs(dA) < abs(dNearest)) { dNearest = dA; }
    float hueSnap = clamp(dNearest * 0.55, -0.085, 0.085);
    hsvSample.x = fract(hsvSample.x - hueSnap + 1.0);
    float colorfulness = smoothstep(0.075, 0.240, hsvSample.y * hsvSample.z);
    float3 field = mix(roleField, hsv2rgb(hsvSample), colorfulness * (0.34 + 0.12 * vibrancy));

    // ── 2.5) 封面低频投影：目标图里的"底下还有一个模糊封面"不是纯光斑，
    // 而是一张围绕真实封面中心放大的颜料场。这里用 albumLightCenter 建立局部坐标，
    // 把低频封面按空间方向投到底板上，再由后面的舒适带统一清洁化。
    float projectionSpan = span * 0.58;
    float2 rawProjectionUV = (point - u.albumLightCenter) / projectionSpan + float2(0.5);
    float2 projectionUV = clamp(rawProjectionUV, float2(0.0), float2(1.0));
    float2 projectionBox = abs(rawProjectionUV - float2(0.5)) * 2.0;
    float projectionShape = 1.0 - smoothstep(0.72, 1.30, max(projectionBox.x, projectionBox.y));
    float projectionDistance = 1.0 - radialT(point, u.albumLightCenter, projectionSpan * 0.92);
    float projectionMask = projectionShape *
        (0.50 + projectionDistance * projectionDistance * 0.40) *
        (0.34 + 0.20 * vibrancy) *
        clamp(u.artworkOpacity, 0.0, 1.0);
    float3 projectedCover = fieldSample(artwork, previousArtwork, fieldSampler, projectionUV, u.textureMix);
    float3 hsvProjection = rgb2hsv(projectedCover);
    float projectionColorful = smoothstep(0.050, 0.220, hsvProjection.y * hsvProjection.z);
    hsvProjection.y = clamp(hsvProjection.y * 1.02 + projectionColorful * 0.020, 0.0, 0.70);
    hsvProjection.z = clamp(pow(max(hsvProjection.z, 0.0), 0.90) * 1.00, 0.18, 0.88);
    field = mix(field, hsv2rgb(hsvProjection), projectionMask * (0.46 + projectionColorful * 0.14));

    // ── 3) 舒适带收敛（透亮、不扎眼、不发灰） ──
    // 亮度整体压缩映射进明亮带（保持封面明暗排序，但绝不跌出下限——
    // 之前"保留明暗起伏"的混合项会把暗部拽到 ~0.59 的灰暗区，正是底板发灰的根因）。
    float3 hsv = rgb2hsv(field);
    float satMax = mix(kLightSatMax, kDarkSatMax, isDark) * (0.82 + 0.18 * vibrancy);
    float satScale = mix(kLightSatScale, kDarkSatScale, isDark);
    // 彩色区域饱和地板：封面有明确颜色时底板不许退成灰白（低彩封面不受影响）。
    float satFloor = smoothstep(0.08, 0.32, hsv.y) * mix(0.110, 0.080, isDark);
    hsv.y = clamp(hsv.y * satScale, satFloor, satMax);
    float vMin = mix(kLightValueMin, kDarkValueMin, isDark);
    float vMax = mix(kLightValueMax, kDarkValueMax, isDark);
    hsv.z = clamp(hsv.z * mix(0.400, 0.30, isDark) + mix(0.455, 0.105, isDark), vMin, vMax);
    field = hsv2rgb(hsv);

    // 无封面 / 纹理未就绪：退到 palette 清洁基色。
    float3 color = mix(u.baseColor.rgb, field, clamp(u.artworkOpacity, 0.0, 1.0));

    // ── 4) 封面光池 ──
    // 以封面光心为圆心的柔光池：把封面发光的能量延续到底板上，
    // 用 glowPrimary（保色相提亮版主色），受控滤色不会洗白。
    float poolT = 1.0 - radialT(point, u.albumLightCenter, span * 0.68);
    float pool = poolT * poolT;
    color = controlledScreen(color, u.glowPrimary.rgb, pool * (isDark * 0.130 + isLight * 0.088) * kPoolStrength);
    float2 poolLow = u.albumLightCenter + float2(span * 0.05, span * 0.16);
    float poolT2 = 1.0 - radialT(point, poolLow, span * 0.44);
    color = controlledScreen(color, u.glowSecondary.rgb, poolT2 * poolT2 * (isDark * 0.060 + isLight * 0.038) * kPoolStrength);

    // ── 5) 两枚远端柔光斑 ──
    // 右上 secondary / 左下 accent，半径大、alpha 低：保住"绚丽多彩"的层次，
    // 但不再堆十几枚光斑互相打架。
    float blobA = 1.0 - radialT(point, float2(0.88, 0.16) * u.viewportSize, span * 0.74);
    color = controlledPlus(color, u.glowSecondary.rgb, blobA * blobA * (isDark * 0.052 + isLight * 0.034) * kBlobStrength);
    float blobB = 1.0 - radialT(point, float2(0.14, 0.88) * u.viewportSize, span * 0.70);
    color = controlledPlus(color, u.glowAccent.rgb, blobB * blobB * (isDark * 0.046 + isLight * 0.030) * kBlobStrength);

    // ── 6) 整窗玻璃面（"被玻璃盖住"的空间感） ──
    float strength = clamp(u.glassIntensity, 0.0, 1.0);
    // 上沿受光：白里带一点封面主色（彩色光而非白光）。
    float3 glassLight = mix(u.glowPrimary.rgb, float3(1.0), 0.46);
    float topLift = (1.0 - smoothstep(0.0, 0.46, uv.y)) * (isDark * 0.030 + isLight * 0.026) * strength;
    color = controlledScreen(color, glassLight, topLift);
    // 下沿入影：极轻压暗，形成玻璃厚度。
    float bottomShade = smoothstep(0.58, 1.0, uv.y) * (isDark * 0.060 + isLight * 0.022) * strength;
    color *= (1.0 - bottomShade);
    // 极薄空气纱（浅色限定）：让浅色底板带"隔着玻璃"的空气感，幅度小到不会发灰。
    float airT = 1.0 - smoothstep(0.0, 0.85, uv.y);
    color = mix(color, min(color + float3(0.014), float3(1.0)), airT * isLight * 0.18 * strength);

    // ── 7) 出图：抖动去断层 + 防纯白 clamp ──
    float dither = fract(sin(dot(point, float2(12.9898, 78.233))) * 43758.5453);
    color += (dither - 0.5) * (1.15 / 255.0);
    color = clamp(color, float3(0.0), float3(0.920));
    return float4(color, 1.0);
}
"""#
}
