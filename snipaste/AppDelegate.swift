//
//  AppDelegate.swift
//  snipaste
//
//  Created by Claude
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置应用不显示在 Dock
        NSApp.setActivationPolicy(.accessory)

        // 全局快捷键：装配动作后按当前设置注册
        // （默认 ⌘⇧X 开始截图，⌥⌘V 从剪贴板贴图，均可在设置页修改）
        HotKeyManager.shared.onAction = { action in
            switch action {
            case .screenshot:
                ScreenshotManager.shared.startCapture()
            case .fullScreen:
                ScreenshotManager.shared.startCapture(mode: .fullScreen)
            case .windowCapture:
                ScreenshotManager.shared.startCapture(mode: .window)
            case .repeatLast:
                ScreenshotManager.shared.startCapture(mode: .repeatLast)
            case .pinFromClipboard:
                PinnedImageController.shared.pinFromPasteboard()
            case .togglePins:
                PinnedImageController.shared.toggleVisibility()
            }
        }
        HotKeyManager.shared.resume()

        // 检查屏幕录制权限
        ScreenCapturePermission.checkAndRequestPermission()

        // 首次运行：弹一次使用说明
        if !UserDefaults.standard.bool(forKey: WelcomeWindowController.hasSeenKey) {
            UserDefaults.standard.set(true, forKey: WelcomeWindowController.hasSeenKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WelcomeWindowController.shared.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 菜单栏应用不应该在最后一个窗口关闭时退出
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("Finalizing cleanup before termination...")
        // 确保在退出前关闭所有截图窗口
        ScreenshotManager.shared.hideCaptureWindow()
    }
}
