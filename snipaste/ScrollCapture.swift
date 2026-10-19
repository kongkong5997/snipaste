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

    /// 在选区下方（放不下则放在选区上方）展示控制条
    func show(near rect: NSRect, windowOrigin: NSPoint,
              onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        close()

        let hint = NSTextField(labelWithString: "滚动页面继续拼接")
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 13, weight: .medium)

        let status = NSTextField(labelWithString: "已拼接 0 px")
        status.textColor = .secondaryLabelColor
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel = status

        let finishButton = NSButton(title: "完成", target: self, action: #selector(finishClicked))
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        finishAction = onFinish
        cancelAction = onCancel

        let stack = NSStackView(views: [hint, status, finishButton, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let size = stack.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .captureOverlay   // 比截图遮罩高一层，保证可见可点
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = container

        // 位置：优先选区下方，放不下则放选区上方
        let global = rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
        let screen = NSScreen.screens.first { $0.frame.intersects(global) } ?? NSScreen.main
        var origin = NSPoint(x: global.midX - size.width / 2, y: global.minY - size.height - 12)
        if let visible = screen?.visibleFrame, origin.y < visible.minY {
            origin.y = global.maxY + 12
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        self.panel = panel
    }

    func updateStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        statusLabel = nil
        finishAction = nil
        cancelAction = nil
    }

    private var finishAction: (() -> Void)?
    private var cancelAction: (() -> Void)?

    @objc private func finishClicked() { finishAction?() }
    @objc private func cancelClicked() { cancelAction?() }
}

// MARK: - 滚动截图会话

final class ScrollCaptureSession {

    /// 轮询间隔
    private static let pollInterval: UInt64 = 320_000_000
    /// 连续多少次没有新内容判定到底
    private static let stableLimit = 3
    /// 拼接总高度上限（物理像素）
    private static let maxTotalHeight = 30000

    private let region: NSRect                       // 视图坐标
    private weak var view: CaptureView?
    private let controlBar = ScrollControlBarController()
    private var task: Task<Void, Never>?

    /// 已拼接的行带：第一个是首帧整图，之后是逐段新增
    private var bands: [CGImage] = []
    private var totalHeight = 0
    private var lastSignature: ScrollStitcher.Signature?
    private var stableCount = 0
    private var unreliableCount = 0

    /// 结束回调：(拼接结果, 选区的逻辑尺寸)；结果为 nil 表示取消或失败
    private let completion: (CGImage?, NSSize) -> Void

    init(region: NSRect, view: CaptureView, completion: @escaping (CGImage?, NSSize) -> Void) {
        self.region = region
        self.view = view
        self.completion = completion
    }

    func start() {
        guard task == nil else { return }
        controlBar.show(near: region,
                        windowOrigin: view?.window?.frame.origin ?? .zero,
                        onFinish: { [weak self] in self?.finish() },
                        onCancel: { [weak self] in self?.cancel() })
        controlBar.updateStatus("准备中…")

        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// 静默中止（截图会话被外部关闭时调用，不触发完成回调）
    func abort() {
        task?.cancel()
        task = nil
        controlBar.close()
    }

    /// 用户点取消（或按 Esc）
    func cancel() {
        task?.cancel()
        task = nil
        controlBar.close()
        completion(nil, region.size)
    }

    // MARK: 内部

    private func finish() {
        task?.cancel()
        task = nil
        controlBar.close()

        guard let image = compose(), image.height > bands.first?.height ?? 0 else {
            // 只有一帧（用户没滚动）：直接返回该帧，仍然可用
            if let first = bands.first {
                completion(first, logicalSize(for: first))
                return
            }
            completion(nil, region.size)
            return
        }
        print("🧵 滚动截图完成: \(image.width)x\(image.height)px")
        completion(image, logicalSize(for: image))
    }

    private func logicalSize(for image: CGImage) -> NSSize {
        let scale = CGFloat(image.width) / max(1, region.width)
        return NSSize(width: region.width, height: CGFloat(image.height) / max(1, scale))
    }

    private func run() async {
        guard let view else {
            completion(nil, region.size)
            return
        }

        guard let first = await view.grabRegionForScrolling(region) else {
            print("❌ 滚动截图首帧抓取失败")
            cancel()
            return
        }
        bands = [first]
        totalHeight = first.height
        lastSignature = ScrollStitcher.signature(of: first)
        controlBar.updateStatus("已拼接 \(totalHeight) px")
        print("🧵 滚动截图开始，选区 \(Int(region.width))x\(Int(region.height))pt")

        let templateHeight = max(40, min(first.height / 4, 240))

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if Task.isCancelled { break }

            guard let frame = await view.grabRegionForScrolling(region),
                  let signature = ScrollStitcher.signature(of: frame) else { continue }

            defer { lastSignature = signature }

            guard let previous = lastSignature else { continue }
            guard let appended = ScrollStitcher.appendedRows(previous: previous,
                                                             next: signature,
                                                             templateHeight: templateHeight,
                                                             scoreThreshold: 6) else {
                // 匹配不可信：多半是滚动太快，提示用户放慢
                unreliableCount += 1
                if unreliableCount == 1 {
                    controlBar.updateStatus("滚动太快，请慢一点")
                }
                continue
            }
            unreliableCount = 0

            if appended == 0 {
                stableCount += 1
                controlBar.updateStatus("已拼接 \(totalHeight) px（检测到底部）")
                if stableCount >= Self.stableLimit {
                    print("🧵 连续 \(Self.stableLimit) 次无新内容，认为已到底")
                    finish()
                    return
                }
            } else {
                stableCount = 0
                appendBand(from: frame, rows: appended)
            }

            if totalHeight >= Self.maxTotalHeight {
                print("🧵 达到高度上限 \(Self.maxTotalHeight)px，自动完成")
                finish()
                return
            }
        }
    }

    /// 把新帧底部新增的行拷成独立小图追加到结果（避免整帧被引用占住内存）
    private func appendBand(from image: CGImage, rows: Int) {
        guard rows > 0, rows <= image.height else { return }
        let rect = CGRect(x: 0, y: image.height - rows, width: image.width, height: rows)
        guard let band = image.cropping(to: rect) else { return }

        let colorSpace = band.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: band.width,
                                  height: band.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: band.width, height: band.height))
        guard let standalone = ctx.makeImage() else { return }

        bands.append(standalone)
        totalHeight += rows
        controlBar.updateStatus("已拼接 \(totalHeight) px")
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

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    func show(image: CGImage, pointSize: NSSize) {
        self.image = image
        self.pointSize = pointSize

        let visibleSize = NSSize(width: min(max(pointSize.width, 420), 1000),
                                 height: min(max(pointSize.height, 320), 820))

        let controller = NSWindowController()
        _ = controller
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

        let copyButton = NSButton(title: "复制到剪贴板", target: self, action: #selector(copyClicked))
        let saveButton = NSButton(title: "保存到文件", target: self, action: #selector(saveClicked))
        let pinButton = NSButton(title: "贴到屏幕", target: self, action: #selector(pinClicked))
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        copyButton.bezelStyle = .rounded
        saveButton.bezelStyle = .rounded
        pinButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded

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
