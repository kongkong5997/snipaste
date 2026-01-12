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
    private var isCapturing = false  // 防止重复调用
    private var currentCaptureTask: Task<Void, Never>?  // 当前截图任务

    private init() {}

    /// 开始截图 - 显示全屏截图窗口
    func startCapture() {
        print("🎬 startCapture 被调用")
        print("   - 当前 isCapturing: \(isCapturing)")
        print("   - 当前 captureWindow: \(captureWindow != nil ? "存在" : "nil")")

        // 取消之前的截图任务
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        isCapturing = false

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

        // 获取主屏幕
        guard let screen = NSScreen.main else {
            print("❌ 无法获取主屏幕")
            return
        }

        print("   - 创建新窗口...")
        // 创建全屏透明窗口
        captureWindow = CaptureWindow(screen: screen)
        captureWindow?.makeKeyAndOrderFront(nil)

        // 进入截图模式
        NSApp.activate(ignoringOtherApps: true)

        print("🎯 进入截图模式")
        print("   - 窗口创建完成: \(captureWindow != nil ? "✅" : "❌")")
        print("   - 窗口可见: \(captureWindow?.isVisible ?? false)")
    }

    /// 截取指定区域
    func captureRegion(_ rect: CGRect) {
        // 防止重复调用
        guard !isCapturing else {
            print("⚠️ 正在截图中，请勿重复调用")
            return
        }
        isCapturing = true

        // 创建并保存任务引用
        currentCaptureTask = Task {
            do {
                // 检查任务是否已被取消
                guard !Task.isCancelled else {
                    await MainActor.run {
                        isCapturing = false
                        currentCaptureTask = nil
                    }
                    return
                }

                // 获取可捕获的内容
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                // 再次检查取消状态
                guard !Task.isCancelled else {
                    await MainActor.run {
                        isCapturing = false
                        currentCaptureTask = nil
                    }
                    return
                }

                // 获取主显示器
                guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    print("❌ 无法获取主显示器")
                    await MainActor.run {
                        isCapturing = false
                        currentCaptureTask = nil
                        hideCaptureWindow()
                    }
                    return
                }

                // 创建截图配置
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = rect
                configuration.width = Int(rect.width)
                configuration.height = Int(rect.height)
                configuration.scalesToFit = false

                // 获取所有窗口的过滤器
                let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])

                // 创建截图
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

                // 最后检查取消状态
                guard !Task.isCancelled else {
                    await MainActor.run {
                        isCapturing = false
                        currentCaptureTask = nil
                    }
                    return
                }

                await MainActor.run {
                    let nsImage = NSImage(cgImage: image, size: rect.size)
                    print("✅ 截图成功！选区: \(rect), 图像尺寸: \(nsImage.size)")

                    // TODO: 保存或处理图像

                    isCapturing = false
                    currentCaptureTask = nil
                    hideCaptureWindow()
                }
            } catch {
                // 如果是任务取消错误，不打印
                if !Task.isCancelled {
                    print("❌ 截图失败: \(error)")
                }
                await MainActor.run {
                    isCapturing = false
                    currentCaptureTask = nil
                    hideCaptureWindow()
                }
            }
        }
    }

    /// 隐藏截图窗口
    func hideCaptureWindow() {
        // 防止重复调用
        guard captureWindow != nil else {
            print("⚠️ 截图窗口已经关闭，跳过重复调用")
            return
        }

        print("🚪 开始关闭截图窗口")

        // 重置状态
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        isCapturing = false

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
