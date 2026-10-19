//
//  WelcomeView.swift
//  snipaste
//
//  首次运行引导（菜单"使用说明"可再次打开）
//

import AppKit
import SwiftUI

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {

    static let shared = WelcomeWindowController()

    /// 记录是否已经看过引导
    static let hasSeenKey = "welcome.hasSeen"

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    /// 展示引导窗口
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "使用说明"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {

    private let settings = AppSettings.shared
    @State private var hasPermission = ScreenCapturePermission.hasPermission()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "scissors")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("截图工具已就绪").font(.title2.weight(.semibold))
                    Text("按快捷键随时截图，完成后可标注、复制、保存或贴到屏幕上。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            row(icon: "keyboard", title: "全局快捷键",
                detail: "区域截图 \(settings.screenshotShortcut.displayString)，全屏 \(settings.fullScreenShortcut.displayString)，窗口 \(settings.windowShortcut.displayString)，从剪贴板贴图 \(settings.pinShortcut.displayString)。都可以在设置里修改。")

            row(icon: hasPermission ? "checkmark.seal" : "exclamationmark.triangle",
                title: hasPermission ? "屏幕录制权限已授权" : "还差屏幕录制权限",
                detail: hasPermission
                    ? "截图功能可用。"
                    : "首次截图前需要在系统设置的隐私与安全性里授权，授权后请重启应用。")

            row(icon: "pencil.tip", title: "截图里能做什么",
                detail: "选区完成后工具栏提供画笔、方框、椭圆、直线、箭头、文字、序号、马赛克、模糊、橡皮擦；⌘S 保存、⌘C 复制、⌘Z 撤销、数字键 1–0 切换工具。")

            row(icon: "pin", title: "贴图",
                detail: "把截图或剪贴板里的图片钉在屏幕上，滚轮缩放、右键可复制 / 另存为 / 关闭；也能一键隐藏全部贴图。")

            Divider()

            HStack {
                if !hasPermission {
                    Button("打开系统设置授权") {
                        ScreenCapturePermission.openPrivacySettings()
                        hasPermission = ScreenCapturePermission.hasPermission()
                    }
                }
                Spacer()
                Button("打开设置") { SettingsWindowController.shared.show() }
                Button("开始使用") { WelcomeWindowController.shared.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
