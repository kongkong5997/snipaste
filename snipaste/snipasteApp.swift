//
//  snipasteApp.swift
//  snipaste
//
//  Created by dino on 2026/1/9.
//

import SwiftUI

@main
struct SnipasteApp: App {
    // 注入 AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 使用 MenuBarExtra 创建菜单栏应用（macOS 13.0+）
        MenuBarExtra("截图", systemImage: "scissors") {
            // 快捷键由 AppDelegate 里的 RegisterEventHotKey 统一注册，
            // 这里不再加 keyboardShortcut，避免双重触发
            Button("截图", action: {
                ScreenshotManager.shared.startCapture()
            })

            Divider()

            Button("退出", action: {
                NSApplication.shared.terminate(nil)
            })
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}
