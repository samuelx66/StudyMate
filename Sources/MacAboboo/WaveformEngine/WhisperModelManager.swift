import Foundation
import Combine

/// Whisper 离线模型级别
public enum WhisperModelLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case tiny
    case base
    case small
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .tiny: return "Tiny 极速版"
        case .base: return "Base 标准版 (推荐)"
        case .small: return "Small 高精版"
        }
    }
    
    public var description: String {
        switch self {
        case .tiny: return "约 75 MB，识别速度极快，适合日常发音清晰的材料"
        case .base: return "约 145 MB，速度与精度黄金平衡，适合绝大部分影视剧和播客"
        case .small: return "约 480 MB，最高识别精度，专克复杂口音、弱读连读与嘈杂背景音"
        }
    }
    
    public var approximateSize: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "145 MB"
        case .small: return "480 MB"
        }
    }
    
    public var filename: String {
        "ggml-\(rawValue).bin"
    }
    
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
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
public final class WhisperModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = WhisperModelManager()
    
    private let userDefaultsKey = "MacAboboo.SelectedWhisperModelLevel"
    
    @Published public var selectedModelLevel: WhisperModelLevel {
        didSet {
            UserDefaults.standard.set(selectedModelLevel.rawValue, forKey: userDefaultsKey)
        }
    }
    
    @Published public var modelStatuses: [WhisperModelLevel: WhisperModelStatus] = [:]
    @Published public var isDownloading: Bool = false
    
    private var downloadTasks: [WhisperModelLevel: URLSessionDownloadTask] = [:]
    private var activeDownloads: [Int: WhisperModelLevel] = [:]
    private var urlSession: URLSession!
    
    public let modelsDirectoryURL: URL
    
    override private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectoryURL = appSupport.appendingPathComponent("MacAboboo/Models", isDirectory: true)
        
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
        // 至少大于 1MB 避免不完整占位文件
        return size > 1_000_000
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
    
    /// 开始下载指定级别的 Whisper 离线模型
    public func startDownload(for level: WhisperModelLevel) {
        guard downloadTasks[level] == nil else { return }
        
        modelStatuses[level] = .downloading(progress: 0.0)
        isDownloading = true
        
        let task = urlSession.downloadTask(with: level.downloadURL)
        downloadTasks[level] = task
        activeDownloads[task.taskIdentifier] = level
        task.resume()
    }
    
    /// 取消下载
    public func cancelDownload(for level: WhisperModelLevel) {
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
        
        try? FileManager.default.removeItem(at: targetURL)
        do {
            try FileManager.default.moveItem(at: location, to: targetURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int64) ?? 0
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
            modelStatuses[level] = .error(message: "下载出错: \(error.localizedDescription)")
        } else if modelStatuses[level] == nil || !isModelDownloaded(level) {
            modelStatuses[level] = .notDownloaded
        }
    }
}
