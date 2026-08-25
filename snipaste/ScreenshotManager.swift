//
//  ScreenshotManager.swift
//  snipaste
//
//  Created by Claude
//

import AppKit
import ScreenCaptureKit

class ScreenshotManager {
    static let shared = ScreenshotManager()
    private var captureWindow: CaptureWindow?

    private init() {}

    /// 开始截图 - 显示全屏截图窗口
    func startCapture() {
        print("🎬 startCapture 被调用")
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

        // 选择鼠标所在的屏幕：多显示器时在哪个屏触发就截哪个屏，
        // 后续 CaptureView 的坐标转换和捕获都以这块屏为准
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            print("❌ 无法获取屏幕")
            return
        }

        print("   - 创建新窗口...")

        // 先激活应用
        NSApp.activate(ignoringOtherApps: true)

        // 创建全屏透明窗口
        captureWindow = CaptureWindow(screen: screen)

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
