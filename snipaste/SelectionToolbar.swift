//
//  SelectionToolbar.swift
//  snipaste
//
//

import AppKit

// MARK: - 工具栏图标按钮（纯 AppKit：命中区域即按钮帧，行为完全确定）

final class ToolbarIconButton: NSButton {

    private let actionClosure: () -> Void
    private var trackingArea: NSTrackingArea?

    private let idleBackground = NSColor.white.withAlphaComponent(0.10)
    private let hoverBackground = NSColor.white.withAlphaComponent(0.28)

    init(icon: String, label: String, action: @escaping () -> Void) {
        actionClosure = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.sideLength, height: Self.sideLength))

        let configuration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .white
        setAccessibilityLabel(label)

        // 自定义悬浮高亮背景
        wantsLayer = true
        layer?.backgroundColor = idleBackground.cgColor
        layer?.cornerRadius = 8

        target = self
        self.action = #selector(clicked)  // 显式 self：避免与同名 init 参数遮蔽
    }

    /// 按钮边长（同时决定命中区域大小）
    static let sideLength: CGFloat = 32

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
        layer?.backgroundColor = hoverBackground.cgColor
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = idleBackground.cgColor
        NSCursor.arrow.set()
    }
}

// MARK: - 工具栏主体

final class SelectionToolbarView: NSStackView {

    /// fittingSize 异常时的兜底尺寸（7 按钮 + 分隔线 + 间距 + 内边距的估算值）
    static let estimatedSize = NSSize(width: 386, height: 100)

    init(onClose: @escaping () -> Void,
         onPin: @escaping () -> Void,
         onCopy: @escaping () -> Void) {
        super.init(frame: .zero)

        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)

        // 深色半透明圆角底板
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 6

        let buttons: [NSView] = [
            ToolbarIconButton(icon: "pencil", label: "画笔") { print("✏️ 画笔工具") },
            ToolbarIconButton(icon: "square", label: "方框") { print("⬜ 方框工具") },
            ToolbarIconButton(icon: "arrow.up.right", label: "箭头") { print("↗️ 箭头工具") },
            ToolbarIconButton(icon: "checkerboard.rectangle", label: "马赛克") { print("🔲 马赛克工具") },
            Self.separator(),
            ToolbarIconButton(icon: "pin", label: "置顶", action: onPin),
            ToolbarIconButton(icon: "doc.on.doc", label: "复制", action: onCopy),
            ToolbarIconButton(icon: "xmark", label: "关闭", action: onClose),
        ]
        for view in buttons {
            addArrangedSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 XIB 初始化")
    }

    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
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
