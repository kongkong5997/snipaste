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
            // 快捷键由 HotKeyManager 统一按设置注册，
            // 这里不再加 keyboardShortcut，避免双重触发
            Button("区域截图", action: {
                ScreenshotManager.shared.startCapture()
            })

            Button("全屏截图", action: {
                ScreenshotManager.shared.startCapture(mode: .fullScreen)
            })

            Button("窗口截图", action: {
                ScreenshotManager.shared.startCapture(mode: .window)
            })

            Button("重复上一次截图", action: {
                ScreenshotManager.shared.startCapture(mode: .repeatLast)
            })

            Divider()

            Button("从剪贴板贴图", action: {
                PinnedImageController.shared.pinFromPasteboard()
            })

            Button("隐藏 / 显示所有贴图", action: {
                PinnedImageController.shared.toggleVisibility()
            })

            HistoryMenu()

            Divider()

            Button("设置…", action: {
                SettingsWindowController.shared.show()
            })

            Button("使用说明", action: {
                WelcomeWindowController.shared.show()
            })

            Button("检查更新…", action: {
                UpdateChecker.checkAndReport()
            })

            Text("版本 \(UpdateChecker.displayVersion)")

            Divider()

            Button("退出", action: {
                NSApplication.shared.terminate(nil)
            })
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

/// 菜单栏里的"最近截图"子菜单：点击条目即复制回剪贴板
private struct HistoryMenu: View {

    @ObservedObject private var history = ScreenshotHistory.shared

    var body: some View {
        Menu("最近截图") {
            if history.items.isEmpty {
                Text("暂无记录")
            } else {
                ForEach(history.items) { item in
                    Button(item.summary) {
                        ImageClipboard.copy(item.image, pointSize: item.pointSize)
                        Feedback.success("已复制历史截图")
                    }
                }
                Divider()
                Button("清空最近截图") {
                    history.clear()
                }
            }
        }
    }
}
