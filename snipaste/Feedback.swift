//
//  Feedback.swift
//  snipaste
//
//  操作反馈：顶部轻提示（HUD）+ 提示音，用于复制 / 保存 / 贴图等操作的结果告知。
//  提示条可带一个动作按钮（例如"在访达中显示"）
//

import AppKit

enum Feedback {

    /// 成功：提示音 + 提示条（可带动作按钮）
    static func success(_ message: String,
                        actionTitle: String? = nil,
                        action: (() -> Void)? = nil) {
        playSound(named: "Tink")
        ToastPresenter.shared.show(message, actionTitle: actionTitle, action: action)
    }

    /// 失败：提示音 + 提示条（红色图标）
    static func failure(_ message: String) {
        playSound(named: "Basso")
        ToastPresenter.shared.show(message, isError: true)
    }

    private static func playSound(named name: String) {
        guard AppSettings.shared.playSound else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// 鼠标所在屏幕顶部居中的轻提示：默认 1.4 秒后淡出（带动作按钮时 4 秒）。
/// 面板与内容视图复用同一个实例；没有动作按钮时点击穿透
final class ToastPresenter {

    static let shared = ToastPresenter()

    private var panel: NSPanel?
    private var toastView: ToastView?
    private var dismissWorkItem: DispatchWorkItem?
    /// 递增代次：淡出回调据此判断自己是否已被新提示取代
    private var generation = 0

    private init() {}

    func show(_ message: String,
              isError: Bool = false,
              actionTitle: String? = nil,
              action: (() -> Void)? = nil) {
        guard AppSettings.shared.showToast else { return }

        dismissWorkItem?.cancel()
        generation += 1
        let currentGeneration = generation

        let toast: ToastView
        let panel: NSPanel
        if let existingView = toastView, let existingPanel = self.panel {
            toast = existingView
            panel = existingPanel
        } else {
            toast = ToastView()
            panel = makePanel(contentView: toast)
            toastView = toast
            self.panel = panel
        }

        toast.update(message: message, isError: isError, actionTitle: actionTitle) { [weak self] in
            action?()
            self?.dismiss()
        }
        toast.layoutSubtreeIfNeeded()

        let size = toast.fittingSize
        let wasVisible = panel.isVisible
        panel.ignoresMouseEvents = (actionTitle == nil)   // 有按钮时才需要接收鼠标
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFront(nil)

        if wasVisible {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }

        let duration: TimeInterval = actionTitle == nil ? 1.4 : 4.0
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 淡出并收起
    private func dismiss() {
        guard let panel else { return }
        let currentGeneration = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.panel?.orderOut(nil)
        })
    }

    private func makePanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .captureToast     // 高于截图遮罩，截图过程中也能看到反馈
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = contentView
        return panel
    }

    /// 鼠标所在屏幕的顶部居中
    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(x: visible.midX - size.width / 2,
                       y: visible.maxY - size.height - 48)
    }
}

/// 提示条外观：深色圆角底板 + 图标 + 单行文本（+ 可选动作按钮）
final class ToastView: NSView {

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var actionHandler: (() -> Void)?

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = 10

        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.isBordered = false
        actionButton.font = .systemFont(ofSize: 13, weight: .semibold)
        actionButton.contentTintColor = .controlAccentColor
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.isHidden = true

        let stack = NSStackView(views: [iconView, label, actionButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    func update(message: String,
                isError: Bool,
                actionTitle: String? = nil,
                action: (() -> Void)? = nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        iconView.contentTintColor = isError ? .systemRed : .systemGreen
        label.stringValue = message

        actionHandler = action
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = (actionTitle == nil)
    }

    @objc private func performAction() {
        actionHandler?()
    }
}

// MARK: - 浮层窗口层级

extension NSWindow.Level {
    /// 截图遮罩（screenSaver = 1000）之上的一层：工具栏、滚动控制条等浮层使用。
    /// 与遮罩同级时，遮罩一旦被重新置前就会把浮层压到下面，
    /// 而遮罩会整屏绘制冻结底图，被压住后浮层会完全看不见
    static let captureOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    /// 操作提示条：盖在遮罩之上，保证截图过程中也能看到反馈
    static let captureToast = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
}
