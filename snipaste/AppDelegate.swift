//
//  AppDelegate.swift
//  snipaste
//
//  Created by Claude
//

import AppKit
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置应用不显示在 Dock
        NSApp.setActivationPolicy(.accessory)

        // 注册全局快捷键 Cmd+Shift+X
        setupHotKeys()

        // 检查屏幕录制权限
        ScreenCapturePermission.checkAndRequestPermission()
    }

    func setupHotKeys() {
        // 使用 RegisterEventHotKey 注册全局快捷键：
        // 不需要"输入监听"权限，且本应用处于前台时同样生效（NSEvent 全局监听两者都做不到）
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            print("⌨️ 快捷键 Cmd+Shift+X 被按下")
            ScreenshotManager.shared.startCapture()
            return noErr
        }, 1, &eventType, nil, nil)

        // X 的 keyCode 是 7（kVK_ANSI_X）
        var hotKeyID = EventHotKeyID(signature: OSType(0x534E4950) /* 'SNIP' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_X),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            print("❌ 全局快捷键注册失败: \(status)")
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
