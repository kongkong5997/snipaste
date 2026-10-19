//
//  Annotation.swift
//  snipaste
//
//  标注工具（画笔 / 方框 / 箭头 / 马赛克）的数据模型与渲染器
//

import AppKit
import CoreImage

// MARK: - 标注工具类型

/// 标注工具。声明顺序同时决定工具栏顺序与数字键映射（1–9、0）
enum AnnotationTool: CaseIterable {
    case pencil      // 1 画笔：自由手绘线条
    case rectangle   // 2 方框：拖拽矩形描边
    case ellipse     // 3 椭圆：拖拽椭圆描边
    case line        // 4 直线：按住 Shift 可画 45° 倍数
    case arrow       // 5 箭头：拖拽直线 + 实心箭头
    case text        // 6 文字：点击后内联输入
    case numbering   // 7 序号：点击放置递增编号
    case mosaic      // 8 马赛克：笔刷涂抹打码
    case blur        // 9 模糊：笔刷涂抹高斯模糊
    case eraser      // 0 橡皮擦：点击删除整条标注

    /// 工具栏 SF Symbol 图标名
    var icon: String {
        switch self {
        case .pencil: return "pencil"
        case .rectangle: return "square"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .numbering: return "1.circle"
        case .mosaic: return "checkerboard.rectangle"
        case .blur: return "camera.filters"
        case .eraser: return "eraser"
        }
    }

    var label: String {
        switch self {
        case .pencil: return "画笔"
        case .rectangle: return "方框"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .text: return "文字"
        case .numbering: return "序号"
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        case .eraser: return "橡皮擦"
        }
    }

    /// 是否用笔刷涂抹（马赛克 / 模糊），决定拖拽采样方式
    var isBrush: Bool { self == .mosaic || self == .blur }
}

// MARK: - 标注模型

/// 一条标注。坐标一律使用视图坐标（pt，原点左下角），
/// 预览与导出共用同一份数据，导出时统一换算到物理像素
enum Annotation {
    case pencil(points: [NSPoint], color: NSColor, width: CGFloat)
    case rectangle(rect: NSRect, color: NSColor, width: CGFloat)
    case ellipse(rect: NSRect, color: NSColor, width: CGFloat)
    case line(from: NSPoint, to: NSPoint, color: NSColor, width: CGFloat)
    case arrow(from: NSPoint, to: NSPoint, color: NSColor, width: CGFloat)
    /// origin 为文字包围盒左下角（视图坐标）
    case text(origin: NSPoint, string: String, color: NSColor, fontSize: CGFloat)
    /// center 为序号圆心
    case numbering(center: NSPoint, number: Int, color: NSColor)
    case mosaic(points: [NSPoint], radius: CGFloat)
    case blur(points: [NSPoint], radius: CGFloat)
}

/// 马赛克 / 模糊取样用的整屏底图
struct ObscureSources {
    /// 马赛克小图（整屏降采样，绘制时最近邻放大）
    let pixelated: CGImage?
    /// 高斯模糊图（与冻结底图同尺寸）
    let blurred: CGImage?

    static let none = ObscureSources(pixelated: nil, blurred: nil)
}

// MARK: - 标注渲染器

/// 预览（overlay 窗口，视图坐标）与导出（物理像素位图）共用同一套绘制逻辑，
/// 保证所见即所得：预览里看到的标注与复制/置顶的输出逐像素一致
enum AnnotationRenderer {

    // MARK: 视觉参数

    /// 画笔 / 方框 / 箭头的默认描边颜色与线宽（pt）。
    /// 实际取值由设置页决定（AppSettings.annotationColor / annotationLineWidth），
    /// 这里只是初始默认值
    static let defaultStrokeColor = NSColor.systemRed
    static let defaultStrokeWidth: CGFloat = 3

    /// 马赛克笔刷半径（pt）
    static let mosaicRadius: CGFloat = 12

    /// 马赛克块大小（pt）：导出的物理块大小 = 该值 × 屏幕缩放因子
    static let mosaicBlockPointSize: CGFloat = 10

    /// 序号标注的圆半径（pt）与数字字号
    static let numberingRadius: CGFloat = 12
    static let numberingFontSize: CGFloat = 14

    /// 模糊半径（pt）：导出的物理半径 = 该值 × 屏幕缩放因子
    static let blurRadiusPointSize: CGFloat = 12

    // MARK: 预览渲染（视图坐标）

    /// 在给定上下文中按顺序绘制所有标注（调用方负责裁剪到选区）
    /// - Parameters:
    ///   - pixelatedImage: 整屏马赛克小图；nil（冻结未就绪）时马赛克暂不显示
    ///   - screenRect: 整屏区域（视图坐标），马赛克小图铺满该区域
    static func render(_ annotations: [Annotation],
                       sources: ObscureSources,
                       screenRect: NSRect,
                       into ctx: CGContext) {
        for annotation in annotations {
            draw(annotation, sources: sources, screenRect: screenRect, into: ctx)
        }
    }

    // MARK: 导出合成（物理像素）

    /// 从整屏原图裁出选区并叠加所有标注，输出物理像素图像
    /// - Parameters:
    ///   - baseImage: 整屏原图（物理像素）
    ///   - pixelatedImage: 整屏马赛克小图（与 baseImage 同一坐标系）
    ///   - selectionRect: 选区（视图坐标 / pt）
    ///   - screenSize: 视图尺寸（pt），用于反推缩放因子与裁剪换算
    static func composite(baseImage: CGImage,
                          sources: ObscureSources,
                          annotations: [Annotation],
                          selectionRect: NSRect,
                          screenSize: CGSize) -> CGImage? {
        guard screenSize.width > 0, screenSize.height > 0, baseImage.width > 0 else {
            print("❌ 合成失败：尺寸异常")
            return nil
        }
        let scale = CGFloat(baseImage.width) / screenSize.width

        let cropRect = pixelCropRect(selection: selectionRect,
                                     screenSize: screenSize,
                                     imageSize: CGSize(width: baseImage.width, height: baseImage.height))
        guard !cropRect.isEmpty, !cropRect.isNull,
              let baseCrop = baseImage.cropping(to: cropRect) else {
            print("❌ 合成失败：裁剪范围无效 \(cropRect)")
            return nil
        }

        let colorSpace = baseImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: baseCrop.width,
                                  height: baseCrop.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            print("❌ 合成失败：无法创建位图上下文")
            return nil
        }

        // 统一变换到"视图坐标"绘制：device = (view - selectionOrigin) × scale。
        // CG 位图上下文原点在左下，与视图一致，无需 Y 翻转
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -selectionRect.minX, y: -selectionRect.minY)

        // 1) 底图按 1:1 像素铺回选区位置（无重采样）
        // cropRect 是物理像素、screenSize 是 pt：先除回 pt 再换算视图坐标
        let baseRect = NSRect(x: cropRect.minX / scale,
                              y: screenSize.height - cropRect.maxY / scale,
                              width: CGFloat(baseCrop.width) / scale,
                              height: CGFloat(baseCrop.height) / scale)
        ctx.draw(baseCrop, in: baseRect)

        // 2) 按添加顺序叠加标注
        render(annotations,
               sources: sources,
               screenRect: CGRect(origin: .zero, size: screenSize),
               into: ctx)

        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// 选区（视图坐标 pt）-> 物理像素裁剪矩形（左上原点），并夹在图像范围内。
    /// 裁剪换算的唯一出处：CaptureView.cropImage 与 composite 共用，避免两处各改各的
    static func pixelCropRect(selection: NSRect, screenSize: CGSize, imageSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0, imageSize.width > 0 else { return .null }
        let scale = imageSize.width / screenSize.width
        let rect = CGRect(x: (selection.minX * scale).rounded(),
                          y: ((screenSize.height - selection.maxY) * scale).rounded(),
                          width: max(1, (selection.width * scale).rounded()),
                          height: max(1, (selection.height * scale).rounded()))
        return rect.intersection(CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
    }

    /// 生成整屏马赛克小图：降采样为"每块 1 像素"，绘制时再用最近邻放大回去。
    /// 数据量极小（整屏 / 块大小），放大后方块的尺寸与相位和预览完全一致
    static func makePixelatedSmall(from image: CGImage, blockPixels: Int) -> CGImage? {
        let block = max(2, blockPixels)
        let smallWidth = max(1, image.width / block)
        let smallHeight = max(1, image.height / block)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: smallWidth,
                                  height: smallHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        // 高质量降采样 ≈ 每个块取平均色
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        return ctx.makeImage()
    }

    /// 生成整屏高斯模糊图（模糊工具用，Core Image 走 GPU，一次会话只算一次）
    static func makeBlurred(from image: CGImage, radiusPixels: CGFloat) -> CGImage? {
        guard radiusPixels > 0 else { return image }
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radiusPixels, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    // MARK: 日志

    static func describe(_ annotation: Annotation) -> String {
        switch annotation {
        case let .pencil(points, _, width): return "画笔 \(points.count) 点 宽\(Int(width))"
        case let .rectangle(rect, _, _): return "方框 \(Int(rect.width))x\(Int(rect.height))"
        case let .ellipse(rect, _, _): return "椭圆 \(Int(rect.width))x\(Int(rect.height))"
        case let .line(from, to, _, _): return "直线 (\(Int(from.x)),\(Int(from.y))) → (\(Int(to.x)),\(Int(to.y)))"
        case let .arrow(from, to, _, _): return "箭头 (\(Int(from.x)),\(Int(from.y))) → (\(Int(to.x)),\(Int(to.y)))"
        case let .text(_, string, _, _): return "文字「\(string)」"
        case let .numbering(_, number, _): return "序号 \(number)"
        case let .mosaic(points, _): return "马赛克 \(points.count) 点"
        case let .blur(points, _): return "模糊 \(points.count) 点"
        }
    }

    // MARK: - 单条标注绘制（视图坐标）

    private static func draw(_ annotation: Annotation,
                             sources: ObscureSources,
                             screenRect: NSRect,
                             into ctx: CGContext) {
        switch annotation {
        case let .pencil(points, color, width):
            drawPencil(points: points, color: color, width: width, into: ctx)

        case let .rectangle(rect, color, width):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.stroke(rect)

        case let .ellipse(rect, color, width):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.strokeEllipse(in: rect)

        case let .line(from, to, color, width):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case let .arrow(from, to, color, width):
            drawArrow(from: from, to: to, color: color, width: width, into: ctx)

        case let .text(origin, string, color, fontSize):
            drawText(string, at: origin, color: color, fontSize: fontSize, into: ctx)

        case let .numbering(center, number, color):
            drawNumbering(number, at: center, color: color, into: ctx)

        case let .mosaic(points, radius):
            drawObscured(points: points, radius: radius, image: sources.pixelated,
                         screenRect: screenRect, into: ctx)

        case let .blur(points, radius):
            drawObscured(points: points, radius: radius, image: sources.blurred,
                         screenRect: screenRect, into: ctx)
        }
    }

    /// 手绘线条：中点二次曲线做轻量平滑；单点渲染成圆点
    private static func drawPencil(points: [NSPoint], color: NSColor, width: CGFloat, into ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if points.count == 1 {
            ctx.setFillColor(color.cgColor)
            let r = width / 2
            ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
            return
        }

        ctx.addPath(pencilPath(points))
        ctx.strokePath()
    }

    /// 手绘路径：move 到首点，逐段用"控制点取原采样点、终点取相邻中点"的二次曲线连接
    static func pencilPath(_ points: [NSPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = NSPoint(x: (points[i].x + points[i + 1].x) / 2,
                              y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// 箭头：线宽自适应的实心三角头部 + 箭杆（杆尾伸入头部，消除接缝）
    private static func drawArrow(from: NSPoint, to: NSPoint, color: NSColor, width: CGFloat, into ctx: CGContext) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return }
        let ux = dx / length
        let uy = dy / length

        // 头部长度随线宽缩放；短箭头时不超过总长的一半
        let headLength = min(max(width * 4.5, 12), length * 0.5)
        let headHalfWidth = headLength * 0.42
        let baseX = to.x - ux * headLength
        let baseY = to.y - uy * headLength

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)

        // 箭杆：画到头部底边再顺势伸入 width 距离
        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: NSPoint(x: baseX + ux * width, y: baseY + uy * width))
        ctx.strokePath()

        // 头部三角
        let nx = -uy
        let ny = ux
        ctx.beginPath()
        ctx.move(to: to)
        ctx.addLine(to: NSPoint(x: baseX + nx * headHalfWidth, y: baseY + ny * headHalfWidth))
        ctx.addLine(to: NSPoint(x: baseX - nx * headHalfWidth, y: baseY - ny * headHalfWidth))
        ctx.closePath()
        ctx.fillPath()
    }

    /// 遮蔽绘制（马赛克 / 模糊共用）：把笔刷经过的区域裁剪出来，
    /// 在其中绘制整屏的处理后底图
    private static func drawObscured(points: [NSPoint], radius: CGFloat,
                                     image: CGImage?, screenRect: NSRect, into ctx: CGContext) {
        guard !points.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(mosaicClipPath(points, radius: radius))
        ctx.clip()
        if let image {
            ctx.interpolationQuality = .none   // 马赛克走最近邻；模糊图本身已是平滑的
            ctx.draw(image, in: screenRect)
        }
        ctx.restoreGState()
    }

    /// 文字：CoreText 绘制（预览与导出同一套代码，基线取包围盒底部上方 0.2 字号）
    private static func drawText(_ string: String, at origin: NSPoint,
                                 color: NSColor, fontSize: CGFloat, into ctx: CGContext) {
        guard !string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + fontSize * 0.2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 序号：实心圆 + 白色编号 + 细白描边保证在深色背景上也清晰
    private static func drawNumbering(_ number: Int, at center: NSPoint,
                                      color: NSColor, into ctx: CGContext) {
        let rect = CGRect(x: center.x - numberingRadius, y: center.y - numberingRadius,
                          width: numberingRadius * 2, height: numberingRadius * 2)

        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect)

        let text = "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: numberingFontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX,
                                   y: center.y - numberingFontSize * 0.36)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 文字包围盒（预估排版尺寸，命中检测用）
    static func textBounds(_ string: String, at origin: NSPoint, fontSize: CGFloat) -> NSRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]
        let size = (string as NSString).size(withAttributes: attributes)
        return NSRect(x: origin.x, y: origin.y, width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: 命中检测（橡皮擦用）

    /// 点是否落在标注的可点击区域内
    static func hitTest(_ annotation: Annotation, at point: NSPoint, tolerance: CGFloat = 6) -> Bool {
        switch annotation {
        case let .pencil(points, _, width):
            return distanceToPolyline(point, points) <= width / 2 + tolerance

        case let .line(from, to, _, width):
            return distanceToSegment(point, from, to) <= width / 2 + tolerance

        case let .arrow(from, to, _, width):
            // 箭头头部比线宽宽得多，放宽一点
            return distanceToSegment(point, from, to) <= width / 2 + tolerance + 6

        case let .rectangle(rect, _, width):
            return rect.insetBy(dx: -(width + tolerance), dy: -(width + tolerance)).contains(point)

        case let .ellipse(rect, _, width):
            return rect.insetBy(dx: -(width + tolerance), dy: -(width + tolerance)).contains(point)

        case let .text(origin, string, _, fontSize):
            return textBounds(string, at: origin, fontSize: fontSize)
                .insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case let .numbering(center, _, _):
            return hypot(point.x - center.x, point.y - center.y) <= numberingRadius + tolerance

        case let .mosaic(points, radius), let .blur(points, radius):
            return distanceToPolyline(point, points) <= radius + tolerance
        }
    }

    private static func distanceToSegment(_ point: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    private static func distanceToPolyline(_ point: NSPoint, _ points: [NSPoint]) -> CGFloat {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<(points.count - 1) {
            best = min(best, distanceToSegment(point, points[index], points[index + 1]))
        }
        return best
    }

    /// 笔刷涂抹区域：沿路径每个采样点画圆，非零环绕规则下自动求并集
    static func mosaicClipPath(_ points: [NSPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let size = radius * 2
        for p in points {
            path.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: size, height: size))
        }
        return path
    }
}
