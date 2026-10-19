//
//  SettingsView.swift
//  snipaste
//
//  设置窗口：分组式设置页（快捷键 / 截图 / 标注 / 贴图 / 通用）
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 设置窗口控制器

/// 菜单栏应用没有标准的偏好设置窗口入口，这里手动管理一个单例窗口
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var hiddenDuringCapture = false

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    /// 打开（或前置）设置窗口
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 截图开始前隐藏：本应用的窗口不会进入截图，避免"看得见却截不到"的困惑
    func hideDuringCapture() {
        guard let window, window.isVisible else { return }
        hiddenDuringCapture = true
        window.orderOut(nil)
    }

    /// 截图会话结束后恢复
    func restoreAfterCapture() {
        guard hiddenDuringCapture else { return }
        hiddenDuringCapture = false
        window?.orderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 录制中关闭窗口时保证全局快捷键恢复注册
        HotKeyManager.shared.resume()
        // 关掉随颜色选择器弹出的取色面板
        NSColorPanel.shared.close()
    }
}

// MARK: - 设置页

struct SettingsView: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared

    @State private var showResetConfirm = false
    @State private var hasScreenPermission = ScreenCapturePermission.hasPermission()

    var body: some View {
        Form {
            shortcutSection
            captureSection
            saveSection
            annotationSection
            pinSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 780)
        .onAppear {
            settings.syncLaunchAtLoginStatus()
            hasScreenPermission = ScreenCapturePermission.hasPermission()
        }
        .confirmationDialog("恢复默认设置？", isPresented: $showResetConfirm) {
            Button("恢复默认", role: .destructive) { settings.resetToDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有设置项将回到初始值。")
        }
    }

    // MARK: 快捷键

    private var shortcutSection: some View {
        Section {
            LabeledContent("区域截图") {
                ShortcutRecorder(descriptor: $settings.screenshotShortcut)
            }
            LabeledContent("全屏截图") {
                ShortcutRecorder(descriptor: $settings.fullScreenShortcut)
            }
            LabeledContent("窗口截图") {
                ShortcutRecorder(descriptor: $settings.windowShortcut)
            }
            LabeledContent("重复上一次截图") {
                ShortcutRecorder(descriptor: $settings.repeatShortcut)
            }
            LabeledContent("从剪贴板贴图") {
                ShortcutRecorder(descriptor: $settings.pinShortcut)
            }
            LabeledContent("隐藏 / 显示所有贴图") {
                ShortcutRecorder(descriptor: $settings.togglePinsShortcut)
            }
        } header: {
            Text("快捷键")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("点击右侧按钮后按下新组合键：⌫ 清除，⎋ 取消。快捷键需包含 ⌘ / ⌥ / ⌃，或使用 F1–F20。")
                if let error = hotKeys.registrationError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: 截图

    private var captureSection: some View {
        Section("截图") {
            Toggle("智能吸附到窗口边缘", isOn: $settings.snapToWindows)
            Toggle("显示选区尺寸", isOn: $settings.showSizeLabel)
            Toggle("包含鼠标指针", isOn: $settings.includeCursor)
            Toggle("双击选区执行默认动作", isOn: $settings.doubleClickCopies)
            Picker("默认动作", selection: $settings.defaultAction) {
                ForEach(CaptureDefaultAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
            LabeledContent("遮罩暗度") {
                HStack(spacing: 8) {
                    Slider(value: $settings.maskOpacity, in: 0.1...0.6)
                        .frame(width: 170)
                    Text("\(Int(settings.maskOpacity * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // MARK: 保存

    private var saveSection: some View {
        Section {
            Picker("图片格式", selection: $settings.saveFormat) {
                ForEach(ImageFileFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            if settings.saveFormat.supportsQuality {
                LabeledContent("JPEG 质量") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.jpegQuality, in: 0.6...1.0, step: 0.05)
                            .frame(width: 170)
                        Text("\(Int(settings.jpegQuality * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            TextField("文件名前缀", text: $settings.saveFileNamePrefix)

            LabeledContent("快速保存目录") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(settings.saveDirectoryPath ?? "未设置，保存时弹出对话框")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)
                    HStack(spacing: 8) {
                        Button("选择…") { settings.chooseSaveDirectory() }
                        if settings.saveDirectoryPath != nil {
                            Button("清除") { settings.clearSaveDirectory() }
                        }
                    }
                }
            }

            if let error = settings.saveDirectoryError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("保存")
        } footer: {
            Text("按 ⌘S 或工具栏保存按钮：已设置目录时直接保存，否则弹出保存对话框。")
        }
    }

    // MARK: 标注

    private var annotationSection: some View {
        Section("标注") {
            ColorPicker("标注颜色", selection: annotationColorBinding, supportsOpacity: false)
            LabeledContent("线条粗细") {
                HStack(spacing: 8) {
                    Slider(value: $settings.annotationLineWidth, in: 1...10, step: 1)
                        .frame(width: 170)
                    Text("\(Int(settings.annotationLineWidth)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    /// 颜色设置以 sRGB 存储，这里做 SwiftUI Color 与 NSColor 的归一化转换
    private var annotationColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: settings.annotationColor) },
            set: { settings.annotationColor = NSColor($0).usingColorSpace(.sRGB) ?? .systemRed }
        )
    }

    // MARK: 贴图

    private var pinSection: some View {
        Section {
            Toggle("双击贴图关闭", isOn: $settings.pinDoubleClickClose)
            Toggle("截图包含贴图窗口", isOn: $settings.includePinnedImages)
        } header: {
            Text("贴图")
        } footer: {
            Text("贴图可以把截图或剪贴板里的图片钉在屏幕上，拖动移动、右键菜单关闭。")
        }
    }

    // MARK: 通用

    private var generalSection: some View {
        Section {
            Toggle("登录时启动", isOn: $settings.launchAtLogin)

            if let error = settings.launchAtLoginError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            LabeledContent("屏幕录制权限") {
                HStack(spacing: 8) {
                    Text(hasScreenPermission ? "已授权" : "未授权")
                        .foregroundStyle(hasScreenPermission ? Color.secondary : Color.red)
                    Button("打开系统设置") {
                        ScreenCapturePermission.openPrivacySettings()
                        hasScreenPermission = ScreenCapturePermission.hasPermission()
                    }
                }
            }

            Toggle("显示操作提示", isOn: $settings.showToast)
            Toggle("提示音", isOn: $settings.playSound)

            LabeledContent("版本") {
                Text(UpdateChecker.displayVersion).foregroundStyle(.secondary)
            }

            TextField("更新检查地址（可选）", text: $settings.updateFeedURL)
                .textFieldStyle(.roundedBorder)

            Button("恢复默认设置") { showResetConfirm = true }
        } header: {
            Text("通用")
        } footer: {
            Text("屏幕录制权限变更后需要重新启动应用才会生效。更新地址填一个返回 version 与 url 字段的 JSON，即可启用菜单里的检查更新。")
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

// MARK: - 快捷键录制控件

/// SwiftUI 包装：点击开始录制，直接捕获键盘事件（含 ⌘ 组合键）
struct ShortcutRecorder: NSViewRepresentable {

    @Binding var descriptor: HotKeyDescriptor

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(width: 140)
        let binding = $descriptor
        button.onCapture = { binding.wrappedValue = $0 }
        button.onRecordingChanged = { isRecording in
            // 录制期间必须挂起全局快捷键，否则按下的组合键会被自己拦走
            if isRecording {
                HotKeyManager.shared.suspend()
            } else {
                HotKeyManager.shared.resume()
            }
        }
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        guard !button.isRecording else { return }
        button.descriptor = descriptor
    }
}

/// 录制按钮：第一次点击进入录制态，随后捕获 keyDown / 带 ⌘ 的组合键
final class ShortcutRecorderButton: NSButton {

    var descriptor: HotKeyDescriptor = .none {
        didSet { if !isRecording { refreshTitle() } }
    }
    var onCapture: ((HotKeyDescriptor) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var isRecording = false

    init(width: CGFloat = 140) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        alignment = .center
        font = .systemFont(ofSize: NSFont.systemFontSize)
        setContentHuggingPriority(.required, for: .horizontal)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = "请按新快捷键…"
        onRecordingChanged?(true)
        window?.makeFirstResponder(self)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        refreshTitle()
        onRecordingChanged?(false)
    }

    private func refreshTitle() {
        title = descriptor.displayString
        setAccessibilityLabel("快捷键：\(descriptor.displayString)")
    }

    /// 录到一半点到别处 = 取消
    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    /// 带 ⌘ 的组合键会作为 key equivalent 派发，需要在这里拦下
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        // ⎋ 取消录制
        if event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            return
        }
        // ⌫ / ⌦ 清除快捷键
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            descriptor = .none
            onCapture?(.none)
            endRecording()
            return
        }

        let candidate = HotKeyDescriptor(keyCode: UInt32(event.keyCode),
                                         modifiers: Self.carbonModifiers(from: event.modifierFlags))
        guard candidate.isValid else {
            NSSound.beep()   // 需要修饰键（功能键除外）
            return
        }
        descriptor = candidate
        onCapture?(candidate)
        endRecording()
    }

    /// NSEvent 修饰键 -> Carbon 标志
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
