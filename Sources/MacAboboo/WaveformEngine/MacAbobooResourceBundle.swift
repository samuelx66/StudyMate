import Foundation

/// 显式解析 SwiftPM 资源包，避免在发布版 App 中触发 Bundle.module 的 fatalError。
///
/// SwiftPM 为可执行目标生成的资源访问器只尝试 `Bundle.main.bundleURL` 和构建目录。
/// 嵌入标准 macOS App 后，资源实际位于 `Contents/Resources`，因此这里同时覆盖
/// 发布包、SwiftPM 测试包和直接运行可执行文件三种布局。
enum MacAbobooResourceBundle {
    static let name = "MacAboboo_MacAbobooKit.bundle"

    static var bundle: Bundle? {
        var candidates: [URL] = []
        let mainBundle = Bundle.main

        if let resourceURL = mainBundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(name, isDirectory: true))
        }
        candidates.append(mainBundle.bundleURL.appendingPathComponent(name, isDirectory: true))
        if let executableURL = mainBundle.executableURL {
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true))
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }
}
