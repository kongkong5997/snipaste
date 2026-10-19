//
//  AppSettings.swift
//  snipaste
//
//  全局设置：UserDefaults 持久化，改完立即生效（快捷键会重新注册）
//

import AppKit
import Combine
import ServiceManagement

/// 截图完成后的默认动作（双击选区 / 回车触发）
enum CaptureDefaultAction: String, CaseIterable, Identifiable {
    case copy
    case save
    case pin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copy: return "复制到剪贴板"
        case .save: return "保存到文件"
        case .pin: return "贴到屏幕"
        }
    }
}

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - UserDefaults 键

    private enum Key {
        static let screenshotKeyCode = "shortcut.screenshot.keyCode"
        static let screenshotModifiers = "shortcut.screenshot.modifiers"
        static let pinKeyCode = "shortcut.pin.keyCode"
        static let pinModifiers = "shortcut.pin.modifiers"
        static let fullScreenKeyCode = "shortcut.fullScreen.keyCode"
        static let fullScreenModifiers = "shortcut.fullScreen.modifiers"
        static let windowKeyCode = "shortcut.window.keyCode"
        static let windowModifiers = "shortcut.window.modifiers"
        static let repeatKeyCode = "shortcut.repeat.keyCode"
        static let repeatModifiers = "shortcut.repeat.modifiers"
        static let togglePinsKeyCode = "shortcut.togglePins.keyCode"
        static let togglePinsModifiers = "shortcut.togglePins.modifiers"
        static let defaultAction = "capture.defaultAction"
        static let includeCursor = "capture.includeCursor"
        static let lastSelection = "capture.lastSelection"
        static let includePinnedImages = "capture.includePinnedImages"
        static let updateFeedURL = "update.feedURL"
        static let snapToWindows = "capture.snapToWindows"
        static let showSizeLabel = "capture.showSizeLabel"
        static let doubleClickCopies = "capture.doubleClickCopies"
        static let maskOpacity = "capture.maskOpacity"
        static let annotationColor = "annotation.color"
        static let annotationLineWidth = "annotation.lineWidth"
        static let pinDoubleClickClose = "pin.doubleClickClose"
        static let saveFormat = "save.format"
        static let jpegQuality = "save.jpegQuality"
        static let saveFileNamePrefix = "save.fileNamePrefix"
        static let saveDirectoryBookmark = "save.directoryBookmark"
        static let saveDirectoryPath = "save.directoryPath"
        static let showToast = "feedback.showToast"
        static let playSound = "feedback.playSound"
    }

    private let defaults: UserDefaults

    // MARK: - 快捷键

    /// 区域截图（默认 ⇧⌘X）
    @Published var screenshotShortcut: HotKeyDescriptor {
        didSet { shortcutsDidChange() }
    }

    /// 全屏截图（默认 ⌃⌘A）
    @Published var fullScreenShortcut: HotKeyDescriptor {
        didSet { shortcutsDidChange() }
    }

    /// 窗口截图（默认 ⌃⌘W）
    @Published var windowShortcut: HotKeyDescriptor {
        didSet { shortcutsDidChange() }
    }

    /// 重复上一次截图（默认 ⌃⌘R）
    @Published var repeatShortcut: HotKeyDescriptor {
        didSet { shortcutsDidChange() }
    }

    /// 从剪贴板贴图（默认 ⌥⌘V）
    @Published var pinShortcut: HotKeyDescriptor {
        didSet { shortcutsDidChange() }
    }

    /// 隐藏 / 显示所有贴图（默认 ⌃⌘H）
    @Published var togglePinsShortcut: HotKeyDescriptor {
        didSet { shortcutsDidChange() }
    }

    private func shortcutsDidChange() {
        saveShortcuts()
        HotKeyManager.shared.apply()
    }

    private func saveShortcuts() {
        defaults.set(Int(screenshotShortcut.keyCode), forKey: Key.screenshotKeyCode)
        defaults.set(Int(screenshotShortcut.modifiers), forKey: Key.screenshotModifiers)
        defaults.set(Int(fullScreenShortcut.keyCode), forKey: Key.fullScreenKeyCode)
        defaults.set(Int(fullScreenShortcut.modifiers), forKey: Key.fullScreenModifiers)
        defaults.set(Int(windowShortcut.keyCode), forKey: Key.windowKeyCode)
        defaults.set(Int(windowShortcut.modifiers), forKey: Key.windowModifiers)
        defaults.set(Int(repeatShortcut.keyCode), forKey: Key.repeatKeyCode)
        defaults.set(Int(repeatShortcut.modifiers), forKey: Key.repeatModifiers)
        defaults.set(Int(pinShortcut.keyCode), forKey: Key.pinKeyCode)
        defaults.set(Int(pinShortcut.modifiers), forKey: Key.pinModifiers)
        defaults.set(Int(togglePinsShortcut.keyCode), forKey: Key.togglePinsKeyCode)
        defaults.set(Int(togglePinsShortcut.modifiers), forKey: Key.togglePinsModifiers)
    }

    // MARK: - 截图

    /// 拖拽 / 悬浮时自动吸附到应用窗口边缘
    @Published var snapToWindows: Bool {
        didSet { defaults.set(snapToWindows, forKey: Key.snapToWindows) }
    }

    /// 显示选区尺寸标签
    @Published var showSizeLabel: Bool {
        didSet { defaults.set(showSizeLabel, forKey: Key.showSizeLabel) }
    }

    /// 双击选区直接复制、结束截图
    @Published var doubleClickCopies: Bool {
        didSet { defaults.set(doubleClickCopies, forKey: Key.doubleClickCopies) }
    }

    /// 选区外的遮罩暗度（0.1 – 0.6）
    @Published var maskOpacity: Double {
        didSet { defaults.set(maskOpacity, forKey: Key.maskOpacity) }
    }

    /// 截图是否包含鼠标指针
    @Published var includeCursor: Bool {
        didSet { defaults.set(includeCursor, forKey: Key.includeCursor) }
    }

    /// 双击选区 / 回车的默认动作
    @Published var defaultAction: CaptureDefaultAction {
        didSet { defaults.set(defaultAction.rawValue, forKey: Key.defaultAction) }
    }

    /// 截图是否把贴图窗口也截进画面（默认是：贴图是画面的一部分，避免"看得见截不到"）
    @Published var includePinnedImages: Bool {
        didSet { defaults.set(includePinnedImages, forKey: Key.includePinnedImages) }
    }

    /// 更新检查地址（JSON：{"version": "1.1", "url": "下载页"}），留空表示不检查
    @Published var updateFeedURL: String {
        didSet { defaults.set(updateFeedURL, forKey: Key.updateFeedURL) }
    }

    /// 上一次的选区（视图坐标 pt），"重复上一次截图"用
    private(set) var lastSelectionRect: NSRect?

    /// 记录本次选区，供下次"重复上一次截图"使用
    func rememberSelection(_ rect: NSRect) {
        lastSelectionRect = rect
        defaults.set([Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
                     forKey: Key.lastSelection)
    }

    // MARK: - 标注

    /// 新标注的默认颜色（已有标注保持各自颜色）
    @Published var annotationColor: NSColor {
        didSet { Self.save(color: annotationColor, to: defaults, key: Key.annotationColor) }
    }

    /// 新标注的默认线宽（pt）
    @Published var annotationLineWidth: Double {
        didSet { defaults.set(annotationLineWidth, forKey: Key.annotationLineWidth) }
    }

    // MARK: - 贴图

    /// 双击贴图关闭（关掉可避免误触，右键菜单仍可关闭）
    @Published var pinDoubleClickClose: Bool {
        didSet { defaults.set(pinDoubleClickClose, forKey: Key.pinDoubleClickClose) }
    }

    // MARK: - 保存

    /// 保存格式（PNG / JPEG）
    @Published var saveFormat: ImageFileFormat {
        didSet { defaults.set(saveFormat.rawValue, forKey: Key.saveFormat) }
    }

    /// JPEG 质量（0.6 – 1.0）
    @Published var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) }
    }

    /// 文件名前缀，最终形如「前缀_2026-10-18_14-32-05.png」
    @Published var saveFileNamePrefix: String {
        didSet { defaults.set(saveFileNamePrefix, forKey: Key.saveFileNamePrefix) }
    }

    /// 快速保存目录（沙箱下只能写用户主动选过的目录，用安全作用域书签持久化授权）
    @Published private(set) var saveDirectoryPath: String?

    /// 目录设置失败提示
    @Published var saveDirectoryError: String?

    private var saveDirectoryBookmark: Data?

    // MARK: - 反馈

    /// 显示操作提示（顶部轻提示条）
    @Published var showToast: Bool {
        didSet { defaults.set(showToast, forKey: Key.showToast) }
    }

    /// 操作提示音
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Key.playSound) }
    }

    // MARK: - 通用

    /// 登录时启动（真实状态来自 SMAppService，设置失败会回滚并给出提示）
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
                print("⚙️ 登录时启动：\(launchAtLogin ? "已开启" : "已关闭")")
            } catch {
                launchAtLoginError = "设置开机启动失败：\(error.localizedDescription)"
                print("⚙️❌ \(launchAtLoginError ?? "")")
                // 回滚开关，避免界面状态与系统不一致
                isSyncingLaunchAtLogin = true
                launchAtLogin = oldValue
                isSyncingLaunchAtLogin = false
            }
        }
    }

    /// 开机启动设置失败提示（nil = 无错误）
    @Published var launchAtLoginError: String?

    private var isSyncingLaunchAtLogin = false

    // MARK: - 初始化

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        screenshotShortcut = Self.loadShortcut(from: defaults,
                                               codeKey: Key.screenshotKeyCode,
                                               modifiersKey: Key.screenshotModifiers,
                                               fallback: .defaultScreenshot)
        pinShortcut = Self.loadShortcut(from: defaults,
                                        codeKey: Key.pinKeyCode,
                                        modifiersKey: Key.pinModifiers,
                                        fallback: .defaultPin)
        snapToWindows = defaults.object(forKey: Key.snapToWindows) as? Bool ?? true
        showSizeLabel = defaults.object(forKey: Key.showSizeLabel) as? Bool ?? true
        doubleClickCopies = defaults.object(forKey: Key.doubleClickCopies) as? Bool ?? true
        maskOpacity = defaults.object(forKey: Key.maskOpacity) as? Double ?? 0.3
        annotationColor = Self.loadColor(from: defaults, key: Key.annotationColor)
            ?? AnnotationRenderer.defaultStrokeColor
        annotationLineWidth = defaults.object(forKey: Key.annotationLineWidth) as? Double
            ?? Double(AnnotationRenderer.defaultStrokeWidth)
        pinDoubleClickClose = defaults.object(forKey: Key.pinDoubleClickClose) as? Bool ?? true
        fullScreenShortcut = Self.loadShortcut(from: defaults,
                                               codeKey: Key.fullScreenKeyCode,
                                               modifiersKey: Key.fullScreenModifiers,
                                               fallback: .defaultFullScreen)
        windowShortcut = Self.loadShortcut(from: defaults,
                                           codeKey: Key.windowKeyCode,
                                           modifiersKey: Key.windowModifiers,
                                           fallback: .defaultWindowCapture)
        repeatShortcut = Self.loadShortcut(from: defaults,
                                           codeKey: Key.repeatKeyCode,
                                           modifiersKey: Key.repeatModifiers,
                                           fallback: .defaultRepeatLast)
        togglePinsShortcut = Self.loadShortcut(from: defaults,
                                               codeKey: Key.togglePinsKeyCode,
                                               modifiersKey: Key.togglePinsModifiers,
                                               fallback: .defaultTogglePins)
        includeCursor = defaults.object(forKey: Key.includeCursor) as? Bool ?? false
        includePinnedImages = defaults.object(forKey: Key.includePinnedImages) as? Bool ?? true
        updateFeedURL = defaults.string(forKey: Key.updateFeedURL) ?? ""
        defaultAction = CaptureDefaultAction(rawValue: defaults.string(forKey: Key.defaultAction) ?? "") ?? .copy
        if let values = defaults.array(forKey: Key.lastSelection) as? [Double], values.count == 4 {
            lastSelectionRect = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }

        saveFormat = ImageFileFormat(rawValue: defaults.string(forKey: Key.saveFormat) ?? "") ?? .png
        jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9
        saveFileNamePrefix = defaults.string(forKey: Key.saveFileNamePrefix) ?? "截图"
        saveDirectoryPath = defaults.string(forKey: Key.saveDirectoryPath)
        saveDirectoryBookmark = defaults.data(forKey: Key.saveDirectoryBookmark)
        showToast = defaults.object(forKey: Key.showToast) as? Bool ?? true
        playSound = defaults.object(forKey: Key.playSound) as? Bool ?? true
        launchAtLogin = Self.currentLaunchAtLogin()
    }

    // MARK: - 操作

    /// 与系统实际状态同步（打开设置窗口时调用，覆盖在系统设置里被改动的情况）
    func syncLaunchAtLoginStatus() {
        let actual = Self.currentLaunchAtLogin()
        guard launchAtLogin != actual else { return }
        isSyncingLaunchAtLogin = true
        launchAtLogin = actual
        isSyncingLaunchAtLogin = false
    }

    /// 恢复默认设置（不改动系统的"登录时启动"状态）
    func resetToDefaults() {
        screenshotShortcut = .defaultScreenshot
        fullScreenShortcut = .defaultFullScreen
        windowShortcut = .defaultWindowCapture
        repeatShortcut = .defaultRepeatLast
        pinShortcut = .defaultPin
        togglePinsShortcut = .defaultTogglePins
        includeCursor = false
        includePinnedImages = true
        defaultAction = .copy
        snapToWindows = true
        showSizeLabel = true
        doubleClickCopies = true
        maskOpacity = 0.3
        annotationColor = AnnotationRenderer.defaultStrokeColor
        annotationLineWidth = Double(AnnotationRenderer.defaultStrokeWidth)
        pinDoubleClickClose = true
        saveFormat = .png
        jpegQuality = 0.9
        saveFileNamePrefix = "截图"
        showToast = true
        playSound = true
        clearSaveDirectory()
        launchAtLoginError = nil
        print("⚙️ 设置已恢复默认")
    }

    // MARK: - 快速保存目录

    /// 设置窗口「选择…」：让用户挑一个目录，用安全作用域书签记住授权
    func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择用于快速保存截图的文件夹"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            saveDirectoryError = "无法记住该目录，请换一个再试"
            print("⚙️❌ 快速保存目录书签创建失败: \(url.path)")
            return
        }
        saveDirectoryBookmark = bookmark
        saveDirectoryPath = url.path
        defaults.set(bookmark, forKey: Key.saveDirectoryBookmark)
        defaults.set(url.path, forKey: Key.saveDirectoryPath)
        saveDirectoryError = nil
        print("⚙️ 快速保存目录: \(url.path)")
    }

    func clearSaveDirectory() {
        saveDirectoryBookmark = nil
        saveDirectoryPath = nil
        saveDirectoryError = nil
        defaults.removeObject(forKey: Key.saveDirectoryBookmark)
        defaults.removeObject(forKey: Key.saveDirectoryPath)
    }

    /// 解析快速保存目录并开启安全作用域访问；未配置 / 解析失败返回 nil（调用方回退到保存面板）。
    /// 用完需要调用 stopAccessingSecurityScopedResource()
    func beginAccessingSaveDirectory() -> URL? {
        guard let bookmark = saveDirectoryBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            saveDirectoryError = "快速保存目录已失效，请重新选择"
            return nil
        }
        // 非沙箱环境下可能返回 false，此时仍可直接写入，忽略返回值
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    // MARK: - 读写辅助

    private static func loadShortcut(from defaults: UserDefaults, codeKey: String,
                                     modifiersKey: String, fallback: HotKeyDescriptor) -> HotKeyDescriptor {
        guard defaults.object(forKey: codeKey) != nil else { return fallback }
        return HotKeyDescriptor(
            keyCode: UInt32(clamping: defaults.integer(forKey: codeKey)),
            modifiers: UInt32(clamping: defaults.integer(forKey: modifiersKey))
        )
    }

    /// 命令行 / 无 bundle 环境下 SMAppService 不可用，直接当作未开启
    private static func currentLaunchAtLogin() -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    private static func save(color: NSColor, to defaults: UserDefaults, key: String) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        defaults.set("\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent)",
                     forKey: key)
    }

    private static func loadColor(from defaults: UserDefaults, key: String) -> NSColor? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }
}
