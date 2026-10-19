//
//  ScreenshotManager.swift
//  snipaste
//
//  Created by Claude
//

import AppKit
import ScreenCaptureKit

/// 截图会话的进入方式
enum CaptureMode {
    case region        // 手动拖拽选择区域
    case fullScreen    // 整个屏幕（多显示器时为全部显示器）
    case window        // 点选窗口：自动高亮窗口，点击即选中
    case repeatLast    // 恢复上一次的选区
}

class ScreenshotManager {
    static let shared = ScreenshotManager()
    private var captureWindow: CaptureWindow?

    private init() {}

    /// 开始截图 - 显示全屏截图窗口
    /// - Parameter mode: 进入方式（区域拖拽 / 全屏 / 窗口点选 / 重复上次选区）
    func startCapture(mode: CaptureMode = .region) {
        print("🎬 startCapture 被调用 mode=\(mode)")
        print("   - 当前 captureWindow: \(captureWindow != nil ? "存在" : "nil")")

        // 检查权限
        guard ScreenCapturePermission.hasPermission() else {
            print("❌ 没有屏幕录制权限")
            ScreenCapturePermission.showPermissionAlert()
            return
        }

        // 关闭已存在的窗口
        captureWindow?.close()
        captureWindow = nil
        print("   - 已清理旧窗口")

        // 覆盖所有显示器的并集：支持跨屏选区；单屏时就是该屏本身
        let union = DisplayStitcher.unionFrame(of: NSScreen.screens.map { $0.frame })
        guard !union.isNull, union.width > 0, union.height > 0 else {
            print("❌ 无法获取屏幕")
            return
        }

        // 隐藏设置窗口：本应用的窗口不会进入截图，避免"看得见却截不到"的困惑
        SettingsWindowController.shared.hideDuringCapture()

        print("   - 创建新窗口...")

        // 先激活应用
        NSApp.activate(ignoringOtherApps: true)

        // 创建全屏透明窗口
        captureWindow = CaptureWindow(windowFrame: union, mode: mode)

        // 确保窗口获得焦点
        captureWindow?.makeKeyAndOrderFront(nil)

        // 再次确保窗口是 key window
        captureWindow?.makeKey()

        print("🎯 进入截图模式")
        print("   - 窗口创建完成: \(captureWindow != nil ? "✅" : "❌")")
        print("   - 窗口可见: \(captureWindow?.isVisible ?? false)")
        print("   - 窗口是否为 key: \(captureWindow?.isKeyWindow ?? false)")
    }

    /// 隐藏截图窗口
    func hideCaptureWindow() {
        // 防止重复调用
        guard captureWindow != nil else {
            print("⚠️ 截图窗口已经关闭，跳过重复调用")
            return
        }

        // 截图会话结束，恢复之前隐藏的设置窗口
        SettingsWindowController.shared.restoreAfterCapture()

        print("🚪 开始关闭截图窗口")

        // 保存窗口引用
        guard let window = captureWindow else { return }
        captureWindow = nil  // 立即清空引用，防止重复调用

        // 异步关闭窗口，避免阻塞主线程
        DispatchQueue.main.async {
            print("🧹 执行窗口清理...")
            window.cleanup()

            // 先隐藏窗口，立即给用户反馈
            window.orderOut(nil)
            print("👻 窗口已隐藏")

            // 延迟关闭窗口，确保所有清理完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                window.close()
                print("✅ 窗口已关闭并释放")
            }
        }
    }
}
