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
                .fill(Color.white.opacity(0.1))
        )
        .contentShape(Rectangle())
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
            // 调试：显示整个 GeometryReader 的边界
            Color.clear

            SelectionToolbar(onClose: onClose, onPin: onPin, onCopy: onCopy)
                .background(
                    GeometryReader { toolbarGeometry in
                        Color.clear
                            .onAppear {
                                toolbarSize = toolbarGeometry.size
                                print("📏 工具栏尺寸: \(toolbarGeometry.size)")
                                print("🖼️ 屏幕尺寸: \(screenBounds)")
                                print("📦 选区(AppKit坐标): \(selectionRect)")

                                let pos = calculateSwiftUIPosition()
                                print("📍 计算的工具栏位置(SwiftUI坐标): \(pos)")
                            }
                            .onChange(of: toolbarGeometry.size) { _, newSize in
                                toolbarSize = newSize
                                print("📏 工具栏尺寸变化: \(newSize)")
                            }
                    }
                )
                .position(calculateSwiftUIPosition())
        }
        .frame(width: screenBounds.width, height: screenBounds.height)
        .onAppear {
            print("🎬 FloatingToolbar appeared")
            print("📐 View frame: width=\(screenBounds.width), height=\(screenBounds.height)")
        }
    }

    /// 计算 SwiftUI 坐标系下的 position
    /// SwiftUI 坐标系：原点在左上角，Y 轴向下
    /// AppKit 坐标系：原点在左下角，Y 轴向上
    private func calculateSwiftUIPosition() -> CGPoint {
        guard toolbarSize.width > 0 && toolbarSize.height > 0 else {
            // 工具栏尺寸还未确定，返回默认位置
            print("⚠️ 工具栏尺寸未确定，使用默认位置")
            return CGPoint(x: screenBounds.width / 2, y: screenBounds.height / 2)
        }

        let padding: CGFloat = 12  // 工具栏与选区的间距

        // 计算水平居中位置
        var toolbarX = selectionRect.midX

        // 确保工具栏不超出屏幕左右边界
        let minX = toolbarSize.width / 2 + padding
        let maxX = screenBounds.width - toolbarSize.width / 2 - padding
        toolbarX = max(minX, min(maxX, toolbarX))

        // 将 AppKit Y 坐标转换为 SwiftUI Y 坐标
        // AppKit: selectionRect.minY 是选区底部（距离屏幕底部的距离）
        // SwiftUI: 我们需要距离屏幕顶部的距离
        let selectionBottomInSwiftUI = screenBounds.height - selectionRect.minY

        print("🔄 坐标转换: AppKit Y=\(selectionRect.minY) -> SwiftUI Y=\(selectionBottomInSwiftUI)")

        // 默认放在选区下方
        var toolbarY = selectionBottomInSwiftUI + padding + toolbarSize.height / 2

        print("📍 初始工具栏位置: (\(toolbarX), \(toolbarY))")

        // 检查是否超出屏幕底部
        if toolbarY + toolbarSize.height / 2 > screenBounds.height {
            // 超出底部，放在选区上方
            let selectionTopInSwiftUI = screenBounds.height - selectionRect.maxY
            toolbarY = selectionTopInSwiftUI - padding - toolbarSize.height / 2

            print("⬆️ 底部空间不足，放在选区上方: Y=\(toolbarY)")

            // 如果上方也放不下，放在选区内部顶部
            if toolbarY - toolbarSize.height / 2 < 0 {
                toolbarY = selectionTopInSwiftUI + padding + toolbarSize.height / 2
                print("⚠️ 上方也不足，放在选区内部: Y=\(toolbarY)")
            }
        }

        let finalPos = CGPoint(x: toolbarX, y: toolbarY)
        print("✅ 最终工具栏位置: \(finalPos)")
        return finalPos
    }
}
