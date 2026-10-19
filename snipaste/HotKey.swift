//
//  HotKey.swift
//  snipaste
//
//  全局快捷键：描述模型（键码 + 修饰键 + 显示名）与 Carbon 注册管理器
//

import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - 快捷键描述

/// 一个全局快捷键：Carbon 键码 + 修饰键标志
struct HotKeyDescriptor: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey / shiftKey / optionKey / controlKey

    /// "未设置"的哨兵键码。
    /// 不能用 0：Carbon 里 kVK_ANSI_A 就是 0，⌘A 这类快捷键会被误判成未设置
    static let disabledKeyCode: UInt32 = 0xFFFF

    /// 空快捷键（未设置 / 已禁用）
    static let none = HotKeyDescriptor(keyCode: disabledKeyCode, modifiers: 0)

    /// 默认：开始截图 ⌘⇧X
    static let defaultScreenshot = HotKeyDescriptor(keyCode: UInt32(kVK_ANSI_X),
                                                    modifiers: UInt32(cmdKey | shiftKey))

    /// 默认：从剪贴板贴图 ⌥⌘V
    static let defaultPin = HotKeyDescriptor(keyCode: UInt32(kVK_ANSI_V),
                                             modifiers: UInt32(optionKey | cmdKey))

    // 新截图模式的默认键都避开 ⇧⌘ 系（浏览器等应用常用），选 ⌃⌘ 组合
    static let defaultFullScreen = HotKeyDescriptor(keyCode: UInt32(kVK_ANSI_A),
                                                    modifiers: UInt32(controlKey | cmdKey))
    static let defaultWindowCapture = HotKeyDescriptor(keyCode: UInt32(kVK_ANSI_W),
                                                       modifiers: UInt32(controlKey | cmdKey))
    static let defaultRepeatLast = HotKeyDescriptor(keyCode: UInt32(kVK_ANSI_R),
                                                    modifiers: UInt32(controlKey | cmdKey))
    static let defaultTogglePins = HotKeyDescriptor(keyCode: UInt32(kVK_ANSI_H),
                                                    modifiers: UInt32(controlKey | cmdKey))

    var isDisabled: Bool { keyCode == Self.disabledKeyCode }

    /// 是否可作为全局快捷键：
    /// 必须带修饰键，或者使用功能键（F1–F20，不占用普通字符输入）
    var isValid: Bool {
        guard !isDisabled else { return true }   // 允许留空（禁用该功能入口）
        // 必须带 ⌘ / ⌥ / ⌃ 之一：只带 ⇧ 会全局吞掉普通输入（例如 ⇧A 之后
        // 所有应用都打不出大写 A）；功能键不占字符输入，可以不带强修饰键
        if modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 { return true }
        return HotKeyKeyNames.functionKeyCodes.contains(keyCode)
    }

    /// 显示字符串，如 "⌘⇧X"；修饰键按 ⌃⌥⇧⌘ 顺序
    var displayString: String {
        guard !isDisabled else { return "未设置" }
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += HotKeyKeyNames.name(for: keyCode)
        return text
    }
}

// MARK: - 键码名称

enum HotKeyKeyNames {

    /// 功能键键码（可以不带修饰键单独使用）
    static let functionKeyCodes: Set<UInt32> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
        kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
        kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map { UInt32($0) })

    private static let names: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Space): "空格", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "键码\(keyCode)"
    }
}

// MARK: - 全局快捷键管理器

/// 全局快捷键注册（Carbon RegisterEventHotKey）：
/// 不需要"输入监听"权限，本应用处于前台时同样生效。
/// 快捷键取值来自 AppSettings，改动后由设置页触发 apply 重新注册。
final class HotKeyManager: ObservableObject {

    static let shared = HotKeyManager()

    enum Action: UInt32, CaseIterable {
        case screenshot = 1
        case fullScreen = 2
        case windowCapture = 3
        case repeatLast = 4
        case pinFromClipboard = 5
        case togglePins = 6

        var title: String {
            switch self {
            case .screenshot: return "区域截图"
            case .fullScreen: return "全屏截图"
            case .windowCapture: return "窗口截图"
            case .repeatLast: return "重复上一次截图"
            case .pinFromClipboard: return "从剪贴板贴图"
            case .togglePins: return "隐藏 / 显示所有贴图"
            }
        }
    }

    /// 触发时的动作（由 AppDelegate 装配，避免与本管理器耦合）
    var onAction: ((Action) -> Void)?

    /// 最近一次注册失败的提示（nil = 全部成功）
    @Published private(set) var registrationError: String?

    private var eventHandlerInstalled = false
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var isSuspended = false

    private init() {}

    // MARK: - 注册

    /// 按当前设置注册全部快捷键（设置改动、应用启动、恢复挂起时调用）
    func apply() {
        unregisterAll()
        guard !isSuspended else { return }
        installEventHandlerIfNeeded()

        var failures: [String] = []
        for (action, descriptor) in Self.descriptors(from: AppSettings.shared) {
            if !register(action, descriptor: descriptor) { failures.append(action.title) }
        }

        registrationError = failures.isEmpty
            ? nil
            : "以下快捷键注册失败，可能已被系统或其他应用占用：\(failures.joined(separator: "、"))"
        if let registrationError { print("⌨️⚠️ \(registrationError)") }
    }

    /// 动作 -> 当前设置的快捷键
    private static func descriptors(from settings: AppSettings) -> [(Action, HotKeyDescriptor)] {
        [(.screenshot, settings.screenshotShortcut),
         (.fullScreen, settings.fullScreenShortcut),
         (.windowCapture, settings.windowShortcut),
         (.repeatLast, settings.repeatShortcut),
         (.pinFromClipboard, settings.pinShortcut),
         (.togglePins, settings.togglePinsShortcut)]
    }

    /// 按当前设置重新注册（关闭设置窗口、恢复挂起时调用）
    func resume() {
        isSuspended = false
        apply()
    }

    /// 录制快捷键期间挂起：先释放已有注册，否则录制时按下的组合键会被自己拦走
    func suspend() {
        isSuspended = true
        unregisterAll()
        registrationError = nil   // 挂起期间没有注册，旧的失败提示不再适用
    }

    // MARK: - 内部

    private func register(_ action: Action, descriptor: HotKeyDescriptor) -> Bool {
        guard !descriptor.isDisabled else { return true }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4950) /* 'SNIP' */, id: action.rawValue)
        let status = RegisterEventHotKey(descriptor.keyCode, descriptor.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            print("⌨️⚠️ 注册失败 [\(action.title)] \(descriptor.displayString)，状态 \(status)")
            return false
        }
        hotKeyRefs[action.rawValue] = ref
        return true
    }

    private func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return noErr }
            HotKeyManager.shared.handle(id: hotKeyID.id)
            return noErr
        }, 1, &eventType, nil, nil)
        eventHandlerInstalled = true
    }

    private func handle(id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        print("⌨️ 快捷键触发: \(action.title)")
        onAction?(action)
    }
}
