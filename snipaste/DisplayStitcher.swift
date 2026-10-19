//
//  DisplayStitcher.swift
//  snipaste
//
//  多显示器拼接几何（纯函数，便于单独验证）。
//  单屏时输出尺寸与原生物理尺寸一致，不做任何重采样
//

import AppKit

enum DisplayStitcher {

    /// 一块屏幕：全局框（AppKit 坐标，pt）与物理像素尺寸
    struct Tile {
        let frame: NSRect
        let pixelSize: CGSize
    }

    /// 所有屏幕的并集（全局坐标，pt）
    static func unionFrame(of frames: [NSRect]) -> NSRect {
        frames.reduce(NSRect.null) { $0.union($1) }
    }

    /// 拼接输出尺寸（物理像素）：并集乘以统一缩放因子
    static func outputPixelSize(union: NSRect, scale: CGFloat) -> CGSize {
        CGSize(width: (union.width * scale).rounded(), height: (union.height * scale).rounded())
    }

    /// 统一缩放因子：取所有屏幕里最大的 backingScaleFactor，避免 Retina 屏被降质
    static func outputScale(scales: [CGFloat]) -> CGFloat {
        max(1, scales.max() ?? 1)
    }

    /// 某块屏幕在拼接图中的目标矩形（左上原点坐标，与 CGImage 的行序一致）。
    /// 缩放因子不同的屏幕会被等比缩放到统一画布上，排布与屏幕实际位置一致
    static func tileRect(union: NSRect, tileFrame: NSRect, scale: CGFloat) -> CGRect {
        CGRect(x: (tileFrame.minX - union.minX) * scale,
               y: (union.maxY - tileFrame.maxY) * scale,
               width: (tileFrame.width * scale).rounded(),
               height: (tileFrame.height * scale).rounded())
    }
}
