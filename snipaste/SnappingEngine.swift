//
//  SnappingEngine.swift
//  snipaste
//
//

import AppKit

/// 窗口吸附引擎：
/// 截图开始时枚举屏幕上的普通层级应用窗口（CGWindowList，同步轻量调用），
/// 悬浮命中返回包含光标的最小窗口框，拖拽时向窗口边缘吸附。
final class SnappingEngine {

    /// 候选窗口框（视图坐标，AppKit 左下原点，单位 pt）
    private(set) var candidateRects: [CGRect] = []

    /// 最小窗口尺寸：小于此视为噪点
    private static let minWindowSize: CGFloat = 16

    /// 是否已有可用候选框
    var isReady: Bool { !candidateRects.isEmpty }

    // MARK: - 候选收集

    /// 枚举屏幕上的应用窗口，换算到视图坐标并缓存。
    /// 吸附目标是"完整的应用窗口框"：按窗口前后顺序做可见性判定，
    /// 完全被遮挡的窗口排除，部分可见的窗口仍吸附其完整边框。
    func reload(viewBounds: NSRect) {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            candidateRects = []
            return
        }

        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        // 主屏高度用于 CG 全局坐标（左上原点）-> AppKit 全局坐标（左下原点）的换算
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0

        var rects: [CGRect] = []
        var occluders: [CGRect] = []  // 更靠前的窗口帧，用于可见性裁剪

        for info in windowList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            // CG 全局（左上原点）-> AppKit 全局（左下原点）-> 本屏视图坐标
            let local = NSRect(
                x: cgBounds.minX - viewBounds.minX,
                y: primaryHeight - cgBounds.maxY - viewBounds.minY,
                width: cgBounds.width,
                height: cgBounds.height
            )

            // 与本屏无交集的窗口（其它显示器上的）不参与
            guard local.intersects(viewBounds) else { continue }

            // 只要普通层级的窗口才作为吸附目标（排除菜单栏、Dock、输入法面板等）
            let isCandidate = (info[kCGWindowLayer as String] as? Int) == 0
                && (info[kCGWindowOwnerPID as String] as? Int) != myPID
                && cgBounds.width >= Self.minWindowSize
                && cgBounds.height >= Self.minWindowSize

            if isCandidate {
                // 可见性判定：减去靠前普通窗口的遮挡区域，
                // 只要还剩任意可见部分，就吸附"完整窗口框"；
                // 完全被遮挡（一块都看不见）的窗口不作为吸附目标
                var visiblePieces: [NSRect] = [local]
                for occluder in occluders where !visiblePieces.isEmpty {
                    visiblePieces = visiblePieces.flatMap { Self.subtract($0, cover: occluder) }
                }

                if !visiblePieces.isEmpty {
                    rects.append(local)
                }

                // 只有普通应用窗口会遮挡其它窗口。
                // 注意：程序坞进程持有一个全屏窗口（桌面组件层），若把它当遮挡物
                // 会把所有普通窗口判为不可见——所以系统浮层一律不参与遮挡。
                occluders.append(local)
            }
        }

        candidateRects = rects
        print("🧲 窗口吸附候选就绪: \(rects.count) 个可见窗口")
    }

    /// 从 rect 中减去 cover 覆盖的部分，返回剩余子矩形集合（最多 4 块）
    private static func subtract(_ rect: NSRect, cover: NSRect) -> [NSRect] {
        let inter = rect.intersection(cover)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return [rect] }

        var pieces: [NSRect] = []
        // 左侧竖条
        if inter.minX > rect.minX {
            pieces.append(NSRect(x: rect.minX, y: rect.minY,
                                 width: inter.minX - rect.minX, height: rect.height))
        }
        // 右侧竖条
        if rect.maxX > inter.maxX {
            pieces.append(NSRect(x: inter.maxX, y: rect.minY,
                                 width: rect.maxX - inter.maxX, height: rect.height))
        }
        // 中间下方横条
        if inter.minY > rect.minY {
            pieces.append(NSRect(x: inter.minX, y: rect.minY,
                                 width: inter.width, height: inter.minY - rect.minY))
        }
        // 中间上方横条
        if rect.maxY > inter.maxY {
            pieces.append(NSRect(x: inter.minX, y: inter.maxY,
                                 width: inter.width, height: rect.maxY - inter.maxY))
        }
        return pieces
    }

    // MARK: - 命中与吸附

    /// 命中检测：返回包含该点（含边缘容差）的候选窗口中面积最小的一个
    func hitTest(at point: NSPoint, edgeTolerance: CGFloat = 6) -> NSRect? {
        var best: NSRect?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for rect in candidateRects {
            let expanded = rect.insetBy(dx: -edgeTolerance, dy: -edgeTolerance)
            guard expanded.contains(point) else { continue }
            let area = rect.width * rect.height
            if area < bestArea {
                bestArea = area
                best = rect
            }
        }
        return best
    }

    /// 点吸附：x/y 各自寻找最近的候选窗口边缘，距离 ≤ 容差才贴合
    func snapPoint(_ point: NSPoint, edgeTolerance: CGFloat = 6) -> NSPoint {
        guard !candidateRects.isEmpty else { return point }

        var x = point.x
        var y = point.y
        var bestDX = edgeTolerance
        var bestDY = edgeTolerance

        for rect in candidateRects {
            for edgeX in [rect.minX, rect.maxX] {
                let distance = abs(edgeX - point.x)
                if distance < bestDX {
                    bestDX = distance
                    x = edgeX
                }
            }
            for edgeY in [rect.minY, rect.maxY] {
                let distance = abs(edgeY - point.y)
                if distance < bestDY {
                    bestDY = distance
                    y = edgeY
                }
            }
        }
        return NSPoint(x: x, y: y)
    }
}
