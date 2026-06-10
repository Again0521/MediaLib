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
                    let base: NSImage?
#if DEBUG
                    if let debugCover = MusicPlayerVisualDebugFixtures.coverImage(forPath: path, size: 160) {
                        base = debugCover
                    } else {
                        base = ArtworkImageCache.image(
                            path: path,
                            targetSize: CGSize(width: 160, height: 160)
                        )
                    }
#else
                    base = ArtworkImageCache.image(
                        path: path,
                        targetSize: CGSize(width: 160, height: 160)
                    )
#endif
                    // 提取低频专辑颜料场作为底板主色源；palette 只做轻微校色。
                    // 色场先小网格重采样再低半径柔化，保留专辑多色关系但去掉文字/锐边/噪点。
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
        // 文档要求 albumField 成为底板主色源；palette 只轻校色，因此这里按彩度区分纹理权重。
        // 彩色封面：dark/light 都让低频封面色场占主体；低彩封面也保留足够权重，避免退回灰底。
        let artworkVibrancy = min(max(palette.vibrancy, 0), 1)
        let colorfulness = min(max((artworkVibrancy - 0.24) / 0.46, 0), 1)
        let lowOpacity = (isDarkMode ? 0.50 : 0.46) + (isDarkMode ? 0.10 : 0.10) * artworkVibrancy
        let colorfulOpacity = (isDarkMode ? 0.78 : 0.72) + (isDarkMode ? 0.10 : 0.10) * pow(artworkVibrancy, 0.72)
        let opacity = lowOpacity * (1 - colorfulness) + colorfulOpacity * colorfulness
        self.artworkOpacity = state.artworkReady ? Float(opacity) : 0
        self.isDark = isDarkMode ? 1 : 0
        self.vibrancy = Float(min(max(palette.vibrancy, 0), 1))
    }

    private enum PaletteRole {
        case primary
        case secondary
        case accent
    }

    private static func warmRedRisk(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGFloat {
        let h = Double(hue)
        let redOrangeRisk: Double
        if h >= 0.94 || h <= 0.055 {
            redOrangeRisk = 1
        } else if h < 0.125 {
            redOrangeRisk = max(0, (0.125 - h) / 0.070)
        } else {
            redOrangeRisk = 0
        }
        let satRisk = min(max((Double(saturation) - 0.14) / 0.40, 0), 1)
        let briRisk = min(max((Double(brightness) - 0.28) / 0.54, 0), 1)
        return CGFloat(redOrangeRisk * satRisk * briRisk)
    }

    /// 干净底色：借鉴 Material tonal palette / Vibrant swatch 的思路，先让每个封面色进入可控的明度、
    /// 饱和度区间，再由主色定基底，辅色/强调色只作为轻量色场参与。避免互补色直接 RGB 平均后变灰发脏。
    private static func cleanMetalBaseColor(palette: AlbumColorPalette, isDark: Bool) -> SIMD4<Float> {
        let primary = cleanMetalRoleColor(palette.primary, palette: palette, role: .primary, isDark: isDark)
        let secondary = cleanMetalRoleColor(palette.secondary, palette: palette, role: .secondary, isDark: isDark)
        let accent = cleanMetalRoleColor(palette.accent, palette: palette, role: .accent, isDark: isDark)
        let lowVibrancy = palette.vibrancy < 0.32
        var mixed = primary
        // 底色保持"干净的主色基调"：secondary/accent 只轻轻掺入定基底，多色层次交给上层的
        // 颜料色场与定位渐变去呈现。掺入过多互补色会在 RGB 平均后发灰发脏（旧 0.170/0.130 偏重）。
        mixed = mixRGB(mixed, secondary, amount: lowVibrancy ? 0.055 : 0.120)
        mixed = mixRGB(mixed, accent, amount: lowVibrancy ? 0.040 : 0.085)
        let pearl = isDark
            ? NSColor(calibratedRed: 0.060, green: 0.066, blue: 0.080, alpha: 1)
            : NSColor(calibratedRed: 0.820, green: 0.858, blue: 0.872, alpha: 1)
        mixed = mixRGB(mixed, pearl, amount: isDark ? 0.045 : 0.050)
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var al: CGFloat = 0
        mixed.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &al)
        let cleanedSat: CGFloat
        let cleanedBri: CGFloat
        // 底板保持克制，绚丽感交给后续 mesh blobs；这里过饱和会让整窗底色发脏发怪。
        if isDark {
            cleanedSat = lowVibrancy
                ? min(max(sat * 0.60, 0.0), 0.15)
                : min(max(sat * 0.71, 0.19), 0.34)
            cleanedBri = lowVibrancy
                ? min(max(bri, 0.18), 0.31)
                : min(max(bri * 0.90, 0.17), 0.29)
        } else {
            cleanedSat = lowVibrancy
                ? min(max(sat * 0.54, 0.0), 0.12)
                : min(max(sat * 0.60, sat < 0.035 ? sat : 0.13), 0.235)
            cleanedBri = lowVibrancy
                ? min(max(bri, 0.80), 0.90)
                : min(max(bri * 0.96, 0.64), 0.80)
        }
        let warmRisk = warmRedRisk(hue: hue, saturation: sat, brightness: bri)
        let cleaned = NSColor(
            calibratedHue: hue,
            saturation: cleanedSat * (1 - warmRisk * (isDark ? 0.12 : 0.24)),
            brightness: cleanedBri,
            alpha: 1
        )
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
            saturation: min(max(saturation * (isDark ? 0.80 : 0.68), 0.0), isDark ? 0.32 : 0.26),
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
        // 角色色用于柔光斑和语义染色，保持可读即可；不能把整窗推成高饱和底。
        let cleanedSaturation: CGFloat
        if lowColor {
            cleanedSaturation = min(max(saturation * 0.61, 0.0), isDark ? 0.17 : 0.14)
        } else {
            let scaled = saturation * (isDark ? 0.71 : 0.66) + vibrancy * (isDark ? 0.024 : 0.026) + roleSatOffset
            cleanedSaturation = min(max(scaled, isDark ? 0.16 : 0.14), isDark ? 0.48 : 0.42)
        }
        let cleanedBrightness: CGFloat
        if isDark {
            cleanedBrightness = lowColor
                ? min(max(brightness * 0.92, 0.22), 0.42)
                : min(max(brightness * 0.84 * roleBrightness, 0.23), 0.47)
        } else {
            cleanedBrightness = lowColor
                ? min(max(brightness * 1.02, 0.72), 0.90)
                : min(max(brightness * 0.98 * roleBrightness, 0.46), 0.80)
        }
        let warmRisk = warmRedRisk(hue: hue, saturation: saturation, brightness: brightness)
        return NSColor(
            calibratedHue: hue,
            saturation: cleanedSaturation * (1 - warmRisk * (isDark ? 0.08 : 0.15)),
            brightness: cleanedBrightness,
            alpha: 1
        )
    }

    private static func cleanMetalGlowColor(_ source: AlbumPaletteColor, palette: AlbumColorPalette, isDark: Bool) -> NSColor {
        let color = source.nsColor
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let lowColor = palette.vibrancy < 0.32 || saturation < 0.12
        // 发光色可比底板更鲜明，但仍需克制，避免浅色模式出现霓虹色块。
        var glowSaturation = lowColor
            ? min(max(saturation * 0.69, 0.0), isDark ? 0.21 : 0.17)
            : min(max(saturation * (isDark ? 0.69 : 0.61), isDark ? 0.19 : 0.16), isDark ? 0.52 : 0.46)
        glowSaturation *= 1 - warmRedRisk(hue: hue, saturation: saturation, brightness: brightness) * (isDark ? 0.08 : 0.14)
        let glowBrightness = isDark
            ? min(max(brightness * 1.04, 0.56), 0.80)
            : min(max(brightness * 0.96, 0.58), 0.82)
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

    /// 提取封面的低频空间色场：约 160px 输入 → 约 38px 网格 → 中等半径柔化。
    /// 它是 Metal 底板的主色来源；palette 只做轻微校色，形成更柔和的高斯取色玻璃底。
    static func paintPalette(_ image: NSImage?, grid: Int = 38, soften: Double = 15.0) -> NSImage? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        // ① 下采样到中等低频网格，丢弃文字/边缘等锐结构，但保留封面的多色区域关系。
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

        // ② 在小坐标系里进一步揉开，保留多彩关系，避免 raw cover 大模糊造成泥色。
        if soften > 0, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(working.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(soften, forKey: kCIInputRadiusKey)
            working = blur.outputImage ?? working
        }

        // ③ 不再回补鲜艳度，只保留轻微清洁化。底板需要像被玻璃揉开的颜料，
        // 不能比封面更艳，也不能把黑场和文字边缘揉成脏色。
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(working, forKey: kCIInputImageKey)
            controls.setValue(1.020, forKey: kCIInputSaturationKey)
            controls.setValue(0.006, forKey: kCIInputBrightnessKey)
            controls.setValue(0.90, forKey: kCIInputContrastKey)
            working = controls.outputImage ?? working
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(working, forKey: kCIInputImageKey)
            vibrance.setValue(0.080, forKey: "inputAmount")
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
constant float kExposure             = 1.004; // 整体曝光（>1 提亮，<1 压暗）
constant float kGlowStrength         = 0.56;  // 专辑彩光总强度；范围更大但强度更低，避免底板抢过封面
constant float kWhiteVeilStrength    = 0.074; // 白色 veil 只保留极少镜面空气感，主受光交给专辑色
constant float kChromaBoost          = 1.06;  // 出图前彩度补偿；避免大面积高饱和刺眼
constant float kHighlightCompression = 0.96;  // 高光压缩强度（越大越压，越不易过曝）

static float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

static float3 srgbToLinear(float3 c) {
    return pow(clamp(c, float3(0.0), float3(1.0)), float3(2.2));
}

static float3 linearToSRGB(float3 c) {
    return pow(clamp(c, float3(0.0), float3(1.0)), float3(1.0 / 2.2));
}

static float4 linearColor(float4 c) {
    return float4(srgbToLinear(c.rgb), c.a);
}

static float3 boostChroma(float3 c, float amount) {
    float L = luminance(c);
    return clamp(mix(float3(L), c, amount), float3(0.0), float3(1.0));
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

static float3 harmonicShift(float3 color, float hueDelta, float saturationScale, float valueScale) {
    float3 hsv = rgb2hsv(clamp(color, float3(0.0), float3(1.0)));
    hsv.x = fract(hsv.x + hueDelta);
    hsv.y = clamp(hsv.y * saturationScale, 0.0, 0.70);
    hsv.z = clamp(hsv.z * valueScale, 0.0, 0.94);
    float3 shifted = hsv2rgb(hsv);
    float originalL = max(luminance(color), 0.001);
    float shiftedL = max(luminance(shifted), 0.001);
    float targetL = mix(originalL, shiftedL, 0.42);
    return clamp(shifted * (targetL / shiftedL), float3(0.0), float3(1.0));
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
    float darkInk = 1.0 - smoothstep(0.060, 0.240, L);
    float3 pearl = mix(float3(0.820, 0.858, 0.872), float3(0.058, 0.064, 0.078), isDark);
    // 只把低频封面纹理清洁成色温场：亮/中色可以舒适抬起，
    // 近黑区域则进入干净阴影，不能被硬抬成“会发光”的亮色块。
    float litMinL = mix(0.54, 0.13, isDark);
    float inkMinL = mix(0.32, 0.075, isDark);
    float minL = mix(litMinL, inkMinL, darkInk);
    float maxL = mix(0.84, 0.50, isDark);
    float Lt = clamp(L, minL, maxL);
    float3 toned = c * (Lt / max(L, 0.001));
    float3 quietTint = mix(semanticTint, pearl, 0.28 + lowChroma * 0.18);
    float3 inkShade = mix(pearl * mix(0.74, 0.62, isDark), semanticTint, 0.10 + vibrancy * 0.10);
    toned = mix(toned, inkShade, darkInk * (0.58 - vibrancy * 0.10));
    toned = mix(toned, pearl, lowChroma * (0.16 - vibrancy * 0.05));
    toned = mix(toned, semanticTint, (0.024 + vibrancy * 0.024) * (1.0 - lowChroma * 0.66) * (1.0 - darkInk * 0.38));

    // 棕绿/灰棕低频混合最容易显脏：轻轻拉回干净 pearl 与语义色之间，不凭空造新色。
    float3 hsv = rgb2hsv(toned);
    float warmMudHue = smoothstep(0.075, 0.130, hsv.x) * (1.0 - smoothstep(0.225, 0.310, hsv.x));
    float greenMudHue = smoothstep(0.215, 0.285, hsv.x) * (1.0 - smoothstep(0.355, 0.430, hsv.x));
    float mudBody = smoothstep(0.10, 0.36, hsv.y) * smoothstep(0.18, 0.42, hsv.z) * (1.0 - smoothstep(0.58, 0.82, hsv.z));
    float mudRisk = max(warmMudHue, greenMudHue * 0.80) * mudBody;
    toned = mix(toned, mix(pearl, semanticTint, 0.22 + vibrancy * 0.14), mudRisk * (isDark * 0.22 + (1.0 - isDark) * 0.46));
    float lowVibrancyClean = (1.0 - smoothstep(0.24, 0.52, vibrancy)) * (1.0 - isDark);
    float3 cleanWash = mix(pearl, semanticTint, 0.18 + vibrancy * 0.10);
    toned = mix(toned, cleanWash, lowVibrancyClean * (0.10 + lowChroma * 0.12 + mudRisk * 0.24));

    float chromaAmount = mix(0.92, 1.07, vibrancy) * (1.0 - lowChroma * 0.22) * (1.0 - darkInk * 0.30);
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
    float4 baseColor = linearColor(u.baseColor);
    float4 glassBaseColor = linearColor(u.glassBaseColor);
    float4 primary = linearColor(u.primary);
    float4 secondary = linearColor(u.secondary);
    float4 accent = linearColor(u.accent);
    float4 glowPrimary = linearColor(u.glowPrimary);
    float4 glowSecondary = linearColor(u.glowSecondary);
    float4 glowAccent = linearColor(u.glowAccent);
    float harmonicDrift = (lowFlow - 0.5) * 0.018 + (crossFlow - 0.5) * 0.012;
    float3 backdropPrimary = harmonicShift(primary.rgb, 0.030 + harmonicDrift, 0.82, 0.97);
    float3 backdropSecondary = harmonicShift(secondary.rgb, -0.045 + harmonicDrift * 0.70, 0.80, 1.02);
    float3 backdropAccent = harmonicShift(accent.rgb, 0.064 - harmonicDrift * 0.55, 0.76, 0.96);
    float whiteSpecular = clamp(0.18 - vibrancy * 0.06, 0.10, 0.18);
    float3 glassLightColor = mix(glowPrimary.rgb, float3(1.0), whiteSpecular);
    float3 color = baseColor.rgb;

    float wv = kWhiteVeilStrength;

    // ── L0 底板主色场：封面高斯取色层 ──
    // artwork 传入的不是原始封面，而是 paintPalette 生成的低频高斯色场。这里把它拉满整窗，
    // 再通过 glassifyAlbumColor 做明度/彩度清洁；palette 只轻微校色，不能替代封面空间颜色。
    float2 fieldUV = uv + refractOffset * 0.6;
    float fieldDiag = linearT(fieldUV, float2(0.04, -0.02), float2(0.96, 1.02));
    float3 fieldMid = mix(backdropPrimary, backdropSecondary, 0.60);
    float3 semanticField = (fieldDiag < 0.5)
        ? mix(backdropPrimary, fieldMid, fieldDiag * 2.0)
        : mix(fieldMid, backdropSecondary, (fieldDiag - 0.5) * 2.0);
    float fieldCross = linearT(fieldUV, float2(1.02, 0.02), float2(-0.02, 0.98));
    semanticField = mix(semanticField, backdropAccent, fieldCross * (0.12 + vibrancy * 0.10));
    float fieldFocus = 1.0 - radialT(point, u.albumLightCenter, 0.0, max(u.viewportSize.x, u.viewportSize.y) * 0.96);
    semanticField = mix(semanticField, mix(backdropPrimary, semanticField, 0.46), fieldFocus * (0.16 + vibrancy * 0.12));

    float2 coverUV = clamp(fieldUV * 0.96 + 0.02, float2(0.0), float2(1.0));
    float4 albumSample = artwork.sample(artworkSampler, coverUV);
    float texturePresence = clamp(u.artworkOpacity * albumSample.a, 0.0, 1.0);
    float3 albumFieldRaw = linearColor(float4(albumSample.rgb, 1.0)).rgb;
    float3 albumField = glassifyAlbumColor(albumFieldRaw, semanticField, vibrancy, isDark);
    float albumL = luminance(albumField);
    float albumChroma = length(albumField - float3(albumL));
    float rawLightGate = smoothstep(0.16, 0.42, luminance(albumFieldRaw));
    float shiftable = smoothstep(0.026, 0.150, albumChroma) * rawLightGate;
    float albumHueTravel = mix(-0.035, 0.046, fieldDiag) + (fieldCross - 0.5) * 0.022 + harmonicDrift * 0.58;
    float3 albumHarmonic = harmonicShift(albumField, albumHueTravel, 0.84, 1.0);
    float3 albumBridge = mix(albumHarmonic, semanticField, 0.10 + vibrancy * 0.08);
    albumField = mix(albumField, albumBridge, shiftable * (0.28 + vibrancy * 0.18));
    float fallbackAmount = (1.0 - texturePresence) * (isDark * 0.42 + isLight * 0.32) * (0.48 + vibrancy * 0.26);
    color = mix(color, semanticField, clamp(fallbackAmount, 0.0, 1.0));
    float albumAmount = pow(texturePresence, 0.92) * (isDark * 0.80 + isLight * 0.76);
    color = mix(color, albumField, clamp(albumAmount, 0.0, 1.0));

    // 白色薄纱只保留空气感，主体颜色交给专辑三色，避免浅色模式发白。
    float veilT = linearT(uv, float2(0.12, 0.0), float2(0.92, 1.0));
    float4 veil = gradient3(
        float4(glassLightColor, (isDark * 0.034 + isLight * 0.018) * wv),
        float4(glassLightColor, (isDark * 0.012 + isLight * 0.006) * wv),
        float4(glassLightColor, (isDark * 0.040 + isLight * 0.020) * wv),
        veilT
    );
    veil.a *= isLight;
    color = overBlend(color, veil);

    // 纵向渐变：只做底板色温分区，不让大面积 tint 抢过主色。
    float verticalT = linearT(uv, float2(0.5, 0.0), float2(0.5, 1.0));
    color = overBlend(color, gradient3(
        colorWithAlpha(float4(backdropSecondary, 1.0), isDark * 0.018 + isLight * 0.012),
        colorWithAlpha(float4(backdropPrimary, 1.0), isDark * 0.030 + isLight * 0.022),
        colorWithAlpha(float4(backdropAccent, 1.0), isDark * 0.014 + isLight * 0.010),
        verticalT
    ));

    // 斜向多色染色保留为非常轻的基底层，绚丽感交给后面的加色柔光斑。
    float diagonalT = linearT(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    color = overBlend(color, gradient4(
        colorWithAlpha(float4(backdropPrimary, 1.0), isDark * 0.026 + isLight * 0.018),
        colorWithAlpha(float4(backdropSecondary, 1.0), isDark * 0.020 + isLight * 0.014),
        colorWithAlpha(float4(backdropAccent, 1.0), isDark * 0.017 + isLight * 0.012),
        colorWithAlpha(float4(backdropPrimary, 1.0), isDark * 0.010 + isLight * 0.008),
        diagonalT
    ));

    color = overBlend(color, radial3(
        point,
        float2(0.28, 0.42) * u.viewportSize,
        28.0,
        720.0,
        colorWithAlpha(float4(backdropPrimary, 1.0), isDark * 0.022 + isLight * 0.016),
        colorWithAlpha(float4(backdropAccent, 1.0), isDark * 0.012 + isLight * 0.008),
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
        colorWithAlpha(glowPrimary, (isDark * 0.050 + isLight * 0.040) * (0.58 + vibrancy * 0.42)),
        colorWithAlpha(float4(backdropPrimary, 1.0), (isDark * 0.018 + isLight * 0.014) * (0.48 + vibrancy * 0.34)),
        float4(0.0)
    ));
    color = controlledScreen(color, radial3(
        point,
        float2(0.73 + lowFlow * 0.05, 0.28 + crossFlow * 0.05) * u.viewportSize,
        0.0,
        max(620.0, meshSpan * 0.66),
        colorWithAlpha(secondary, (isDark * 0.040 + isLight * 0.030) * (0.54 + vibrancy * 0.36)),
        colorWithAlpha(accent, (isDark * 0.015 + isLight * 0.012) * (0.45 + vibrancy * 0.28)),
        float4(0.0)
    ));
    color = controlledScreen(color, radial3(
        point,
        float2(0.92 - lowFlow * 0.03, 0.76 + crossFlow * 0.04) * u.viewportSize,
        0.0,
        max(520.0, meshSpan * 0.54),
        colorWithAlpha(accent, (isDark * 0.024 + isLight * 0.018) * (0.42 + vibrancy * 0.35)),
        colorWithAlpha(secondary, (isDark * 0.010 + isLight * 0.008) * (0.42 + vibrancy * 0.24)),
        float4(0.0)
    ));

    // Apple Music 式多色网格：主/辅/强调色作为大柔光斑铺满四角与中心。
    // 用 controlledPlus 受控加光：在中/暗调区显现绚丽彩光，亮区因 headroom 衰减不会被推白。
    float blobReach = max(meshSpan * 0.72, 760.0);
    float gs = kGlowStrength;
    // §4.3 mesh blobs 颜色一律走 glow*（lightenedForGlow：最低亮度有保证、饱和≤0.80、严格保色相），
    // 深色专辑也不发脏暗光；绚丽来自这些柔光斑而非底板。
    color = controlledPlus(color, radial2(point, float2(0.82, 0.14) * u.viewportSize, 0.0, blobReach, colorWithAlpha(glowSecondary, (isDark * 0.090 + isLight * 0.075) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.90, 0.84) * u.viewportSize, 0.0, blobReach * 1.04, colorWithAlpha(glowAccent, (isDark * 0.082 + isLight * 0.068) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.10, 0.88) * u.viewportSize, 0.0, blobReach * 0.98, colorWithAlpha(glowPrimary, (isDark * 0.092 + isLight * 0.070) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.15, 0.16) * u.viewportSize, 0.0, blobReach * 0.92, colorWithAlpha(glowPrimary, (isDark * 0.052 + isLight * 0.040) * gs), float4(0.0)));
    color = controlledPlus(color, radial2(point, float2(0.50, 0.48) * u.viewportSize, 0.0, blobReach * 1.14, colorWithAlpha(glowSecondary, (isDark * 0.040 + isLight * 0.032) * gs), float4(0.0)));
    // §4.2 第 4 个柔光斑：颜色取 secondary 与 accent 的中间插值（着色器内 mix 0.5），丰富多色层次；
    // 仍走 glow* 体系，色相严格落在 secondary/accent 之间，绝不做 hue 偏移。
    float4 blobMix = mix(glowSecondary, glowAccent, 0.5);
    color = controlledPlus(color, radial2(point, float2(0.36, 0.72) * u.viewportSize, 0.0, blobReach * 1.02, colorWithAlpha(blobMix, (isDark * 0.048 + isLight * 0.038) * gs), float4(0.0)));

    // 斜向高光：白色端再压（浅色 0.05），保留专辑主/次色染色。
    float shineT = linearT(uv, float2(0.08, 0.03), float2(0.94, 0.98));
    color = overBlend(color, gradient4(
        float4(glassLightColor, (isDark * 0.012 + isLight * 0.009) * wv),
        colorWithAlpha(float4(backdropPrimary, 1.0), isDark * 0.030 + isLight * 0.020),
        float4(0.0),
        colorWithAlpha(float4(backdropSecondary, 1.0), isDark * 0.025 + isLight * 0.016),
        shineT
    ));

    float canvasSpan = max(u.viewportSize.x, u.viewportSize.y);
    float longReach = max(canvasSpan * 0.98, 920.0);
    float midReach = max(canvasSpan * 0.62, 620.0);
    float2 c = u.albumLightCenter;

    // 大面积 ambient / 静态背光 / 近场光：全部改用 controlledScreen，
    // 亮背景上自动退化为染色而非滤色，从根本上不再洗白。
    color = controlledScreen(color, radial5(point, c, 0.0, longReach * 0.82, colorWithAlpha(glowPrimary, (isDark * 0.052 + isLight * 0.040) * gs), colorWithAlpha(glowPrimary, (isDark * 0.032 + isLight * 0.025) * gs), colorWithAlpha(glowSecondary, (isDark * 0.020 + isLight * 0.016) * gs), colorWithAlpha(glowAccent, (isDark * 0.012 + isLight * 0.009) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c, 0.0, midReach * 0.40, colorWithAlpha(glowPrimary, (isDark * 0.040 + isLight * 0.030) * gs), colorWithAlpha(glowAccent, (isDark * 0.020 + isLight * 0.016) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(190.0, 42.0), 0.0, midReach * 0.76, colorWithAlpha(accent, (isDark * 0.028 + isLight * 0.022) * gs), colorWithAlpha(primary, (isDark * 0.014 + isLight * 0.010) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(310.0, -82.0), 0.0, midReach * 0.72, colorWithAlpha(secondary, (isDark * 0.024 + isLight * 0.017) * gs), colorWithAlpha(accent, (isDark * 0.012 + isLight * 0.009) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(-170.0, 178.0), 0.0, midReach * 0.58, colorWithAlpha(primary, (isDark * 0.018 + isLight * 0.014) * gs), colorWithAlpha(accent, (isDark * 0.010 + isLight * 0.008) * gs), float4(0.0)));
    color = controlledScreen(color, beam(point, c + float2(longReach * 0.26, 10.0), float2(longReach * 1.02, 210.0), -3.14159265 / 20.0, colorWithAlpha(primary, 0.0), colorWithAlpha(primary, (isDark * 0.014 + isLight * 0.011) * gs), colorWithAlpha(accent, (isDark * 0.018 + isLight * 0.013) * gs), float4(0.0)));

    float beat = 0.82;
    float slow = 0.56;
    float driftX = cos(slow * 6.2831853) * (30.0 + beat * 28.0);
    float driftY = sin((slow + beat * 0.16) * 6.2831853) * (22.0 + beat * 20.0);
    float localPulse = clamp((beat - 0.32) / 0.64, 0.0, 1.0);
    // 近场跳动光斑：用 controlledPlus（彩光加亮，受 headroom 控制不过曝）。
    color = controlledPlus(color, radial3(point, c + float2(driftX * 0.70, driftY * 0.70), 0.0, 190.0 + localPulse * 68.0, colorWithAlpha(primary, ((isDark * 0.035 + isLight * 0.026) + localPulse * 0.012) * gs), colorWithAlpha(accent, (0.012 + localPulse * 0.005) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(150.0 + driftX * 0.52, 18.0 - driftY * 0.28), 0.0, 220.0 + localPulse * 60.0, colorWithAlpha(primary, (0.020 + localPulse * 0.006) * gs), colorWithAlpha(secondary, (0.012 + slow * 0.003) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, c + float2(44.0 - driftX * 0.20, 164.0 + driftY * 0.42), 0.0, 170.0 + localPulse * 48.0, colorWithAlpha(accent, (0.018 + localPulse * 0.005) * gs), colorWithAlpha(primary, (0.010 + slow * 0.003) * gs), float4(0.0)));

    // 整窗玻璃层：偏专辑色，白色高光只留边缘空气。
    float strength = clamp(u.glassIntensity, 0.0, 1.0);
    color = overBlend(color, colorWithAlpha(glassBaseColor, (isDark * 0.105 + isLight * 0.045) * strength));
    float glassT = linearT(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    color = overBlend(color, gradient3(
        float4(glassLightColor, (isDark * 0.010 + isLight * 0.008) * strength * wv),
        colorWithAlpha(float4(backdropPrimary, 1.0), (isDark * 0.014 + isLight * 0.010) * strength),
        colorWithAlpha(float4(backdropSecondary, 1.0), (isDark * 0.006 + isLight * 0.004) * strength),
        glassT
    ));
    color = controlledScreen(color, radial3(point, float2(0.28, 0.24) * u.viewportSize, 0.0, 720.0, float4(glassLightColor, (isDark * 0.006 + isLight * 0.006) * strength * wv), colorWithAlpha(glowPrimary, (isDark * 0.014 + isLight * 0.011) * strength * gs), float4(0.0)));

    // Continuous full-screen Liquid Glass overlay. The "refraction" is a soft color-space ripple over the
    // album backdrop, not a behind-window blur, so it stays opaque and cheap.
    float liquidWave = sin((uv.x * 1.75 + uv.y * 2.25 + lowFlow * 0.72) * 6.2831853) * 0.5 + 0.5;
    float liquidBand = smoothstep(0.50, 0.92, liquidWave) * (1.0 - smoothstep(0.86, 1.0, liquidWave));
    float glassChroma = (0.010 + vibrancy * 0.012) * strength;
    color = controlledScreen(color, colorWithAlpha(float4(mix(backdropPrimary, backdropSecondary, lowFlow), 1.0), glassChroma * liquidBand * (isDark * 0.72 + isLight * 0.52)));
    color = controlledScreen(color, colorWithAlpha(glowAccent, (isDark * 0.007 + isLight * 0.005) * strength * crossFlow * (0.55 + vibrancy * 0.35)));
    float refractiveLift = (lowFlow - 0.5) * (isDark * 0.016 + isLight * 0.010) * strength;
    color = mix(color, color + color * refractiveLift, 0.55);

    // §1.1 整片镜面高光带：一条贯穿全窗、极低对比的斜向高光，方向由封面光心(albumLightCenter)指向窗口对侧
    //（光从封面方向斜扫过玻璃）。只在窗口对角线中段出现、两端淡出为 0，让人感到"有一块玻璃盖在彩色底上"，
    // 而不是颜色本身在变。强度上限：浅色 ≤0.05、深色 ≤0.035（再经 strength*wv 全局衰减）。
    float2 sweepUV = uv + refractOffset;
    float2 sweepLC = u.albumLightCenter / u.viewportSize;
    float2 sweepTarget = mix(float2(0.82, 0.64), float2(0.58, 0.46), isDark * 0.18);
    float2 sweepVector = sweepTarget - sweepLC;
    float2 sweepDir = normalize(float2(1.0, 0.62));
    if (dot(sweepVector, sweepVector) > 0.0001) {
        sweepDir = normalize(sweepVector);
    }
    float sweepAlong = dot(sweepUV - sweepLC, sweepDir);
    float sweepAcross = dot(sweepUV - sweepLC, float2(-sweepDir.y, sweepDir.x));
    float sweepBand = exp(-sweepAcross * sweepAcross / 0.0026);            // 垂直轴方向的窄高光带
    float sweepMid = smoothstep(-0.55, -0.05, sweepAlong) *
                     (1.0 - smoothstep(0.18, 0.72, sweepAlong));          // 中段出现、两端淡出为 0
    float sweepSpecular = sweepBand * sweepMid;
    color = controlledScreen(color, float4(glassLightColor, sweepSpecular * (isDark * 0.020 + isLight * 0.028) * strength));

    beat = 0.78;
    slow = 0.54;
    driftX = cos(slow * 6.2831853) * (30.0 + beat * 28.0);
    driftY = sin((slow + beat * 0.14) * 6.2831853) * (14.0 + beat * 18.0);
    float2 nearCenter = c + float2(driftX, driftY);
    float2 rightWash = c + float2(168.0 + driftX * 0.56, 36.0 - driftY * 0.22);
    float2 lowerWash = c + float2(40.0 - driftX * 0.24, 166.0 + driftY * 0.36);
    float beamWidth = clamp(u.viewportSize.x * 0.34, 420.0, 620.0);
    color = controlledScreen(color, radial3(point, nearCenter, 0.0, 172.0 + beat * 52.0, colorWithAlpha(primary, ((isDark * 0.024 + isLight * 0.018) + beat * 0.006) * gs), colorWithAlpha(accent, (0.010 + beat * 0.004) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, rightWash, 0.0, 230.0 + beat * 52.0, colorWithAlpha(secondary, (0.014 + beat * 0.004) * gs), colorWithAlpha(primary, (0.009 + slow * 0.002) * gs), float4(0.0)));
    color = controlledScreen(color, radial3(point, lowerWash, 0.0, 166.0 + beat * 40.0, colorWithAlpha(accent, (0.012 + beat * 0.003) * gs), colorWithAlpha(primary, (0.008 + slow * 0.002) * gs), float4(0.0)));
    color = controlledScreen(color, beam(point, c + float2(230.0 + driftX * 0.34, 12.0 + driftY * 0.16), float2(beamWidth, 112.0 + beat * 26.0), (-7.0 + beat * 3.2) * 3.14159265 / 180.0, float4(0.0), colorWithAlpha(primary, (0.006 + beat * 0.003) * gs), colorWithAlpha(accent, (0.007 + slow * 0.002) * gs), float4(0.0)));

    // 边缘空气感：白色高光只作为四周很窄的一圈"空气"，浅色 0.22→0.09，且仅在边缘（edgeMask）局部出现。
    float edgeDistance = min(min(point.x, point.y), min(u.viewportSize.x - point.x, u.viewportSize.y - point.y));
    float edgeMask = 1.0 - smoothstep(0.0, 1.0, edgeDistance);
    color = controlledScreen(color, float4(glassLightColor, (isDark * 0.024 + isLight * 0.020) * strength * edgeMask * wv));

    // 整窗连续玻璃面板的纵向深度：顶部极轻提亮、底部极轻压暗，让整块玻璃有"上沿受光、下沿入影"的
    // 空间层次（Liquid Glass 的轻微深度阴影）。幅度克制（约 1.5%~5%），浅色更弱，不改变色相、不洗白。
    float depthT = clamp(uv.y, 0.0, 1.0);
    float topLift = (1.0 - smoothstep(0.0, 0.52, depthT)) * (isDark * 0.020 + isLight * 0.013) * strength;
    float bottomShade = smoothstep(0.56, 1.0, depthT) * (isDark * 0.050 + isLight * 0.030) * strength;
    color = controlledScreen(color, float4(glassLightColor, topLift * wv));
    color *= (1.0 - bottomShade);

    // ── 出图后处理：曝光 → 高光柔压（保彩度）→ 彩度补偿 → 抖动去断层 → 防纯白 clamp ──
    color *= kExposure;
    color = softTonemap(color, kHighlightCompression);
    float outL = luminance(color);
    float chromaLimit = mix(kChromaBoost * 0.92, kChromaBoost, 1.0 - smoothstep(0.68, 0.86, outL));
    color = mix(float3(outL), color, chromaLimit);           // 回补彩度，但亮区不再继续推艳
    color = linearToSRGB(color);
    // 抖动(dithering)：大面积平滑渐变在 8bit 输出时会出现可见色彩断层（banding），
    // 只保留极低幅度打散量化台阶；grain 不参与观感，避免底板发脏。
    float dither = fract(sin(dot(point, float2(12.9898, 78.233))) * 43758.5453);
    float grain = hash21(floor(point * 0.72) + float2(5.17, 9.31)) - 0.5;
    color += (dither - 0.5) * (0.52 / 255.0);
    color += grain * (0.045 / 255.0) * (0.34 + vibrancy * 0.20);
    color = clamp(color, float3(0.0), float3(0.935));         // 上限低于纯白，杜绝大片洗白/刺眼
    return float4(color, 1.0);
}
"""#
}
