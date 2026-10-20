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

    /// 在屏幕指定位置（AppKit 全局坐标）钉一张图。
    /// nativeSize 是图像的原始逻辑尺寸（"实际大小"还原用），默认与显示尺寸一致
    func pin(image: CGImage, at globalRect: CGRect, nativeSize: NSSize? = nil) {
        let window = PinnedImageWindow(contentRect: globalRect, image: image, nativeSize: nativeSize)
        pinnedWindows.append(window)
        window.orderFront(nil)
        print("📌 已置顶贴图 #\(pinnedWindows.count): origin=\(globalRect.origin), size=\(globalRect.size)")
    }

    /// 临时隐藏 / 显示所有贴图（看一眼被挡住的桌面，不销毁贴图）
    func toggleVisibility() {
        guard !pinnedWindows.isEmpty else {
            Feedback.failure("当前没有贴图")
            return
        }
        let shouldHide = pinnedWindows.contains { $0.isVisible }
        for window in pinnedWindows {
            if shouldHide {
                window.orderOut(nil)
            } else {
                window.orderFront(nil)
            }
        }
        print("📌 贴图\(shouldHide ? "已隐藏" : "已显示") \(pinnedWindows.count) 个")
        Feedback.success(shouldHide ? "已隐藏全部贴图" : "已显示全部贴图")
    }

    /// 关闭所有贴图（右键菜单）
    func removeAll() {
        let windows = pinnedWindows
        pinnedWindows.removeAll()
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        print("📌 已关闭全部贴图（\(windows.count) 个）")
    }

    /// 从剪贴板读取图片并贴到屏幕上（贴图快捷键 / 菜单栏入口共用）
    @discardableResult
    func pinFromPasteboard() -> Bool {
        guard let pasteboardImage = Self.pasteboardImage(),
              let cgImage = pasteboardImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("📌 剪贴板里没有图片")
            NSSound.beep()
            return false
        }

        let nativeSize = Self.nativeSize(for: pasteboardImage, fallback: cgImage)
        let displaySize = Self.displaySize(nativeSize, in: Self.targetScreen())
        pin(image: cgImage, at: Self.placementRect(for: displaySize), nativeSize: nativeSize)
        return true
    }

    /// 读剪贴板图片：优先图片数据（截图 / 网页复制的图片），其次 Finder 里复制的图片文件
    private static func pasteboardImage() -> NSImage? {
        let pasteboard = NSPasteboard.general

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            return image
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first,
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    /// 图像原始逻辑尺寸（pt）：NSImage.size 一般就是；拿不到时按 2x 位图估算
    private static func nativeSize(for image: NSImage, fallback: CGImage) -> NSSize {
        let size = image.size
        if size.width < 1 || size.height < 1 {
            return NSSize(width: fallback.width / 2, height: fallback.height / 2)
        }
        return size
    }

    /// 显示尺寸（pt）：图片逻辑尺寸过大时等比缩到屏幕可见区域的 80%
    private static func displaySize(_ size: NSSize, in screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame else { return size }
        return PinGeometry.fittedSize(size, maxSize: NSSize(width: visible.width * 0.8,
                                                            height: visible.height * 0.8))
    }

    /// 初始位置：鼠标所在屏幕，居中于光标并钳制在可见范围内
    private static func placementRect(for size: NSSize) -> CGRect {
        guard let screen = targetScreen() else {
            return CGRect(origin: .zero, size: size)
        }
        let mouse = NSEvent.mouseLocation
        let visible = screen.visibleFrame
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    func remove(_ window: PinnedImageWindow) {
        pinnedWindows.removeAll { $0 === window }
        window.orderOut(nil)
        window.close()
        print("📌 已关闭贴图，剩余 \(pinnedWindows.count) 个")
    }
}

/// 单个贴图窗口：无边框悬浮、可拖动，支持缩放 / 复制 / 另存为，
/// 双击或右键菜单关闭
final class PinnedImageWindow: NSWindow {

    /// 原始图像（复制 / 另存为用，保持无损）
    let sourceImage: CGImage
    /// 原始逻辑尺寸（"实际大小"还原用）
    let sourcePointSize: NSSize

    /// 窗口标题：截图时用它把贴图窗口与其它自家窗口区分开
    /// （设置"截图包含贴图窗口"打开时，贴图不参与排除）
    static let screenCaptureTitle = "SnipastePinWindow"

    /// 缩放下限 / 上限（窗口宽度，pt）
    private static let minZoomWidth: CGFloat = 48
    private static let maxZoomWidth: CGFloat = 8000

    init(contentRect: NSRect, image: CGImage, nativeSize: NSSize? = nil) {
        sourceImage = image
        // 剪贴板超大批量图片会先被缩小显示，"实际大小"要回到原始尺寸而不是缩小后的尺寸
        sourcePointSize = nativeSize ?? contentRect.size

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        title = Self.screenCaptureTitle

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

    // MARK: - 缩放

    /// 以鼠标位置为不动点缩放（缩放后钳制在屏幕内，避免越缩越跑出屏幕）
    func zoom(by factor: CGFloat) {
        let current = frame
        let target = PinGeometry.zoomedFrame(current: current,
                                            factor: factor,
                                            anchor: NSEvent.mouseLocation,
                                            minWidth: Self.minZoomWidth,
                                            maxWidth: Self.maxZoomWidth)
        guard target != current else { return }
        setFrame(clamped(target), display: true)
    }

    /// 还原成原始尺寸（以当前中心为基准）
    func resetZoom() {
        let current = frame
        let size = NSSize(width: sourcePointSize.width, height: sourcePointSize.height)
        let origin = NSPoint(x: current.midX - size.width / 2, y: current.midY - size.height / 2)
        setFrame(clamped(NSRect(origin: origin, size: size)), display: true)
    }

    /// 钳制到所在屏幕的可见范围
    private func clamped(_ frame: NSRect) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return frame }
        return PinGeometry.clampedToVisibleFrame(frame, visibleFrame: visible)
    }
}

/// 贴图内容视图：支持拖动、双击关闭与右键菜单
final class PinImageView: NSImageView {

    private var trackingArea: NSTrackingArea?

    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        // 图像按视图尺寸等比显示：截图贴图的窗口尺寸与图像逻辑尺寸一致，即 1:1；
        // 剪贴板里的超大图片会被缩到屏幕范围内
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = "滚轮向上放大、向下缩小；拖动移动；右键查看更多操作"
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
        // 双击贴图 → 关闭（可在设置里关掉，避免误触）
        if event.clickCount == 2, AppSettings.shared.pinDoubleClickClose {
            closeSelf()
            return
        }
        super.mouseDown(with: event)   // 其余情况交给窗口的拖动机制
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        menu.addItem(menuItem("复制图片", #selector(copyImageAction), "c"))
        menu.addItem(menuItem("另存为…", #selector(saveImageAction), "s"))
        menu.addItem(.separator())
        menu.addItem(menuItem("放大", #selector(zoomInAction), "+"))
        menu.addItem(menuItem("缩小", #selector(zoomOutAction), "-"))
        menu.addItem(menuItem("实际大小", #selector(zoomResetAction), "0"))
        menu.addItem(.separator())

        // 不透明度子菜单，当前值打勾
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        let currentAlpha = Double(window?.alphaValue ?? 1)
        for percent in [100, 90, 75, 50] {
            let value = Double(percent) / 100
            let item = menuItem("\(percent)%", #selector(setOpacityAction(_:)), "")
            item.representedObject = value
            item.state = abs(currentAlpha - value) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        menu.addItem(menuItem("关闭贴图", #selector(closeSelf), "w"))
        menu.addItem(menuItem("关闭全部贴图", #selector(closeAllAction), ""))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - 键盘 / 滚轮

    /// 贴图窗口获得焦点时，⌘C 复制、⌘S 另存为、⌘W 关闭、⌘0/⌘+/- 缩放
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "c": copyImageToPasteboard(); return true
        case "s": saveImageToFile(); return true
        case "w": closeSelf(); return true
        case "0": (window as? PinnedImageWindow)?.resetZoom(); return true
        case "=", "+": (window as? PinnedImageWindow)?.zoom(by: 1.15); return true
        case "-", "_": (window as? PinnedImageWindow)?.zoom(by: 1 / 1.15); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// 滚轮 / 触控板滑动缩放（鼠标滚轮一格步长大，触控板细滑步长小）
    override func scrollWheel(with event: NSEvent) {
        guard let window = window as? PinnedImageWindow else { return }
        // 缩放只跟随主动的纵向滚动，避免横向滑动和松手后的惯性继续改变图片大小。
        guard event.momentumPhase.isEmpty,
              abs(event.scrollingDeltaY) > 0.01,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return }

        // 抵消系统自然滚动对事件方向的反转，保持滚轮向上放大、向下缩小。
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.14
        // 指数缩放让正反滚动互为逆操作，同时限制单次增量，避免快速滚动时尺寸突变。
        let exponent = min(max(delta * step, -0.4), 0.4)
        window.zoom(by: exp(exponent))
    }

    // MARK: - 菜单动作

    @objc private func copyImageAction() { copyImageToPasteboard() }
    @objc private func saveImageAction() { saveImageToFile() }
    @objc private func zoomInAction() { (window as? PinnedImageWindow)?.zoom(by: 1.15) }
    @objc private func zoomOutAction() { (window as? PinnedImageWindow)?.zoom(by: 1 / 1.15) }
    @objc private func zoomResetAction() { (window as? PinnedImageWindow)?.resetZoom() }
    @objc private func closeAllAction() { PinnedImageController.shared.removeAll() }

    @objc private func setOpacityAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        window?.alphaValue = value
    }

    // MARK: - 复制 / 另存为

    private func copyImageToPasteboard() {
        guard let window = window as? PinnedImageWindow else { return }
        if ImageClipboard.copy(window.sourceImage, pointSize: window.sourcePointSize) {
            print("📌 已复制贴图")
            Feedback.success("已复制图片")
        } else {
            Feedback.failure("复制失败")
        }
    }

    private func saveImageToFile() {
        guard let window = window as? PinnedImageWindow else { return }
        let settings = AppSettings.shared
        let format = settings.saveFormat
        let name = ImageSaver.fileName(prefix: settings.saveFileNamePrefix, format: format)

        guard let url = ImageSaver.presentSavePanel(suggestedName: name, format: format) else { return }
        guard let data = ImageSaver.data(from: window.sourceImage,
                                         pointSize: window.sourcePointSize,
                                         format: format,
                                         quality: settings.jpegQuality) else {
            Feedback.failure("保存失败：图片编码出错")
            return
        }
        do {
            try ImageSaver.write(data, to: url)
            print("📌 贴图已保存: \(url.path)")
            Feedback.success("已保存到 \(url.lastPathComponent)")
        } catch {
            Feedback.failure("保存失败：\(error.localizedDescription)")
        }
    }

    @objc private func closeSelf() {
        guard let window = window as? PinnedImageWindow else { return }
        PinnedImageController.shared.remove(window)
    }
}
