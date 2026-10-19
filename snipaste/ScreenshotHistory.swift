//
//  ScreenshotHistory.swift
//  snipaste
//
//  最近截图历史：内存中保留最近若干张合成后的图像，供菜单栏"最近截图"快速取回。
//  不落盘，退出应用即清空
//

import AppKit
import Combine

final class ScreenshotHistory: ObservableObject {

    static let shared = ScreenshotHistory()

    struct Item: Identifiable {
        let id = UUID()
        let image: CGImage
        let pointSize: NSSize
        let date: Date

        /// 菜单里显示的一行摘要
        var summary: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "\(formatter.string(from: date))  ·  \(Int(pointSize.width))×\(Int(pointSize.height))"
        }
    }

    /// 最多保留张数
    static let capacity = 9

    @Published private(set) var items: [Item] = []

    private init() {}

    /// 记录一张新截图（最新的排最前）
    func record(_ image: CGImage, pointSize: NSSize, date: Date = Date()) {
        items.insert(Item(image: image, pointSize: pointSize, date: date), at: 0)
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
        }
    }

    func clear() {
        items.removeAll()
    }
}
