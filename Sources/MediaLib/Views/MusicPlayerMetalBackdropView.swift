import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import QuartzCore
import SwiftUI

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
            loadArtworkTextureIfNeeded(path: artworkReady ? posterPath : nil)
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

        private func drawNow(in view: MTKView) {
            applyFallbackBackdrop(to: view)
            guard let renderer else {
                drawFallback(in: view)
                applyPauseState()
                return
            }
            renderer.draw(
                in: view,
                state: latestState,
                artworkTexture: artworkTexture
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

        private func loadArtworkTextureIfNeeded(path: String?) {
            guard posterPath != path else { return }
            posterPath = path
            textureLoadTask?.cancel()
            guard let path else {
                pendingTexturePath = nil
                artworkTexture = nil
                requestDraw()
                return
            }
            pendingTexturePath = path
            textureLoadTask = Task { @MainActor [weak self] in
                let textureImage = await Task.detached(priority: .utility) {
                    let base = ArtworkImageCache.image(
                        path: path,
                        targetSize: CGSize(width: 112, height: 112)
                    )
                    let blurred = MusicAlbumBackdropImageBlur.blurred(base, radius: 22) ?? base
                    return SendableMusicMetalBackdropImage(blurred?.cgImageForMetalTexture())
                }.value
                guard let self,
                      !Task.isCancelled,
                      self.pendingTexturePath == path,
                      let device = self.view?.device,
                      let cgImage = textureImage.image else { return }
                do {
                    let loader = MTKTextureLoader(device: device)
                    self.artworkTexture = try await loader.newTexture(
                        cgImage: cgImage,
                        options: [
                            .SRGB: false,
                            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
                        ]
                    )
                    self.requestDraw()
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

    func draw(in view: MTKView, state: MusicAlbumBackdropState, artworkTexture: MTLTexture?) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var uniforms = MusicAlbumBackdropUniforms(
            state: state,
            viewportSize: view.drawableSize
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MusicAlbumBackdropUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MusicAlbumBackdropUniforms>.stride, index: 0)
        encoder.setFragmentTexture(artworkTexture ?? fallbackTexture, index: 0)
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
    var glassBaseColor: SIMD4<Float>
    var primary: SIMD4<Float>
    var secondary: SIMD4<Float>
    var accent: SIMD4<Float>
    var glowPrimary: SIMD4<Float>
    var glowSecondary: SIMD4<Float>
    var glowAccent: SIMD4<Float>
    var glassIntensity: Float
    var artworkOpacity: Float
    var isDark: Float
    var _padding: Float = 0

    init(state: MusicAlbumBackdropState, viewportSize: CGSize) {
        let palette = state.palette
        self.viewportSize = SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1)))
        self.albumLightCenter = SIMD2(Float(state.albumLightCenter.x), Float(state.albumLightCenter.y))
        // 底色用 cleanMetalBaseColor：专辑主色占比最高、白色混入(whiteMix)很低、饱和/亮度受限，
        // 既保证来自专辑取色，又避免低饱和封面发灰、避免过亮发白。
        self.baseColor = Self.cleanMetalBaseColor(palette: palette, isDark: state.colorScheme == .dark)
        self.glassBaseColor = NSColor(palette.albumGlassBaseColor(for: state.colorScheme)).metalRGBA(alpha: 1)
        self.primary = palette.primary.nsColor.metalRGBA(alpha: 1)
        self.secondary = palette.secondary.nsColor.metalRGBA(alpha: 1)
        self.accent = palette.accent.nsColor.metalRGBA(alpha: 1)
        self.glowPrimary = palette.glowPrimary.nsColor.metalRGBA(alpha: 1)
        self.glowSecondary = palette.glowSecondary.nsColor.metalRGBA(alpha: 1)
        self.glowAccent = palette.glowAccent.nsColor.metalRGBA(alpha: 1)
        self.glassIntensity = Float(min(max(state.glassIntensity, 0), 1))
        // 背景不再"严格按封面像素位置"直采（那样偏脏、偏写实）。改为只保留极轻的封面纹理做有机变化，
        // 主体颜色交给下方由 基/主/辅/强调色 组成的 Apple Music 式多色网格（overBlend 染色，干净不发白、不偏色相）。
        self.artworkOpacity = state.artworkReady ? Float(state.colorScheme == .dark ? 0.34 : 0.22) : 0
        self.isDark = state.colorScheme == .dark ? 1 : 0
    }

    /// 干净底色：专辑主色为主（占比最高），少量辅/强调色，白色混入极低；
    /// 转 HSB 后限制饱和度与亮度区间——低饱和封面给一个饱和度下限（不发灰），高亮封面压住亮度（不发白）。
    /// 色相严格保留，不向其他色系偏移。
    static func cleanMetalBaseColor(palette: AlbumColorPalette, isDark: Bool) -> SIMD4<Float> {
        let p = palette.primary
        let s = palette.secondary
        let a = palette.accent
        let pw = isDark ? 0.66 : 0.54
        let sw = isDark ? 0.22 : 0.24
        let aw = isDark ? 0.14 : 0.18
        let whiteMix = isDark ? 0.014 : 0.026
        func clamp01(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
        let mixed = NSColor(
            calibratedRed: clamp01(p.red * pw + s.red * sw + a.red * aw + whiteMix),
            green: clamp01(p.green * pw + s.green * sw + a.green * aw + whiteMix),
            blue: clamp01(p.blue * pw + s.blue * sw + a.blue * aw + whiteMix),
            alpha: 1
        )
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var al: CGFloat = 0
        mixed.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &al)
        let cleanedSat: CGFloat
        let cleanedBri: CGFloat
        if isDark {
            cleanedSat = min(max(sat, 0.22), 0.52)
            cleanedBri = min(max(bri, 0.15), 0.30)
        } else {
            cleanedSat = min(max(sat, 0.22), 0.54)
            cleanedBri = min(max(bri, 0.72), 0.86)
        }
        let cleaned = NSColor(calibratedHue: hue, saturation: cleanedSat, brightness: cleanedBri, alpha: 1)
        let rgb = cleaned.usingColorSpace(.deviceRGB) ?? cleaned
        return SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
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

    static func blurred(_ image: NSImage?, radius: Double) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        let clamped = input.clampedToExtent()
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(clamped, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = blurFilter.outputImage else { return image }
        let colored: CIImage
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(blurred, forKey: kCIInputImageKey)
            colorFilter.setValue(1.25, forKey: kCIInputSaturationKey)
            colored = colorFilter.outputImage ?? blurred
        } else {
            colored = blurred
        }
        guard let outputCG = context.createCGImage(colored, from: input.extent) else { return image }
        return NSImage(cgImage: outputCG, size: input.extent.size)
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
    float4 glassBaseColor;
    float4 primary;
    float4 secondary;
    float4 accent;
    float4 glowPrimary;
    float4 glowSecondary;
    float4 glowAccent;
    float glassIntensity;
    float artworkOpacity;
    float isDark;
    float padding0;
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

static float4 colorWithAlpha(float4 color, float alpha) {
    return float4(color.rgb, clamp(alpha, 0.0, 1.0));
}

static float3 overBlend(float3 dst, float4 src) {
    return mix(dst, src.rgb, clamp(src.a, 0.0, 1.0));
}

static float3 plusLighter(float3 dst, float4 src) {
    return min(dst + src.rgb * clamp(src.a, 0.0, 1.0), float3(1.0));
}

static float3 screenBlend(float3 dst, float4 src) {
    float3 screened = 1.0 - (1.0 - dst) * (1.0 - src.rgb);
    return mix(dst, screened, clamp(src.a, 0.0, 1.0));
}

// ───────────────── 背景观感调参（集中管理的"调试参数"）─────────────────
// 调这几个常量即可整体调节背景：曝光 / 光效强度 / 白色总量 / 彩度 / 高光压缩。
constant float kExposure             = 1.015; // 整体曝光（>1 提亮，<1 压暗）
constant float kGlowStrength         = 1.40;  // 受控专辑彩光总强度（提高→底色更鲜艳）
constant float kWhiteVeilStrength    = 0.36;  // 所有白色 veil/高光的总闸（降低→减少白色雾化，保留专辑色）
constant float kChromaBoost          = 1.22;  // 出图前彩度补偿（保住绚丽）
constant float kHighlightCompression = 0.92;  // 高光压缩强度（越大越压，越不易过曝）

static float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// 柔和高光压缩（保彩度）：只压"拐点(knee)以上的高光"，拐点以下（中/暗调）几乎不变，
// 因此浅色底板仍保持明亮，仅把接近纯白的高光向下收，绝不大面积逼近纯白。按亮度比例缩放 RGB，色相/饱和不变。
static float3 softTonemap(float3 c, float compression) {
    float L = luminance(c);
    if (L <= 0.0001) { return c; }
    const float knee = 0.70;
    if (L <= knee) { return c; }
    float over = L - knee;
    // 拐点以上做渐进压缩：over 越大，被压得越多，但始终低于 1.0。
    float compressedOver = over / (1.0 + over * (1.5 + compression * 2.0));
    float Lt = knee + compressedOver;
    return c * (Lt / L);
}

// 受控加光（替代 plusLighter）：加光量随背景已有亮度衰减（headroom）。
// 亮区几乎不再加光 → 不会被推成纯白；暗/中调区正常显现专辑彩光。
static float3 controlledPlus(float3 dst, float4 src) {
    float a = clamp(src.a, 0.0, 1.0);
    float headroom = clamp(1.0 - luminance(dst), 0.0, 1.0);
    return min(dst + src.rgb * a * headroom, float3(1.0));
}

// 受控滤色（替代 screen）：在"纯染色 over"与"滤色 screen"之间按背景亮度插值。
// 背景暗→接近 screen（通透发光）；背景亮→接近 over（只染色、不发白）。
// 这是浅色模式不再被 screen 叠加洗白的关键。
static float3 controlledScreen(float3 dst, float4 src) {
    float a = clamp(src.a, 0.0, 1.0);
    float3 screened = 1.0 - (1.0 - dst) * (1.0 - src.rgb);
    float3 scr = mix(dst, screened, a);
    float3 ovr = mix(dst, src.rgb, a);
    float headroom = clamp(1.0 - luminance(dst), 0.0, 1.0);
    float k = clamp(headroom * 1.2, 0.0, 1.0);
    return mix(ovr, scr, k);
}

static float linearT(float2 uv, float2 start, float2 end) {
    float2 direction = end - start;
    float denom = max(dot(direction, direction), 0.0001);
    return clamp(dot(uv - start, direction) / denom, 0.0, 1.0);
}

static float radialT(float2 point, float2 center, float startRadius, float endRadius) {
    float distance = length(point - center);
    return clamp((distance - startRadius) / max(endRadius - startRadius, 0.0001), 0.0, 1.0);
}

static float4 mix4(float4 a, float4 b, float t) {
    return mix(a, b, clamp(t, 0.0, 1.0));
}

static float4 gradient3(float4 a, float4 b, float4 c, float t) {
    t = clamp(t, 0.0, 1.0);
    if (t < 0.5) {
        return mix4(a, b, t * 2.0);
    }
    return mix4(b, c, (t - 0.5) * 2.0);
}

static float4 gradient4(float4 a, float4 b, float4 c, float4 d, float t) {
    t = clamp(t, 0.0, 1.0);
    if (t < 0.34) {
        return mix4(a, b, t / 0.34);
    }
    if (t < 0.60) {
        return mix4(b, c, (t - 0.34) / 0.26);
    }
    return mix4(c, d, (t - 0.60) / 0.40);
}

static float4 staticRadial5(float4 a, float4 b, float4 c, float4 d, float4 e, float t) {
    t = clamp(t, 0.0, 1.0);
    if (t < 0.25) return mix4(a, b, t / 0.25);
    if (t < 0.50) return mix4(b, c, (t - 0.25) / 0.25);
    if (t < 0.75) return mix4(c, d, (t - 0.50) / 0.25);
    return mix4(d, e, (t - 0.75) / 0.25);
}

static float4 radial2(float2 point, float2 center, float startRadius, float endRadius, float4 a, float4 b) {
    float t = radialT(point, center, startRadius, endRadius);
    return mix4(a, b, t);
}

static float4 radial3(float2 point, float2 center, float startRadius, float endRadius, float4 a, float4 b, float4 c) {
    float t = radialT(point, center, startRadius, endRadius);
    return gradient3(a, b, c, t);
}

static float4 radial5(float2 point, float2 center, float startRadius, float endRadius, float4 a, float4 b, float4 c, float4 d, float4 e) {
    float t = radialT(point, center, startRadius, endRadius);
    return staticRadial5(a, b, c, d, e, t);
}

static float4 beam(float2 point, float2 center, float2 size, float angle, float4 a, float4 b, float4 c, float4 d) {
    float s = sin(-angle);
    float co = cos(-angle);
    float2 p = point - center;
    float2 r = float2(p.x * co - p.y * s, p.x * s + p.y * co);
    float edge = 1.0 - smoothstep(size.y * 0.36, size.y * 0.50, abs(r.y));
    float t = clamp((r.x / size.x) + 0.5, 0.0, 1.0);
    float4 g = gradient4(a, b, c, d, t);
    g.a *= edge;
    return g;
}

fragment float4 musicAlbumBackdropFragment(
    VertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]],
    texture2d<float> artwork [[texture(0)]]
) {
    constexpr sampler artworkSampler(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.uv, float2(0.0), float2(1.0));
    float2 point = uv * u.viewportSize;
    float isDark = step(0.5, u.isDark);
    float isLight = 1.0 - isDark;
    float3 color = u.baseColor.rgb;

    float wv = kWhiteVeilStrength;

    float2 artUV = (uv - 0.5) / 1.24 + 0.5;
    float4 art = artwork.sample(artworkSampler, artUV);
    color = overBlend(color, float4(art.rgb, u.artworkOpacity));

    // 白色薄纱只保留空气感，主体颜色交给专辑三色，避免浅色模式发白。
    float veilT = linearT(uv, float2(0.12, 0.0), float2(0.92, 1.0));
    float4 veil = gradient3(
        float4(1.0, 1.0, 1.0, (isDark * 0.060 + isLight * 0.026) * wv),
        float4(1.0, 1.0, 1.0, (isDark * 0.020 + isLight * 0.008) * wv),
        float4(1.0, 1.0, 1.0, (isDark * 0.075 + isLight * 0.030) * wv),
        veilT
    );
    veil.rgb = mix(float3(0.0), veil.rgb, isLight);
    color = overBlend(color, veil);

    // 纵向渐变：几乎不掺白，中段保留专辑主/辅色。
    float verticalT = linearT(uv, float2(0.5, 0.0), float2(0.5, 1.0));
    color = overBlend(color, gradient3(
        colorWithAlpha(u.secondary, isDark * 0.12 + isLight * 0.080),
        colorWithAlpha(u.primary, isDark * 0.22 + isLight * 0.255),
        colorWithAlpha(u.accent, isDark * 0.10 + isLight * 0.090),
        verticalT
    ));

    // 斜向多色染色（纯专辑色，overBlend，干净保彩度）。浅色染色略降，让底板更通透干净。
    float diagonalT = linearT(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    color = overBlend(color, gradient4(
        colorWithAlpha(u.primary, isDark * 0.27 + isLight * 0.205),
        colorWithAlpha(u.secondary, isDark * 0.22 + isLight * 0.165),
        colorWithAlpha(u.accent, isDark * 0.20 + isLight * 0.145),
        colorWithAlpha(u.primary, isDark * 0.14 + isLight * 0.105),
        diagonalT
    ));

    color = overBlend(color, radial3(
        point,
        float2(0.28, 0.42) * u.viewportSize,
        28.0,
        720.0,
        colorWithAlpha(u.primary, isDark * 0.27 + isLight * 0.205),
        colorWithAlpha(u.accent, isDark * 0.15 + isLight * 0.118),
        float4(0.0)
    ));

    // Apple Music 式多色网格：主/辅/强调色作为大柔光斑铺满四角与中心。
    // 用 controlledPlus 受控加光：在中/暗调区显现绚丽彩光，亮区因 headroom 衰减不会被推白。
    float meshSpan = max(u.viewportSize.x, u.viewportSize.y);
    float blobReach = max(meshSpan * 0.66, 680.0);
    float gs = kGlowStrength;
    color = controlledPlus(color, radial2(point, float2(0.82, 0.14) * u.viewportSize, 0.0, blobReach, colorWithAlpha(u.secondary, (isDark * 0.46 + isLight * 0.48) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.90, 0.84) * u.viewportSize, 0.0, blobReach * 1.04, colorWithAlpha(u.accent, (isDark * 0.42 + isLight * 0.44) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.10, 0.88) * u.viewportSize, 0.0, blobReach * 0.98, colorWithAlpha(u.primary, (isDark * 0.46 + isLight * 0.44) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.15, 0.16) * u.viewportSize, 0.0, blobReach * 0.92, colorWithAlpha(u.primary, (isDark * 0.30 + isLight * 0.30) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.50, 0.48) * u.viewportSize, 0.0, blobReach * 1.14, colorWithAlpha(u.secondary, (isDark * 0.22 + isLight * 0.20) * gs), float4(0.0)));

    // 斜向高光：白色端再压（浅色 0.05），保留专辑主/次色染色。
    float shineT = linearT(uv, float2(0.08, 0.03), float2(0.94, 0.98));
    color = overBlend(color, gradient4(
        float4(1.0, 1.0, 1.0, (isDark * 0.035 + isLight * 0.026) * wv),
        colorWithAlpha(u.primary, isDark * 0.30 + isLight * 0.27),
        float4(0.0),
        colorWithAlpha(u.secondary, isDark * 0.25 + isLight * 0.225),
        shineT
    ));

    float canvasSpan = max(u.viewportSize.x, u.viewportSize.y);
    float longReach = max(canvasSpan * 0.98, 920.0);
    float midReach = max(canvasSpan * 0.62, 620.0);
    float2 c = u.albumLightCenter;

    // 大面积 ambient / 静态背光 / 近场光：全部改用 controlledScreen，
    // 亮背景上自动退化为染色而非滤色，从根本上不再洗白。
    color = controlledScreen(color, radial5(point, c, 0.0, longReach * 0.82, colorWithAlpha(u.glowPrimary, (isDark * 0.34 + isLight * 0.29) * gs), colorWithAlpha(u.glowPrimary, (isDark * 0.22 + isLight * 0.19) * gs), colorWithAlpha(u.glowSecondary, (isDark * 0.13 + isLight * 0.12) * gs), colorWithAlpha(u.glowAccent, (isDark * 0.070 + isLight * 0.064) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c, 0.0, midReach * 0.40, colorWithAlpha(u.glowPrimary, (isDark * 0.26 + isLight * 0.225) * gs), colorWithAlpha(u.glowAccent, (isDark * 0.13 + isLight * 0.11) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(190.0, 42.0), 0.0, midReach * 0.76, colorWithAlpha(u.accent, (isDark * 0.20 + isLight * 0.17) * gs), colorWithAlpha(u.primary, (isDark * 0.090 + isLight * 0.078) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(310.0, -82.0), 0.0, midReach * 0.72, colorWithAlpha(u.secondary, (isDark * 0.16 + isLight * 0.135) * gs), colorWithAlpha(u.accent, (isDark * 0.070 + isLight * 0.063) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(-170.0, 178.0), 0.0, midReach * 0.58, colorWithAlpha(u.primary, (isDark * 0.13 + isLight * 0.108) * gs), colorWithAlpha(u.accent, (isDark * 0.058 + isLight * 0.050) * gs), float4(0.0)));
    color = controlledScreen(color, beam(point, c + float2(longReach * 0.26, 10.0), float2(longReach * 1.02, 245.0), -3.14159265 / 20.0, colorWithAlpha(u.primary, 0.0), colorWithAlpha(u.primary, (isDark * 0.10 + isLight * 0.082) * gs), colorWithAlpha(u.accent, (isDark * 0.12 + isLight * 0.10) * gs), float4(0.0)));

    float beat = 0.82;
    float slow = 0.56;
    float driftX = cos(slow * 6.2831853) * (30.0 + beat * 28.0);
    float driftY = sin((slow + beat * 0.16) * 6.2831853) * (22.0 + beat * 20.0);
    float localPulse = clamp((beat - 0.32) / 0.64, 0.0, 1.0);
    // 近场跳动光斑：用 controlledPlus（彩光加亮，受 headroom 控制不过曝）。
    color = controlledPlus(color, radial3(point, c + float2(driftX * 0.70, driftY * 0.70), 0.0, 190.0 + localPulse * 68.0, colorWithAlpha(u.primary, ((isDark * 0.32 + isLight * 0.27) + localPulse * 0.10) * gs), colorWithAlpha(u.accent, (0.11 + localPulse * 0.045) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(150.0 + driftX * 0.52, 18.0 - driftY * 0.28), 0.0, 220.0 + localPulse * 60.0, colorWithAlpha(u.primary, (0.15 + localPulse * 0.050) * gs), colorWithAlpha(u.secondary, (0.085 + slow * 0.024) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(44.0 - driftX * 0.20, 164.0 + driftY * 0.42), 0.0, 170.0 + localPulse * 48.0, colorWithAlpha(u.accent, (0.13 + localPulse * 0.038) * gs), colorWithAlpha(u.primary, (0.070 + slow * 0.016) * gs), float4(0.0)));

    // 整窗玻璃层：偏专辑色，提升浅色模式的玻璃覆盖感，同时白色高光只留边缘空气。
    float strength = clamp(u.glassIntensity, 0.0, 1.0);
    color = overBlend(color, colorWithAlpha(u.glassBaseColor, (isDark * 0.30 + isLight * 0.22) * strength));
    float glassT = linearT(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    color = overBlend(color, gradient3(
        float4(1.0, 1.0, 1.0, (isDark * 0.024 + isLight * 0.020) * strength * wv),
        colorWithAlpha(u.primary, (isDark * 0.13 + isLight * 0.15) * strength),
        colorWithAlpha(u.secondary, (isDark * 0.035 + isLight * 0.040) * strength),
        glassT
    ));
    color = controlledScreen(color, radial3(point, float2(0.28, 0.24) * u.viewportSize, 0.0, 720.0, float4(1.0, 1.0, 1.0, (isDark * 0.020 + isLight * 0.026) * strength * wv), colorWithAlpha(u.glowPrimary, (isDark * 0.13 + isLight * 0.14) * strength * gs), float4(0.0)));

    beat = 0.78;
    slow = 0.54;
    driftX = cos(slow * 6.2831853) * (30.0 + beat * 28.0);
    driftY = sin((slow + beat * 0.14) * 6.2831853) * (14.0 + beat * 18.0);
    float2 nearCenter = c + float2(driftX, driftY);
    float2 rightWash = c + float2(168.0 + driftX * 0.56, 36.0 - driftY * 0.22);
    float2 lowerWash = c + float2(40.0 - driftX * 0.24, 166.0 + driftY * 0.36);
    float beamWidth = clamp(u.viewportSize.x * 0.34, 420.0, 620.0);
    color = controlledScreen(color, radial3(point, nearCenter, 0.0, 172.0 + beat * 52.0, colorWithAlpha(u.primary, ((isDark * 0.25 + isLight * 0.20) + beat * 0.065) * gs), colorWithAlpha(u.accent, (0.092 + beat * 0.032) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, rightWash, 0.0, 230.0 + beat * 52.0, colorWithAlpha(u.secondary, (0.12 + beat * 0.030) * gs), colorWithAlpha(u.primary, (0.074 + slow * 0.020) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, lowerWash, 0.0, 166.0 + beat * 40.0, colorWithAlpha(u.accent, (0.088 + beat * 0.028) * gs), colorWithAlpha(u.primary, (0.058 + slow * 0.014) * gs), float4(0.0)));
    color = controlledScreen(color, beam(point, c + float2(230.0 + driftX * 0.34, 12.0 + driftY * 0.16), float2(beamWidth, 112.0 + beat * 26.0), (-7.0 + beat * 3.2) * 3.14159265 / 180.0, float4(0.0), colorWithAlpha(u.primary, (0.042 + beat * 0.024) * gs), colorWithAlpha(u.accent, (0.052 + slow * 0.016) * gs), float4(0.0)));

    // 边缘空气感：白色高光只作为四周很窄的一圈"空气"，浅色 0.22→0.09，且仅在边缘（edgeMask）局部出现。
    float edgeDistance = min(min(point.x, point.y), min(u.viewportSize.x - point.x, u.viewportSize.y - point.y));
    float edgeMask = 1.0 - smoothstep(0.0, 1.0, edgeDistance);
    color = controlledScreen(color, float4(1.0, 1.0, 1.0, (isDark * 0.052 + isLight * 0.052) * strength * edgeMask * wv));

    // ── 出图后处理：曝光 → 高光柔压（保彩度）→ 彩度补偿 → 抖动去断层 → 防纯白 clamp ──
    color *= kExposure;
    color = softTonemap(color, kHighlightCompression);
    float outL = luminance(color);
    color = mix(float3(outL), color, kChromaBoost);          // 回补彩度（更绚丽但保留 tonemap）
    // 抖动(dithering)：大面积平滑渐变在 8bit 输出时会出现可见色彩断层（banding），
    // 加入幅度约 ±1.2/255 的有序噪声打散量化台阶，肉眼几乎不可见，但能消除断层。
    float dither = fract(sin(dot(point, float2(12.9898, 78.233))) * 43758.5453);
    color += (dither - 0.5) * (1.6 / 255.0);
    color = clamp(color, float3(0.0), float3(0.972));         // 上限略低于纯白，杜绝大片洗白
    return float4(color, 1.0);
}
"""#
}
