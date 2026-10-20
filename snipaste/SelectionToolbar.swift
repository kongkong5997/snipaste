//
//  SelectionToolbar.swift
//  snipaste
//
//

import AppKit

// MARK: - 设计常量

private enum ToolbarStyle {
    /// 工具栏整体圆角
    static let cornerRadius: CGFloat = 14
    /// 按钮边长（同时决定命中区域大小）
    static let buttonSide: CGFloat = 32
    /// 按钮圆角
    static let buttonRadius: CGFloat = 8
    /// 图标字号
    static let iconPointSize: CGFloat = 15
    /// 强调色（激活工具 / 主操作）
    static let accent = NSColor(calibratedRed: 0.10, green: 0.52, blue: 1.0, alpha: 1.0)
    static let accentHover = NSColor(calibratedRed: 0.25, green: 0.60, blue: 1.0, alpha: 1.0)
    static let accentPressed = NSColor(calibratedRed: 0.05, green: 0.43, blue: 0.90, alpha: 1.0)
    /// 危险色（关闭按钮悬浮）
    static let danger = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
}

// MARK: - 工具栏图标按钮（纯 AppKit：命中区域即按钮帧，行为完全确定）

final class ToolbarIconButton: NSButton {

    /// 按钮视觉风格
    enum Style {
        case tool      // 标注工具：选中时蓝色高亮
        case action    // 普通动作：悬浮时浅色底
        case primary   // 主操作：常驻蓝色底
        case danger    // 危险操作：悬浮时红色底
    }

    private let actionClosure: () -> Void
    private let style: Style
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// 按下态（鼠标按住时）
    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    /// 激活状态（标注工具被选中时持续高亮）
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            updateAppearance()
        }
    }

    init(icon: String, label: String, tooltip: String? = nil,
         style: Style = .action, action: @escaping () -> Void) {
        actionClosure = action
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: ToolbarStyle.buttonSide, height: ToolbarStyle.buttonSide))

        let configuration = NSImage.SymbolConfiguration(
            pointSize: ToolbarStyle.iconPointSize, weight: .medium)
        image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(label)
        toolTip = tooltip ?? label

        // 固定尺寸，避免被图像固有尺寸撑大
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: ToolbarStyle.buttonSide).isActive = true
        heightAnchor.constraint(equalToConstant: ToolbarStyle.buttonSide).isActive = true

        // 自定义背景（悬浮 / 按下 / 激活高亮）
        wantsLayer = true
        layer?.cornerRadius = ToolbarStyle.buttonRadius
        layer?.cornerCurve = .continuous
        updateAppearance()

        target = self
        self.action = #selector(clicked)  // 显式 self：避免与同名 init 参数遮蔽
    }

    @objc private func clicked() {
        actionClosure()
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
        NSCursor.arrow.set()
    }

    /// 根据风格与状态刷新背景色与图标色
    /// 优先级：按下 > 激活 > 悬浮 > 常态
    private func updateAppearance() {
        let background: NSColor
        let tint: NSColor

        switch style {
        case .tool:
            if isActive {
                background = isHighlighted ? ToolbarStyle.accentPressed
                    : (isHovered ? ToolbarStyle.accentHover : ToolbarStyle.accent)
                tint = .white
            } else {
                background = isHighlighted ? NSColor.white.withAlphaComponent(0.20)
                    : (isHovered ? NSColor.white.withAlphaComponent(0.12) : .clear)
                tint = NSColor.white.withAlphaComponent(isHovered ? 1.0 : 0.82)
            }
        case .action:
            background = isHighlighted ? NSColor.white.withAlphaComponent(0.20)
                : (isHovered ? NSColor.white.withAlphaComponent(0.12) : .clear)
            tint = NSColor.white.withAlphaComponent(isHovered ? 1.0 : 0.82)
        case .primary:
            background = isHighlighted ? ToolbarStyle.accentPressed
                : (isHovered ? ToolbarStyle.accentHover : ToolbarStyle.accent)
            tint = .white
        case .danger:
            background = isHighlighted ? ToolbarStyle.danger.withAlphaComponent(0.75)
                : (isHovered ? ToolbarStyle.danger : .clear)
            tint = isHovered ? .white : NSColor.white.withAlphaComponent(0.82)
        }

        layer?.backgroundColor = background.cgColor
        contentTintColor = tint
    }
}

// MARK: - 分隔线

private final class ToolbarDivider: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.cornerRadius = 0.5
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }
}

// MARK: - 描边层（不拦截鼠标事件）

private final class ToolbarBorderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ToolbarStyle.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 工具栏主体

final class SelectionToolbarView: NSView {

    /// fittingSize 异常时的兜底尺寸（10 工具 + 分隔线 + 5 动作按钮的估算值）
    static let estimatedSize = NSSize(width: 556, height: 48)

    /// 标注工具按钮索引（用于同步激活高亮）
    private var toolButtons: [AnnotationTool: ToolbarIconButton] = [:]

    private let stack = NSStackView()

    init(onSelectTool: @escaping (AnnotationTool) -> Void,
         onClose: @escaping () -> Void,
         onPin: @escaping () -> Void,
         onCopy: @escaping () -> Void,
         onSave: @escaping () -> Void,
         onScroll: @escaping () -> Void) {
        super.init(frame: .zero)

        // 固定深色外观，保证在任意底图上都是深色毛玻璃
        appearance = NSAppearance(named: .vibrantDark)

        setupBackground()

        // 工具按钮组
        var views: [NSView] = []
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            let shortcut = (index + 1) % 10   // 第 10 个工具对应数字键 0
            let button = ToolbarIconButton(
                icon: tool.icon, label: tool.label,
                tooltip: "\(tool.label)（\(shortcut)）", style: .tool
            ) {
                onSelectTool(tool)
            }
            toolButtons[tool] = button
            views.append(button)
        }

        // 动作按钮组
        let divider = ToolbarDivider()
        views.append(divider)
        views.append(ToolbarIconButton(icon: "scroll", label: "滚动截图", action: onScroll))
        views.append(ToolbarIconButton(icon: "pin", label: "置顶", action: onPin))
        views.append(ToolbarIconButton(icon: "square.and.arrow.down", label: "保存", action: onSave))
        views.append(ToolbarIconButton(icon: "xmark", label: "关闭", style: .danger, action: onClose))
        let copyButton = ToolbarIconButton(
            icon: "checkmark", label: "复制", tooltip: "复制到剪贴板", style: .primary, action: onCopy)
        views.append(copyButton)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            stack.addArrangedSubview(view)
        }
        // 分隔线两侧留出更大的间距，形成视觉分组
        if let previous = views.firstIndex(of: divider), previous > 0 {
            stack.setCustomSpacing(8, after: views[previous - 1])
            stack.setCustomSpacing(8, after: divider)
        }
        // 关闭与确认之间稍微拉开，避免误触
        stack.setCustomSpacing(6, after: views[views.count - 2])

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 描边放在最上层
        let border = ToolbarBorderView()
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    /// 毛玻璃底板：使用 maskImage 裁剪圆角，窗口阴影会跟随圆角轮廓
    private func setupBackground() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: ToolbarStyle.cornerRadius)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// 更新激活工具的按钮高亮（nil 表示无工具激活）
    func setActiveTool(_ tool: AnnotationTool?) {
        for (candidate, button) in toolButtons {
            button.isActive = (candidate == tool)
        }
    }
}

// MARK: - 工具栏定位计算器

struct ToolbarPositionCalculator {
    /// 计算工具栏的最佳位置
    /// - Parameters:
    ///   - selectionRect: 选区矩形
    ///   - toolbarSize: 工具栏尺寸
    ///   - screenBounds: 屏幕边界
    /// - Returns: 工具栏应该显示的位置（原点在左下角）
    static func calculatePosition(
        selectionRect: CGRect,
        toolbarSize: CGSize,
        screenBounds: CGRect
    ) -> CGPoint {
        let toolbarWidth = toolbarSize.width
        let toolbarHeight = toolbarSize.height
        let padding: CGFloat = 12  // 工具栏与选区的间距

        // 默认位置：选区正下方，工具栏右缘与选区右缘平齐
        var toolbarX = selectionRect.maxX - toolbarWidth
        var toolbarY = selectionRect.minY - toolbarHeight - padding

        // 确保不超出屏幕左侧
        if toolbarX < screenBounds.minX {
            toolbarX = screenBounds.minX + padding
        }

        // 确保不超出屏幕右侧
        if toolbarX + toolbarWidth > screenBounds.maxX {
            toolbarX = screenBounds.maxX - toolbarWidth - padding
        }

        // 检查底部是否有足够空间
        let spaceBelow = selectionRect.minY - screenBounds.minY

        if spaceBelow < toolbarHeight + padding {
            // 底部空间不足，检查选区内部是否有空间
            if selectionRect.height > toolbarHeight + padding * 2 {
                // 显示在选区内部底部
                toolbarY = selectionRect.minY + padding
            } else {
                // 选区内部也不够，显示在选区上方
                let spaceAbove = screenBounds.maxY - selectionRect.maxY
                if spaceAbove >= toolbarHeight + padding {
                    // 上方有空间，显示在选区上方
                    toolbarY = selectionRect.maxY + padding
                } else {
                    // 哪里都没空间，强制显示在选区内部（可能遮挡部分内容）
                    toolbarY = selectionRect.minY + padding
                }
            }
        }

        // 最后检查：确保不超出屏幕顶部
        if toolbarY + toolbarHeight > screenBounds.maxY {
            toolbarY = screenBounds.maxY - toolbarHeight - padding
        }

        return CGPoint(x: toolbarX, y: toolbarY)
    }
}
