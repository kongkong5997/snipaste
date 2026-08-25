//
//  CaptureWindow.swift
//  snipaste
//
//  Created by Claude
//

import AppKit

class CaptureWindow: NSWindow {
    private var captureView: CaptureView
    private var viewController: NSViewController

    init(screen: NSScreen) {
        let rect = screen.frame
        captureView = CaptureView(frame: rect)
        viewController = NSViewController()
        viewController.view = captureView

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // 设置内容视图控制器
        self.contentViewController = viewController

        // 窗口配置
        setupWindow()
        setupCallbacks()

        // 确保窗口立即成为焦点
        makeFirstResponder(captureView)
    }

    private func setupWindow() {
        // 透明窗口配置
        isOpaque = false
        backgroundColor = .clear

        // 窗口层级 - 确保在所有窗口之上
        level = .screenSaver

        // 确保窗口可以接收鼠标事件
        ignoresMouseEvents = false

        // 接收 mouseMoved 事件，用于悬浮时切换光标
        acceptsMouseMovedEvents = true

        // 窗口行为
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 手动管理窗口释放，避免立即释放导致的问题
        isReleasedWhenClosed = false
    }

    func cleanup() {
        print("🧹 Cleaning up CaptureWindow...")
        captureView.cleanup()
        contentViewController = nil
    }

    private func setupCallbacks() {
        // 选区完成回调
        captureView.onRegionSelected = { [weak self] rect in
            self?.handleRegionSelected(rect)
        }

        // 取消回调
        captureView.onCancelled = { [weak self] in
            self?.handleCancelled()
        }
    }

    private func handleRegionSelected(_ rect: CGRect) {
        // 选区已完成，工具栏已显示
        // 现在等待用户从工具栏选择操作
        // 不再立即截图
        print("✅ 选区已完成: \(rect)")
    }

    private func handleCancelled() {
        ScreenshotManager.shared.hideCaptureWindow()
    }

    // MARK: - 重写方法

    override var canBecomeKey: Bool {
        return true
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeKey() {
        super.becomeKey()
        print("🪟 窗口成为 key")
    }

    override func resignKey() {
        super.resignKey()
        print("🪟⚠️ 窗口失去 key（此后的第一次点击可能被系统吞掉用于激活）")
    }
}
