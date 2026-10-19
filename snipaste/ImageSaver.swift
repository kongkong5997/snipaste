//
//  ImageSaver.swift
//  snipaste
//
//  图片输出：编码为文件数据、文件命名、保存面板，以及复制到剪贴板。
//  （截图保存、贴图另存为、复制图片三处共用）
//

import AppKit
import UniformTypeIdentifiers

// MARK: - 图片格式

enum ImageFileFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    /// 落盘扩展名（JPEG 用 jpg，兼容性最好）
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    /// 是否支持质量参数
    var supportsQuality: Bool { self == .jpeg }
}

// MARK: - 保存到文件

enum ImageSaver {

    /// 编码为文件数据。
    /// pointSize 写入分辨率元数据：Retina 截图带着正确的逻辑尺寸，
    /// 在其它应用里打开显示为实际大小，而不是放大一倍
    static func data(from image: CGImage,
                     pointSize: CGSize,
                     format: ImageFileFormat,
                     quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        if pointSize.width > 0, pointSize.height > 0 {
            rep.size = pointSize
        }
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            let clamped = min(max(quality, 0.1), 1.0)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: clamped])
        }
    }

    /// 默认文件名：前缀_2026-10-18_14-32-05.png
    static func fileName(prefix: String, format: ImageFileFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "截图" : trimmed
        return "\(base)_\(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// 同目录内避免重名：xxx.png -> xxx (2).png
    static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) (\(index)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// 弹出保存面板（沙箱下由用户授权目标位置）；返回选中位置，取消返回 nil
    static func presentSavePanel(suggestedName: String, format: ImageFileFormat) -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存图片"
        panel.message = "选择图片保存位置"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - 复制到剪贴板

enum ImageClipboard {

    /// 复制图片到剪贴板：TIFF 无损 + PNG 兼容，pointSize 决定粘贴后的逻辑尺寸
    @discardableResult
    static func copy(_ image: CGImage, pointSize: CGSize) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        if pointSize.width > 0, pointSize.height > 0 {
            rep.size = pointSize
        }

        // TIFF 默认无压缩，逐字节保留原始像素
        guard let tiffData = rep.tiffRepresentation else {
            print("❌ 无法生成 TIFF 数据")
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // 先写入的类型成为首选类型，粘贴方优先取用
        let tiffResult = pasteboard.setData(tiffData, forType: .tiff)
        print("   - TIFF 写入: \(tiffResult ? "✅" : "❌")")

        if let pngData = rep.representation(using: .png, properties: [:]) {
            let pngResult = pasteboard.setData(pngData, forType: .png)
            print("   - PNG 写入: \(pngResult ? "✅" : "❌")")
        }
        return tiffResult
    }
}
