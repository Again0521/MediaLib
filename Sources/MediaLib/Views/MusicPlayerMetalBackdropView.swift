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
            // Keep the next texture warm even while the entrance/backdrop readiness flag is false.
            // The shader still gates usage through artworkOpacity, so song switches do not flash to gray.
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
                        targetSize: CGSize(width: 192, height: 192)
                    )
                    // 成熟音乐播放器常用的是"封面本体低分辨率大模糊"作为底层色场，
                    // 这里预先做一次较重 blur，运行时 shader 只采样小纹理并调色。
                    let blurred = MusicAlbumBackdropImageBlur.blurred(base, radius: 44) ?? base
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
    var vibrancy: Float

    init(state: MusicAlbumBackdropState, viewportSize: CGSize) {
        let palette = state.palette
        self.viewportSize = SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1)))
        self.albumLightCenter = SIMD2(Float(state.albumLightCenter.x), Float(state.albumLightCenter.y))
        // 底色用 cleanMetalBaseColor：主色定基调，辅色/强调色以 tonal 方式轻轻叠入。
        // 运行时再叠加模糊封面纹理，形成"封面高斯被玻璃盖住"的底层色场。
        let isDarkMode = state.colorScheme == .dark
        self.baseColor = Self.cleanMetalBaseColor(palette: palette, isDark: isDarkMode)
        self.glassBaseColor = Self.cleanMetalGlassBaseColor(palette: palette, isDark: isDarkMode).metalRGBA(alpha: 1)
        self.primary = Self.cleanMetalRoleColor(palette.primary, palette: palette, role: .primary, isDark: isDarkMode).metalRGBA(alpha: 1)
        self.secondary = Self.cleanMetalRoleColor(palette.secondary, palette: palette, role: .secondary, isDark: isDarkMode).metalRGBA(alpha: 1)
        self.accent = Self.cleanMetalRoleColor(palette.accent, palette: palette, role: .accent, isDark: isDarkMode).metalRGBA(alpha: 1)
        self.glowPrimary = Self.cleanMetalGlowColor(palette.glowPrimary, palette: palette, isDark: isDarkMode).metalRGBA(alpha: 1)
        self.glowSecondary = Self.cleanMetalGlowColor(palette.glowSecondary, palette: palette, isDark: isDarkMode).metalRGBA(alpha: 1)
        self.glowAccent = Self.cleanMetalGlowColor(palette.glowAccent, palette: palette, isDark: isDarkMode).metalRGBA(alpha: 1)
        self.glassIntensity = Float(min(max(state.glassIntensity, 0), 1))
        // 让模糊封面纹理重新成为底板主成分之一：彩色封面更像专辑图被玻璃遮住后糊开，
        // 低彩封面保留更克制权重，避免白/灰图直接洗成白雾。
        let artworkVibrancy = min(max(palette.vibrancy, 0), 1)
        let artworkBase = isDarkMode ? 0.38 : 0.30
        let artworkLift = isDarkMode ? 0.16 : 0.16
        self.artworkOpacity = state.artworkReady ? Float(artworkBase + artworkLift * pow(artworkVibrancy, 0.72)) : 0
        self.isDark = isDarkMode ? 1 : 0
        self.vibrancy = Float(min(max(palette.vibrancy, 0), 1))
    }

    private enum PaletteRole {
        case primary
        case secondary
        case accent
    }

    /// 干净底色：借鉴 Material tonal palette / Vibrant swatch 的思路，先让每个封面色进入可控的明度、
    /// 饱和度区间，再由主色定基底，辅色/强调色只作为轻量色场参与。避免互补色直接 RGB 平均后变灰发脏。
    private static func cleanMetalBaseColor(palette: AlbumColorPalette, isDark: Bool) -> SIMD4<Float> {
        let primary = cleanMetalRoleColor(palette.primary, palette: palette, role: .primary, isDark: isDark)
        let secondary = cleanMetalRoleColor(palette.secondary, palette: palette, role: .secondary, isDark: isDark)
        let accent = cleanMetalRoleColor(palette.accent, palette: palette, role: .accent, isDark: isDark)
        let lowVibrancy = palette.vibrancy < 0.32
        var mixed = primary
        mixed = mixRGB(mixed, secondary, amount: lowVibrancy ? 0.060 : 0.170)
        mixed = mixRGB(mixed, accent, amount: lowVibrancy ? 0.045 : 0.130)
        let pearl = isDark
            ? NSColor(calibratedRed: 0.060, green: 0.066, blue: 0.080, alpha: 1)
            : NSColor(calibratedRed: 0.760, green: 0.795, blue: 0.815, alpha: 1)
        mixed = mixRGB(mixed, pearl, amount: isDark ? 0.045 : 0.085)
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var al: CGFloat = 0
        mixed.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &al)
        let cleanedSat: CGFloat
        let cleanedBri: CGFloat
        if isDark {
            cleanedSat = lowVibrancy
                ? min(max(sat * 0.58, 0.0), 0.13)
                : min(max(sat * 0.88, 0.21), 0.46)
            cleanedBri = lowVibrancy
                ? min(max(bri, 0.18), 0.31)
                : min(max(bri * 0.92, 0.18), 0.32)
        } else {
            cleanedSat = lowVibrancy
                ? min(max(sat * 0.52, 0.0), 0.10)
                : min(max(sat * 0.80, sat < 0.035 ? sat : 0.165), 0.36)
            cleanedBri = lowVibrancy
                ? min(max(bri, 0.76), 0.88)
                : min(max(bri * 0.98, 0.68), 0.82)
        }
        let cleaned = NSColor(calibratedHue: hue, saturation: cleanedSat, brightness: cleanedBri, alpha: 1)
        let rgb = cleaned.usingColorSpace(.deviceRGB) ?? cleaned
        return SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
    }

    private static func cleanMetalGlassBaseColor(palette: AlbumColorPalette, isDark: Bool) -> NSColor {
        let baseComponents = cleanMetalBaseColor(palette: palette, isDark: isDark)
        let base = NSColor(
            calibratedRed: CGFloat(baseComponents.x),
            green: CGFloat(baseComponents.y),
            blue: CGFloat(baseComponents.z),
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            calibratedHue: hue,
            saturation: min(max(saturation * (isDark ? 0.76 : 0.64), 0.0), isDark ? 0.30 : 0.24),
            brightness: min(max(brightness * (isDark ? 1.08 : 1.03), isDark ? 0.22 : 0.74), isDark ? 0.37 : 0.88),
            alpha: 1
        )
    }

    private static func cleanMetalRoleColor(
        _ source: AlbumPaletteColor,
        palette: AlbumColorPalette,
        role: PaletteRole,
        isDark: Bool
    ) -> NSColor {
        let color = source.nsColor
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let vibrancy = CGFloat(min(max(palette.vibrancy, 0), 1))
        let lowColor = palette.vibrancy < 0.32 || saturation < 0.12
        let roleSatOffset: CGFloat = {
            switch role {
            case .primary: return 0.000
            case .secondary: return -0.018
            case .accent: return 0.018
            }
        }()
        let roleBrightness: CGFloat = {
            switch role {
            case .primary: return 1.00
            case .secondary: return isDark ? 1.08 : 1.04
            case .accent: return isDark ? 0.98 : 0.96
            }
        }()
        let cleanedSaturation: CGFloat
        if lowColor {
            cleanedSaturation = min(max(saturation * 0.58, 0.0), isDark ? 0.16 : 0.12)
        } else {
            let scaled = saturation * (isDark ? 0.76 : 0.64) + vibrancy * (isDark ? 0.042 : 0.034) + roleSatOffset
            cleanedSaturation = min(max(scaled, isDark ? 0.21 : 0.16), isDark ? 0.54 : 0.42)
        }
        let cleanedBrightness: CGFloat
        if isDark {
            cleanedBrightness = lowColor
                ? min(max(brightness * 0.92, 0.22), 0.42)
                : min(max(brightness * 0.84 * roleBrightness, 0.23), 0.45)
        } else {
            cleanedBrightness = lowColor
                ? min(max(brightness * 1.02, 0.72), 0.90)
                : min(max(brightness * 1.00 * roleBrightness, 0.60), 0.84)
        }
        return NSColor(calibratedHue: hue, saturation: cleanedSaturation, brightness: cleanedBrightness, alpha: 1)
    }

    private static func cleanMetalGlowColor(_ source: AlbumPaletteColor, palette: AlbumColorPalette, isDark: Bool) -> NSColor {
        let color = source.nsColor
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let lowColor = palette.vibrancy < 0.32 || saturation < 0.12
        let glowSaturation = lowColor
            ? min(max(saturation * 0.72, 0.0), isDark ? 0.20 : 0.16)
            : min(max(saturation * (isDark ? 0.78 : 0.68), isDark ? 0.24 : 0.18), isDark ? 0.64 : 0.56)
        let glowBrightness = isDark
            ? min(max(brightness * 1.08, 0.60), 0.86)
            : min(max(brightness * 1.02, 0.68), 0.90)
        return NSColor(calibratedHue: hue, saturation: glowSaturation, brightness: glowBrightness, alpha: 1)
    }

    private static func mixRGB(_ lhs: NSColor, _ rhs: NSColor, amount: CGFloat) -> NSColor {
        let a = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let b = rhs.usingColorSpace(.deviceRGB) ?? rhs
        let t = min(max(amount, 0), 1)
        return NSColor(
            calibratedRed: a.redComponent * (1 - t) + b.redComponent * t,
            green: a.greenComponent * (1 - t) + b.greenComponent * t,
            blue: a.blueComponent * (1 - t) + b.blueComponent * t,
            alpha: 1
        )
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

    /// 把封面渲染成一块"颜料调色盘"小纹理（取代旧的"高分辨率大模糊封面"）：
    ///   1) Lanczos 大幅下采样到 grid×grid —— 每个 texel 就是封面对应区域的一抹平均颜料，
    ///      所有可辨识的图像结构（人脸/文字/边缘）被丢弃，从源头消除"玻璃直接盖在封面上"的观感；
    ///   2) 在小图坐标系里做一次轻高斯，把相邻颜料块揉开 —— 上传后 GPU 双线性再插值，
    ///      得到完全平滑、无重影的低频色场，根除旧的多尺度采样造成的不均匀色斑；
    ///   3) 回补饱和度 + 轻微 vibrance —— 抵消"下采样平均必然发灰"的脏感，让调色盘保持封面的鲜活。
    /// 纹理虽小，但因为保留了封面的空间布局（上/下/左/右的颜料位置），底板仍"贴合封面"。
    static func paintPalette(_ image: NSImage?, grid: Int = 40, soften: Double = 8) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        // ① 下采样为"颜料网格"。
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

        // ② 轻高斯揉开颜料块（小坐标系里 soften 很小即可）。
        if soften > 0, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(working.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(soften, forKey: kCIInputRadiusKey)
            working = blur.outputImage ?? working
        }

        // ③ 回补饱和度，抵消平均带来的发灰；vibrance 只补低饱和区，避免高饱和区过艳。
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(working, forKey: kCIInputImageKey)
            controls.setValue(1.18, forKey: kCIInputSaturationKey)
            working = controls.outputImage ?? working
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(working, forKey: kCIInputImageKey)
            vibrance.setValue(0.20, forKey: "inputAmount")
            working = vibrance.outputImage ?? working
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

// ───────────────── 背景观感调参（集中管理的"调试参数"）─────────────────
// 调这几个常量即可整体调节背景：曝光 / 光效强度 / 白色总量 / 彩度 / 高光压缩。
constant float kExposure             = 1.000; // 整体曝光（>1 提亮，<1 压暗）
constant float kGlowStrength         = 1.20;  // 受控专辑彩光总强度
constant float kWhiteVeilStrength    = 0.46;  // 所有白色 veil/高光的总闸（压掉白雾）
constant float kChromaBoost          = 1.18;  // 出图前彩度补偿（绚丽但不过艳）
constant float kHighlightCompression = 0.96;  // 高光压缩强度（越大越压，越不易过曝）

static float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

static float3 boostChroma(float3 c, float amount) {
    float L = luminance(c);
    return clamp(mix(float3(L), c, amount), float3(0.0), float3(1.0));
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

static float3 glassifyAlbumColor(float3 c, float3 semanticTint, float vibrancy, float isDark) {
    float L = luminance(c);
    float chroma = length(c - float3(L));
    float lowChroma = 1.0 - smoothstep(0.030, 0.150, chroma);
    float3 pearl = mix(float3(0.760, 0.790, 0.812), float3(0.058, 0.064, 0.078), isDark);
    float minL = mix(0.58, 0.18, isDark);
    float maxL = mix(0.86, 0.66, isDark);
    float Lt = clamp(L, minL, maxL);
    float3 toned = c * (Lt / max(L, 0.001));
    toned = mix(toned, pearl, lowChroma * (0.24 - vibrancy * 0.10));
    toned = mix(toned, semanticTint, (0.075 + vibrancy * 0.085) * (1.0 - lowChroma * 0.42));
    float chromaAmount = mix(0.90, 1.14, vibrancy) * (1.0 - lowChroma * 0.14);
    return boostChroma(softTonemap(toned, 0.36), chromaAmount);
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
    float vibrancy = clamp(u.vibrancy, 0.0, 1.0);
    float lowFlow = valueNoise(uv * float2(2.05, 1.55) + float2(0.17, 0.41));
    float crossFlow = valueNoise(uv * float2(3.10, 2.35) + float2(2.31, 1.67));
    float2 refractOffset = (float2(lowFlow, crossFlow) - 0.5) * (0.006 + vibrancy * 0.004);
    float3 color = u.baseColor.rgb;

    float wv = kWhiteVeilStrength;

    // 玻璃下方的主色场：成熟播放器通常不是只铺 dominant color，而是把专辑图低分辨率大模糊后作为背景。
    // 这里在预模糊小纹理上做三次不同尺度采样，合成一个更像"封面高斯被玻璃遮住"的低频色场。
    float2 artUV = (uv - 0.5) / (1.12 + lowFlow * 0.040) + 0.5 + refractOffset * 0.34;
    float2 artUVWide = (uv - 0.5) / (0.86 + crossFlow * 0.030) + 0.5 - refractOffset * 0.22;
    float2 artUVDrift = (uv - 0.5) / (1.46 + lowFlow * 0.050) + 0.5 + float2(0.035, -0.028) + refractOffset * 0.18;
    float4 artSampleA = artwork.sample(artworkSampler, artUV);
    float4 artSampleB = artwork.sample(artworkSampler, artUVWide);
    float4 artSampleC = artwork.sample(artworkSampler, artUVDrift);
    float artPresence = max(max(artSampleA.a, artSampleB.a), artSampleC.a);
    float effectiveArtworkOpacity = u.artworkOpacity * artPresence;
    float3 albumField = mix(mix(artSampleA.rgb, artSampleB.rgb, 0.42), artSampleC.rgb, 0.30);
    // Palette 色只做语义调色：primary 定基调，secondary/accent 给高斯场补冷暖层次；低彩封面自动降低染色。
    float3 semanticTint = mix(u.primary.rgb, mix(u.secondary.rgb, u.accent.rgb, 0.42), 0.34 + vibrancy * 0.12);
    albumField = glassifyAlbumColor(albumField, semanticTint, vibrancy, isDark);
    float3 albumToned = mix(albumField, semanticTint, (0.040 + vibrancy * 0.070) * effectiveArtworkOpacity);
    color = overBlend(color, float4(albumToned, effectiveArtworkOpacity));
    color = controlledScreen(color, float4(boostChroma(albumField, 1.02 + vibrancy * 0.12), effectiveArtworkOpacity * (isDark * 0.20 + isLight * 0.145)));

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

    float meshSpan = max(u.viewportSize.x, u.viewportSize.y);

    // Album-color backdrop: keep the primary color strongest near the artwork, then let secondary/accent
    // drift toward the quiet right side. Low-vibrancy artwork gets shorter, cleaner color travel.
    float albumReachScale = 0.78 + vibrancy * 0.30;
    color = controlledScreen(color, radial3(
        point,
        u.albumLightCenter + float2(-18.0, -10.0),
        0.0,
        max(540.0, meshSpan * 0.58) * albumReachScale,
        colorWithAlpha(u.glowPrimary, (isDark * 0.28 + isLight * 0.24) * (0.58 + vibrancy * 0.42)),
        colorWithAlpha(u.primary, (isDark * 0.14 + isLight * 0.12) * (0.52 + vibrancy * 0.38)),
        float4(0.0)
    ));
    color = controlledScreen(color, radial3(
        point,
        float2(0.73 + lowFlow * 0.05, 0.28 + crossFlow * 0.05) * u.viewportSize,
        0.0,
        max(620.0, meshSpan * 0.66),
        colorWithAlpha(u.secondary, (isDark * 0.24 + isLight * 0.20) * (0.54 + vibrancy * 0.36)),
        colorWithAlpha(u.accent, (isDark * 0.09 + isLight * 0.075) * (0.45 + vibrancy * 0.28)),
        float4(0.0)
    ));
    color = overBlend(color, radial3(
        point,
        float2(0.92 - lowFlow * 0.03, 0.76 + crossFlow * 0.04) * u.viewportSize,
        0.0,
        max(520.0, meshSpan * 0.54),
        colorWithAlpha(u.accent, (isDark * 0.16 + isLight * 0.12) * (0.42 + vibrancy * 0.35)),
        colorWithAlpha(u.secondary, (isDark * 0.055 + isLight * 0.046) * (0.42 + vibrancy * 0.24)),
        float4(0.0)
    ));

    // Apple Music 式多色网格：主/辅/强调色作为大柔光斑铺满四角与中心。
    // 用 controlledPlus 受控加光：在中/暗调区显现绚丽彩光，亮区因 headroom 衰减不会被推白。
    float blobReach = max(meshSpan * 0.66, 680.0);
    float gs = kGlowStrength;
    // §4.3 mesh blobs 颜色一律走 glow*（lightenedForGlow：最低亮度有保证、饱和≤0.80、严格保色相），
    // 深色专辑也不发脏暗光；绚丽来自这些柔光斑而非底板。
    color = controlledPlus(color, radial2(point, float2(0.82, 0.14) * u.viewportSize, 0.0, blobReach, colorWithAlpha(u.glowSecondary, (isDark * 0.46 + isLight * 0.48) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.90, 0.84) * u.viewportSize, 0.0, blobReach * 1.04, colorWithAlpha(u.glowAccent, (isDark * 0.42 + isLight * 0.44) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.10, 0.88) * u.viewportSize, 0.0, blobReach * 0.98, colorWithAlpha(u.glowPrimary, (isDark * 0.46 + isLight * 0.44) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.15, 0.16) * u.viewportSize, 0.0, blobReach * 0.92, colorWithAlpha(u.glowPrimary, (isDark * 0.30 + isLight * 0.30) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.50, 0.48) * u.viewportSize, 0.0, blobReach * 1.14, colorWithAlpha(u.glowSecondary, (isDark * 0.22 + isLight * 0.20) * gs), float4(0.0)));
    // §4.2 第 4 个柔光斑：颜色取 secondary 与 accent 的中间插值（着色器内 mix 0.5），丰富多色层次；
    // 仍走 glow* 体系，色相严格落在 secondary/accent 之间，绝不做 hue 偏移。
    float4 blobMix = mix(u.glowSecondary, u.glowAccent, 0.5);
    color = controlledPlus(color, radial2(point, float2(0.36, 0.72) * u.viewportSize, 0.0, blobReach * 1.02, colorWithAlpha(blobMix, (isDark * 0.26 + isLight * 0.26) * gs), float4(0.0)));

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

    // 整窗玻璃层：偏专辑色，白色高光只留边缘空气。
    float strength = clamp(u.glassIntensity, 0.0, 1.0);
    color = overBlend(color, colorWithAlpha(u.glassBaseColor, (isDark * 0.30 + isLight * 0.115) * strength));
    float glassT = linearT(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    color = overBlend(color, gradient3(
        float4(1.0, 1.0, 1.0, (isDark * 0.024 + isLight * 0.020) * strength * wv),
        colorWithAlpha(u.primary, (isDark * 0.13 + isLight * 0.15) * strength),
        colorWithAlpha(u.secondary, (isDark * 0.035 + isLight * 0.040) * strength),
        glassT
    ));
    color = controlledScreen(color, radial3(point, float2(0.28, 0.24) * u.viewportSize, 0.0, 720.0, float4(1.0, 1.0, 1.0, (isDark * 0.020 + isLight * 0.026) * strength * wv), colorWithAlpha(u.glowPrimary, (isDark * 0.13 + isLight * 0.14) * strength * gs), float4(0.0)));

    // Continuous full-screen Liquid Glass overlay. The "refraction" is a soft color-space ripple over the
    // album backdrop, not a behind-window blur, so it stays opaque and cheap.
    float liquidWave = sin((uv.x * 1.75 + uv.y * 2.25 + lowFlow * 0.72) * 6.2831853) * 0.5 + 0.5;
    float liquidBand = smoothstep(0.50, 0.92, liquidWave) * (1.0 - smoothstep(0.86, 1.0, liquidWave));
    float glassChroma = (0.020 + vibrancy * 0.026) * strength;
    color = controlledScreen(color, colorWithAlpha(mix(u.primary, u.secondary, lowFlow), glassChroma * liquidBand * (isDark * 1.08 + isLight * 0.82)));
    color = overBlend(color, colorWithAlpha(u.glowAccent, (isDark * 0.040 + isLight * 0.030) * strength * crossFlow * (0.55 + vibrancy * 0.35)));
    float refractiveLift = (lowFlow - 0.5) * (isDark * 0.030 + isLight * 0.020) * strength;
    color = mix(color, color + color * refractiveLift, 0.55);

    // §1.1 整片镜面高光带：一条贯穿全窗、极低对比的斜向高光，方向由封面光心(albumLightCenter)指向窗口对侧
    //（光从封面方向斜扫过玻璃）。只在窗口对角线中段出现、两端淡出为 0，让人感到"有一块玻璃盖在彩色底上"，
    // 而不是颜色本身在变。强度上限：浅色 ≤0.05、深色 ≤0.035（再经 strength*wv 全局衰减）。
    float2 sweepUV = uv + refractOffset;
    float2 sweepLC = u.albumLightCenter / u.viewportSize;
    float2 sweepDir = normalize(float2(1.0, 0.62));
    float sweepAlong = dot(sweepUV - sweepLC, sweepDir);
    float sweepAcross = dot(sweepUV - sweepLC, float2(-sweepDir.y, sweepDir.x));
    float sweepBand = exp(-sweepAcross * sweepAcross / 0.0026);            // 垂直轴方向的窄高光带
    float sweepMid = smoothstep(-0.55, -0.05, sweepAlong) *
                     (1.0 - smoothstep(0.18, 0.72, sweepAlong));          // 中段出现、两端淡出为 0
    float sweepSpecular = sweepBand * sweepMid;
    color = controlledScreen(color, float4(1.0, 1.0, 1.0, sweepSpecular * (isDark * 0.035 + isLight * 0.050) * strength * wv));

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

    // 整窗连续玻璃面板的纵向深度：顶部极轻提亮、底部极轻压暗，让整块玻璃有"上沿受光、下沿入影"的
    // 空间层次（Liquid Glass 的轻微深度阴影）。幅度克制（约 1.5%~5%），浅色更弱，不改变色相、不洗白。
    float depthT = clamp(uv.y, 0.0, 1.0);
    float topLift = (1.0 - smoothstep(0.0, 0.52, depthT)) * (isDark * 0.020 + isLight * 0.013) * strength;
    float bottomShade = smoothstep(0.56, 1.0, depthT) * (isDark * 0.050 + isLight * 0.030) * strength;
    color = controlledScreen(color, float4(1.0, 1.0, 1.0, topLift * wv));
    color *= (1.0 - bottomShade);

    // ── 出图后处理：曝光 → 高光柔压（保彩度）→ 彩度补偿 → 抖动去断层 → 防纯白 clamp ──
    color *= kExposure;
    color = softTonemap(color, kHighlightCompression);
    float outL = luminance(color);
    color = mix(float3(outL), color, kChromaBoost);          // 回补彩度（更绚丽但保留 tonemap）
    // 抖动(dithering)：大面积平滑渐变在 8bit 输出时会出现可见色彩断层（banding），
    // 加入幅度约 ±1.2/255 的有序噪声打散量化台阶，肉眼几乎不可见，但能消除断层。
    float dither = fract(sin(dot(point, float2(12.9898, 78.233))) * 43758.5453);
    float grain = hash21(floor(point * 0.72) + float2(5.17, 9.31)) - 0.5;
    color += (dither - 0.5) * (1.35 / 255.0);
    color += grain * (0.52 / 255.0) * (0.50 + vibrancy * 0.40);
    color = clamp(color, float3(0.0), float3(0.972));         // 上限略低于纯白，杜绝大片洗白
    return float4(color, 1.0);
}
"""#
}
