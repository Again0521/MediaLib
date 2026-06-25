import AppKit

// 从 PlayerView.swift 物理拆出（零行为变化）：视频/沉浸播放器窗口的全屏、置顶、迷你悬浮窗、尺寸调整动作。
// 依赖的 ImmersivePlayerWindow / VideoWindowSizing 仍在 PlayerView.swift（均为模块内部可见，跨文件引用安全）。
enum PlayerWindowActions {
    static func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    static func setAlwaysOnTop(_ enabled: Bool) {
        guard let window = NSApp.windows
            .compactMap({ $0 as? ImmersivePlayerWindow })
            .first(where: \.isVisible) else { return }
        window.level = enabled ? .floating : .normal
    }

    static func exitFullScreenIfNeeded() -> Bool {
        guard let window = NSApp.keyWindow,
              window.styleMask.contains(.fullScreen) else {
            return false
        }
        window.toggleFullScreen(nil)
        return true
    }

    /// 进入迷你悬浮窗：缩到屏幕右下角的小窗、置顶、跨空间显示、隐藏红黄绿按钮。
    /// 返回进入前的窗口 frame 供恢复；全屏或非播放器窗口返回 nil。
    static func enterMiniMode(aspect: CGFloat) -> NSRect? {
        // 不能用 keyWindow：从齿轮弹层点「进入」时 key 窗口还是 NSPopover 的宿主窗口。
        guard let window = NSApp.windows
                .compactMap({ $0 as? ImmersivePlayerWindow })
                .first(where: { !$0.isMiniMode && $0.isVisible }),
              !window.styleMask.contains(.fullScreen) else { return nil }
        let previousFrame = window.frame
        window.isMiniMode = true

        let safeAspect = max(aspect, 0.01)
        let contentSize = NSSize(width: 380, height: (380 / safeAspect).rounded())
        let miniMinimum = NSSize(width: 240, height: (240 / safeAspect).rounded())
        window.contentMinSize = miniMinimum
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: miniMinimum)).size
        window.contentAspectRatio = contentSize
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = true
        }
        // 不用带动画的 setFrame：动画分步触发 windowWillResize/最小尺寸约束，
        // 会在中途被旧的 680pt 内容下限顶住，落点变宽出黑边。
        window.setContentSize(contentSize)
        let visibleFrame = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - window.frame.width - 16,
            y: visibleFrame.minY + 16
        ))
        return previousFrame
    }

    static func exitMiniMode(restoring frame: NSRect, alwaysOnTop: Bool) {
        guard let window = NSApp.windows.compactMap({ $0 as? ImmersivePlayerWindow }).first(where: \.isMiniMode) else { return }
        window.isMiniMode = false
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior.remove(.canJoinAllSpaces)
        let restoredMinimum = NSSize(
            width: VideoWindowSizing.minimumControlSafeWidth,
            height: VideoWindowSizing.minimumControlSafeHeight
        )
        window.contentMinSize = restoredMinimum
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: restoredMinimum)).size
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = false
        }
        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
    }

    static func updateMiniModeAspect(_ aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0,
              let window = NSApp.windows.compactMap({ $0 as? ImmersivePlayerWindow }).first(where: \.isMiniMode),
              !window.styleMask.contains(.fullScreen) else { return }
        let safeAspect = max(aspect, 0.01)
        let currentContent = window.contentLayoutRect.size
        let targetContent = NSSize(
            width: max(currentContent.width, 240),
            height: (max(currentContent.width, 240) / safeAspect).rounded()
        )
        guard abs(currentContent.width - targetContent.width) > 1 ||
                abs(currentContent.height - targetContent.height) > 1 else {
            window.contentAspectRatio = targetContent
            return
        }
        let oldFrame = window.frame
        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContent)).size
        window.contentAspectRatio = targetContent
        window.contentMinSize = NSSize(width: 240, height: (240 / safeAspect).rounded())
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        window.setFrame(
            NSRect(
                x: oldFrame.maxX - targetFrameSize.width,
                y: oldFrame.minY,
                width: targetFrameSize.width,
                height: targetFrameSize.height
            ),
            display: true,
            animate: false
        )
    }

    static func resizeCurrentWindow(toContentSize contentSize: NSSize, animate: Bool = false) {
        guard let window = NSApp.keyWindow,
              !window.styleMask.contains(.fullScreen),
              contentSize.width.isFinite,
              contentSize.height.isFinite,
              contentSize.width > 0,
              contentSize.height > 0 else { return }
        var targetContentSize = contentSize
        if let visibleFrame = window.screen?.visibleFrame {
            let maxFrameSize = NSSize(
                width: max(visibleFrame.width - 20, 1),
                height: max(visibleFrame.height - 20, 1)
            )
            let proposedFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
            let scale = min(maxFrameSize.width / max(proposedFrameSize.width, 1), maxFrameSize.height / max(proposedFrameSize.height, 1), 1)
            targetContentSize = NSSize(width: targetContentSize.width * scale, height: targetContentSize.height * scale)
        }
        let currentFrame = window.frame
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
        window.contentAspectRatio = targetContentSize
        let origin = NSPoint(
            x: currentFrame.midX - frameSize.width / 2,
            y: currentFrame.midY - frameSize.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: frameSize), display: true, animate: animate)
    }
}
