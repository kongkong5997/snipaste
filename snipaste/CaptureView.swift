//
//  CaptureView.swift
//  snipaste
//
//  Created by Claude
//

import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

class CaptureView: NSView {
    // 回调闭包
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    // MARK: - 选区交互状态机

    /// creating   - 初次按下并拖拽生成矩形
    /// idle       - 选区已确认，根据悬浮位置切换光标
    /// moving     - 鼠标在选区内部拖拽，整体平移
    /// resizing   - 鼠标在控制柄或边框上拖拽，修改选区宽高与坐标
    /// annotating - 标注工具激活时在选区内拖拽绘制标注
    private enum InteractionState {
        case creating, idle, moving, resizing, annotating
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
    /// 主工具栏的附属样式栏，独立面板保证按钮可点击并跟随主工具栏移动。
    private var annotationOptionsPanel: NSPanel?
    private var isCapturing = false  // 防止重复截图
    private var isClosed = false  // 防止重复关闭
    private var currentCaptureTask: Task<Void, Never>?  // 当前截图任务

    /// 全局设置（吸附、遮罩、尺寸标签、标注样式等）
    private let settings = AppSettings.shared

    /// 会话进入方式（由 CaptureWindow 在展示前设置）
    var initialMode: CaptureMode = .region
    private var didApplyInitialMode = false

    // 窗口吸附（智能吸附只针对应用窗口边框）
    private let snappingEngine = SnappingEngine()
    private var hoveredSnappedRect: NSRect?   // 悬浮命中的窗口框（未生成选区时高亮）
    private var pressedOnSnappedRect: NSRect? // 按下时命中的窗口（抬手仍未拖出选区则直接选中它）

    // MARK: - 标注状态

    /// 当前激活的标注工具（nil = 普通选区模式）
    private var activeTool: AnnotationTool?
    /// 已提交的标注（视图坐标）
    private var annotations: [Annotation] = []
    /// 撤销 / 重做栈：记录"添加"与"删除"两种编辑，橡皮擦删除也能撤销
    private var editStack: [AnnotationEdit] = []
    private var redoEditStack: [AnnotationEdit] = []

    /// 可撤销的标注编辑
    private enum AnnotationEdit {
        case add(Annotation)
        case remove(annotation: Annotation, index: Int)
    }

    /// 模糊工具用的整屏高斯模糊图（懒加载，一次会话只算一次）
    private var blurredBackground: CGImage?

    /// 正在编辑的文字输入框及其锚点（视图坐标）
    private var textEditor: NSTextField?
    private var textEditorAnchor: NSPoint = .zero

    /// 滚动截图会话（进行中时非空）
    private var scrollSession: ScrollCaptureSession?
    /// 正在绘制中的标注（收笔后提交）
    private var inProgressAnnotation: Annotation?
    /// 正在绘制标注的锚点（方框 / 箭头的起点）
    private var annotationAnchor: NSPoint = .zero

    /// 冻结的整屏底图（物理像素）：激活标注工具时抓取，
    /// 保证标注预览、马赛克取样与导出结果完全一致
    private var frozenImage: CGImage?
    /// 冻结底图对应的马赛克小图（整屏尺寸 / 块大小 的像素）
    private var pixelatedBackground: CGImage?
    /// 冻结任务（防止重复抓取）
    private var freezeTask: Task<Void, Never>?
    /// 工具栏视图引用（用于同步激活工具的高亮）
    private var toolbarViewRef: SelectionToolbarView?

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
        freezeTask?.cancel()
        freezeTask = nil
        scrollSession?.abort()
        scrollSession = nil
        // 确保清理工具栏
        hideToolbar()
    }

    private func setupView() {
        // 接受第一响应者（用于接收键盘事件）
        wantsLayer = true

        // 吸附开关收在引擎内部；窗口原点用于把 CG 全局坐标换算到本屏视图坐标
        // （副屏原点不是 (0,0)，不换算会导致整屏候选全部失配）
        snappingEngine.isEnabled = settings.snapToWindows
        snappingEngine.reload(viewBounds: bounds, screenOrigin: window?.frame.origin ?? .zero)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyInitialModeIfNeeded()
    }

    /// 应用会话进入方式：
    /// - 全屏：直接选中整屏并显示工具栏
    /// - 窗口：强制开启窗口高亮，点击窗口即完成选区
    /// - 重复上次：恢复上次选区（超出屏幕时夹回，失效则退回整屏）
    private func applyInitialModeIfNeeded() {
        guard !didApplyInitialMode, window != nil else { return }
        didApplyInitialMode = true

        switch initialMode {
        case .region:
            break
        case .fullScreen:
            confirmSelection(bounds)
        case .window:
            snappingEngine.isEnabled = true
            snappingEngine.reload(viewBounds: bounds, screenOrigin: window?.frame.origin ?? .zero)
            needsDisplay = true
        case .repeatLast:
            if let last = settings.lastSelectionRect {
                let rect = last.intersection(bounds)
                if rect.width > 20, rect.height > 20 {
                    confirmSelection(rect)
                    return
                }
            }
            print("↩️ 上次选区不可用，退回整屏")
            confirmSelection(bounds)
        }
    }

    /// 以指定矩形完成选区（程序化入口：全屏 / 窗口 / 重复上次）
    private func confirmSelection(_ rect: NSRect) {
        guard !isClosed else { return }
        state = .idle
        selectionRect = rect
        hoveredSnappedRect = nil
        showToolbar(for: rect)
        onRegionSelected?(rect)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 冻结底图铺满全屏：激活标注工具后画面内容固定，
        // 标注预览与最终导出都以它为基准（马赛克也需要真实像素取样）
        if scrollSession == nil, let frozenImage {
            context.draw(frozenImage, in: bounds)
        }

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
            NSColor.black.withAlphaComponent(CGFloat(settings.maskOpacity)).setFill()
            screenPath.fill()

            // 恢复上下文状态
            context.restoreGState()

            // 标注层：裁剪在选区内绘制，与导出的裁剪口径一致
            if scrollSession == nil, let selection = selectionRect {
                context.saveGState()
                context.clip(to: selection)
                AnnotationRenderer.render(displayAnnotations,
                                          sources: ObscureSources(pixelated: pixelatedBackground,
                                                                  blurred: blurredBackground),
                                          screenRect: bounds,
                                          into: context)
                context.restoreGState()
            }

            // 绘制选区边框
            (scrollSession == nil ? NSColor.white : NSColor.systemBlue).setStroke()
            let borderWidth: CGFloat = 2.0
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = borderWidth
            borderPath.stroke()

            // 只有真实选区才绘制 8 个缩放控制点（吸附预览不可交互，不画）
            if isActiveSelection, scrollSession == nil {
                drawSelectionHandles(rect)
            }

            // 绘制尺寸信息（可在设置里关闭）
            if settings.showSizeLabel, scrollSession == nil {
                drawSizeLabel(for: rect)
            }
        } else {
            // 没有选区时，绘制整个屏幕的遮罩
            NSColor.black.withAlphaComponent(CGFloat(settings.maskOpacity)).setFill()
            bounds.fill()

            // 窗口点选模式：给出操作提示
            if initialMode == .window {
                drawHintLabel("点击要截取的窗口，或在空白处拖拽选择区域")
            }
        }
    }

    /// 屏幕顶部居中的操作提示（窗口点选模式用）
    private func drawHintLabel(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: bounds.midX - (size.width + 28) / 2,
                          y: bounds.maxY - 92,
                          width: size.width + 28,
                          height: 32)

        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + (rect.height - size.height) / 2),
                                withAttributes: attributes)
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

        // 自愈：工具栏面板可能因失活或层级变化被隐藏，任何交互都把它重新置前
        if let panel = toolbarPanel, !panel.isVisible {
            panel.orderFront(nil)
        }

        // 文字编辑中：这一击只用于提交输入，不再开始新标注
        if textEditor != nil {
            commitTextEditing()
            window?.makeFirstResponder(self)
            return
        }

        // 双击选区内部 → 截图并复制到剪贴板
        // 重要：延迟到下一个 runloop 执行，避免在事件处理中阻塞
        if event.clickCount == 2, activeTool == nil, settings.doubleClickCopies,
           case .inside = hitTestSelection(point) {
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
            if let tool = activeTool {
                // 标注工具激活 → 选区内部拖拽绘制标注
                beginAnnotation(with: tool, at: point)
            } else {
                // 选区内部 → 整体平移
                guard let rect = selectionRect else { return }
                state = .moving
                moveGrabOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
                Self.moveCursor.set()
            }

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

        case .annotating:
            // 只失效笔迹变化的区域：整屏重绘（含冻结底图）会拖慢跟手度
            let previous = inProgressAnnotation
            updateInProgressAnnotation(to: point)
            invalidateAnnotationRegion(previous: previous, current: inProgressAnnotation)

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

        case .annotating:
            finishAnnotation(at: point)
            updateCursor(at: point)

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
        case .inside:
            // 标注工具激活时用十字光标提示"可绘制"
            if activeTool != nil {
                NSCursor.crosshair.set()
            } else {
                Self.moveCursor.set()
            }
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

    // MARK: - 标注工具

    /// 待渲染的标注（已提交的 + 正在绘制的那条）
    private var displayAnnotations: [Annotation] {
        guard let inProgressAnnotation else { return annotations }
        return annotations + [inProgressAnnotation]
    }

    /// 工具栏点击：切换激活的标注工具（再次点击同一工具 → 取消激活，回到选区操作）
    private func toggleTool(_ tool: AnnotationTool) {
        guard !isClosed, !isCapturing, state == .idle, selectionRect != nil else { return }

        if activeTool == tool {
            deactivateTool()
            print("🎨 已退出标注工具: \(tool.label)")
        } else {
            setTool(tool)
        }
    }

    /// 直接激活指定工具（数字键 / 工具栏共用，不切换关闭）
    private func setTool(_ tool: AnnotationTool) {
        guard !isClosed, !isCapturing, state == .idle, selectionRect != nil else { return }
        guard activeTool != tool else { return }
        commitTextEditing()
        activeTool = tool
        inProgressAnnotation = nil
        // 冻结底图：保证标注预览、马赛克取样与导出结果完全一致
        ensureFrozenBackground()
        if tool == .blur {
            ensureBlurredBackground()
        }
        toolbarViewRef?.setActiveTool(tool)
        showAnnotationOptions()
        needsDisplay = true
        print("🎨 已激活标注工具: \(tool.label)")
    }

    /// 取消激活标注工具（保留选区与已有标注）。
    /// 没有任何标注时顺手释放冻结底图：否则取消工具后画面停在旧帧，
    /// 与 Esc 清空选区（会解冻）的行为不一致
    private func deactivateTool() {
        commitTextEditing()
        activeTool = nil
        inProgressAnnotation = nil
        toolbarViewRef?.setActiveTool(nil)
        hideAnnotationOptions()
        if annotations.isEmpty {
            releaseFrozenBackground()
        }
    }

    /// 释放冻结底图，回到实时取景
    private func releaseFrozenBackground() {
        freezeTask?.cancel()
        freezeTask = nil
        frozenImage = nil
        pixelatedBackground = nil
        blurredBackground = nil
        needsDisplay = true
    }

    /// 模糊图懒加载：首次用到模糊工具时才计算（GPU 高斯模糊）
    private func ensureBlurredBackground() {
        guard blurredBackground == nil, let frozen = frozenImage else { return }
        let scale = CGFloat(frozen.width) / max(1, bounds.width)
        let radius = AnnotationRenderer.blurRadiusPointSize * scale
        print("🌀 生成模糊底图，半径 \(Int(radius))px")
        blurredBackground = AnnotationRenderer.makeBlurred(from: frozen, radiusPixels: radius)
    }

    /// 冻结屏幕：抓取整屏（排除本应用窗口）作为固定底图，并预生成马赛克小图。
    /// 幂等：已冻结或正在冻结时直接返回
    private func ensureFrozenBackground() {
        guard frozenImage == nil, freezeTask == nil else { return }
        print("🧊 开始冻结标注底图...")

        freezeTask = Task { [weak self] in
            guard let self = self else { return }
            guard let image = try? await self.grabAllScreensExcludingSelf() else {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.freezeTask = nil
                    print("❌ 冻结底图失败")
                }
                return
            }

            let scale = CGFloat(image.width) / max(1, self.bounds.width)
            let blockPixels = max(2, Int((AnnotationRenderer.mosaicBlockPointSize * scale).rounded()))

            await MainActor.run { [weak self] in
                guard let self = self, !self.isClosed else { return }
                self.frozenImage = image
                self.pixelatedBackground = AnnotationRenderer.makePixelatedSmall(from: image, blockPixels: blockPixels)
                self.freezeTask = nil
                if self.activeTool == .blur {
                    self.ensureBlurredBackground()
                }
                self.needsDisplay = true
                print("🧊 标注底图已冻结: \(image.width)x\(image.height), 马赛克块 \(blockPixels)px")
            }
        }
    }

    /// 文字字号独立于箭头 / 画笔线宽，由快捷样式栏设置。
    private var textFontSize: CGFloat {
        CGFloat(settings.annotationFontSize)
    }

    /// 非激活样式面板不会提交输入；调整字号或颜色时同步更新正在编辑的文字。
    private func updateTextEditorStyle() {
        guard let field = textEditor else { return }
        let font = NSFont.systemFont(ofSize: textFontSize, weight: .medium)
        field.font = font
        field.textColor = settings.annotationColor
        if let editor = field.currentEditor() as? NSTextView {
            editor.font = font
            editor.textColor = settings.annotationColor
            editor.insertionPointColor = settings.annotationColor
        }
        let size = (field.stringValue as NSString).size(withAttributes: [.font: font])
        field.frame.size = NSSize(width: max(120, min(size.width + 28, 640)), height: textFontSize + 8)
        needsDisplay = true
    }

    /// 开始编辑文字标注：点击处放一个内联输入框，回车 / 点别处提交，Esc 取消
    private func beginTextEditing(at point: NSPoint) {
        commitTextEditing()

        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 3, width: 220, height: textFontSize + 8))
        field.font = .systemFont(ofSize: textFontSize, weight: .medium)
        field.textColor = settings.annotationColor
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.placeholderString = "输入文字后回车"
        field.delegate = self

        addSubview(field)
        textEditor = field
        textEditorAnchor = point
        window?.makeFirstResponder(field)
        print("✍️ 开始输入文字")
    }

    /// 提交文字编辑
    private func commitTextEditing() {
        guard let field = textEditor else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = textEditorAnchor
        field.removeFromSuperview()
        textEditor = nil

        if !text.isEmpty {
            apply(.add(.text(origin: anchor, string: text, color: settings.annotationColor,
                             fontSize: textFontSize)))
            print("✍️ 已添加文字标注「\(text)」")
        }
        needsDisplay = true
    }

    /// 取消文字编辑（Esc）
    private func cancelTextEditing() {
        guard textEditor != nil else { return }
        textEditor?.removeFromSuperview()
        textEditor = nil
        needsDisplay = true
    }

    /// 开始一条新标注（记录锚点，进入绘制状态）。
    /// 文字是点击输入、橡皮擦是点击删除，都不进入绘制状态
    private func beginAnnotation(with tool: AnnotationTool, at point: NSPoint) {
        switch tool {
        case .text:
            beginTextEditing(at: point)
            return
        case .eraser:
            eraseAnnotation(at: point)
            return
        default:
            break
        }

        annotationAnchor = point
        // 颜色与线宽取当前设置（每条标注独立保存，改设置只影响之后画的）
        let color = settings.annotationColor
        let width = CGFloat(settings.annotationLineWidth)
        switch tool {
        case .pencil:
            inProgressAnnotation = .pencil(points: [point], color: color, width: width)
        case .rectangle:
            inProgressAnnotation = .rectangle(rect: NSRect(origin: point, size: .zero),
                                              color: color, width: width)
        case .ellipse:
            inProgressAnnotation = .ellipse(rect: NSRect(origin: point, size: .zero),
                                            color: color, width: width)
        case .line:
            inProgressAnnotation = .line(from: point, to: point, color: color, width: width)
        case .arrow:
            inProgressAnnotation = .arrow(from: point, to: point, color: color, width: width)
        case .numbering:
            inProgressAnnotation = .numbering(center: point, number: nextNumberingIndex(), color: color)
        case .mosaic:
            inProgressAnnotation = .mosaic(points: [point], radius: AnnotationRenderer.mosaicRadius)
        case .blur:
            inProgressAnnotation = .blur(points: [point], radius: AnnotationRenderer.mosaicRadius)
        case .text, .eraser:
            break   // 已在上面提前返回
        }
        state = .annotating
        needsDisplay = true
    }

    /// 下一个序号：现有标注里的最大编号 + 1（撤销后编号会自动收回）
    private func nextNumberingIndex() -> Int {
        let maximum = annotations.compactMap { annotation -> Int? in
            if case let .numbering(_, number, _) = annotation { return number }
            return nil
        }.max() ?? 0
        return maximum + 1
    }

    /// 橡皮擦：删除点中的最上层一条标注（可撤销）
    private func eraseAnnotation(at point: NSPoint) {
        for index in annotations.indices.reversed()
        where AnnotationRenderer.hitTest(annotations[index], at: point) {
            let removed = annotations[index]
            annotations.remove(at: index)
            editStack.append(.remove(annotation: removed, index: index))
            redoEditStack.removeAll()
            print("🧽 已擦除标注: \(AnnotationRenderer.describe(removed))")
            needsDisplay = true
            return
        }
    }

    /// 拖拽中更新当前标注：手绘类追加采样点，几何类更新终点
    private func updateInProgressAnnotation(to point: NSPoint) {
        guard let current = inProgressAnnotation else { return }
        switch current {
        case let .pencil(points, color, width):
            guard Self.isFarEnough(point, from: points.last, minSpacing: 2) else { return }
            inProgressAnnotation = .pencil(points: points + [point], color: color, width: width)

        case let .mosaic(points, radius):
            guard Self.isFarEnough(point, from: points.last, minSpacing: 3) else { return }
            inProgressAnnotation = .mosaic(points: points + [point], radius: radius)

        case let .blur(points, radius):
            guard Self.isFarEnough(point, from: points.last, minSpacing: 3) else { return }
            inProgressAnnotation = .blur(points: points + [point], radius: radius)

        case let .rectangle(_, color, width):
            inProgressAnnotation = .rectangle(rect: Self.rect(from: annotationAnchor, to: point),
                                              color: color, width: width)

        case let .ellipse(_, color, width):
            inProgressAnnotation = .ellipse(rect: Self.rect(from: annotationAnchor, to: point),
                                            color: color, width: width)

        case let .line(_, _, color, width):
            inProgressAnnotation = .line(from: annotationAnchor,
                                         to: Self.constrainedPoint(point, from: annotationAnchor),
                                         color: color, width: width)

        case let .arrow(_, _, color, width):
            inProgressAnnotation = .arrow(from: annotationAnchor,
                                          to: Self.constrainedPoint(point, from: annotationAnchor),
                                          color: color, width: width)

        case .numbering, .text:
            break   // 点击即定形，拖拽不改形状
        }
    }

    /// 按住 Shift 时把终点约束到 45° 倍数方向（直线 / 箭头用）
    private static func constrainedPoint(_ point: NSPoint, from anchor: NSPoint) -> NSPoint {
        guard NSEvent.modifierFlags.contains(.shift) else { return point }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 1 else { return point }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return NSPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    /// 采样点距离过滤：与上一个点距离不足 minSpacing（pt）时丢弃
    private static func isFarEnough(_ point: NSPoint, from last: NSPoint?, minSpacing: CGFloat) -> Bool {
        guard let last else { return true }
        let dx = point.x - last.x
        let dy = point.y - last.y
        return dx * dx + dy * dy >= minSpacing * minSpacing
    }

    /// 归一化拖拽出的矩形（任意方向拖拽都成立）
    private static func rect(from anchor: NSPoint, to point: NSPoint) -> NSRect {
        NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
               width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
    }

    /// 标注拖拽时只失效变化区域。手绘类只重绘新增尾段，几何类重绘新旧外接框并集
    private func invalidateAnnotationRegion(previous: Annotation?, current: Annotation?) {
        let dirty: NSRect
        switch (previous, current) {
        case let (.pencil(_, _, width), .pencil(newPoints, _, _)):
            // 追加式：只有最后几段会变（末段曲线由最后 3 个点决定）
            dirty = Self.pointsBounds(Array(newPoints.suffix(4)), padding: width + 4)
        case let (.mosaic(_, _), .mosaic(newPoints, radius)),
             let (.blur(_, _), .blur(newPoints, radius)):
            dirty = Self.pointsBounds(Array(newPoints.suffix(2)), padding: radius + 4)
        case let (old?, new?):
            dirty = Self.bounds(of: old).union(Self.bounds(of: new))
        case let (nil, new?):
            dirty = Self.bounds(of: new)
        default:
            return
        }
        guard !dirty.isNull else { return }
        setNeedsDisplay(dirty.insetBy(dx: -6, dy: -6).intersection(bounds))
    }

    /// 标注的外接矩形（含线宽 / 笔刷半径的余量）
    private static func bounds(of annotation: Annotation) -> NSRect {
        switch annotation {
        case let .pencil(points, _, width):
            return pointsBounds(points, padding: width)
        case let .rectangle(rect, _, width), let .ellipse(rect, _, width):
            return rect.insetBy(dx: -width, dy: -width)
        case let .line(from, to, _, width):
            return pointsBounds([from, to], padding: width)
        case let .arrow(from, to, _, width):
            // 箭头头部可达线宽的 4.5 倍，留足余量
            return pointsBounds([from, to], padding: width * 6)
        case let .text(origin, string, _, fontSize):
            return AnnotationRenderer.textBounds(string, at: origin, fontSize: fontSize).insetBy(dx: -4, dy: -4)
        case let .numbering(center, _, _):
            let radius = AnnotationRenderer.numberingRadius
            return NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case let .mosaic(points, radius), let .blur(points, radius):
            return pointsBounds(points, padding: radius)
        }
    }

    private static func pointsBounds(_ points: [NSPoint], padding: CGFloat) -> NSRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return NSRect(x: minX - padding, y: minY - padding,
                      width: maxX - minX + padding * 2,
                      height: maxY - minY + padding * 2)
    }

    /// 收笔：太短的几何标注视为误点丢弃，其余提交入栈
    private func finishAnnotation(at point: NSPoint) {
        updateInProgressAnnotation(to: point)
        defer {
            inProgressAnnotation = nil
            state = .idle
            needsDisplay = true
        }
        guard let annotation = inProgressAnnotation else { return }

        switch annotation {
        case .rectangle(let rect, _, _) where rect.width < 4 && rect.height < 4:
            return
        case .ellipse(let rect, _, _) where rect.width < 4 && rect.height < 4:
            return
        case .line(let from, let to, _, _), .arrow(let from, let to, _, _)
            where (to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y) < 16:
            return
        default:
            break
        }

        apply(.add(annotation))
        print("🎨 已添加标注 #\(annotations.count): \(AnnotationRenderer.describe(annotation))")
    }

    /// 应用一次编辑：记入撤销栈并清空重做栈
    private func apply(_ edit: AnnotationEdit) {
        switch edit {
        case .add(let annotation):
            annotations.append(annotation)
        case .remove(let annotation, let index):
            annotations.insert(annotation, at: min(index, annotations.count))
        }
        editStack.append(edit)
        redoEditStack.removeAll()
    }

    /// 撤销上一步标注编辑（Cmd+Z），包括橡皮擦的删除
    private func undoAnnotation() {
        guard let edit = editStack.popLast() else { return }
        switch edit {
        case .add:
            // 撤销添加：上一步刚追加的那条就是最后一条
            annotations.removeLast()
        case .remove(let annotation, let index):
            annotations.insert(annotation, at: min(index, annotations.count))
        }
        redoEditStack.append(edit)
        needsDisplay = true
        print("↩️ 撤销标注，剩余 \(annotations.count) 条")
    }

    /// 重做（Cmd+Shift+Z）
    private func redoAnnotation() {
        guard let edit = redoEditStack.popLast() else { return }
        switch edit {
        case .add(let annotation):
            annotations.append(annotation)
        case .remove(_, let index):
            guard index < annotations.count else { return }
            annotations.remove(at: index)
        }
        editStack.append(edit)
        needsDisplay = true
        print("↪️ 重做标注，共 \(annotations.count) 条")
    }

    /// 处理 Cmd+Z / Cmd+Shift+Z；无可撤销/重做内容时返回 false 交还系统
    private func handleUndoRedo(_ event: NSEvent) -> Bool {
        guard !isCapturing, !isClosed else { return false }
        let flags = event.modifierFlags
        guard flags.contains(.command),
              !flags.contains(.option), !flags.contains(.control),
              event.charactersIgnoringModifiers?.lowercased() == "z",
              !editStack.isEmpty || !redoEditStack.isEmpty else { return false }

        if flags.contains(.shift) {
            redoAnnotation()
        } else {
            undoAnnotation()
        }
        return true
    }

    // MARK: - 滚动截图

    /// 进入滚动截图：遮罩让出鼠标事件，用户自行滚动页面，程序按间隔抓帧拼接。
    /// 完成后打开长图预览并结束会话；取消则恢复截图会话继续操作
    private func startScrollCapture() {
        guard let rect = selectionRect, state == .idle, !isCapturing, !isClosed else { return }
        commitTextEditing()
        isCapturing = true
        hideToolbar()

        // 让出鼠标事件以操作下层页面；滚动模式暂时隐藏冻结底图及标注，返回选区时恢复。
        window?.ignoresMouseEvents = true
        NSCursor.arrow.set()

        let session = ScrollCaptureSession(region: rect, view: self) { [weak self] image, logicalSize in
            guard let self else { return }
            self.scrollSession = nil
            self.window?.ignoresMouseEvents = false
            self.needsDisplay = true

            if let image {
                print("🧵 滚动截图完成，逻辑尺寸 \(Int(logicalSize.width))x\(Int(logicalSize.height))pt")
                ScreenshotHistory.shared.record(image, pointSize: logicalSize)
                LongImagePreviewController.shared.show(image: image, pointSize: logicalSize)
                self.isCapturing = false
                self.safeCancelAndClose()
            } else {
                // 取消 / 失败：恢复截图会话
                self.isCapturing = false
                self.window?.alphaValue = 1.0
                self.window?.makeKey()
                self.window?.makeFirstResponder(self)
                if self.selectionRect != nil {
                    self.showToolbar(for: rect)
                }
            }
        }
        scrollSession = session
        needsDisplay = true
        session.start()
        print("🧵 进入滚动截图模式，选区 \(Int(rect.width))x\(Int(rect.height))pt")
    }

    // MARK: - 动作键与保存

    /// 快捷键：⌥⌘S 另存为、⌘S 保存、⌘C 复制、⌘A 全屏选区、回车执行默认动作
    private func handleActionKey(_ event: NSEvent) -> Bool {
        guard selectionRect != nil, state == .idle, !isCapturing, !isClosed else { return false }

        let flags = event.modifierFlags
        guard !flags.contains(.control) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()

        // ⌥⌘S：强制弹出保存对话框（忽略快速保存目录）
        if flags.contains(.command), flags.contains(.option), key == "s" {
            handleSaveAction(forcePanel: true)
            return true
        }
        guard !flags.contains(.option) else { return false }

        if flags.contains(.command), key == "s" {
            handleSaveAction()
            return true
        }
        if flags.contains(.command), key == "c" {
            handleCopyAction()
            return true
        }
        // ⌘A：选中整个屏幕
        if flags.contains(.command), key == "a" {
            confirmSelection(bounds)
            return true
        }
        // 回车 / 小键盘回车：执行设置里的默认动作
        if !flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            performDefaultAction()
            return true
        }
        return false
    }

    /// 执行"截图后默认动作"（回车 / 双击选区触发）
    private func performDefaultAction() {
        guard selectionRect != nil, state == .idle, !isCapturing, !isClosed else { return }
        switch settings.defaultAction {
        case .copy: handleCopyAction()
        case .save: handleSaveAction()
        case .pin: handlePinAction()
        }
    }

    private func handleSaveAction(forcePanel: Bool = false) {
        guard selectionRect != nil, state == .idle, !isCapturing else { return }
        print("💾 保存选区\(forcePanel ? "（另存为）" : ""): \(selectionRect.map { "\($0.origin), \($0.size)" } ?? "nil")")
        startSaveProcess(forcePanel: forcePanel)
    }

    /// 保存流程：合成图像 -> 快速保存或弹保存面板 -> 反馈并结束会话。
    /// 面板路径需要先把遮罩窗口让开（否则会被 .screenSaver 层级挡在后面）
    private func startSaveProcess(forcePanel: Bool = false) {
        guard !isCapturing, !isClosed, let rect = selectionRect else { return }
        isCapturing = true

        hideToolbar()
        window?.alphaValue = 0.3

        currentCaptureTask?.cancel()
        currentCaptureTask = Task { [weak self] in
            guard let self = self else { return }

            guard let image = await self.resolveOutputImage(for: rect) else {
                await MainActor.run { [weak self] in
                    guard let self = self, !self.isClosed else { return }
                    self.recoverAfterFailedAction(message: "保存失败：无法获取截图", rect: rect)
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self = self, !self.isClosed else { return }
                self.finishSave(image: image, rect: rect, forcePanel: forcePanel)
            }
        }
    }

    /// 主线程落盘：配置了快速保存目录就静默保存，否则弹面板
    private func finishSave(image: CGImage, rect: CGRect, forcePanel: Bool) {
        let format = settings.saveFormat
        guard let data = ImageSaver.data(from: image,
                                         pointSize: rect.size,
                                         format: format,
                                         quality: settings.jpegQuality) else {
            recoverAfterFailedAction(message: "保存失败：图片编码出错", rect: rect)
            return
        }

        let suggestedName = ImageSaver.fileName(prefix: settings.saveFileNamePrefix, format: format)

        // 1) 快速保存：直接写入配置目录（另存为时跳过）
        if !forcePanel, let directory = settings.beginAccessingSaveDirectory() {
            defer { directory.stopAccessingSecurityScopedResource() }
            let url = ImageSaver.uniqueURL(in: directory, fileName: suggestedName)
            do {
                try ImageSaver.write(data, to: url)
                print("💾 已保存: \(url.path)")
                isCapturing = false
                currentCaptureTask = nil
                settings.rememberSelection(rect)
                ScreenshotHistory.shared.record(image, pointSize: rect.size)
                Feedback.success("已保存到 \(url.lastPathComponent)", actionTitle: "在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                safeCancelAndClose()
            } catch {
                recoverAfterFailedAction(message: "保存失败：\(error.localizedDescription)", rect: rect)
            }
            return
        }

        // 2) 未配置目录：弹保存面板，先把遮罩窗口让开
        window?.orderOut(nil)
        guard let url = ImageSaver.presentSavePanel(suggestedName: suggestedName, format: format) else {
            // 用户取消：恢复截图会话继续操作
            restoreOverlay(for: rect)
            return
        }

        do {
            try ImageSaver.write(data, to: url)
            print("💾 已保存: \(url.path)")
            isCapturing = false
            currentCaptureTask = nil
            settings.rememberSelection(rect)
            ScreenshotHistory.shared.record(image, pointSize: rect.size)
            Feedback.success("已保存到 \(url.lastPathComponent)", actionTitle: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            safeCancelAndClose()
        } catch {
            restoreOverlay(for: rect)
            recoverAfterFailedAction(message: "保存失败：\(error.localizedDescription)", rect: rect)
        }
    }

    /// 保存面板取消后恢复截图会话
    private func restoreOverlay(for rect: CGRect) {
        isCapturing = false
        currentCaptureTask = nil
        window?.alphaValue = 1.0
        window?.orderFront(nil)
        window?.makeKey()
        window?.makeFirstResponder(self)
        showToolbar(for: rect)
        updateCursor(at: NSPoint(x: rect.midX, y: rect.midY))
    }

    /// 操作失败：恢复截图会话并给出失败提示
    private func recoverAfterFailedAction(message: String, rect: CGRect) {
        if !isClosed {
            restoreOverlay(for: rect)
        }
        Feedback.failure(message)
    }

    // MARK: - 工具栏管理

    /// 构造工具栏（闭包里打印触发日志，便于诊断点击链路）
    private func makeToolbar() -> SelectionToolbarView {
        SelectionToolbarView(
            onSelectTool: { [weak self] tool in
                print("🔘 工具栏：\(tool.label)工具被点击")
                self?.toggleTool(tool)
            },
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
            },
            onSave: { [weak self] in
                print("🔘 工具栏：保存按钮被点击")
                self?.handleSaveAction()
            },
            onScroll: { [weak self] in
                print("🔘 工具栏：滚动截图按钮被点击")
                self?.startScrollCapture()
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
        // 必须比截图遮罩高一层：同级时遮罩一旦被重新置前就会盖住工具栏，
        // 而遮罩现在会整屏绘制冻结底图，被盖住后工具栏会彻底看不见
        panel.level = .captureOverlay
        panel.hidesOnDeactivate = false   // 应用失去激活（例如切到别的应用）时不要自动隐藏
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = toolbarView
        panel.setFrameOrigin(ToolbarPositionCalculator.calculatePosition(
            selectionRect: rect, toolbarSize: size, screenBounds: bounds))
        panel.orderFront(nil)

        toolbarPanel = panel
        toolbarViewRef = toolbarView
        toolbarView.setActiveTool(activeTool)   // 重建后同步激活工具高亮
        showAnnotationOptions()
    }

    /// 与参考图一致，在选中绘图工具后显示第二条紧凑样式栏。
    private func showAnnotationOptions() {
        hideAnnotationOptions()
        guard let toolbarPanel, let tool = activeTool, !tool.isBrush, tool != .eraser else { return }
        let options = AnnotationOptionsView(tool: tool) { [weak self] in
            self?.updateTextEditorStyle()
        }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: options.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .captureOverlay
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = options
        annotationOptionsPanel = panel
        toolbarPanel.addChildWindow(panel, ordered: .above)
        refreshAnnotationOptionsPosition()
        panel.orderFront(nil)
    }

    /// 下方放不下时翻到工具栏上方，并将整个快捷栏限制在当前屏幕可见范围内。
    private func refreshAnnotationOptionsPosition() {
        guard let panel = annotationOptionsPanel, let toolbar = toolbarPanel else { return }
        let visible = (toolbar.screen ?? NSScreen.main)?.visibleFrame ?? bounds
        let x = min(max(toolbar.frame.minX, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        var y = toolbar.frame.minY - panel.frame.height - 6
        if y < visible.minY + 8 { y = toolbar.frame.maxY + 6 }
        y = min(max(y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hideAnnotationOptions() {
        guard let panel = annotationOptionsPanel else { return }
        annotationOptionsPanel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
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
            refreshAnnotationOptionsPosition()
        }
    }

    private func hideToolbar() {
        hideAnnotationOptions()
        guard let panel = toolbarPanel else { return }

        // 立即清空引用，防止重复调用
        toolbarPanel = nil
        toolbarViewRef = nil

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

        // 标注与冻结底图一并清空：回到实时取景，下次选区从头开始
        cancelTextEditing()
        annotations.removeAll()
        editStack.removeAll()
        redoEditStack.removeAll()
        inProgressAnnotation = nil
        deactivateTool()   // 内部会释放冻结底图（此时标注已清空）

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
        guard selectionRect != nil, state == .idle, !isCapturing else { return }
        print("📌 置顶选区: \(selectionRect.map { "\($0.origin), \($0.size)" } ?? "nil")")

        startPinProcess()
    }

    /// 置顶流程：捕获选区 -> 以悬浮窗口钉在桌面原位置 -> 结束截图会话
    private func startPinProcess() {
        guard !isCapturing, !isClosed else { return }
        guard let rect = selectionRect else { return }
        isCapturing = true

        // 先隐藏工具栏再捕获（本应用窗口本就被捕获过滤器排除，这里主要为了视觉干净）
        hideToolbar()
        window?.alphaValue = 0.3

        // 视图坐标 -> AppKit 全局坐标（贴图窗口按全局坐标摆放）
        let windowOrigin = window?.frame.origin ?? .zero
        let globalRect = rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)

        currentCaptureTask?.cancel()
        currentCaptureTask = Task { [weak self] in
            guard let self = self else { return }

            guard let image = await self.resolveOutputImage(for: rect) else {
                await MainActor.run { [weak self] in
                    guard let self = self, !self.isClosed else { return }
                    print("❌ 置顶失败，恢复工具栏")
                    self.isCapturing = false
                    self.currentCaptureTask = nil
                    self.window?.alphaValue = 1.0
                    if let rect = self.selectionRect {
                        self.showToolbar(for: rect)
                    }
                    Feedback.failure("置顶失败，请重试")
                }
                return
            }

            await MainActor.run { [weak self] in
                PinnedImageController.shared.pin(image: image, at: globalRect)

                guard let self = self, !self.isClosed else { return }
                self.isCapturing = false
                self.currentCaptureTask = nil
                self.settings.rememberSelection(rect)
                ScreenshotHistory.shared.record(image, pointSize: rect.size)
                Feedback.success("已置顶到屏幕")
                self.safeCancelAndClose()
                print("✅ 贴图完成，截图会话已结束")
            }
        }
    }

    private func handleCopyAction() {
        guard selectionRect != nil, state == .idle, !isCapturing else { return }
        print("📋 复制选区: \(selectionRect.map { "\($0.origin), \($0.size)" } ?? "nil")")

        startCaptureProcess()
    }

    private func handleDoubleClickSelection() {
        guard selectionRect != nil, state == .idle, !isCapturing else { return }
        print("🖱️ 双击选区，执行默认动作: \(settings.defaultAction.displayName)")

        performDefaultAction()
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
                    self.settings.rememberSelection(rect)
                    Feedback.success("已复制到剪贴板")
                    self.safeCancelAndClose()
                } else {
                    print("❌ 截图失败，恢复工具栏")
                    if let rect = self.selectionRect {
                        self.showToolbar(for: rect)
                    }
                    Feedback.failure("复制失败，请重试")
                }
            }
        }
    }

    /// 抓取所有显示器的画面并拼接成一张整图（排除本应用的遮罩 / 工具栏 / 提示条等窗口，
    /// 按设置保留贴图窗口）。
    /// 单屏走原生物理像素快路径，与旧行为完全一致；多屏按最大缩放因子拼到统一画布，
    /// 输出图像与视图 bounds（所有屏幕并集，pt）成固定比例
    func grabAllScreensExcludingSelf() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // 排除本应用的窗口，避免遮罩/选区边框/工具栏被截进图像；
        // 贴图窗口例外：它属于画面内容，用户希望"看得见就截得到"
        let bundleID = Bundle.main.bundleIdentifier
        let includePins = settings.includePinnedImages
        let selfWindows = content.windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == bundleID else { return false }
            if includePins, window.title == PinnedImageWindow.screenCaptureTitle { return false }
            return true
        }

        // NSScreen -> SCDisplay，并记录缩放因子
        var tiles: [(display: SCDisplay, tile: DisplayStitcher.Tile, scale: CGFloat)] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let tile = DisplayStitcher.Tile(
                frame: screen.frame,
                pixelSize: CGSize(width: CGFloat(display.width), height: CGFloat(display.height)))
            tiles.append((display, tile, screen.backingScaleFactor))
        }
        guard !tiles.isEmpty else {
            print("❌ 无法获取显示器")
            throw NSError(domain: "snipaste.capture", code: -2)
        }

        // 单屏：直接原样抓取，无拼接无重采样
        if tiles.count == 1, let only = tiles.first {
            return try await captureDisplay(only.display, excluding: selfWindows)
        }

        let union = DisplayStitcher.unionFrame(of: NSScreen.screens.map { $0.frame })
        let scale = DisplayStitcher.outputScale(scales: tiles.map { $0.scale })
        let outputSize = DisplayStitcher.outputPixelSize(union: union, scale: scale)

        // 逐屏抓取，按屏幕实际位置拼到统一画布
        var images: [(CGImage, CGRect)] = []
        for entry in tiles {
            guard let image = try? await captureDisplay(entry.display, excluding: selfWindows) else {
                print("⚠️ 跳过一块抓取失败的显示器: \(entry.tile.frame)")
                continue
            }
            images.append((image, DisplayStitcher.tileRect(union: union, tileFrame: entry.tile.frame, scale: scale)))
        }
        guard let first = images.first else {
            print("❌ 所有显示器抓取失败")
            throw NSError(domain: "snipaste.capture", code: -3)
        }

        let colorSpace = first.0.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(outputSize.width),
                                  height: Int(outputSize.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            print("❌ 无法创建拼接画布")
            throw NSError(domain: "snipaste.capture", code: -4)
        }
        ctx.interpolationQuality = .high
        for (image, rect) in images {
            // rect 是左上原点坐标，位图上下文原点在左下，需要翻转 y
            let flipped = CGRect(x: rect.minX,
                                 y: outputSize.height - rect.maxY,
                                 width: rect.width,
                                 height: rect.height)
            ctx.draw(image, in: flipped)
        }
        guard let stitched = ctx.makeImage() else {
            print("❌ 拼接失败")
            throw NSError(domain: "snipaste.capture", code: -5)
        }
        print("🖥️ 已拼接 \(images.count) 块屏幕: \(stitched.width)x\(stitched.height)px（缩放 \(scale)x）")
        return stitched
    }

    /// 抓取单个显示器（原生物理像素，保留原生色彩空间）
    private func captureDisplay(_ display: SCDisplay, excluding windows: [SCWindow]) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.scalesToFit = false
        configuration.showsCursor = settings.includeCursor      // 是否包含鼠标指针由设置决定
        configuration.backgroundColor = .clear
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // 注意：不设置 colorSpaceName，保留显示器原生色彩空间，
        // 避免 P3 -> sRGB 转换造成色偏，保证截到的是"原图"

        let filter = SCContentFilter(display: display, excludingWindows: windows)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// 抓取指定选区（视图坐标）的当前画面，供滚动截图逐帧取图
    func grabRegionForScrolling(_ rect: NSRect) async -> CGImage? {
        guard let full = try? await grabAllScreensExcludingSelf() else { return nil }
        return cropImage(full, to: rect)
    }

    /// 生成最终输出图像（复制与置顶共用）：
    /// - 用过标注工具（存在冻结底图）时：在冻结底图上按选区裁剪并合成标注，
    ///   与用户绘制时看到的画面严格一致（所见即所得）；
    /// - 否则实时抓取整屏后裁剪（保持原有行为，所见即当时屏幕）
    private func resolveOutputImage(for rect: CGRect) async -> CGImage? {
        var base = frozenImage
        var pixelated = pixelatedBackground

        if base == nil {
            // 检查任务是否已取消
            guard !Task.isCancelled else {
                print("⚠️ 任务已取消，停止截图")
                return nil
            }

            let stepStart = Date()
            guard let fullImage = try? await grabAllScreensExcludingSelf() else {
                print("❌ 实时抓屏失败")
                return nil
            }
            let stepDuration = Date().timeIntervalSince(stepStart) * 1000
            print("⏱️ 整屏捕获完成，耗时: \(Int(stepDuration))ms, 图像 \(fullImage.width)x\(fullImage.height)")

            base = fullImage
            pixelated = nil
        }

        guard let baseImage = base else { return nil }

        // 无标注：直接整数像素裁剪（原有复制/置顶路径）
        guard !annotations.isEmpty else {
            return cropImage(baseImage, to: rect)
        }

        // 遮蔽底图兜底：冻结时未生成（或走的是实时抓屏路径）时现场生成
        let scale = CGFloat(baseImage.width) / max(1, bounds.width)
        let hasMosaic = annotations.contains { if case .mosaic = $0 { return true }; return false }
        let hasBlur = annotations.contains { if case .blur = $0 { return true }; return false }
        if pixelated == nil, hasMosaic {
            let blockPixels = max(2, Int((AnnotationRenderer.mosaicBlockPointSize * scale).rounded()))
            pixelated = AnnotationRenderer.makePixelatedSmall(from: baseImage, blockPixels: blockPixels)
        }
        var blurred = blurredBackground
        if blurred == nil, hasBlur {
            blurred = AnnotationRenderer.makeBlurred(from: baseImage,
                                                     radiusPixels: AnnotationRenderer.blurRadiusPointSize * scale)
        }

        print("🖼️ 合成标注输出: \(annotations.count) 条")
        return AnnotationRenderer.composite(baseImage: baseImage,
                                            sources: ObscureSources(pixelated: pixelated, blurred: blurred),
                                            annotations: annotations,
                                            selectionRect: rect,
                                            screenSize: bounds.size)
    }

    /// 整屏图像按视图坐标选区做整数物理像素裁剪（纯像素提取，无重采样）。
    /// 缩放因子从实际位图反推，保证裁剪与真实位图严格对齐、输出为 1:1 原图
    func cropImage(_ fullImage: CGImage, to rect: CGRect) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0, fullImage.width > 0 else {
            print("❌ 屏幕或图像尺寸异常")
            return nil
        }
        // 裁剪换算统一走 AnnotationRenderer.pixelCropRect（与标注合成同一份逻辑）
        let cropRect = AnnotationRenderer.pixelCropRect(
            selection: rect,
            screenSize: bounds.size,
            imageSize: CGSize(width: fullImage.width, height: fullImage.height))
        guard !cropRect.isEmpty, !cropRect.isNull,
              let image = fullImage.cropping(to: cropRect) else {
            print("❌ 选区裁剪失败: crop=\(cropRect)")
            return nil
        }

        print("✂️ 裁剪选区: 逻辑 \(Int(rect.width))x\(Int(rect.height))pt -> 物理 \(Int(cropRect.width))x\(Int(cropRect.height))px")
        return image
    }

    private func captureAndCopyToClipboard(rect: CGRect) async -> Bool {
        guard let image = await resolveOutputImage(for: rect) else { return false }
        ScreenshotHistory.shared.record(image, pointSize: rect.size)

        // 最后检查取消
        guard !Task.isCancelled else {
            print("⚠️ 任务已取消，停止截图")
            return false
        }

        // 在主线程操作剪贴板（逻辑尺寸取选区尺寸，Retina 下携带正确的 DPI）
        let success = await MainActor.run { () -> Bool in
            ImageClipboard.copy(image, pointSize: rect.size)
        }

        if success {
            print("✅ 截图已复制到剪贴板")
        } else {
            print("❌ 剪贴板写入失败")
        }
        return success
    }

    // MARK: - 键盘事件

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func keyDown(with event: NSEvent) {
        // 滚动截图进行中：回车完成、空格暂停 / 继续、Esc 返回选区。
        if let scrollSession {
            _ = scrollSession.handleKeyDown(event)
            return
        }

        // Cmd+Z / Cmd+Shift+Z：撤销 / 重做标注
        if handleUndoRedo(event) { return }

        // Cmd+S 保存 / Cmd+C 复制 / 回车复制并结束
        if handleActionKey(event) { return }

        // 数字键切换标注工具（1–9、0 按工具栏顺序；带修饰键时不触发）
        let digitFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let tool = Self.tool(forDigitKeyCode: event.keyCode),
           digitFlags.subtracting(.capsLock).isEmpty {
            setTool(tool)
            return
        }

        // 方向键微调选区：1px，Shift + 方向键 10px（选区确认后生效）
        if let delta = Self.arrowKeyDeltas[event.keyCode],
           selectionRect != nil, state == .idle, !isCapturing, !isClosed {
            let scale: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            nudgeSelection(dx: delta.0 * scale, dy: delta.1 * scale)
            return
        }

        // ESC key (keyCode = 53)：逐级退出
        // 放弃正在绘制的标注 → 退出标注工具 → 清除选区 → 取消整个截图
        if event.keyCode == 53 {
            if state == .annotating {
                inProgressAnnotation = nil
                state = .idle
                needsDisplay = true
            } else if activeTool != nil {
                deactivateTool()
                needsDisplay = true
                print("🎨 ESC 退出标注工具")
            } else if selectionRect != nil {
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

    /// Cmd 组合键在视图层优先处理，避免被系统菜单里的同名项抢走
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleUndoRedo(event) { return true }
        if handleActionKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// 数字键 → 标注工具（1–9、0 对应工具栏顺序，超出范围返回 nil）
    private static func tool(forDigitKeyCode keyCode: UInt16) -> AnnotationTool? {
        let indexByKeyCode: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 0, UInt16(kVK_ANSI_2): 1, UInt16(kVK_ANSI_3): 2,
            UInt16(kVK_ANSI_4): 3, UInt16(kVK_ANSI_5): 4, UInt16(kVK_ANSI_6): 5,
            UInt16(kVK_ANSI_7): 6, UInt16(kVK_ANSI_8): 7, UInt16(kVK_ANSI_9): 8,
            UInt16(kVK_ANSI_0): 9,
        ]
        guard let index = indexByKeyCode[keyCode] else { return nil }
        let tools = AnnotationTool.allCases
        guard index < tools.count else { return nil }
        return tools[index]
    }

    /// 方向键 → 位移增量（AppKit Y 轴向上：↑ 为 +y）
    private static let arrowKeyDeltas: [UInt16: (CGFloat, CGFloat)] = [
        123: (-1, 0),  // ←
        124: (1, 0),   // →
        125: (0, -1),  // ↓
        126: (0, 1),   // ↑
    ]
}

// MARK: - 文字标注的内联编辑

extension CaptureView: NSTextFieldDelegate {

    /// 回车 / 失焦提交，Esc 取消
    func controlTextDidEndEditing(_ notification: Notification) {
        guard textEditor != nil else { return }
        let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSTextMovement.cancel.rawValue {
            cancelTextEditing()
        } else {
            commitTextEditing()
        }
    }

    /// 输入时按内容宽度调整输入框
    func controlTextDidChange(_ notification: Notification) {
        guard let field = textEditor, let font = field.font else { return }
        let size = (field.stringValue as NSString).size(withAttributes: [.font: font])
        field.frame.size.width = max(120, min(size.width + 28, 640))
    }
}
