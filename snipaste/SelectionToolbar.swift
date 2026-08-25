//
//  SelectionToolbar.swift
//  snipaste
//
//  Created by Claude
//

import SwiftUI

// MARK: - 工具栏按钮样式
struct ToolbarButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovering ? 0.25 : 0.1))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            // 悬浮切换手型光标，并给出轻微高亮反馈
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - 工具栏主视图
struct SelectionToolbar: View {
    let onClose: () -> Void
    let onPin: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ToolbarButton(icon: "pencil") {
                print("✏️ 画笔工具")
            }

            ToolbarButton(icon: "square") {
                print("⬜ 方框工具")
            }

            ToolbarButton(icon: "arrow.up.right") {
                print("↗️ 箭头工具")
            }

            ToolbarButton(icon: "checkerboard.rectangle") {
                print("🔲 马赛克工具")
            }

            Divider()
                .frame(height: 20)
                .background(Color.white.opacity(0.3))

            ToolbarButton(icon: "pin") {
                onPin()
            }

            ToolbarButton(icon: "doc.on.doc") {
                onCopy()
            }

            ToolbarButton(icon: "xmark") {
                onClose()
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.75))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        )
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

        // 默认位置：选区正下方，水平居中
        var toolbarX = selectionRect.midX - toolbarWidth / 2
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

// MARK: - 工具栏容器视图（处理定位）
struct FloatingToolbar: View {
    let selectionRect: CGRect
    let screenBounds: CGRect
    let onClose: () -> Void
    let onPin: () -> Void
    let onCopy: () -> Void

    @State private var toolbarSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.clear

            SelectionToolbar(onClose: onClose, onPin: onPin, onCopy: onCopy)
                .background(
                    GeometryReader { toolbarGeometry in
                        Color.clear
                            .onAppear {
                                toolbarSize = toolbarGeometry.size
                            }
                            .onChange(of: toolbarGeometry.size) { _, newSize in
                                toolbarSize = newSize
                            }
                    }
                )
                .position(calculateSwiftUIPosition())
        }
        .frame(width: screenBounds.width, height: screenBounds.height)
    }

    /// 计算 SwiftUI 坐标系下的 position
    /// SwiftUI 坐标系：原点在左上角，Y 轴向下
    /// AppKit 坐标系：原点在左下角，Y 轴向上
    private func calculateSwiftUIPosition() -> CGPoint {
        guard toolbarSize.width > 0 && toolbarSize.height > 0 else {
            // 工具栏尺寸还未确定，先放屏幕中心，等尺寸回调后再修正
            return CGPoint(x: screenBounds.width / 2, y: screenBounds.height / 2)
        }

        let padding: CGFloat = 12  // 工具栏与选区的间距

        // 靠选区右边对齐：工具栏右缘与选区右缘平齐，并确保不超出屏幕边界
        var toolbarX = selectionRect.maxX - toolbarSize.width / 2
        let minX = toolbarSize.width / 2 + padding
        let maxX = screenBounds.width - toolbarSize.width / 2 - padding
        toolbarX = max(minX, min(maxX, toolbarX))

        // AppKit 的 minY 是选区底部（距屏幕底部的距离），转成距屏幕顶部的距离
        let selectionBottomInSwiftUI = screenBounds.height - selectionRect.minY

        // 默认放在选区下方
        var toolbarY = selectionBottomInSwiftUI + padding + toolbarSize.height / 2

        // 超出屏幕底部时放到选区上方；上方也放不下则放进选区内部顶部
        if toolbarY + toolbarSize.height / 2 > screenBounds.height {
            let selectionTopInSwiftUI = screenBounds.height - selectionRect.maxY
            toolbarY = selectionTopInSwiftUI - padding - toolbarSize.height / 2

            if toolbarY - toolbarSize.height / 2 < 0 {
                toolbarY = selectionTopInSwiftUI + padding + toolbarSize.height / 2
            }
        }

        return CGPoint(x: toolbarX, y: toolbarY)
    }
}
