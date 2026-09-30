import Foundation
import Combine

/// Whisper 离线模型级别
public enum WhisperModelLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case tiny
    case base
    case small
    case mediumQ8 = "medium-q8_0"
    case mediumEnQ8 = "medium.en-q8_0"
    case largeV3TurboQ8 = "large-v3-turbo-q8_0"

    public var id: String { rawValue }

    /// 是否为仅支持英语的专版模型
    public var isEnglishOnly: Bool {
        self == .mediumEnQ8
    }

    public var title: String {
        let isZh = LanguageManager.shared.currentLanguage == .zh
        switch self {
        case .tiny:
            return isZh ? "Tiny 极速版" : "Tiny (Fast)"
        case .base:
            return isZh ? "Base 标准版" : "Base (Standard)"
        case .small:
            return isZh ? "Small 高精版" : "Small (Enhanced)"
        case .mediumQ8:
            return isZh ? "Medium 超精版" : "Medium (Ultra)"
        case .mediumEnQ8:
            return isZh ? "Medium 纯英语" : "Medium (English)"
        case .largeV3TurboQ8:
            return isZh ? "Large 旗舰版" : "Large (Flagship)"
        }
    }

    public var description: String {
        let isZh = LanguageManager.shared.currentLanguage == .zh
        switch self {
        case .tiny:
            return isZh
                ? "约 75 MB，识别速度极快且极省资源，适合发音清晰标准的简短材料。"
                : "About 75 MB, extremely fast with minimal resource usage, best for clear and standard speech."
        case .base:
            return isZh
                ? "约 145 MB，速度与精度的黄金平衡，适合绝大部分日常影视剧与播客。"
                : "About 145 MB, golden balance of speed and accuracy, suitable for most movies and podcasts."
        case .small:
            return isZh
                ? "约 480 MB，精度优秀且资源占用适中，适合语速较快、带日常连读与轻微背景音的材料。"
                : "About 480 MB, excellent accuracy with moderate footprint, suitable for faster speech and light background noise."
        case .mediumQ8:
            return isZh
                ? "约 785 MB（8-bit 高保真量化），支持中英等多语种，复杂背景音与专业词汇识别精度极高。"
                : "About 785 MB (8-bit quantization), supports multilingual audio with very high accuracy on complex background audio and technical terms."
        case .mediumEnQ8:
            return isZh
                ? "约 785 MB（8-bit 高保真量化），专为纯英语深度优化，英语发音、断句与拼写精度显著优于通用模型（仅限英语）。"
                : "About 785 MB (8-bit quantization), dedicated to pure English with significantly superior accuracy, timing, and spelling (English only)."
        case .largeV3TurboQ8:
            return isZh
                ? "约 834 MB（8-bit 高保真量化），具备 Whisper 顶级的声学抗噪与复杂吞音还原能力，兼具极速推理表现。"
                : "About 834 MB (8-bit quantization), top-tier Whisper noise resistance and slurred speech decoding with rapid inference."
        }
    }

    public var approximateSize: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "145 MB"
        case .small: return "480 MB"
        case .mediumQ8: return "785 MB"
        case .mediumEnQ8: return "785 MB"
        case .largeV3TurboQ8: return "834 MB"
        }
    }

    public var filename: String {
        "ggml-\(rawValue).bin"
    }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    public var mirrorDownloadURL: URL {
        URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    /// 仅用于识别明显残缺的下载或代理返回的错误页面，不改变模型选择。
    public var minimumValidFileSize: Int64 {
        switch self {
        case .tiny: return 50_000_000
        case .base: return 100_000_000
        case .small: return 300_000_000
        case .mediumQ8, .mediumEnQ8: return 500_000_000
        case .largeV3TurboQ8: return 600_000_000
        }
    }
}

/// 模型就绪状态
public enum WhisperModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case ready(fileSize: String)
    case error(message: String)
}

/// Whisper 模型文件与下载生命周期管理器
@MainActor
public final class WhisperModelManager: NSObject, ObservableObject, @preconcurrency URLSessionDownloadDelegate {
    public static let shared = WhisperModelManager()
    
    private let userDefaultsKey = "StudyMate.SelectedWhisperModelLevel"
    
    @Published public var selectedModelLevel: WhisperModelLevel {
        didSet {
            UserDefaults.standard.set(selectedModelLevel.rawValue, forKey: userDefaultsKey)
            NotificationCenter.default.post(name: .whisperModelDidChange, object: selectedModelLevel)
            if selectedModelLevel.isEnglishOnly {
                NotificationCenter.default.post(name: .whisperModelDidSelectEnglishOnly, object: nil)
            }
        }
    }
    
    @Published public var modelStatuses: [WhisperModelLevel: WhisperModelStatus] = [:]
    @Published public var isDownloading: Bool = false
    
    private var downloadTasks: [WhisperModelLevel: URLSessionDownloadTask] = [:]
    private var activeDownloads: [Int: WhisperModelLevel] = [:]
    private var attemptedMirrors: Set<WhisperModelLevel> = []
    private var urlSession: URLSession!
    
    public let modelsDirectoryURL: URL
    
    override private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectoryURL = appSupport.appendingPathComponent("StudyMate/Models", isDirectory: true)
        
        let saved = UserDefaults.standard.string(forKey: userDefaultsKey) ?? WhisperModelLevel.base.rawValue
        self.selectedModelLevel = WhisperModelLevel(rawValue: saved) ?? .base
        
        super.init()
        
        try? FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
        
        let config = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
        refreshAllModelStatuses()
    }
    
    /// 获取模型文件本地路径
    public func modelFileURL(for level: WhisperModelLevel) -> URL {
        modelsDirectoryURL.appendingPathComponent(level.filename)
    }
    
    /// 检查指定模型是否已下载就绪
    public func isModelDownloaded(_ level: WhisperModelLevel) -> Bool {
        let fileURL = modelFileURL(for: level)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        return size >= level.minimumValidFileSize
    }
    
    /// 刷新所有模型的磁盘状态
    public func refreshAllModelStatuses() {
        for level in WhisperModelLevel.allCases {
            if let task = downloadTasks[level], task.state == .running {
                // 保持正在下载状态
                continue
            }
            if isModelDownloaded(level) {
                let fileURL = modelFileURL(for: level)
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                modelStatuses[level] = .ready(fileSize: formatted)
            } else {
                modelStatuses[level] = .notDownloaded
            }
        }
    }
    
    /// 开始下载指定级别的 Whisper 离线模型，支持国内镜像源自动回退
    public func startDownload(for level: WhisperModelLevel, useMirror: Bool = false) {
        guard downloadTasks[level] == nil else { return }
        
        modelStatuses[level] = .downloading(progress: 0.0)
        isDownloading = true
        
        let targetURL = useMirror ? level.mirrorDownloadURL : level.downloadURL
        let task = urlSession.downloadTask(with: targetURL)
        downloadTasks[level] = task
        activeDownloads[task.taskIdentifier] = level
        task.resume()
    }
    
    /// 取消下载
    public func cancelDownload(for level: WhisperModelLevel) {
        attemptedMirrors.remove(level)
        if let task = downloadTasks[level] {
            task.cancel()
            downloadTasks.removeValue(forKey: level)
            activeDownloads.removeValue(forKey: task.taskIdentifier)
        }
        modelStatuses[level] = .notDownloaded
        isDownloading = !downloadTasks.isEmpty
    }
    
    /// 删除已下载的本地模型文件
    public func deleteModel(for level: WhisperModelLevel) {
        cancelDownload(for: level)
        let fileURL = modelFileURL(for: level)
        try? FileManager.default.removeItem(at: fileURL)
        modelStatuses[level] = .notDownloaded
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let level = activeDownloads[downloadTask.taskIdentifier] else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        modelStatuses[level] = .downloading(progress: progress)
    }
    
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let level = activeDownloads[downloadTask.taskIdentifier] else { return }
        let targetURL = modelFileURL(for: level)

        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                throw ModelDownloadValidationError.invalidHTTPResponse
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size >= level.minimumValidFileSize else {
                throw ModelDownloadValidationError.incompleteFile(actualBytes: size)
            }
            // 先验证临时文件，再替换旧模型，失败时保留原有可用文件。
            if FileManager.default.fileExists(atPath: targetURL.path) {
                _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: location)
            } else {
                try FileManager.default.moveItem(at: location, to: targetURL)
            }
            attemptedMirrors.remove(level)
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            modelStatuses[level] = .ready(fileSize: formatted)
        } catch {
            modelStatuses[level] = .error(message: "保存失败: \(error.localizedDescription)")
        }
        
        downloadTasks.removeValue(forKey: level)
        activeDownloads.removeValue(forKey: downloadTask.taskIdentifier)
        isDownloading = !downloadTasks.isEmpty
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let level = activeDownloads[task.taskIdentifier] else { return }
        downloadTasks.removeValue(forKey: level)
        activeDownloads.removeValue(forKey: task.taskIdentifier)
        isDownloading = !downloadTasks.isEmpty
        
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            // 如果官方源下载受阻且尚未尝试镜像，自动使用国内高可用镜像源重试
            if !attemptedMirrors.contains(level) {
                attemptedMirrors.insert(level)
                startDownload(for: level, useMirror: true)
                return
            }
            modelStatuses[level] = .error(message: "下载出错: \(error.localizedDescription)")
        } else if modelStatuses[level] == nil || !isModelDownloaded(level) {
            modelStatuses[level] = .notDownloaded
        }
    }
}

private enum ModelDownloadValidationError: LocalizedError {
    case invalidHTTPResponse
    case incompleteFile(actualBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "服务器返回异常，请稍后重试"
        case let .incompleteFile(actualBytes):
            let size = ByteCountFormatter.string(fromByteCount: actualBytes, countStyle: .file)
            return "模型文件不完整（仅收到 \(size)），请重新下载"
        }
    }
}

extension Notification.Name {
    public static let whisperModelDidChange = Notification.Name("StudyMate.WhisperModelDidChange")
    public static let whisperModelDidSelectEnglishOnly = Notification.Name("StudyMate.WhisperModelDidSelectEnglishOnly")
}
