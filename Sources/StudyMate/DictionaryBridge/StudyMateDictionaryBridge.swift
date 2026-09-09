import Foundation
import AppKit

/// 外部词典应用程序 (StudyMateDictionary) 调度桥接器。
///
/// 负责将查词请求通过 `studymatedict://lookup?word=...` URL Scheme 派发给独立的词典应用；
/// 当系统尚未注册 URL Scheme 时，自动定位嵌入的 `Contents/Applications/StudyMateDictionary.app`、
/// `/Applications/StudyMateDictionary.app` 或开发构建目录并拉起运行。
@MainActor
public enum StudyMateDictionaryBridge {
    public static let urlScheme = "studymatedict"
    public static let bundleIdentifier = "com.samuel.StudyMateDictionary"

    /// 构建查词 URL
    public static func makeLookupURL(query: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.host = "lookup"
            components.queryItems = [
                URLQueryItem(name: "word", value: query.trimmingCharacters(in: .whitespacesAndNewlines))
            ]
        } else {
            components.host = "open"
        }
        return components.url
    }

    /// 打开独立词典程序，可附带查询词
    @discardableResult
    public static func openDictionary(query: String? = nil) -> Bool {
        let cleanQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetURL = makeLookupURL(query: cleanQuery) {
            // 首先尝试使用系统注册的 URL Scheme 唤起
            if NSWorkspace.shared.open(targetURL) {
                return true
            }
        }

        // URL 唤起失败时，定位 App Bundle 实体并启动
        guard let appURL = locateDictionaryApp() else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let cleanQuery, !cleanQuery.isEmpty, let targetURL = makeLookupURL(query: cleanQuery) {
            NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: configuration) { _, error in
                if error != nil {
                    // 若带 URL 启动受限，以纯应用形式拉起
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
                }
            }
            return true
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
            return true
        }
    }

    /// 定位应被建立快捷方式的内置/工程词典应用本体
    public static func locateEmbeddedDictionaryApp() -> URL? {
        let fileManager = FileManager.default

        // 1. App Bundle 内部嵌入的应用：Contents/Applications/StudyMateDictionary.app
        let embeddedInContents = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Applications/StudyMateDictionary.app", isDirectory: true)
        if fileManager.fileExists(atPath: embeddedInContents.path) {
            return embeddedInContents
        }

        // 2. Resources 目录下的辅助应用回退
        if let resourceURL = Bundle.main.url(forResource: "StudyMateDictionary", withExtension: "app") {
            return resourceURL
        }

        // 3. 本地开发调试工程中的构建产物与 Embedded 缓存
        let devCandidates = [
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent() // DictionaryBridge
                .deletingLastPathComponent() // StudyMate
                .deletingLastPathComponent() // Sources
                .deletingLastPathComponent() // StudyMate project root
                .appendingPathComponent("Embedded/StudyMateDictionary.app", isDirectory: true),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent() // XcodeProject
                .appendingPathComponent("StudyMateDictionary/dist/StudyMateDictionary.app", isDirectory: true)
        ]

        for candidate in devCandidates {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    /// 多层级定位词典应用位置
    public static func locateDictionaryApp() -> URL? {
        let fileManager = FileManager.default

        if let embedded = locateEmbeddedDictionaryApp() {
            return embedded
        }

        // 系统 /Applications 目录
        let systemApp = URL(fileURLWithPath: "/Applications/StudyMateDictionary.app")
        if fileManager.fileExists(atPath: systemApp.path) {
            return systemApp
        }

        // 用户 ~/Applications 目录
        if let userApps = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            let userApp = userApps.appendingPathComponent("StudyMateDictionary.app", isDirectory: true)
            if fileManager.fileExists(atPath: userApp.path) {
                return userApp
            }
        }

        return nil
    }

    public static let shortcutFileName = "StudyMateDictionary.app"
    public static let shortcutPreferenceDomainKey = "StudyMate.CreateDictionaryShortcutInApplications"

    /// 判断指定路径是否为符号链接（即便为断链也能正确识别）
    public static func isSymbolicLink(at url: URL) -> Bool {
        var statBuf = stat()
        guard lstat(url.path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFLNK
    }

    /// 获取快捷方式目标所在的主要应用程序目录（优先系统 /Applications，无写入权限时回退至用户 ~/Applications）
    public static func targetApplicationsDirectory() -> URL {
        let fileManager = FileManager.default
        let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fileManager.isWritableFile(atPath: systemApps.path) {
            return systemApps
        }
        if let userApps = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            return userApps
        }
        return systemApps
    }

    /// 部署在应用程序目录中的词典完整目标 URL
    public static func dictionaryShortcutURL() -> URL {
        targetApplicationsDirectory().appendingPathComponent(shortcutFileName, isDirectory: true)
    }

    /// 检查应用程序目录中是否已安装了词典应用程序
    public static func isDictionaryShortcutInstalled() -> Bool {
        let fileManager = FileManager.default
        let primaryURL = dictionaryShortcutURL()
        if fileManager.fileExists(atPath: primaryURL.path) {
            return true
        }
        if let userApps = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            let userURL = userApps.appendingPathComponent(shortcutFileName, isDirectory: true)
            if fileManager.fileExists(atPath: userURL.path) {
                return true
            }
        }
        return false
    }

    /// 以 APFS 写时复制（Copy-on-Write）秒级克隆方式将词典应用部署到“应用程序”目录
    ///
    /// 克隆出的为 100% 正规的原生 Application Bundle，可被用户自由拖拽固定至程序坞（Dock），
    /// 并在启动台与聚焦搜索中原生呈现，且几乎不额外消耗物理磁盘空间。
    @discardableResult
    public static func installDictionaryShortcut() throws -> URL {
        guard let sourceURL = locateEmbeddedDictionaryApp() else {
            throw NSError(
                domain: "StudyMateDictionaryBridge",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到可供克隆部署的词典应用，请确认应用包完整。"]
            )
        }

        let targetURL = dictionaryShortcutURL()
        let fileManager = FileManager.default

        // 如果存在目标（不论是旧目录、普通文件还是旧符号链接），先安全清理
        if fileManager.fileExists(atPath: targetURL.path) || isSymbolicLink(at: targetURL) {
            try fileManager.removeItem(at: targetURL)
        }

        // 使用 APFS 写时复制机制克隆整个应用包（耗时通常 <10ms，不占用额外物理磁盘块）
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        NSWorkspace.shared.noteFileSystemChanged(targetURL.path)
        return targetURL
    }

    /// 从应用程序目录中彻底移除词典应用
    public static func removeDictionaryShortcut() throws {
        let fileManager = FileManager.default
        let primaryURL = dictionaryShortcutURL()
        if fileManager.fileExists(atPath: primaryURL.path) || isSymbolicLink(at: primaryURL) {
            try fileManager.removeItem(at: primaryURL)
            NSWorkspace.shared.noteFileSystemChanged(primaryURL.path)
        }

        if let userApps = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            let userURL = userApps.appendingPathComponent(shortcutFileName, isDirectory: true)
            if fileManager.fileExists(atPath: userURL.path) || isSymbolicLink(at: userURL) {
                try fileManager.removeItem(at: userURL)
                NSWorkspace.shared.noteFileSystemChanged(userURL.path)
            }
        }
    }

    /// 在应用启动时同步词典部署状态：若在访达中被手动删除，则自动将设置同步为“未勾选”，尊重用户删除意图
    public static func synchronizeShortcutIfNeeded() {
        guard UserDefaults.standard.bool(forKey: shortcutPreferenceDomainKey) else { return }

        // 若偏好记录为已部署，但磁盘实体已被用户在访达中手动删除，自动同步偏好为 false
        if !isDictionaryShortcutInstalled() {
            UserDefaults.standard.set(false, forKey: shortcutPreferenceDomainKey)
            return
        }

        // 若依然存在，检查源应用是否有新版本更新，按需更新克隆
        guard let sourceURL = locateEmbeddedDictionaryApp() else { return }
        let targetURL = dictionaryShortcutURL()
        let fileManager = FileManager.default

        if let sourceMod = (try? fileManager.attributesOfItem(atPath: sourceURL.path))?[.modificationDate] as? Date,
           let targetMod = (try? fileManager.attributesOfItem(atPath: targetURL.path))?[.modificationDate] as? Date,
           sourceMod > targetMod {
            _ = try? installDictionaryShortcut()
        }
    }
}
