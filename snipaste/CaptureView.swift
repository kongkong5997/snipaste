//
//  CaptureView.swift
//  snipaste
//
//  Created by Claude
//

import AppKit
import SwiftUI
import ScreenCaptureKit

class CaptureView: NSView {
    // 回调闭包
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    // 状态变量
    private var startPoint: NSPoint?
    private var currentRect: NSRect?
    private var isDragging = false
    private var confirmedSelectionRect: NSRect?
    private var toolbarHostingView: NSHostingView<FloatingToolbar>?
    private var isCapturing = false  // 防止重复截图
    private var isClosed = false  // 防止重复关闭
    private var currentCaptureTask: Task<Void, Never>?  // 当前截图任务

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    deinit {
        print("🗑️ CaptureView deinit")
        cleanup()
    }

    func cleanup() {
        print("🧹 Performing CaptureView cleanup...")
        // 取消所有进行中的任务
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        // 确保清理工具栏
        hideToolbar()
    }

    private func setupView() {
        // 接受第一响应者（用于接收键盘事件）
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 优先显示已确认的选区（工具栏模式）
        let displayRect = confirmedSelectionRect ?? currentRect

        // 如果有选区，先绘制选区边框（在遮罩之下）
        if let rect = displayRect {
            // 保存上下文状态
            context.saveGState()

            // 创建反向路径：整个屏幕减去选区
            let screenPath = NSBezierPath(rect: bounds)
            let selectionPath = NSBezierPath(rect: rect)
            screenPath.append(selectionPath)
            screenPath.windingRule = .evenOdd

            // 绘制半透明黑色遮罩（只在选区外部）
            NSColor.black.withAlphaComponent(0.3).setFill()
            screenPath.fill()

            // 恢复上下文状态
            context.restoreGState()

            // 绘制选区边框
            NSColor.white.setStroke()
            let borderWidth: CGFloat = 2.0
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = borderWidth
            borderPath.stroke()

            // 绘制尺寸信息
            let sizeText = NSString(format: "%.0f × %.0f", rect.width, rect.height)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let textSize = sizeText.size(withAttributes: attributes)

            // 文本背景框
            var textRect = NSRect(
                x: rect.origin.x,
                y: rect.origin.y - 28,
                width: textSize.width + 16,
                height: 24
            )

            // 确保文本框不超出屏幕
            if textRect.maxX > bounds.maxX {
                textRect.origin.x = bounds.maxX - textRect.width
            }
            if textRect.minY < bounds.minY {
                textRect.origin.y = rect.maxY + 4
            }

            // 绘制文本背景
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4).fill()

            // 绘制文本
            let textPoint = NSPoint(
                x: textRect.origin.x + (textRect.width - textSize.width) / 2,
                y: textRect.origin.y + (textRect.height - textSize.height) / 2
            )
            sizeText.draw(at: textPoint, withAttributes: attributes)
        } else {
            // 没有选区时，绘制整个屏幕的遮罩
            NSColor.black.withAlphaComponent(0.3).setFill()
            bounds.fill()
        }
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 检测双击
        if event.clickCount == 2, let rect = confirmedSelectionRect, rect.contains(point) {
            // 双击选区，截图并复制到剪贴板
            // 重要：延迟到下一个 runloop 执行，避免在事件处理中阻塞
            print("🖱️ 检测到双击，准备延迟执行截图")
            DispatchQueue.main.async { [weak self] in
                self?.handleDoubleClickSelection()
            }
            return
        }

        startPoint = point
        isDragging = true
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let rect = NSRect(
            x: min(start.x, currentPoint.x),
            y: min(start.y, currentPoint.y),
            width: abs(currentPoint.x - start.x),
            height: abs(currentPoint.y - start.y)
        )

        currentRect = rect
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false

        // 选区需要大于 10x10 像素才有效
        let minSize: CGFloat = 10
        if let rect = currentRect, rect.width > minSize, rect.height > minSize {
            // 完成选区，保存选区并显示工具栏
            confirmedSelectionRect = rect
            showToolbar(for: rect)
            onRegionSelected?(rect)
        } else {
            // 选区太小，取消
            hideToolbar()
            safeCancelAndClose()
        }

        startPoint = nil
        currentRect = nil
        needsDisplay = true
    }

    // MARK: - 工具栏管理

    private func showToolbar(for rect: NSRect) {
        // 移除旧的工具栏
        hideToolbar()

        print("📐 显示工具栏，选区(AppKit坐标): origin=(\(rect.origin.x), \(rect.origin.y)), size=(\(rect.width)x\(rect.height))")
        print("📐 屏幕边界(AppKit坐标): \(bounds)")

        // 创建 SwiftUI 工具栏
        let toolbar = FloatingToolbar(
            selectionRect: rect,
            screenBounds: bounds,
            onClose: { [weak self] in
                self?.safeCancelAndClose()
            },
            onPin: { [weak self] in
                self?.handlePinAction()
            },
            onCopy: { [weak self] in
                self?.handleCopyAction()
            }
        )

        // 使用 NSHostingView 托管 SwiftUI 视图
        let hostingView = NSHostingView(rootView: toolbar)
        hostingView.frame = bounds
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // 确保视图可见
        hostingView.alphaValue = 1.0
        hostingView.isHidden = false

        addSubview(hostingView)
        toolbarHostingView = hostingView

        print("📦 工具栏已添加到视图层级")
        print("   - NSHostingView frame: \(hostingView.frame)")
        print("   - NSHostingView superview: \(hostingView.superview != nil ? "✅" : "❌")")
        print("   - CaptureView subviews count: \(self.subviews.count)")
    }

    private func hideToolbar() {
        guard let hostingView = toolbarHostingView else { return }

        // 立即清空引用，防止重复调用
        toolbarHostingView = nil

        // 确保在主线程执行
        if Thread.isMainThread {
            hostingView.removeFromSuperview()
            print("🗑️ 工具栏已移除")
        } else {
            DispatchQueue.main.async {
                hostingView.removeFromSuperview()
                print("🗑️ 工具栏已移除（异步）")
            }
        }
    }

    private func clearSelection() {
        guard !isClosed else {
            print("⚠️ 已经关闭，跳过清理")
            return
        }

        // 取消截图任务
        currentCaptureTask?.cancel()
        currentCaptureTask = nil

        confirmedSelectionRect = nil
        isCapturing = false
        hideToolbar()
        needsDisplay = true
        print("🗑️ 选区已清除")
    }

    /// 安全地调用 onCancelled 回调，防止重复调用
    private func safeCancelAndClose() {
        guard !isClosed else {
            print("⚠️ 已经关闭，跳过重复调用")
            return
        }
        isClosed = true

        // 取消截图任务
        currentCaptureTask?.cancel()
        currentCaptureTask = nil

        print("🚪 安全关闭截图窗口")
        onCancelled?()
    }

    private func handlePinAction() {
        print("📌 置顶功能 - 待实现")
        // TODO: 实现置顶功能
    }

    private func handleCopyAction() {
        guard let rect = confirmedSelectionRect, !isCapturing else { return }
        print("📋 复制选区: \(rect)")

        startCaptureProcess()
    }

    private func handleDoubleClickSelection() {
        guard confirmedSelectionRect != nil, !isCapturing else { return }
        print("🖱️ 双击选区，开始截图并复制")

        startCaptureProcess()
    }

    private func startCaptureProcess() {
        guard !isCapturing else {
            print("⚠️ 已经在截图中，跳过")
            return
        }
        guard !isClosed else {
            print("⚠️ 窗口已关闭，跳过截图")
            return
        }
        isCapturing = true
        print("🎬 开始截图流程")

        // 保存选区引用
        guard let rect = confirmedSelectionRect else {
            print("❌ 没有选区")
            isCapturing = false
            return
        }

        print("📍 选区坐标（AppKit坐标系，原点在左下角）:")
        print("   - rect.origin: (\(rect.origin.x), \(rect.origin.y))")
        print("   - rect.size: (\(rect.width), \(rect.height))")
        print("   - 窗口bounds: \(window?.frame ?? .zero)")
        print("   - 屏幕frame: \(window?.screen?.frame ?? .zero)")

        // 先隐藏工具栏，避免截图包含工具栏
        hideToolbar()

        // 修改窗口透明度，给用户视觉反馈
        window?.alphaValue = 0.3

        // 取消之前的任务
        currentCaptureTask?.cancel()

        // 使用 Task 而不是 Task.detached，确保继承主 actor 上下文
        currentCaptureTask = Task { [weak self] in
            guard let self = self else {
                print("⚠️ CaptureView 已被释放（Task 开始时）")
                return
            }

            let startTime = Date()
            print("⏱️ [0ms] 开始后台截图任务")

            let success = await self.captureAndCopyToClipboard(rect: rect)

            let duration = Date().timeIntervalSince(startTime) * 1000
            print("⏱️ [\(Int(duration))ms] 截图任务完成，success: \(success)")

            // 确保在主线程处理结果
            await MainActor.run { [weak self] in
                guard let self = self else {
                    print("⚠️ CaptureView 已被释放（MainActor.run）")
                    return
                }

                guard !self.isClosed else {
                    print("⚠️ 窗口已关闭，跳过后续处理")
                    return
                }

                print("🔄 恢复窗口状态")
                self.isCapturing = false
                self.currentCaptureTask = nil
                self.window?.alphaValue = 1.0

                if success {
                    print("✅ 截图成功，准备关闭窗口")
                    print("📞 调用 safeCancelAndClose()")
                    self.safeCancelAndClose()
                    print("✅ safeCancelAndClose() 已调用")
                } else {
                    print("❌ 截图失败，恢复工具栏")
                    if let rect = self.confirmedSelectionRect {
                        self.showToolbar(for: rect)
                    }
                }
            }
        }
    }

    private func captureAndCopyToClipboard(rect: CGRect) async -> Bool {
        do {
            // 检查任务是否已取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            let step1Start = Date()
            print("⏱️ [Step 1] 开始获取屏幕内容...")

            // 获取可捕获的内容
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            let step1Duration = Date().timeIntervalSince(step1Start) * 1000
            print("⏱️ [Step 1] 屏幕内容获取完成，耗时: \(Int(step1Duration))ms")

            // 再次检查取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            // 使用截图窗口所在的屏幕，保证显示器、坐标系、缩放因子三者一致
            guard let screen = window?.screen ?? NSScreen.main,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                print("❌ 无法获取目标屏幕")
                return false
            }

            guard let mainDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                print("❌ 无法获取显示器 (displayID=\(displayID))")
                return false
            }

            print("⏱️ [Step 2] 配置截图参数...")

            // 获取屏幕缩放因子（Retina 屏幕为 2.0）
            let scaleFactor = screen.backingScaleFactor
            print("📱 屏幕缩放因子: \(scaleFactor)")

            // 获取屏幕高度用于坐标转换
            let screenHeight = screen.frame.height

            // 转换坐标系：AppKit（原点左下角）-> ScreenCaptureKit（原点左上角）
            // SCK的Y = 屏幕高度 - AppKit的Y - 选区高度
            let sckRect = CGRect(
                x: rect.origin.x,
                y: screenHeight - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )

            print("📍 坐标转换:")
            print("   - AppKit rect (原点左下角): origin=(\(rect.origin.x), \(rect.origin.y)), size=(\(rect.width)x\(rect.height))")
            print("   - SCK rect (原点左上角): origin=(\(sckRect.origin.x), \(sckRect.origin.y)), size=(\(sckRect.width)x\(sckRect.height))")
            print("   - 屏幕高度: \(screenHeight)")

            // 创建截图配置
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sckRect  // 使用转换后的坐标
            // 物理像素尺寸四舍五入，与源区域保持 1:1，不引入重采样缩放
            configuration.width = Int((rect.width * scaleFactor).rounded())
            configuration.height = Int((rect.height * scaleFactor).rounded())
            configuration.scalesToFit = false

            // 设置高质量参数
            configuration.showsCursor = false  // 不显示光标
            configuration.backgroundColor = .clear  // 透明背景
            configuration.pixelFormat = kCVPixelFormatType_32BGRA  // 高质量像素格式
            // 注意：不设置 colorSpaceName，保留显示器原生色彩空间，
            // 避免 P3 -> sRGB 转换造成色偏，保证截到的是"原图"

            print("📐 逻辑尺寸: \(Int(rect.width))x\(Int(rect.height))")
            print("📐 物理像素: \(configuration.width)x\(configuration.height)")

            // 获取所有窗口的过滤器，排除本应用的窗口，
            // 避免遮罩/选区边框被截进图像（否则边缘会带约 1px 白线）
            let bundleID = Bundle.main.bundleIdentifier
            let selfWindows = content.windows.filter { window in
                window.owningApplication?.bundleIdentifier == bundleID
            }
            let filter = SCContentFilter(display: mainDisplay, excludingWindows: selfWindows)

            let step2Start = Date()
            print("⏱️ [Step 3] 开始捕获图像...")

            // 创建截图
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

            let step2Duration = Date().timeIntervalSince(step2Start) * 1000
            print("⏱️ [Step 3] 图像捕获完成，耗时: \(Int(step2Duration))ms")
            print("📊 捕获的图像尺寸: \(image.width)x\(image.height)")

            // 再次检查取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            let step3Start = Date()
            print("⏱️ [Step 4] 准备图像数据...")

            // 直接在当前上下文生成 PNG 数据，不使用嵌套 Task
            print("⏱️ [后台] 开始生成 PNG 数据...")
            let dataStart = Date()

            // 创建 NSBitmapImageRep 来生成高质量图像数据
            let bitmapRep = NSBitmapImageRep(cgImage: image)

            // 正确设置逻辑尺寸（单位：points）
            bitmapRep.size = NSSize(width: CGFloat(image.width) / scaleFactor, height: CGFloat(image.height) / scaleFactor)

            print("📊 BitmapRep 像素尺寸: \(bitmapRep.pixelsWide)x\(bitmapRep.pixelsHigh)")
            print("📊 BitmapRep 逻辑尺寸: \(bitmapRep.size)")
            print("📊 计算的 DPI: \(72.0 * scaleFactor)") // 标准 72 DPI * 缩放因子

            // 使用 TIFF 格式（无损且保留所有元数据）
            guard let tiffData = bitmapRep.tiffRepresentation else {
                print("❌ [后台] 无法生成 TIFF 数据")
                return false
            }

            let dataDuration = Date().timeIntervalSince(dataStart) * 1000
            print("⏱️ [后台] TIFF 数据生成完成，耗时: \(Int(dataDuration))ms, 大小: \(tiffData.count) bytes")

            let step3Duration = Date().timeIntervalSince(step3Start) * 1000
            print("⏱️ [Step 4] 图像数据准备完成，总耗时: \(Int(step3Duration))ms")

            // 最后检查取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            // 在主线程操作剪贴板
            let success = await MainActor.run {
                print("⏱️ [主线程] 写入剪贴板...")
                let pasteboardStart = Date()

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()

                // 方法1：TIFF，默认无压缩，逐字节保留原始像素；
                // 先写入的类型成为首选类型，粘贴方优先取用
                let tiffResult = pasteboard.setData(tiffData, forType: .tiff)
                print("   - TIFF 写入: \(tiffResult ? "✅" : "❌")")

                // 方法2：PNG，无损压缩——解码后像素与原图完全一致，
                // 兼容只认 PNG 的应用；两者都不会有画质损失
                if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                    let pngResult = pasteboard.setData(pngData, forType: .png)
                    print("   - PNG 写入: \(pngResult ? "✅" : "❌")")
                }

                let duration = Date().timeIntervalSince(pasteboardStart) * 1000
                print("⏱️ [主线程] 剪贴板写入完成，耗时: \(Int(duration))ms")

                return tiffResult
            }

            if success {
                print("✅ 截图已复制到剪贴板")
            } else {
                print("❌ 剪贴板写入失败")
            }
            return success
        } catch {
            print("❌ 截图失败: \(error)")
            print("❌ 错误详情: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 键盘事件

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        // ESC key (keyCode = 53)
        if event.keyCode == 53 {
            if confirmedSelectionRect != nil {
                // 如果有已确认的选区，清除选区
                clearSelection()
            } else {
                // 否则取消整个截图
                isCapturing = false
                safeCancelAndClose()
            }
        } else {
            super.keyDown(with: event)
        }
    }
}
