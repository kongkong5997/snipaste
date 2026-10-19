//
//  UpdateChecker.swift
//  snipaste
//
//  轻量更新检查：从设置里的更新地址拉一个 JSON（{"version": "1.1", "url": "下载页"}），
//  与当前版本比较后提示。地址留空时提示未配置
//

import AppKit

enum UpdateChecker {

    struct Feed: Decodable {
        let version: String
        let url: String?
    }

    enum CheckError: LocalizedError {
        case notConfigured
        case invalidResponse
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未配置更新地址，可在设置里填写"
            case .invalidResponse: return "更新信息格式不正确"
            case .network(let message): return "检查更新失败：\(message)"
            }
        }
    }

    /// 当前应用版本
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// 展示用版本号（含构建号）
    static var displayVersion: String {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        return "\(currentVersion) (\(build))"
    }

    /// 检查更新，回调在主线程
    static func check(completion: @escaping (Result<Feed, CheckError>) -> Void) {
        let address = AppSettings.shared.updateFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let url = URL(string: address) else {
            completion(.failure(.notConfigured))
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            let result: Result<Feed, CheckError>
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if let data, let feed = try? JSONDecoder().decode(Feed.self, from: data) {
                result = .success(feed)
            } else {
                result = .failure(.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// 版本号比较：1.10 比 1.9 新
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// 菜单入口：检查并提示结果
    static func checkAndReport() {
        check { result in
            switch result {
            case .failure(let error):
                Feedback.failure(error.errorDescription ?? "检查更新失败")
            case .success(let feed):
                guard isNewer(feed.version, than: currentVersion) else {
                    Feedback.success("当前已是最新版本 \(currentVersion)")
                    return
                }
                let downloadURL = feed.url.flatMap { URL(string: $0) }
                ToastPresenter.shared.show("发现新版本 \(feed.version)",
                                           actionTitle: downloadURL == nil ? nil : "前往下载") {
                    if let downloadURL { NSWorkspace.shared.open(downloadURL) }
                }
            }
        }
    }
}
