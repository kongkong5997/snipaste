//
//  AppDelegate.swift
//  snipaste
//
//  Created by Claude
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置应用不显示在 Dock
        NSApp.setActivationPolicy(.accessory)

        // 注册全局快捷键 Cmd+Shift+X
        setupHotKeys()

        // 检查屏幕录制权限
        ScreenCapturePermission.checkAndRequestPermission()
    }

    func setupHotKeys() {
        // 使用 NSEvent 监听 Cmd+Shift+X
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // X key 的 keyCode 是 7
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 7 {
                self?.handleHotKeyPressed()
            }
        }
    }

    @objc private func handleHotKeyPressed() {
        print("⌨️ 快捷键 Cmd+Shift+X 被按下")
        // 触发截图
        ScreenshotManager.shared.startCapture()
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
