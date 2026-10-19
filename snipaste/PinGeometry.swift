//
//  PinGeometry.swift
//  snipaste
//
//  贴图缩放的几何计算（纯函数，便于单独验证）
//

import AppKit

enum PinGeometry {

    /// 以 anchor（屏幕坐标）为不动点缩放窗口，保持 anchor 在窗口内的相对位置不变。
    /// 宽度受 minWidth / maxWidth 钳制，高度按比例同步
    static func zoomedFrame(current: NSRect,
                            factor: CGFloat,
                            anchor: NSPoint,
                            minWidth: CGFloat,
                            maxWidth: CGFloat) -> NSRect {
        guard current.width > 0, current.height > 0, factor > 0 else { return current }

        let targetWidth = min(max(current.width * factor, minWidth), maxWidth)
        guard abs(targetWidth - current.width) > 0.01 else { return current }

        let scale = targetWidth / current.width
        let targetSize = NSSize(width: targetWidth, height: current.height * scale)

        // 锚点必须落在窗口内才是有效缩放中心；否则（例如键盘缩放时鼠标在别处）
        // 退回围绕窗口中心缩放，避免窗口跳到鼠标位置
        let effectiveAnchor = current.contains(anchor)
            ? anchor
            : NSPoint(x: current.midX, y: current.midY)

        let relX = min(max((effectiveAnchor.x - current.minX) / current.width, 0), 1)
        let relY = min(max((effectiveAnchor.y - current.minY) / current.height, 0), 1)

        let origin = NSPoint(x: effectiveAnchor.x - relX * targetSize.width,
                             y: effectiveAnchor.y - relY * targetSize.height)
        return NSRect(origin: origin, size: targetSize)
    }

    /// 把窗口矩形钳制在屏幕可见范围内：
    /// 比屏幕小就整体保持在屏幕内；比屏幕大就保证屏幕被窗口盖住（仍能拖回来）
    static func clampedToVisibleFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        var rect = frame

        if rect.width <= visibleFrame.width {
            rect.origin.x = min(max(rect.minX, visibleFrame.minX), visibleFrame.maxX - rect.width)
        } else {
            rect.origin.x = min(max(rect.minX, visibleFrame.maxX - rect.width), visibleFrame.minX)
        }

        if rect.height <= visibleFrame.height {
            rect.origin.y = min(max(rect.minY, visibleFrame.minY), visibleFrame.maxY - rect.height)
        } else {
            rect.origin.y = min(max(rect.minY, visibleFrame.maxY - rect.height), visibleFrame.minY)
        }
        return rect
    }

    /// 等比缩放到不超过 maxSize（只缩小，不放大）
    static func fittedSize(_ size: NSSize, maxSize: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0, maxSize.width > 0, maxSize.height > 0 else { return size }
        let scale = min(1, min(maxSize.width / size.width, maxSize.height / size.height))
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
