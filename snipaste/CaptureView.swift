//
//  CaptureView.swift
//  snipaste
//
//  Created by Claude
//

import AppKit
import ScreenCaptureKit

class CaptureView: NSView {
    // 回调闭包
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    // MARK: - 选区交互状态机

    /// creating - 初次按下并拖拽生成矩形
    /// idle     - 选区已确认，根据悬浮位置切换光标
    /// moving   - 鼠标在选区内部拖拽，整体平移
    /// resizing - 鼠标在控制柄或边框上拖拽，修改选区宽高与坐标
    private enum InteractionState {
        case creating, idle, moving, resizing
    }

    /// 8 个缩放控制点（四角 + 四边）
    private enum ResizeHandle {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    /// 命中检测结果
    private enum HitTarget {
        case handle(ResizeHandle)
        case inside
        case outside
    }

    private static let handleHitRadius: CGFloat = 5   // 控制点命中半径
    private static let edgeHitTolerance: CGFloat = 4  // 边框吸附容差
    private static let minSelectionSpan: CGFloat = 10 // 最小宽高限制

    private var state: InteractionState = .idle
    private var selectionRect: NSRect?  // 当前选区（视图坐标，原点左下角）

    // 各状态的临时数据
    private var dragAnchor: NSPoint = .zero           // creating：拖拽起点
    private var moveGrabOffset: NSPoint = .zero       // moving：按下点到选区原点的偏移
    private var resizeOriginalRect: NSRect = .zero    // resizing：拖拽前的选区
    private var activeHandle: ResizeHandle?           // resizing：当前操作的控制柄

    // 工具栏使用独立 NSPanel 承载：
    // 若作为子视图嵌入 CaptureView，SwiftUI 未接住的鼠标事件会沿响应者链
    // 上抛给 CaptureView 被静默吞掉；独立面板彻底切断这条通路
    private var toolbarPanel: NSPanel?
    private var isCapturing = false  // 防止重复截图
    private var isClosed = false  // 防止重复关闭
    private var currentCaptureTask: Task<Void, Never>?  // 当前截图任务

    // 窗口吸附（智能吸附只针对应用窗口边框）
    private let snappingEngine = SnappingEngine()
    private var hoveredSnappedRect: NSRect?   // 悬浮命中的窗口框（未生成选区时高亮）
    private var pressedOnSnappedRect: NSRect? // 按下时命中的窗口（抬手仍未拖出选区则直接选中它）

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    deinit {
        print("🗑️ CaptureView deinit")
        cleanup()
    }

    func cleanup() {
        print("🧹 Performing CaptureView cleanup...")
        // 取消所有进行中的任务
        currentCaptureTask?.cancel()
        currentCaptureTask = nil
        // 确保清理工具栏
        hideToolbar()
    }

    private func setupView() {
        // 接受第一响应者（用于接收键盘事件）
        wantsLayer = true

        // 枚举屏幕上的应用窗口供吸附使用（同步轻量调用，立即就绪）
        snappingEngine.reload(viewBounds: bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 悬浮吸附预览复用选区的绘制样式（不单独做高亮样式）；
        // 仅在尚未创建选区且非拖拽创建中时展示
        let snapPreview: NSRect? = (selectionRect == nil && state != .creating) ? hoveredSnappedRect : nil

        // 如果有选区或吸附预览，先绘制挖空遮罩与边框
        if let rect = selectionRect ?? snapPreview {
            let isActiveSelection = (selectionRect != nil)
            // 保存上下文状态
            context.saveGState()

            // 创建反向路径：整个屏幕减去选区
            let screenPath = NSBezierPath(rect: bounds)
            let selectionPath = NSBezierPath(rect: rect)
            screenPath.append(selectionPath)
            screenPath.windingRule = .evenOdd

            // 绘制半透明黑色遮罩（只在选区外部）
            NSColor.black.withAlphaComponent(0.3).setFill()
            screenPath.fill()

            // 恢复上下文状态
            context.restoreGState()

            // 绘制选区边框
            NSColor.white.setStroke()
            let borderWidth: CGFloat = 2.0
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = borderWidth
            borderPath.stroke()

            // 只有真实选区才绘制 8 个缩放控制点（吸附预览不可交互，不画）
            if isActiveSelection {
                drawSelectionHandles(rect)
            }

            // 绘制尺寸信息
            drawSizeLabel(for: rect)
        } else {
            // 没有选区时，绘制整个屏幕的遮罩
            NSColor.black.withAlphaComponent(0.3).setFill()
            bounds.fill()
        }
    }

    /// 绘制尺寸标签（选区与吸附高亮共用）
    private func drawSizeLabel(for rect: NSRect) {
        let sizeText = NSString(format: "%.0f × %.0f", rect.width, rect.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = sizeText.size(withAttributes: attributes)

        // 文本背景框
        var textRect = NSRect(
            x: rect.origin.x,
            y: rect.origin.y - 28,
            width: textSize.width + 16,
            height: 24
        )

        // 确保文本框不超出屏幕
        if textRect.maxX > bounds.maxX {
            textRect.origin.x = bounds.maxX - textRect.width
        }
        if textRect.minY < bounds.minY {
            textRect.origin.y = rect.maxY + 4
        }

        // 绘制文本背景
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4).fill()

        // 绘制文本
        let textPoint = NSPoint(
            x: textRect.origin.x + (textRect.width - textSize.width) / 2,
            y: textRect.origin.y + (textRect.height - textSize.height) / 2
        )
        sizeText.draw(at: textPoint, withAttributes: attributes)
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        print("🖱️ mouseDown: point=\(convert(event.locationInWindow, from: nil)), state=\(state), 有选区=\(selectionRect != nil), 窗口key=\(window?.isKeyWindow ?? false)")
        guard !isClosed, !isCapturing, state == .idle else { return }
        let point = convert(event.locationInWindow, from: nil)

        // 双击选区内部 → 截图并复制到剪贴板
        // 重要：延迟到下一个 runloop 执行，避免在事件处理中阻塞
        if event.clickCount == 2, case .inside = hitTestSelection(point) {
            print("🖱️ 检测到双击，准备延迟执行截图")
            DispatchQueue.main.async { [weak self] in
                self?.handleDoubleClickSelection()
            }
            return
        }

        switch hitTestSelection(point) {
        case .handle(let handle):
            // 控制柄/边框 → 进入拉伸
            guard let rect = selectionRect else { return }
            print("🔧 开始拉伸: \(handle)")
            state = .resizing
            activeHandle = handle
            resizeOriginalRect = rect
            Self.cursor(for: handle).set()

        case .inside:
            // 选区内部 → 整体平移
            guard let rect = selectionRect else { return }
            state = .moving
            moveGrabOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
            Self.moveCursor.set()

        case .outside:
            // 已有选区时，选区外部不允许点击重新选区（操作只通过工具栏按钮）；
            // 仅在还没有选区时才允许按下拖拽创建。
            // 记录按下时命中的候选元素：抬手仍未拖出有效选区则直接选中它
            guard selectionRect == nil else { break }
            pressedOnSnappedRect = hoveredSnappedRect
                ?? snappingEngine.hitTest(at: point, edgeTolerance: 6)
            startCreating(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isClosed else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .creating:
            // 拖拽点先做智能吸附（每轴 ≤6pt 贴齐最近候选边缘）；
            // min/max 归一化天然处理反向拖拽；再与屏幕范围求交做边界约束
            let snapped = snappingEngine.snapPoint(point, edgeTolerance: 6)
            let raw = NSRect(
                x: min(dragAnchor.x, snapped.x),
                y: min(dragAnchor.y, snapped.y),
                width: abs(snapped.x - dragAnchor.x),
                height: abs(snapped.y - dragAnchor.y)
            )
            selectionRect = raw.intersection(bounds)
            needsDisplay = true

        case .moving:
            guard let current = selectionRect else { break }
            // 平移并钳制在屏幕范围内
            var originX = point.x - moveGrabOffset.x
            var originY = point.y - moveGrabOffset.y
            originX = min(max(originX, bounds.minX), bounds.maxX - current.width)
            originY = min(max(originY, bounds.minY), bounds.maxY - current.height)
            selectionRect = NSRect(x: originX, y: originY, width: current.width, height: current.height)
            needsDisplay = true
            refreshToolbarPosition()

        case .resizing:
            guard let handle = activeHandle else { break }
            selectionRect = resizedRect(from: resizeOriginalRect, handle: handle, point: point)
            needsDisplay = true
            refreshToolbarPosition()

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isClosed else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .creating:
            if let rect = selectionRect,
               rect.width >= Self.minSelectionSpan, rect.height >= Self.minSelectionSpan {
                // 完成选区，显示工具栏
                state = .idle
                showToolbar(for: rect)
                onRegionSelected?(rect)
                updateCursor(at: point)
            } else if let element = pressedOnSnappedRect {
                // 智能吸附：按在元素上且几乎未拖动 → 单击直接将该元素设为选区
                print("🧲 吸附选中元素: \(element.origin), \(element.size)")
                state = .idle
                selectionRect = element
                hoveredSnappedRect = nil
                showToolbar(for: element)
                onRegionSelected?(element)
                updateCursor(at: point)
            } else {
                // 选区太小，取消整个截图会话（保持原有行为）
                selectionRect = nil
                hideToolbar()
                safeCancelAndClose()
            }
            pressedOnSnappedRect = nil

        case .moving, .resizing:
            print("✅ 变换完成: \(selectionRect.map { "\($0.origin), \($0.size)" } ?? "nil")")
            state = .idle
            // 拖拽结束后确保工具栏面板仍在最前、可正常接收点击
            toolbarPanel?.orderFront(nil)
            if let panel = toolbarPanel {
                print("🪟 工具栏面板: frame=\(panel.frame)")
            }
            updateCursor(at: point)

        default:
            break
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        // 仅 idle 状态跟随悬浮位置切换光标；拖拽中保持按下时设置的光标
        guard state == .idle, !isCapturing, !isClosed else { return }
        let point = convert(event.locationInWindow, from: nil)

        updateSnapHover(at: point)

        // 未生成选区且命中候选元素时用手型提示"点击即选中"
        if selectionRect == nil, hoveredSnappedRect != nil {
            NSCursor.pointingHand.set()
        } else {
            updateCursor(at: point)
        }
    }

    /// 更新智能吸附悬浮高亮（仅在尚未生成选区时生效）
    private func updateSnapHover(at point: NSPoint) {
        let target: NSRect? = selectionRect == nil
            ? snappingEngine.hitTest(at: point, edgeTolerance: 6)
            : nil
        if target != hoveredSnappedRect {
            hoveredSnappedRect = target
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isClosed else { return }
        // 尚未产生选区时，右键直接退出截图
        if selectionRect == nil {
            print("🖱️ 右键退出截图")
            safeCancelAndClose()
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // MARK: - 命中检测与光标

    /// 悬浮命中检测：控制点（半径判定）> 边框（吸附容差）> 内部 > 外部
    private func hitTestSelection(_ p: NSPoint) -> HitTarget {
        guard let r = selectionRect, !r.isEmpty, !r.isNull else { return .outside }

        // 1. 四角控制点（优先级最高）
        let radius2 = Self.handleHitRadius * Self.handleHitRadius
        let corners: [(NSPoint, ResizeHandle)] = [
            (NSPoint(x: r.minX, y: r.maxY), .topLeft),
            (NSPoint(x: r.maxX, y: r.maxY), .topRight),
            (NSPoint(x: r.minX, y: r.minY), .bottomLeft),
            (NSPoint(x: r.maxX, y: r.minY), .bottomRight),
        ]
        for (cp, handle) in corners {
            let dx = p.x - cp.x
            let dy = p.y - cp.y
            if dx * dx + dy * dy <= radius2 {
                return .handle(handle)
            }
        }

        // 2. 四条边
        let tol = Self.edgeHitTolerance
        let nearX = p.x >= r.minX - tol && p.x <= r.maxX + tol
        let nearY = p.y >= r.minY - tol && p.y <= r.maxY + tol
        if abs(p.x - r.minX) <= tol && nearY { return .handle(.left) }
        if abs(p.x - r.maxX) <= tol && nearY { return .handle(.right) }
        if abs(p.y - r.maxY) <= tol && nearX { return .handle(.top) }
        if abs(p.y - r.minY) <= tol && nearX { return .handle(.bottom) }

        // 3. 内部 / 外部
        return r.contains(p) ? .inside : .outside
    }

    /// 控制点 → 光标映射
    private static func cursor(for handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .topLeft, .bottomRight: return nwseResizeCursor  // nwse-resize
        case .topRight, .bottomLeft: return neswResizeCursor  // nesw-resize
        case .top, .bottom:          return .resizeUpDown     // ns-resize
        case .left, .right:          return .resizeLeftRight  // ew-resize
        }
    }

    private func updateCursor(at p: NSPoint) {
        switch hitTestSelection(p) {
        case .handle(let handle): Self.cursor(for: handle).set()
        case .inside: Self.moveCursor.set()
        case .outside: NSCursor.arrow.set()  // 选区外显示普通箭头
        }
    }

    // MARK: - 自绘光标（AppKit 无内置斜向拉伸和移动光标）

    /// nwse-resize：沿 ↖↘ 方向的双向箭头
    private static let nwseResizeCursor = makeDiagonalResizeCursor(dx: 1, dy: 1)

    /// nesw-resize：沿 ↗↙ 方向的双向箭头
    private static let neswResizeCursor = makeDiagonalResizeCursor(dx: 1, dy: -1)

    /// move：四向箭头
    private static let moveCursor: NSCursor = {
        let size: CGFloat = 20
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let c = size / 2
        let arm: CGFloat = 7
        let head: CGFloat = 3
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            let tip = NSPoint(x: c + dx * arm, y: c + dy * arm)
            path.move(to: NSPoint(x: c, y: c))
            path.line(to: tip)
            // 箭头头部
            let px = -dy, py = dx
            path.move(to: NSPoint(x: tip.x - dx * head + px * head * 0.7, y: tip.y - dy * head + py * head * 0.7))
            path.line(to: tip)
            path.line(to: NSPoint(x: tip.x - dx * head - px * head * 0.7, y: tip.y - dy * head - py * head * 0.7))
        }
        strokeCursorPath(path)
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    /// 双向斜箭头光标，方向由 (dx, dy) 决定
    private static func makeDiagonalResizeCursor(dx: CGFloat, dy: CGFloat) -> NSCursor {
        let size: CGFloat = 20
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let center = NSPoint(x: size / 2, y: size / 2)
        let length = sqrt(dx * dx + dy * dy)
        let ux = dx / length, uy = dy / length
        let arm: CGFloat = 7      // 箭杆半长
        let head: CGFloat = 3.2   // 箭头头部尺寸

        let path = NSBezierPath()
        path.lineWidth = 1.5

        func arrowHead(at tip: NSPoint, dirX: CGFloat, dirY: CGFloat) {
            let px = -dirY, py = dirX
            path.move(to: NSPoint(x: tip.x - dirX * head + px * head * 0.7,
                                  y: tip.y - dirY * head + py * head * 0.7))
            path.line(to: tip)
            path.line(to: NSPoint(x: tip.x - dirX * head - px * head * 0.7,
                                  y: tip.y - dirY * head - py * head * 0.7))
        }

        let end1 = NSPoint(x: center.x - ux * arm, y: center.y - uy * arm)
        let end2 = NSPoint(x: center.x + ux * arm, y: center.y + uy * arm)
        path.move(to: end1)
        path.line(to: end2)
        arrowHead(at: end2, dirX: ux, dirY: uy)
        arrowHead(at: end1, dirX: -ux, dirY: -uy)

        strokeCursorPath(path)
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }

    /// 黑边白身双次描边，保证亮暗背景上都可见
    private static func strokeCursorPath(_ path: NSBezierPath) {
        NSColor.black.withAlphaComponent(0.7).setStroke()
        path.stroke()
        path.lineWidth = 1.0
        NSColor.white.setStroke()
        path.stroke()
    }

    /// 在指定点开始创建新选区（起点同样做智能吸附，保证与候选边缘对齐）
    private func startCreating(at point: NSPoint) {
        hideToolbar()
        selectionRect = nil
        hoveredSnappedRect = nil
        dragAnchor = snappingEngine.snapPoint(point, edgeTolerance: 6)
        state = .creating
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    // MARK: - 选区变换计算

    /// 根据控制柄和鼠标位置计算拉伸后的矩形：
    /// 边界钳制 + 反向拖拽翻转 + 最小宽高限制
    private func resizedRect(from original: NSRect, handle: ResizeHandle, point: NSPoint) -> NSRect {
        // 鼠标先钳制在屏幕范围内
        let px = min(max(point.x, bounds.minX), bounds.maxX)
        let py = min(max(point.y, bounds.minY), bounds.maxY)

        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .topLeft, .bottomLeft, .left:
            (minX, maxX) = spanWithFlip(anchor: original.maxX, moving: px,
                                        lower: bounds.minX, upper: bounds.maxX)
        case .topRight, .bottomRight, .right:
            (minX, maxX) = spanWithFlip(anchor: original.minX, moving: px,
                                        lower: bounds.minX, upper: bounds.maxX)
        case .top, .bottom:
            break
        }

        // 注意 AppKit 原点在左下角：top 边对应 maxY，bottom 边对应 minY
        switch handle {
        case .topLeft, .topRight, .top:
            (minY, maxY) = spanWithFlip(anchor: original.minY, moving: py,
                                        lower: bounds.minY, upper: bounds.maxY)
        case .bottomLeft, .bottomRight, .bottom:
            (minY, maxY) = spanWithFlip(anchor: original.maxY, moving: py,
                                        lower: bounds.minY, upper: bounds.maxY)
        case .left, .right:
            break
        }

        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 单轴跨度计算：对边为锚点固定不动，拖拽端跟随鼠标；
    /// 越过锚点自动翻转起点/终点；不足最小尺寸时沿拖拽方向顶开；最后钳制到屏幕范围
    private func spanWithFlip(anchor: CGFloat, moving: CGFloat,
                              lower: CGFloat, upper: CGFloat) -> (CGFloat, CGFloat) {
        var lo = min(anchor, moving)
        var hi = max(anchor, moving)
        let minSpan = Self.minSelectionSpan

        if hi - lo < minSpan {
            if moving >= anchor {
                hi = lo + minSpan
            } else {
                lo = hi - minSpan
            }
        }

        // 极端贴边场景以屏幕边界为准
        lo = max(lo, lower)
        hi = min(hi, upper)
        return (lo, hi)
    }

    /// 方向键微调：平移选区并做边界钳制
    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard var rect = selectionRect, !isClosed else { return }
        var x = rect.origin.x + dx
        var y = rect.origin.y + dy
        x = min(max(x, bounds.minX), bounds.maxX - rect.width)
        y = min(max(y, bounds.minY), bounds.maxY - rect.height)
        rect.origin = NSPoint(x: x, y: y)
        selectionRect = rect
        needsDisplay = true
        refreshToolbarPosition()
    }

    /// 绘制 8 个缩放控制点（四角 + 四边中点，白底黑边小方块）
    private func drawSelectionHandles(_ rect: NSRect) {
        let side: CGFloat = 8
        let half = side / 2
        let points: [NSPoint] = [
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
            NSPoint(x: rect.minX, y: rect.midY),                                                     NSPoint(x: rect.maxX, y: rect.midY),
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
        ]

        NSColor.white.setFill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        for pt in points {
            let handleRect = NSRect(x: pt.x - half, y: pt.y - half, width: side, height: side)
            let path = NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }

    // MARK: - 工具栏管理

    /// 构造工具栏（闭包里打印触发日志，便于诊断点击链路）
    private func makeToolbar() -> SelectionToolbarView {
        SelectionToolbarView(
            onClose: { [weak self] in
                print("🔘 工具栏：关闭按钮被点击")
                self?.safeCancelAndClose()
            },
            onPin: { [weak self] in
                print("🔘 工具栏：置顶按钮被点击")
                self?.handlePinAction()
            },
            onCopy: { [weak self] in
                print("🔘 工具栏：复制按钮被点击")
                self?.handleCopyAction()
            }
        )
    }

    private func showToolbar(for rect: NSRect) {
        // 移除旧的工具栏
        hideToolbar()
        NSApp.activate(ignoringOtherApps: true)

        let toolbarView = makeToolbar()
        var size = toolbarView.fittingSize
        if size.width <= 0 || size.height <= 0 {
            size = SelectionToolbarView.estimatedSize
        }

        // 非激活面板：点击工具栏不会抢走截图窗口的焦点
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver   // 与截图遮罩同级、后创建者在上
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = toolbarView
        panel.setFrameOrigin(ToolbarPositionCalculator.calculatePosition(
            selectionRect: rect, toolbarSize: size, screenBounds: bounds))
        panel.orderFront(nil)

        toolbarPanel = panel
    }

    /// 选区平移/拉伸时更新工具栏位置
    /// 注意：只在原点真正变化时才移动窗口——拖拽期间每个鼠标事件都触发本方法，
    /// 高频的空窗口事务会让面板进入无法接收点击的异常状态
    private func refreshToolbarPosition() {
        guard let panel = toolbarPanel, let rect = selectionRect else { return }
        let newOrigin = ToolbarPositionCalculator.calculatePosition(
            selectionRect: rect, toolbarSize: panel.frame.size, screenBounds: bounds)
        if panel.frame.origin != newOrigin {
            panel.setFrameOrigin(newOrigin)
        }
    }

    private func hideToolbar() {
        guard let panel = toolbarPanel else { return }

        // 立即清空引用，防止重复调用
        toolbarPanel = nil

        if Thread.isMainThread {
            panel.orderOut(nil)
            print("🗑️ 工具栏已移除")
        } else {
            DispatchQueue.main.async {
                panel.orderOut(nil)
                print("🗑️ 工具栏已移除（异步）")
            }
        }
    }

    private func clearSelection() {
        guard !isClosed else {
            print("⚠️ 已经关闭，跳过清理")
            return
        }

        // 取消截图任务
        currentCaptureTask?.cancel()
        currentCaptureTask = nil

        selectionRect = nil
        activeHandle = nil
        hoveredSnappedRect = nil
        pressedOnSnappedRect = nil
        state = .idle
        isCapturing = false
        hideToolbar()
        needsDisplay = true
        print("🗑️ 选区已清除")
    }

    /// 安全地调用 onCancelled 回调，防止重复调用
    private func safeCancelAndClose() {
        guard !isClosed else {
            print("⚠️ 已经关闭，跳过重复调用")
            return
        }
        isClosed = true

        // 取消截图任务
        currentCaptureTask?.cancel()
        currentCaptureTask = nil

        print("🚪 安全关闭截图窗口")
        onCancelled?()
    }

    private func handlePinAction() {
        print("📌 置顶功能 - 待实现")
        // TODO: 实现置顶功能
    }

    private func handleCopyAction() {
        guard selectionRect != nil, state == .idle, !isCapturing else { return }
        print("📋 复制选区: \(selectionRect.map { "\($0.origin), \($0.size)" } ?? "nil")")

        startCaptureProcess()
    }

    private func handleDoubleClickSelection() {
        guard selectionRect != nil, state == .idle, !isCapturing else { return }
        print("🖱️ 双击选区，开始截图并复制")

        startCaptureProcess()
    }

    private func startCaptureProcess() {
        guard !isCapturing else {
            print("⚠️ 已经在截图中，跳过")
            return
        }
        guard !isClosed else {
            print("⚠️ 窗口已关闭，跳过截图")
            return
        }
        isCapturing = true
        print("🎬 开始截图流程")

        // 保存选区引用
        guard let rect = selectionRect else {
            print("❌ 没有选区")
            isCapturing = false
            return
        }

        print("📍 选区坐标（AppKit坐标系，原点在左下角）:")
        print("   - rect.origin: (\(rect.origin.x), \(rect.origin.y))")
        print("   - rect.size: (\(rect.width), \(rect.height))")
        print("   - 窗口bounds: \(window?.frame ?? .zero)")
        print("   - 屏幕frame: \(window?.screen?.frame ?? .zero)")

        // 先隐藏工具栏，避免截图包含工具栏
        hideToolbar()

        // 修改窗口透明度，给用户视觉反馈
        window?.alphaValue = 0.3

        // 取消之前的任务
        currentCaptureTask?.cancel()

        // 使用 Task 而不是 Task.detached，确保继承主 actor 上下文
        currentCaptureTask = Task { [weak self] in
            guard let self = self else {
                print("⚠️ CaptureView 已被释放（Task 开始时）")
                return
            }

            let startTime = Date()
            print("⏱️ [0ms] 开始后台截图任务")

            let success = await self.captureAndCopyToClipboard(rect: rect)

            let duration = Date().timeIntervalSince(startTime) * 1000
            print("⏱️ [\(Int(duration))ms] 截图任务完成，success: \(success)")

            // 确保在主线程处理结果
            await MainActor.run { [weak self] in
                guard let self = self else {
                    print("⚠️ CaptureView 已被释放（MainActor.run）")
                    return
                }

                guard !self.isClosed else {
                    print("⚠️ 窗口已关闭，跳过后续处理")
                    return
                }

                print("🔄 恢复窗口状态")
                self.isCapturing = false
                self.currentCaptureTask = nil
                self.window?.alphaValue = 1.0

                if success {
                    print("✅ 截图成功，准备关闭窗口")
                    print("📞 调用 safeCancelAndClose()")
                    self.safeCancelAndClose()
                    print("✅ safeCancelAndClose() 已调用")
                } else {
                    print("❌ 截图失败，恢复工具栏")
                    if let rect = self.selectionRect {
                        self.showToolbar(for: rect)
                    }
                }
            }
        }
    }

    /// 整屏按显示器原生物理像素抓取，排除本应用的所有窗口
    /// （遮罩窗口被排除后，截到的是遮罩下方的内容）
    /// - Returns: (整屏图像, 图像所在的屏幕)
    private func grabFullScreenExcludingSelf() async throws -> (CGImage, NSScreen) {
        // 使用截图窗口所在的屏幕，保证显示器、坐标系、缩放因子三者一致
        guard let screen = window?.screen ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            print("❌ 无法获取目标屏幕")
            throw NSError(domain: "snipaste.capture", code: -1)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            print("❌ 无法获取显示器 (displayID=\(displayID))")
            throw NSError(domain: "snipaste.capture", code: -2)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = display.width    // 显示器物理像素宽
        configuration.height = display.height  // 显示器物理像素高
        configuration.scalesToFit = false

        // 高质量参数
        configuration.showsCursor = false                      // 不显示光标
        configuration.backgroundColor = .clear                 // 透明背景
        configuration.pixelFormat = kCVPixelFormatType_32BGRA  // 高质量像素格式
        // 注意：不设置 colorSpaceName，保留显示器原生色彩空间，
        // 避免 P3 -> sRGB 转换造成色偏，保证截到的是"原图"

        // 排除本应用的窗口，避免遮罩/选区边框/工具栏被截进图像
        let bundleID = Bundle.main.bundleIdentifier
        let selfWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID
        }
        let filter = SCContentFilter(display: display, excludingWindows: selfWindows)

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, screen)
    }

    private func captureAndCopyToClipboard(rect: CGRect) async -> Bool {
        do {
            // 检查任务是否已取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            // ===== Step 1~2：整屏原生捕获 + 整数像素裁剪 =====
            // 不走 sourceRect + width/height 的缩放采样路径——那条路径由 SCK 内部
            // 重采样决定输出尺寸，任何比例/取整偏差都会导致画面发虚。
            // 整屏原生抓取 + CGImage.cropping 是纯像素提取，保证严格 1:1 原图。
            let step1Start = Date()

            let (fullImage, screen) = try await grabFullScreenExcludingSelf()
            let screenHeight = screen.frame.height

            let step1Duration = Date().timeIntervalSince(step1Start) * 1000
            print("⏱️ [Step 1] 整屏捕获完成，耗时: \(Int(step1Duration))ms")
            print("📊 整屏图像尺寸: \(fullImage.width)x\(fullImage.height)")

            // 再次检查取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            // ===== 整数物理像素裁剪（纯像素提取，无重采样） =====
            // 缩放因子从"实际捕获到的位图"反推，而不是信任 backingScaleFactor，
            // 保证裁剪计算与真实位图像素严格对齐
            guard screen.frame.width > 0, fullImage.width > 0 else {
                print("❌ 屏幕或图像尺寸异常")
                return false
            }
            let scaleFactor = CGFloat(fullImage.width) / screen.frame.width

            // 选区（视图坐标，AppKit 左下原点）-> 物理像素矩形（左上原点）
            let cropX = (rect.minX * scaleFactor).rounded()
            let cropY = ((screenHeight - rect.maxY) * scaleFactor).rounded()
            let cropW = max(1, (rect.width * scaleFactor).rounded())
            let cropH = max(1, (rect.height * scaleFactor).rounded())

            // 防御：裁剪范围夹在整屏图像内
            let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                .intersection(CGRect(x: 0, y: 0,
                                     width: CGFloat(fullImage.width),
                                     height: CGFloat(fullImage.height)))
            guard !cropRect.isEmpty, !cropRect.isNull,
                  let image = fullImage.cropping(to: cropRect) else {
                print("❌ 选区裁剪失败: crop=\(cropRect)")
                return false
            }

            print("✂️ 裁剪选区: 逻辑 \(Int(rect.width))x\(Int(rect.height))pt -> 物理 \(Int(cropW))x\(Int(cropH))px")

            // 再次检查取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            let step3Start = Date()
            print("⏱️ [Step 4] 准备图像数据...")

            // 直接在当前上下文生成 PNG 数据，不使用嵌套 Task
            print("⏱️ [后台] 开始生成 PNG 数据...")
            let dataStart = Date()

            // 创建 NSBitmapImageRep 来生成高质量图像数据
            let bitmapRep = NSBitmapImageRep(cgImage: image)

            // 正确设置逻辑尺寸（单位：points）
            bitmapRep.size = NSSize(width: CGFloat(image.width) / scaleFactor, height: CGFloat(image.height) / scaleFactor)

            print("📊 BitmapRep 像素尺寸: \(bitmapRep.pixelsWide)x\(bitmapRep.pixelsHigh)")
            print("📊 BitmapRep 逻辑尺寸: \(bitmapRep.size)")
            print("📊 计算的 DPI: \(72.0 * scaleFactor)") // 标准 72 DPI * 缩放因子

            // 使用 TIFF 格式（无损且保留所有元数据）
            guard let tiffData = bitmapRep.tiffRepresentation else {
                print("❌ [后台] 无法生成 TIFF 数据")
                return false
            }

            let dataDuration = Date().timeIntervalSince(dataStart) * 1000
            print("⏱️ [后台] TIFF 数据生成完成，耗时: \(Int(dataDuration))ms, 大小: \(tiffData.count) bytes")

            let step3Duration = Date().timeIntervalSince(step3Start) * 1000
            print("⏱️ [Step 4] 图像数据准备完成，总耗时: \(Int(step3Duration))ms")

            // 最后检查取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return false
            }

            // 在主线程操作剪贴板
            let success = await MainActor.run {
                print("⏱️ [主线程] 写入剪贴板...")
                let pasteboardStart = Date()

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()

                // 方法1：TIFF，默认无压缩，逐字节保留原始像素；
                // 先写入的类型成为首选类型，粘贴方优先取用
                let tiffResult = pasteboard.setData(tiffData, forType: .tiff)
                print("   - TIFF 写入: \(tiffResult ? "✅" : "❌")")

                // 方法2：PNG，无损压缩——解码后像素与原图完全一致，
                // 兼容只认 PNG 的应用；两者都不会有画质损失
                if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                    let pngResult = pasteboard.setData(pngData, forType: .png)
                    print("   - PNG 写入: \(pngResult ? "✅" : "❌")")
                }

                let duration = Date().timeIntervalSince(pasteboardStart) * 1000
                print("⏱️ [主线程] 剪贴板写入完成，耗时: \(Int(duration))ms")

                return tiffResult
            }

            if success {
                print("✅ 截图已复制到剪贴板")
            } else {
                print("❌ 剪贴板写入失败")
            }
            return success
        } catch {
            print("❌ 截图失败: \(error)")
            print("❌ 错误详情: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 键盘事件

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        // 方向键微调选区：1px，Shift + 方向键 10px（选区确认后生效）
        if let delta = Self.arrowKeyDeltas[event.keyCode],
           selectionRect != nil, state == .idle, !isCapturing, !isClosed {
            let scale: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            nudgeSelection(dx: delta.0 * scale, dy: delta.1 * scale)
            return
        }

        // ESC key (keyCode = 53)
        if event.keyCode == 53 {
            if selectionRect != nil {
                // 如果有已确认的选区，清除选区
                clearSelection()
            } else {
                // 否则取消整个截图
                isCapturing = false
                safeCancelAndClose()
            }
        } else {
            super.keyDown(with: event)
        }
    }

    /// 方向键 → 位移增量（AppKit Y 轴向上：↑ 为 +y）
    private static let arrowKeyDeltas: [UInt16: (CGFloat, CGFloat)] = [
        123: (-1, 0),  // ←
        124: (1, 0),   // →
        125: (0, -1),  // ↓
        126: (0, 1),   // ↑
    ]
}
