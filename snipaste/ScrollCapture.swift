//
//  ScrollCapture.swift
//  snipaste
//
//  滚动截图（长图）：选区确认后进入滚动模式，遮罩让出鼠标事件，
//  用户自行滚动页面，程序按固定间隔抓取选区并按重叠行自动拼接。
//  完成后在预览窗口里复制 / 保存 / 贴图
//

import AppKit

// 拼接算法见 ScrollStitcher.swift（纯逻辑，独立文件便于验证）

// MARK: - 滚动控制条

/// 滚动模式下的悬浮控制条（独立面板：遮罩已让出鼠标事件，这里仍可点击）
final class ScrollControlBarController {

    private var panel: NSPanel?
    private var statusLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var sizeLabel: NSTextField?
    private var pauseButton: NSButton?
    private var finishButton: NSButton?

    /// 在选区下方（放不下则放在选区上方）展示控制条
    func show(near rect: NSRect, windowOrigin: NSPoint, globalFinishAvailable: Bool,
              onPause: @escaping () -> Void, onFinish: @escaping () -> Void,
              onCancel: @escaping () -> Void) {
        close()

        let status = NSTextField(labelWithString: "正在准备首屏…")
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel = status

        let size = NSTextField(labelWithString: "")
        size.textColor = .secondaryLabelColor
        size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel = size

        let hint = NSTextField(wrappingLabelWithString: "首屏准备好后，请在选区内缓慢向下滚动。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.maximumNumberOfLines = 2
        hintLabel = hint

        let pauseButton = NSButton(title: "暂停", target: self, action: #selector(pauseClicked))
        pauseButton.bezelStyle = .rounded
        pauseButton.isEnabled = false
        pauseButton.toolTip = "暂停 / 继续（空格，截图窗口获得焦点时）"
        self.pauseButton = pauseButton
        let finishButton = NSButton(title: "结束截图", target: self, action: #selector(finishClicked))
        finishButton.bezelStyle = .rounded
        finishButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        finishButton.imagePosition = .imageLeading
        finishButton.keyEquivalent = "\r"
        finishButton.keyEquivalentModifierMask = []
        finishButton.isEnabled = false
        finishButton.toolTip = "结束捕获并打开长图预览（截图窗口内可按回车）"
        self.finishButton = finishButton
        let cancelButton = NSButton(title: "返回选区", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.toolTip = "放弃本次拼接，返回原选区（Esc）"
        pauseAction = onPause
        finishAction = onFinish
        cancelAction = onCancel

        let titleRow = NSStackView(views: [status, NSView(), size])
        let actions = NSStackView(views: [cancelButton, NSView(), pauseButton, finishButton])
        actions.spacing = 10
        // 将结束入口直接写在控制条上，并明确全局组合键与窗口内按键的区别。
        let shortcut = HotKeyDescriptor.scrollCaptureFinish.displayString
        let shortcuts = NSTextField(wrappingLabelWithString: globalFinishAvailable
            ? "\(shortcut) 全局结束 · 回车结束（截图窗口内）\n空格 暂停/继续 · Esc 返回（截图窗口内）"
            : "全局结束快捷键不可用，请点击「结束截图」\n截图窗口内：回车结束 · 空格暂停/继续 · Esc 返回")
        shortcuts.font = .systemFont(ofSize: 11)
        shortcuts.textColor = .secondaryLabelColor
        shortcuts.maximumNumberOfLines = 2
        let stack = NSStackView(views: [titleRow, hint, actions, shortcuts])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        // 固定深色外观，保证原生按钮和次级文字在深色底板上的对比度。
        container.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.90).cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(stack)
        let global = rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
        let screen = NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(global)
            let right = rhs.frame.intersection(global)
            return left.width * left.height < right.width * right.height
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? global
        let width = min(420, visible.width - 24)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            hint.widthAnchor.constraint(equalTo: titleRow.widthAnchor),
            hint.heightAnchor.constraint(equalToConstant: 34),
            actions.widthAnchor.constraint(equalTo: titleRow.widthAnchor),
            shortcuts.widthAnchor.constraint(equalTo: titleRow.widthAnchor),
            shortcuts.heightAnchor.constraint(equalToConstant: 32),
        ])

        let panelSize = stack.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .captureOverlay   // 比截图遮罩高一层，保证可见可点
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container

        // 优先放在选区外；选满屏时仍将控制条夹在可见范围内，并允许拖动避让。
        let positions: [NSPoint] = [
            NSPoint(x: global.midX - panelSize.width / 2, y: global.minY - panelSize.height - 12),
            NSPoint(x: global.midX - panelSize.width / 2, y: global.maxY + 12),
            NSPoint(x: global.maxX + 12, y: global.midY - panelSize.height / 2),
            NSPoint(x: global.minX - panelSize.width - 12, y: global.midY - panelSize.height / 2),
        ]
        let candidates: [NSPoint] = positions.map { point in
            NSPoint(x: min(max(point.x, visible.minX + 12), visible.maxX - panelSize.width - 12),
                    y: min(max(point.y, visible.minY + 12), visible.maxY - panelSize.height - 12))
        }
        let origin = candidates.first { !NSRect(origin: $0, size: panelSize).intersects(global) }
            ?? candidates[0]
        panel.isMovableByWindowBackground = true
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        self.panel = panel
    }

    func update(status: String, hint: String, height: Int, canFinish: Bool,
                isPaused: Bool = false, canPause: Bool = true) {
        statusLabel?.stringValue = status
        hintLabel?.stringValue = hint
        sizeLabel?.stringValue = height > 0 ? "已捕获 \(height) px" : ""
        finishButton?.isEnabled = canFinish
        pauseButton?.isEnabled = canPause
        pauseButton?.title = isPaused ? "继续" : "暂停"
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        statusLabel = nil
        hintLabel = nil
        sizeLabel = nil
        pauseButton = nil
        finishButton = nil
        pauseAction = nil
        finishAction = nil
        cancelAction = nil
    }

    private var pauseAction: (() -> Void)?
    private var finishAction: (() -> Void)?
    private var cancelAction: (() -> Void)?

    @objc private func pauseClicked() { pauseAction?() }
    @objc private func finishClicked() { finishAction?() }
    @objc private func cancelClicked() { cancelAction?() }
}

// MARK: - 滚动截图会话

final class ScrollCaptureSession {

    /// 轮询间隔
    private static let pollInterval: UInt64 = 320_000_000
    /// 拼接总高度上限（物理像素）
    private static let maxTotalHeight = 30000

    private enum State {
        case preparing, capturing, paused, finishing, limitReached, ended
    }

    private var state: State = .preparing
    private let region: NSRect                       // 视图坐标
    private weak var view: CaptureView?
    private let controlBar = ScrollControlBarController()
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    /// 暂停切换后丢弃尚未返回的旧抓帧，避免暂停期间的内容混入结果。
    private var captureGeneration = 0

    /// 已拼接的行带：第一个是首帧整图，之后是逐段新增
    private var bands: [CGImage] = []
    private var totalHeight = 0
    private var lastSignature: ScrollStitcher.Signature?
    private var needsRecovery = false

    /// 结束回调：(拼接结果, 选区的逻辑尺寸)；结果为 nil 表示取消或失败
    private let completion: (CGImage?, NSSize) -> Void

    init(region: NSRect, view: CaptureView, completion: @escaping (CGImage?, NSSize) -> Void) {
        self.region = region
        self.view = view
        self.completion = completion
    }

    func start() {
        guard task == nil, state == .preparing else { return }
        let globalFinishAvailable = HotKeyManager.shared.beginScrollCapture { [weak self] in
            self?.finish()
        }
        controlBar.show(near: region,
                        windowOrigin: view?.window?.frame.origin ?? .zero,
                        globalFinishAvailable: globalFinishAvailable,
                        onPause: { [weak self] in self?.togglePause() },
                        onFinish: { [weak self] in self?.finish() },
                        onCancel: { [weak self] in self?.cancel() })
        // 只监听本应用的键盘事件，无需全局监听权限；浮动面板获得焦点时也可操作。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) == true ? nil : event
        }

        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// 静默中止（截图会话被外部关闭时调用，不触发完成回调）
    func abort() {
        guard state != .ended else { return }
        state = .ended
        HotKeyManager.shared.endScrollCapture()
        task?.cancel()
        task = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        controlBar.close()
    }

    /// 用户点取消（或按 Esc）
    func cancel() {
        guard state != .ended else { return }
        abort()
        completion(nil, region.size)
    }

    /// 窗口内的无修饰按键仅在截图应用获得焦点时生效，全局结束组合键另行注册。
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        guard [UInt16(53), 36, 76, 49].contains(event.keyCode) else { return false }
        guard !event.isARepeat else { return true }
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: finish()
        default: togglePause()
        }
        return true
    }

    // MARK: 内部

    private func finish() {
        guard !bands.isEmpty, state != .ended, state != .finishing else { return }
        if state == .paused || state == .limitReached {
            complete()
            return
        }
        // 由抓帧循环补上最后一帧后再生成预览，减少点击完成时漏掉末尾内容。
        captureGeneration += 1
        state = .finishing
        updateControls(status: "正在生成预览…", hint: "正在收尾，请稍候。")
    }

    private func complete() {
        guard state != .ended else { return }
        let image = bands.count == 1 ? bands.first : compose()
        abort()
        guard let image else {
            Feedback.failure("长截图生成失败，请重新尝试")
            completion(nil, region.size)
            return
        }
        print("🧵 滚动截图完成: \(image.width)x\(image.height)px")
        completion(image, logicalSize(for: image))
        if needsRecovery {
            Feedback.failure("已生成预览，仅包含成功衔接的内容，请检查末尾")
        }
    }

    private func togglePause() {
        guard state == .capturing || state == .paused else { return }
        captureGeneration += 1
        if state == .capturing {
            state = .paused
            updateControls(status: "已暂停", hint: "暂停期间不采集。继续前请保持页面位置，或直接完成。")
        } else {
            state = .capturing
            updateControls(status: "继续捕获", hint: "在选区内缓慢向下滚动；停顿不会自动结束。")
        }
    }

    private func updateControls(status: String, hint: String) {
        controlBar.update(status: status, hint: hint, height: totalHeight,
                          canFinish: !bands.isEmpty && state != .finishing,
                          isPaused: state == .paused,
                          canPause: state == .capturing || state == .paused)
    }

    private func logicalSize(for image: CGImage) -> NSSize {
        let scale = CGFloat(image.width) / max(1, region.width)
        return NSSize(width: region.width, height: CGFloat(image.height) / max(1, scale))
    }

    private func run() async {
        guard let view else {
            cancel()
            return
        }

        let firstFrame = await view.grabRegionForScrolling(region)
        guard !Task.isCancelled, state != .ended else { return }
        guard let first = firstFrame, let signature = ScrollStitcher.signature(of: first) else {
            print("❌ 滚动截图首帧抓取失败")
            Feedback.failure("无法获取首屏，已返回选区，请重试")
            cancel()
            return
        }
        bands = [first]
        totalHeight = first.height
        lastSignature = signature
        state = .capturing
        updateControls(status: "已就绪，向下滚动开始", hint: "将鼠标移到选区内缓慢向下滚动；停顿不会自动结束。")
        print("🧵 滚动截图开始，选区 \(Int(region.width))x\(Int(region.height))pt")

        let templateHeight = max(40, min(first.height / 4, 240))

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            guard !Task.isCancelled, state != .ended else { return }
            guard state == .capturing || state == .finishing else { continue }

            let generation = captureGeneration
            let frame = await view.grabRegionForScrolling(region)
            guard !Task.isCancelled, state != .ended else { return }
            guard generation == captureGeneration,
                  state == .capturing || state == .finishing else { continue }

            if let frame {
                consume(frame, templateHeight: templateHeight)
            } else {
                needsRecovery = true
                if state != .finishing {
                    updateControls(status: "暂时无法捕获画面", hint: "已保留捕获内容，正在重试；也可以完成或返回选区。")
                }
            }
            if state == .finishing {
                complete()
                return
            }
            if totalHeight >= Self.maxTotalHeight {
                state = .limitReached
                updateControls(status: "已达到长图高度上限", hint: "已保留当前内容，请点击「结束截图」查看预览。")
                return
            }
        }
    }

    private func consume(_ frame: CGImage, templateHeight: Int) {
        guard let signature = ScrollStitcher.signature(of: frame),
              let previous = lastSignature else { return }
        guard let appended = ScrollStitcher.appendedRows(previous: previous,
                                                         next: signature,
                                                         templateHeight: templateHeight,
                                                         scoreThreshold: 6) else {
            // 匹配失败时保留最后成功的参照帧，避免跳过缺口后继续拼出断层。
            needsRecovery = true
            updateControls(status: "画面未衔接，已保留捕获内容", hint: "请向上回到上次捕获的位置，再缓慢向下滚动；也可直接完成。")
            return
        }
        if appended > 0 {
            guard appendBand(from: frame, rows: appended) else {
                needsRecovery = true
                updateControls(status: "本段内容未能加入", hint: "已保留捕获内容，请暂停后重试，或完成并检查预览。")
                return
            }
            lastSignature = signature
        }
        needsRecovery = false
        // 画面静止只能说明没有新内容，不能据此判断已到底，更不能自动结束。
        updateControls(status: appended > 0 ? "正在拼接" : "等待向下滚动",
                       hint: "仅手动结束：到达需要的位置后，点击「结束截图」或按快捷键。")
    }

    /// 把新帧底部新增的行拷成独立小图追加到结果（避免整帧被引用占住内存）
    private func appendBand(from image: CGImage, rows: Int) -> Bool {
        let addedHeight = min(rows, Self.maxTotalHeight - totalHeight)
        guard addedHeight > 0, rows <= image.height else { return false }
        let rect = CGRect(x: 0, y: image.height - rows, width: image.width, height: addedHeight)
        guard let band = image.cropping(to: rect) else { return false }

        let colorSpace = band.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: band.width,
                                  height: band.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: band.width, height: band.height))
        guard let standalone = ctx.makeImage() else { return false }

        bands.append(standalone)
        totalHeight += addedHeight
        return true
    }

    /// 自上而下拼成一张长图
    private func compose() -> CGImage? {
        guard let first = bands.first, totalHeight > 0 else { return nil }
        let colorSpace = first.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: first.width,
                                  height: totalHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        var y = totalHeight
        for band in bands {
            y -= band.height
            ctx.draw(band, in: CGRect(x: 0, y: y, width: band.width, height: band.height))
        }
        return ctx.makeImage()
    }
}

// MARK: - 长图预览窗口

/// 滚动截图结果：可滚动的长图预览 + 复制 / 保存 / 贴图 / 关闭
final class LongImagePreviewController: NSWindowController, NSWindowDelegate {

    static let shared = LongImagePreviewController()

    private var image: CGImage?
    private var pointSize: NSSize = .zero
    private var previewScrollView: NSScrollView?

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    func show(image: CGImage, pointSize: NSSize) {
        // 替换旧预览时先关闭旧窗口，避免多张长图窗口共用当前图片的操作回调。
        close()
        self.image = image
        self.pointSize = pointSize

        let visibleSize = NSSize(width: min(max(pointSize.width, 420), 1000),
                                 height: min(max(pointSize.height, 320), 820))

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: visibleSize),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "长截图 \(Int(pointSize.width))×\(Int(pointSize.height))"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContentView(pointSize: pointSize)
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // AppKit 文档坐标原点在左下，初次预览应从长图顶部开始。
        window.contentView?.layoutSubtreeIfNeeded()
        if let scrollView = previewScrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, pointSize.height - scrollView.contentSize.height)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func makeContentView(pointSize: NSSize) -> NSView {
        let container = NSView()

        let imageView = NSImageView()
        imageView.image = image.map { NSImage(cgImage: $0, size: pointSize) }
        imageView.imageScaling = .scaleNone
        imageView.frame = NSRect(origin: .zero, size: pointSize)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = imageView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView = scrollView

        let copyButton = NSButton(title: "复制到剪贴板", target: self, action: #selector(copyClicked))
        let saveButton = NSButton(title: "保存到文件", target: self, action: #selector(saveClicked))
        let pinButton = NSButton(title: "贴到屏幕", target: self, action: #selector(pinClicked))
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        copyButton.bezelStyle = .rounded
        saveButton.bezelStyle = .rounded
        pinButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded
        // 预览窗口沿用 macOS 常用快捷键，便于直接完成输出。
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = .command
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command

        let bar = NSStackView(views: [copyButton, saveButton, pinButton, closeButton])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            bar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    // MARK: 动作

    @objc private func copyClicked() {
        guard let image else { return }
        if ImageClipboard.copy(image, pointSize: pointSize) {
            Feedback.success("已复制长截图")
        } else {
            Feedback.failure("复制失败")
        }
    }

    @objc private func saveClicked() {
        guard let image else { return }
        let settings = AppSettings.shared
        let format = settings.saveFormat
        guard let data = ImageSaver.data(from: image, pointSize: pointSize,
                                         format: format, quality: settings.jpegQuality) else {
            Feedback.failure("保存失败：图片编码出错")
            return
        }

        // 与截图流程一致：配了快速保存目录就静默保存，否则弹面板
        if let directory = settings.beginAccessingSaveDirectory() {
            defer { directory.stopAccessingSecurityScopedResource() }
            let name = ImageSaver.fileName(prefix: settings.saveFileNamePrefix, format: format)
            let url = ImageSaver.uniqueURL(in: directory, fileName: name)
            do {
                try ImageSaver.write(data, to: url)
                Feedback.success("已保存到 \(url.lastPathComponent)", actionTitle: "在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                Feedback.failure("保存失败：\(error.localizedDescription)")
            }
            return
        }

        let name = ImageSaver.fileName(prefix: settings.saveFileNamePrefix, format: format)
        guard let url = ImageSaver.presentSavePanel(suggestedName: name, format: format) else { return }
        do {
            try ImageSaver.write(data, to: url)
            Feedback.success("已保存到 \(url.lastPathComponent)", actionTitle: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            Feedback.failure("保存失败：\(error.localizedDescription)")
        }
    }

    @objc private func pinClicked() {
        guard let image else { return }
        let size = NSSize(width: min(pointSize.width, 600),
                          height: min(pointSize.height, 600))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        PinnedImageController.shared.pin(image: image,
                                         at: NSRect(origin: origin, size: size),
                                         nativeSize: pointSize)
        Feedback.success("已置顶长截图")
    }

    @objc private func closeClicked() {
        close()
    }
}
