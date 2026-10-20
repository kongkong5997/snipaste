//
//  ScrollStitcher.swift
//  snipaste
//
//  滚动截图的帧间匹配与增量计算（纯逻辑，便于单独验证）：
//  把整帧横向压成灰度签名，在新帧里定位上一帧底部的模板，
//  得出"新增了多少行内容"
//

import AppKit

// MARK: - 拼接算法（纯逻辑，便于单独验证）

enum ScrollStitcher {

    /// 灰度签名：把整帧横向压成 columns 列，纵向保持原分辨率，
    /// 便于逐行比较（比较成本与帧高线性相关）
    struct Signature {
        let width: Int
        let height: Int
        let pixels: [UInt8]   // width * height，行优先
    }

    /// 生成灰度签名（横向降采样做列平均）
    static func signature(of image: CGImage, columns: Int = 64) -> Signature? {
        guard image.width > 0, image.height > 0, columns > 0 else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: columns,
                                  height: image.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: image.height))
        guard let data = ctx.data else { return nil }

        let bytesPerRow = ctx.bytesPerRow
        let pointer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * image.height)
        var pixels = [UInt8](repeating: 0, count: columns * image.height)
        for row in 0..<image.height {
            for column in 0..<columns {
                pixels[row * columns + column] = pointer[row * bytesPerRow + column]
            }
        }
        return Signature(width: columns, height: image.height, pixels: pixels)
    }

    /// 在 next 中寻找 previous 底部模板的最佳匹配行号，返回 (offset, 平均误差)
    static func matchOffset(previous: Signature, next: Signature,
                            templateHeight: Int) -> (offset: Int, score: Double) {
        let template = min(templateHeight, previous.height, next.height)
        guard template > 0, previous.width == next.width else { return (0, .greatestFiniteMagnitude) }

        let startRow = previous.height - template
        let lastCandidate = next.height - template
        guard lastCandidate >= 0 else { return (0, .greatestFiniteMagnitude) }

        var bestOffset = 0
        var bestScore = Double.greatestFiniteMagnitude
        // 相同得分时优先选择较小位移，避免重复背景被误当成大段新增内容。
        for offset in stride(from: lastCandidate, through: 0, by: -1) {
            var difference = 0
            let width = previous.width
            for row in 0..<template {
                let lhsBase = (startRow + row) * width
                let rhsBase = (offset + row) * width
                for column in 0..<width {
                    // 直接按下标访问：ArraySlice 会保留父数组索引，切片下标不能从 0 开始
                    difference += abs(Int(previous.pixels[lhsBase + column]) - Int(next.pixels[rhsBase + column]))
                }
            }
            let score = Double(difference) / Double(template * previous.width)
            if score < bestScore {
                bestScore = score
                bestOffset = offset
            }
        }
        return (bestOffset, bestScore)
    }

    /// 新帧相对上一帧新增的行数：
    /// 0 = 没有新内容（已到底或没滚动）；nil = 匹配不可信（滚动过快或画面变动太大）
    static func appendedRows(previous: Signature, next: Signature,
                            templateHeight: Int, scoreThreshold: Double = 6) -> Int? {
        // 完全静止的画面不需要搜索模板，空白区域也不能被重复追加。
        if previous.width == next.width, previous.height == next.height,
           previous.pixels == next.pixels { return 0 }
        let (offset, score) = matchOffset(previous: previous, next: next, templateHeight: templateHeight)
        guard score <= scoreThreshold else { return nil }

        // 模板在新帧里上移后，底部超出模板的部分就是新增内容。
        let consumed = offset + min(templateHeight, previous.height, next.height)
        return max(0, next.height - consumed)
    }
}
