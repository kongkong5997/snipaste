//
//  ScreenCapturePermission.swift
//  snipaste
//
//  Created by Claude
//

import AppKit
import CoreGraphics

class ScreenCapturePermission {

    /// 检查是否拥有屏幕录制权限
    static func hasPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// 请求屏幕录制权限
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// 检查并请求权限（如果没有）
    static func checkAndRequestPermission() {
        if !hasPermission() {
            print("⚠️ 需要屏幕录制权限")
            requestPermission()
        } else {
            print("✅ 已拥有屏幕录制权限")
        }
    }

    /// 显示权限引导弹窗
    static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在系统设置 > 隐私与安全性 > 屏幕录制中允许此应用，然后重启应用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // 打开系统偏好设置的隐私设置页面
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
