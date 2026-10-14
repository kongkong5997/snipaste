//
//  PinnedImageController.swift
//  snipaste
//
//

import AppKit

/// 贴图（置顶）管理器：把截取的图像以悬浮窗口钉在桌面上，
/// 支持同时存在多个贴图，生命周期独立于截图会话
final class PinnedImageController {

    static let shared = PinnedImageController()
    private init() {}

    private(set) var pinnedWindows: [PinnedImageWindow] = []

    /// 在屏幕指定位置（AppKit 全局坐标）钉一张图，显示尺寸与选区一致
    func pin(image: CGImage, at globalRect: CGRect) {
        let window = PinnedImageWindow(contentRect: globalRect, image: image)
        pinnedWindows.append(window)
        window.orderFront(nil)
        print("📌 已置顶贴图 #\(pinnedWindows.count): origin=\(globalRect.origin), size=\(globalRect.size)")
    }

    func remove(_ window: PinnedImageWindow) {
        pinnedWindows.removeAll { $0 === window }
        window.orderOut(nil)
        window.close()
        print("📌 已关闭贴图，剩余 \(pinnedWindows.count) 个")
    }
}

/// 单个贴图窗口：无边框悬浮、可拖动、双击或右键菜单关闭
final class PinnedImageWindow: NSWindow {

    init(contentRect: NSRect, image: CGImage) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // 悬浮于普通窗口之上、所有桌面空间可见
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 按住任意位置即可拖动贴图
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // 手动管理释放
        isReleasedWhenClosed = false

        let imageView = PinImageView(image: NSImage(cgImage: image, size: contentRect.size))
        imageView.frame = NSRect(origin: .zero, size: contentRect.size)
        imageView.autoresizingMask = [.width, .height]
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }
}

/// 贴图内容视图：支持拖动、双击关闭与右键菜单
final class PinImageView: NSImageView {

    private var trackingArea: NSTrackingArea?

    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        // 图像内容完整铺满视图（尺寸与图像逻辑尺寸一致，1:1 显示）
        imageScaling = .scaleNone
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    /// 关键：允许通过背景拖动窗口。
    /// NSImageView 默认返回 false（把自己当交互内容），导致 isMovableByWindowBackground 失效
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()   // 提示可抓取拖动
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        // 双击贴图 → 关闭
        if event.clickCount == 2 {
            closeSelf()
            return
        }
        super.mouseDown(with: event)   // 其余情况交给窗口的拖动机制
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "关闭贴图", action: #selector(closeSelf), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func closeSelf() {
        guard let window = window as? PinnedImageWindow else { return }
        PinnedImageController.shared.remove(window)
    }
}
