import Foundation
import CryptoKit

/// 单个媒体的当前工程元数据。
///
/// 当前写入格式固定为 schema 4。读取旧工程时由 `ProjectFileManager`
/// 使用迁移解码器转换为这个结构，避免升级软件后丢失用户编辑过的字幕。
public struct MediaProjectFile: Codable, Sendable {
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let mediaPath: String
    public let mediaTitle: String
    public let duration: Double
    public let lastPosition: Double
    public let segments: [SentenceSegment]
    public let waveformData: WaveformData?
    public let waveformCacheFile: String?
    public let mediaFileSize: Int64?
    public let mediaModificationDate: Date?
    public let hasCompletedSegmentation: Bool
    public let acousticBoundaryTimes: [Double]
    public let updatedAt: Date

    public init(
        mediaPath: String,
        mediaTitle: String,
        duration: Double,
        lastPosition: Double,
        segments: [SentenceSegment],
        waveformData: WaveformData? = nil,
        waveformCacheFile: String? = nil,
        mediaFileSize: Int64? = nil,
        mediaModificationDate: Date? = nil,
        hasCompletedSegmentation: Bool? = nil,
        acousticBoundaryTimes: [Double] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.mediaPath = mediaPath
        self.mediaTitle = mediaTitle
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.lastPosition = lastPosition.isFinite ? max(0, lastPosition) : 0
        self.segments = segments
        self.waveformData = waveformData
        self.waveformCacheFile = waveformCacheFile
        self.mediaFileSize = mediaFileSize
        self.mediaModificationDate = mediaModificationDate
        self.hasCompletedSegmentation = hasCompletedSegmentation ?? !segments.isEmpty
        self.acousticBoundaryTimes = Self.normalizedAcousticBoundaryTimes(acousticBoundaryTimes)
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mediaPath
        case mediaTitle
        case duration
        case lastPosition
        case segments
        case waveformData
        case waveformCacheFile
        case mediaFileSize
        case mediaModificationDate
        case hasCompletedSegmentation
        case acousticBoundaryTimes
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "旧版本工程需走 LegacyMediaProjectFile 迁移：\(decodedSchemaVersion)"
            )
        }
        schemaVersion = decodedSchemaVersion
        mediaPath = (try? container.decode(String.self, forKey: .mediaPath)) ?? ""
        mediaTitle = (try? container.decode(String.self, forKey: .mediaTitle))
            ?? URL(fileURLWithPath: mediaPath).deletingPathExtension().lastPathComponent
        let decodedDuration = (try? container.decode(Double.self, forKey: .duration)) ?? 0
        duration = decodedDuration.isFinite ? max(0, decodedDuration) : 0
        let decodedPosition = (try? container.decode(Double.self, forKey: .lastPosition)) ?? 0
        lastPosition = decodedPosition.isFinite ? max(0, decodedPosition) : 0
        segments = (try? container.decode([SentenceSegment].self, forKey: .segments)) ?? []
        waveformData = try? container.decodeIfPresent(WaveformData.self, forKey: .waveformData)
        waveformCacheFile = try? container.decodeIfPresent(String.self, forKey: .waveformCacheFile)
        mediaFileSize = try? container.decodeIfPresent(Int64.self, forKey: .mediaFileSize)
        mediaModificationDate = try? container.decodeIfPresent(Date.self, forKey: .mediaModificationDate)
        hasCompletedSegmentation = (try? container.decodeIfPresent(Bool.self, forKey: .hasCompletedSegmentation)) ?? !segments.isEmpty
        acousticBoundaryTimes = Self.normalizedAcousticBoundaryTimes(
            (try? container.decodeIfPresent([Double].self, forKey: .acousticBoundaryTimes)) ?? []
        )
        updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mediaPath, forKey: .mediaPath)
        try container.encode(mediaTitle, forKey: .mediaTitle)
        try container.encode(duration, forKey: .duration)
        try container.encode(lastPosition, forKey: .lastPosition)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(waveformData, forKey: .waveformData)
        try container.encodeIfPresent(waveformCacheFile, forKey: .waveformCacheFile)
        try container.encodeIfPresent(mediaFileSize, forKey: .mediaFileSize)
        try container.encodeIfPresent(mediaModificationDate, forKey: .mediaModificationDate)
        try container.encode(hasCompletedSegmentation, forKey: .hasCompletedSegmentation)
        try container.encode(acousticBoundaryTimes, forKey: .acousticBoundaryTimes)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func normalizedAcousticBoundaryTimes(_ values: [Double]) -> [Double] {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        var result: [Double] = []
        result.reserveCapacity(sorted.count)
        for value in sorted where result.last.map({ abs($0 - value) <= 0.000001 }) != true {
            result.append(value)
        }
        return result
    }

    /// 防止同一路径上的媒体被替换后仍套用旧波形和断句。
    public func isCompatible(with mediaURL: URL) -> Bool {
        let targetPath = mediaURL.standardizedFileURL.path
        let targetResolved = mediaURL.standardizedFileURL.resolvingSymlinksInPath().path
        let savedResolved = URL(fileURLWithPath: mediaPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard mediaPath == targetPath || savedResolved == targetResolved || mediaPath.isEmpty else {
            return false
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: mediaURL.path) else {
            return true
        }
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value
        if let expectedSize = mediaFileSize, let actualSize, actualSize != expectedSize {
            return false
        }
        if let expectedDate = mediaModificationDate,
           let actualDate = attributes[.modificationDate] as? Date {
            let delta = abs(actualDate.timeIntervalSince(expectedDate))
            if mediaFileSize != nil && actualSize == mediaFileSize {
                // 文件大小吻合，确属同一文件；忽略文件系统微小时间戳漂移
            } else if delta > 60.0 {
                return false
            }
        }
        return true
    }
}

/// 工程读取的结果必须区分“从未保存过”和“已有工程但需要人工处理”。
/// 只有 `.missing` 才允许上层自动生成新的断句。
public enum ProjectLoadResult: Sendable {
    case missing
    case loaded(MediaProjectFile, needsMigration: Bool)
    case unavailable(String)
}

/// 用户明确选择继续使用媒体信息已变化的旧工程时的结果。
/// 这个操作不会重新生成断句，只会在备份旧工程后更新媒体绑定信息。
public enum ProjectAdoptionResult: Sendable {
    case adopted(MediaProjectFile, backupPath: String)
    case failed(String)
}

/// 旧版本工程的宽松读取模型。所有新增字段都提供安全默认值，
/// 读取后立即由 `MediaProjectFile` 重新编码为当前 schema。
private struct LegacyMediaProjectFile: Decodable {
    let schemaVersion: Int?
    let mediaPath: String?
    let mediaTitle: String?
    let duration: Double?
    let lastPosition: Double?
    let segments: [SentenceSegment]?
    let waveformData: WaveformData?
    let waveformCacheFile: String?
    let mediaFileSize: Int64?
    let mediaModificationDate: Date?
    let hasCompletedSegmentation: Bool?
    let acousticBoundaryTimes: [Double]?
    let updatedAt: Date?
}

/// 工程元数据与波形缓存采用独立文件存储，避免每次改一行字幕都重写整份波形。
public final class ProjectFileManager: @unchecked Sendable {
    public static let shared = ProjectFileManager()

    /// 每个媒体保留少量最近快照，避免一次异常保存覆盖全部字幕编辑。
    private static let backupRetentionCount = 5

    private let projectsDirectory: URL
    private let fileQueue = DispatchQueue(label: "com.macaboboo.project.filemanager", qos: .utility)
    private let pendingLock = NSLock()
    private let errorHandlerLock = NSLock()
    private var pendingSaves: [String: SaveRequest] = [:]
    private var isDrainScheduled = false
    private var errorHandler: (@Sendable (String) -> Void)?
    /// 由串行文件队列访问。避免每次字幕失焦保存都重新读取、解码同一份 JSON；
    /// 应用自身是工程文件的唯一写入者，首次读取仍以磁盘为准。
    private var persistedMetadataCache: [String: MediaProjectFile] = [:]

    private struct DecodedProject {
        let project: MediaProjectFile
        let needsMigration: Bool
    }

    private struct SaveRequest: Sendable {
        let mediaURL: URL
        let title: String
        let duration: Double
        let lastPosition: Double
        let segments: [SentenceSegment]
        let waveformData: WaveformData?
        let persistWaveform: Bool
        let fileSize: Int64?
        let modificationDate: Date?
        let hasCompletedSegmentation: Bool
        let acousticBoundaryTimes: [Double]
    }

    /// Saves are frequently requested by more than one UI event (for example,
    /// a text-field blur followed by a focus change).  Comparing this small
    /// metadata snapshot lets the pending queue drop an identical request
    /// without comparing or copying waveform samples.
    private func hasSameMetadata(_ lhs: SaveRequest, _ rhs: SaveRequest) -> Bool {
        lhs.mediaURL == rhs.mediaURL
            && lhs.title == rhs.title
            && lhs.duration == rhs.duration
            && lhs.lastPosition == rhs.lastPosition
            && lhs.segments == rhs.segments
            && lhs.fileSize == rhs.fileSize
            && datesMatch(lhs.modificationDate, rhs.modificationDate)
            && lhs.hasCompletedSegmentation == rhs.hasCompletedSegmentation
            && lhs.acousticBoundaryTimes == rhs.acousticBoundaryTimes
    }

    private func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return abs(left.timeIntervalSince(right)) <= 1.0
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    /// 注入目录主要用于测试隔离；默认仍保存到 Application Support。
    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            projectsDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            projectsDirectory = appSupport
                .appendingPathComponent("MacAboboo", isDirectory: true)
                .appendingPathComponent("Projects", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    public func projectFileURL(for mediaURL: URL) -> URL {
        projectsDirectory.appendingPathComponent(projectBaseName(for: mediaURL) + ".json")
    }

    public func waveformFileURL(for mediaURL: URL) -> URL {
        projectsDirectory.appendingPathComponent(projectBaseName(for: mediaURL) + ".waveform")
    }

    /// 工程读写失败仍在后台队列发生；通过此回调让上层显示状态栏错误，
    /// 不再把可能丢失的工程状态静默留在控制台。
    public func setErrorHandler(_ handler: (@Sendable (String) -> Void)?) {
        errorHandlerLock.lock()
        errorHandler = handler
        errorHandlerLock.unlock()
    }

    private func reportError(_ message: String) {
        errorHandlerLock.lock()
        let handler = errorHandler
        errorHandlerLock.unlock()
        handler?(message)
    }

    private func projectBaseName(for mediaURL: URL) -> String {
        let pathString = mediaURL.standardizedFileURL.path
        let digest = Insecure.MD5.hash(data: Data(pathString.utf8))
        let hashString = digest.map { String(format: "%02hhx", $0) }.joined()
        let safeName = mediaURL.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
            .prefix(32)
        return "\(safeName)_\(hashString)"
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                let isoFractional = ISO8601DateFormatter()
                isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = isoFractional.date(from: string) {
                    return date
                }
                let isoStandard = ISO8601DateFormatter()
                isoStandard.formatOptions = [.withInternetDateTime]
                if let date = isoStandard.date(from: string) {
                    return date
                }
                let standardFormatter = DateFormatter()
                standardFormatter.locale = Locale(identifier: "en_US_POSIX")
                standardFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
                if let date = standardFormatter.date(from: string) {
                    return date
                }
                standardFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                if let date = standardFormatter.date(from: string) {
                    return date
                }
            } else if let doubleValue = try? container.decode(Double.self) {
                if doubleValue > 100_000_000 {
                    return Date(timeIntervalSince1970: doubleValue)
                } else {
                    return Date(timeIntervalSinceReferenceDate: doubleValue)
                }
            }
            return Date.distantPast
        }
        return decoder
    }

    /// 先尝试当前格式；只有当前格式无法读取时才走旧格式迁移。
    /// 这样未来新增 schema 时不会被错误地当成旧格式而静默丢字段。
    private func decodeStoredProject(_ data: Data) throws -> DecodedProject {
        if let current = try? makeDecoder().decode(MediaProjectFile.self, from: data) {
            return DecodedProject(project: current, needsMigration: false)
        }

        let legacy = try makeDecoder().decode(LegacyMediaProjectFile.self, from: data)
        let version = legacy.schemaVersion ?? 1
        guard (1...MediaProjectFile.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "不支持的工程文件版本：\(version)")
            )
        }

        let segments = legacy.segments ?? []
        let mediaPath = legacy.mediaPath ?? ""
        let project = MediaProjectFile(
            mediaPath: mediaPath,
            mediaTitle: legacy.mediaTitle
                ?? URL(fileURLWithPath: mediaPath).deletingPathExtension().lastPathComponent,
            duration: legacy.duration ?? 0,
            lastPosition: legacy.lastPosition ?? 0,
            segments: segments,
            waveformData: legacy.waveformData,
            waveformCacheFile: legacy.waveformCacheFile,
            mediaFileSize: legacy.mediaFileSize,
            mediaModificationDate: legacy.mediaModificationDate,
            hasCompletedSegmentation: legacy.hasCompletedSegmentation ?? !segments.isEmpty,
            acousticBoundaryTimes: legacy.acousticBoundaryTimes ?? [],
            updatedAt: legacy.updatedAt ?? .distantPast
        )
        return DecodedProject(project: project, needsMigration: true)
    }

    /// `persistWaveform` 仅应在波形首次生成或改变时使用；常规字幕编辑只写轻量 JSON。
    public func saveProject(
        for mediaURL: URL,
        title: String,
        duration: Double,
        lastPosition: Double,
        segments: [SentenceSegment],
        waveformData: WaveformData? = nil,
        persistWaveform: Bool = false,
        hasCompletedSegmentation: Bool? = nil,
        acousticBoundaryTimes: [Double] = []
    ) {
        let standardizedURL = mediaURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: standardizedURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
        let modificationDate = attributes?[.modificationDate] as? Date

        let request = SaveRequest(
            mediaURL: standardizedURL,
            title: title,
            duration: duration,
            lastPosition: lastPosition,
            segments: segments,
            waveformData: waveformData,
            persistWaveform: persistWaveform,
            fileSize: fileSize,
            modificationDate: modificationDate,
            hasCompletedSegmentation: hasCompletedSegmentation ?? !segments.isEmpty,
            acousticBoundaryTimes: acousticBoundaryTimes
        )
        pendingLock.lock()
        if let existing = pendingSaves[standardizedURL.path],
           !request.persistWaveform,
           hasSameMetadata(existing, request) {
            // The pending request already contains the exact metadata that
            // this call would write.  Keep any pending waveform persistence
            // and avoid scheduling another utility-queue write.
            pendingLock.unlock()
            return
        }
        if let existing = pendingSaves[standardizedURL.path],
           existing.persistWaveform,
           !request.persistWaveform {
            // Keep the newest lightweight metadata snapshot without dropping
            // an earlier waveform write that has not reached disk yet.
            pendingSaves[standardizedURL.path] = SaveRequest(
                mediaURL: request.mediaURL,
                title: request.title,
                duration: request.duration,
                lastPosition: request.lastPosition,
                segments: request.segments,
                waveformData: existing.waveformData,
                persistWaveform: true,
                fileSize: request.fileSize,
                modificationDate: request.modificationDate,
                hasCompletedSegmentation: request.hasCompletedSegmentation,
                acousticBoundaryTimes: request.acousticBoundaryTimes
            )
        } else {
            pendingSaves[standardizedURL.path] = request
        }
        let shouldSchedule = !isDrainScheduled
        if shouldSchedule { isDrainScheduled = true }
        pendingLock.unlock()

        if shouldSchedule {
            fileQueue.async { [weak self] in
                self?.drainPendingSaves()
            }
        }
    }

    private func drainPendingSaves() {
        while true {
            pendingLock.lock()
            guard !pendingSaves.isEmpty else {
                isDrainScheduled = false
                pendingLock.unlock()
                return
            }
            let requests = Array(pendingSaves.values)
            pendingSaves.removeAll(keepingCapacity: true)
            pendingLock.unlock()

            for request in requests {
                writeProject(request)
            }
        }
    }

    /// 在覆盖工程或波形之前保留一个可恢复快照。备份目录名称以当前工程
    /// 前缀开头，因此删除播放列表条目时会和工程、波形一起被清理。
    private func createBackupIfNeeded(
        metadataURL: URL,
        waveformURL: URL,
        existingProject: MediaProjectFile?
    ) throws -> URL? {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }

        let baseName = metadataURL.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let backupName = "\(baseName).backup-\(stamp)-\(UUID().uuidString.prefix(8))"
        let backupDirectory = projectsDirectory.appendingPathComponent(backupName, isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let backupMetadataURL = backupDirectory.appendingPathComponent("project.json")
        let hasWaveformCache = FileManager.default.fileExists(atPath: waveformURL.path)
        if let existingProject {
            // 让备份在脱离当前工程文件后仍然可以独立恢复。
            let backupProject = MediaProjectFile(
                mediaPath: existingProject.mediaPath,
                mediaTitle: existingProject.mediaTitle,
                duration: existingProject.duration,
                lastPosition: existingProject.lastPosition,
                segments: existingProject.segments,
                waveformData: hasWaveformCache ? nil : existingProject.waveformData,
                waveformCacheFile: hasWaveformCache ? "waveform" : nil,
                mediaFileSize: existingProject.mediaFileSize,
                mediaModificationDate: existingProject.mediaModificationDate,
                hasCompletedSegmentation: existingProject.hasCompletedSegmentation,
                acousticBoundaryTimes: existingProject.acousticBoundaryTimes,
                updatedAt: existingProject.updatedAt
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(backupProject).write(to: backupMetadataURL, options: .atomic)
        } else {
            // 即使旧文件已经损坏，也先保留原始字节，避免后续人工恢复无据可查。
            try FileManager.default.copyItem(at: metadataURL, to: backupMetadataURL)
        }

        if hasWaveformCache {
            try FileManager.default.copyItem(
                at: waveformURL,
                to: backupDirectory.appendingPathComponent("waveform")
            )
        }

        let backups = try FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.lastPathComponent.hasPrefix(baseName + ".backup-") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }

        if backups.count > Self.backupRetentionCount {
            for staleBackup in backups.dropFirst(Self.backupRetentionCount) {
                // Retention is housekeeping.  A single locked or temporarily
                // unavailable snapshot must not make the new project save fail.
                // It will be considered again on the next save.
                try? FileManager.default.removeItem(at: staleBackup)
            }
        }
        return backupDirectory
    }

    private func projectByHydratingWaveform(
        _ project: MediaProjectFile,
        cacheDirectory: URL
    ) -> MediaProjectFile {
        var waveform = project.waveformData
        if waveform == nil, let cacheName = project.waveformCacheFile {
            let safeName = URL(fileURLWithPath: cacheName).lastPathComponent
            if safeName == cacheName {
                let cacheURL = cacheDirectory.appendingPathComponent(safeName)
                if let cacheData = try? Data(contentsOf: cacheURL) {
                    waveform = decodeWaveformCache(cacheData)
                        ?? (try? PropertyListDecoder().decode(WaveformData.self, from: cacheData))
                }
            }
        }
        guard waveform != project.waveformData else { return project }
        return MediaProjectFile(
            mediaPath: project.mediaPath,
            mediaTitle: project.mediaTitle,
            duration: project.duration,
            lastPosition: project.lastPosition,
            segments: project.segments,
            waveformData: waveform,
            waveformCacheFile: project.waveformCacheFile,
            mediaFileSize: project.mediaFileSize,
            mediaModificationDate: project.mediaModificationDate,
            hasCompletedSegmentation: project.hasCompletedSegmentation,
            acousticBoundaryTimes: project.acousticBoundaryTimes,
            updatedAt: project.updatedAt
        )
    }

    /// 当前工程文件损坏或被意外删除时，按时间倒序尝试最近的快照。
    /// 只有能完整解码的快照才会被返回，损坏的快照会继续向更早版本回退。
    private func loadLatestBackupProject(for mediaURL: URL) -> MediaProjectFile? {
        let baseName = projectBaseName(for: mediaURL)
        guard let backupDirectories = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = backupDirectories
            .filter { url in
                guard url.lastPathComponent.hasPrefix(baseName + ".backup-") else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for directory in candidates {
            let metadataURL = directory.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let decoded = try? decodeStoredProject(data) else { continue }
            let project = projectByHydratingWaveform(decoded.project, cacheDirectory: directory)
            guard project.isCompatible(with: mediaURL) else { continue }
            return project
        }
        return nil
    }

    private func writeProject(_ request: SaveRequest) {
        let metadataURL = projectFileURL(for: request.mediaURL)
        let waveformURL = waveformFileURL(for: request.mediaURL)
        do {
            var existingMetadata = persistedMetadataCache[request.mediaURL.standardizedFileURL.path]
                ?? persistedMetadataCache[request.mediaURL.path]
            if existingMetadata == nil, let existingData = try? Data(contentsOf: metadataURL) {
                existingMetadata = try? decodeStoredProject(existingData).project
                if let existingMetadata {
                    persistedMetadataCache[request.mediaURL.standardizedFileURL.path] = existingMetadata
                }
            }
            let existingMetadataIsCompatible = existingMetadata?.isCompatible(with: request.mediaURL) == true
            var hasWaveformCache = existingMetadataIsCompatible
                && FileManager.default.fileExists(atPath: waveformURL.path)
            var waveformCacheChanged = false
            var pendingWaveformData: Data?
            if request.persistWaveform,
               let waveformData = request.waveformData,
               !waveformData.isEmpty {
                let cacheData = encodeWaveformCache(waveformData)
                let existingCacheData = try? Data(contentsOf: waveformURL)
                if existingCacheData != cacheData {
                    pendingWaveformData = cacheData
                    waveformCacheChanged = true
                }
                hasWaveformCache = true
            }

            let project = MediaProjectFile(
                mediaPath: request.mediaURL.path,
                mediaTitle: request.title,
                duration: request.duration,
                lastPosition: request.lastPosition,
                segments: request.segments,
                waveformData: nil,
                waveformCacheFile: hasWaveformCache ? waveformURL.lastPathComponent : nil,
                mediaFileSize: request.fileSize,
                mediaModificationDate: request.modificationDate,
                hasCompletedSegmentation: request.hasCompletedSegmentation,
                acousticBoundaryTimes: request.acousticBoundaryTimes,
                updatedAt: Date()
            )

            let contentChanged = existingMetadata == nil
                || existingMetadata?.segments != project.segments
                || existingMetadata?.acousticBoundaryTimes != project.acousticBoundaryTimes
                || waveformCacheChanged
                || existingMetadata?.hasCompletedSegmentation != project.hasCompletedSegmentation
                || existingMetadata?.mediaTitle != project.mediaTitle
                || existingMetadata?.schemaVersion != project.schemaVersion

            // `updatedAt` is deliberately excluded from this comparison.  It
            // is an audit timestamp, not project content; rewriting the JSON
            // solely to advance it defeats save coalescing.  A changed
            // waveform cache still forces a metadata write so its presence is
            // recorded atomically with the latest project snapshot.
            if !waveformCacheChanged,
               let existingMetadata,
               existingMetadataIsCompatible,
               metadataMatches(existingMetadata, project, datesMatch: datesMatch) {
                return
            }

            // 只有在断句内容、波形结构或版本迁移等实质性内容发生改变时，
            // 才创建备份快照；纯播放进度更新（lastPosition）只写轻量 JSON，绝不生成备份目录。
            if contentChanged {
                _ = try createBackupIfNeeded(
                    metadataURL: metadataURL,
                    waveformURL: waveformURL,
                    existingProject: existingMetadata
                )
            }
            if let pendingWaveformData {
                try pendingWaveformData.write(to: waveformURL, options: .atomic)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
            try data.write(to: metadataURL, options: .atomic)
            persistedMetadataCache[request.mediaURL.standardizedFileURL.path] = project
        } catch {
            reportError("保存工程文件失败：\(error.localizedDescription)")
        }
    }

    private func metadataMatches(
        _ existing: MediaProjectFile,
        _ desired: MediaProjectFile,
        datesMatch: (Date?, Date?) -> Bool
    ) -> Bool {
        let waveformMatches: Bool
        if let existingPeaks = existing.waveformData?.peaks, let desiredPeaks = desired.waveformData?.peaks {
            waveformMatches = existingPeaks == desiredPeaks
        } else if existing.waveformData == nil && desired.waveformData == nil {
            waveformMatches = existing.waveformCacheFile == desired.waveformCacheFile
        } else {
            // One is hydrated in memory, but both refer to the same waveform cache file on disk
            waveformMatches = existing.waveformCacheFile == desired.waveformCacheFile
        }

        return existing.schemaVersion == desired.schemaVersion
            && (existing.mediaPath == desired.mediaPath
                || URL(fileURLWithPath: existing.mediaPath).standardizedFileURL.path == URL(fileURLWithPath: desired.mediaPath).standardizedFileURL.path)
            && existing.mediaTitle == desired.mediaTitle
            && abs(existing.duration - desired.duration) <= 0.000001
            && abs(existing.lastPosition - desired.lastPosition) <= 0.000001
            && existing.segments == desired.segments
            && waveformMatches
            && existing.mediaFileSize == desired.mediaFileSize
            && datesMatch(existing.mediaModificationDate, desired.mediaModificationDate)
            && existing.hasCompletedSegmentation == desired.hasCompletedSegmentation
            && existing.acousticBoundaryTimes == desired.acousticBoundaryTimes
    }

    public func loadProjectResultAsync(for mediaURL: URL) async -> ProjectLoadResult {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                continuation.resume(returning: self.loadProjectResultDirect(for: mediaURL))
            }
        }
    }

    public func loadProjectResult(for mediaURL: URL) -> ProjectLoadResult {
        fileQueue.sync {
            loadProjectResultDirect(for: mediaURL)
        }
    }

    /// 保留旧的可选返回接口，供不需要区分恢复状态的调用方使用。
    public func loadProjectAsync(for mediaURL: URL) async -> MediaProjectFile? {
        switch await loadProjectResultAsync(for: mediaURL) {
        case .loaded(let project, _): return project
        case .missing, .unavailable: return nil
        }
    }

    public func loadProject(for mediaURL: URL) -> MediaProjectFile? {
        switch loadProjectResult(for: mediaURL) {
        case .loaded(let project, _): return project
        case .missing, .unavailable: return nil
        }
    }

    /// 在用户明确确认后，采用当前媒体文件继续使用原工程。
    ///
    /// 该操作与普通保存不同：它始终先生成一份独立备份，然后只更新
    /// 工程中的媒体大小/修改时间绑定，不重新运行任何断句模型。
    public func adoptProjectIgnoringMediaMetadataAsync(
        for mediaURL: URL
    ) async -> ProjectAdoptionResult {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                continuation.resume(
                    returning: self.adoptProjectIgnoringMediaMetadataDirect(for: mediaURL)
                )
            }
        }
    }

    private func adoptProjectIgnoringMediaMetadataDirect(for mediaURL: URL) -> ProjectAdoptionResult {
        let standardizedURL = mediaURL.standardizedFileURL
        let metadataURL = projectFileURL(for: standardizedURL)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return .failed("工程文件不存在，无法继续使用原工程。")
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoded = try decodeStoredProject(data)
            guard decoded.project.mediaPath == standardizedURL.path else {
                return .failed("工程与当前媒体文件路径不一致。")
            }

            let existingProject = projectByHydratingWaveform(
                decoded.project,
                cacheDirectory: projectsDirectory
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: standardizedURL.path)
            let currentSize = (attributes[.size] as? NSNumber)?.int64Value
            let currentDate = attributes[.modificationDate] as? Date
            let reboundProject = MediaProjectFile(
                mediaPath: existingProject.mediaPath,
                mediaTitle: existingProject.mediaTitle,
                duration: existingProject.duration,
                lastPosition: existingProject.lastPosition,
                segments: existingProject.segments,
                waveformData: existingProject.waveformData,
                waveformCacheFile: existingProject.waveformCacheFile,
                mediaFileSize: currentSize,
                mediaModificationDate: currentDate,
                hasCompletedSegmentation: existingProject.hasCompletedSegmentation,
                acousticBoundaryTimes: existingProject.acousticBoundaryTimes,
                updatedAt: Date()
            )

            let backupURL = try createBackupIfNeeded(
                metadataURL: metadataURL,
                waveformURL: waveformFileURL(for: standardizedURL),
                existingProject: existingProject
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let reboundData = try encoder.encode(reboundProject)
            try reboundData.write(to: metadataURL, options: .atomic)
            persistedMetadataCache[standardizedURL.path] = reboundProject

            return .adopted(
                reboundProject,
                backupPath: backupURL?.path ?? ""
            )
        } catch {
            reportError("继续使用原工程失败：\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// 删除指定媒体在 Projects 目录中的全部工程记录，不触碰原始媒体文件。
    /// 同时移除尚未落盘的保存请求，避免删除后被后台写入重新创建。
    public func deleteProject(for mediaURL: URL) throws {
        let standardizedURL = mediaURL.standardizedFileURL
        pendingLock.lock()
        pendingSaves.removeValue(forKey: standardizedURL.path)
        pendingLock.unlock()

        try fileQueue.sync {
            try deleteProjectFilesDirect(for: standardizedURL)
        }
    }

    public func deleteProjectAsync(for mediaURL: URL) async throws {
        let standardizedURL = mediaURL.standardizedFileURL
        cancelPendingSave(for: standardizedURL)

        try await withCheckedThrowingContinuation { continuation in
            fileQueue.async {
                do {
                    try self.deleteProjectFilesDirect(for: standardizedURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cancelPendingSave(for standardizedURL: URL) {
        pendingLock.lock()
        pendingSaves.removeValue(forKey: standardizedURL.path)
        pendingLock.unlock()
    }

    private func deleteProjectFilesDirect(for standardizedURL: URL) throws {
        let baseName = projectBaseName(for: standardizedURL)
        let relatedFiles = try FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.lastPathComponent == baseName || url.lastPathComponent.hasPrefix(baseName + ".")
        }
        for url in relatedFiles {
            try FileManager.default.removeItem(at: url)
        }
        persistedMetadataCache.removeValue(forKey: standardizedURL.path)
    }

    private func locateProjectData(for mediaURL: URL) -> (data: Data, cacheDir: URL)? {
        let metadataURL = projectFileURL(for: mediaURL)
        if let data = try? Data(contentsOf: metadataURL) {
            return (data, projectsDirectory)
        }
        // 跨沙盒容器检查：若当前沙盒目录未找到，尝试检查非沙盒 Application Support 目录
        let userName = NSUserName()
        if let home = NSHomeDirectoryForUser(userName) {
            let globalProjects = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Application Support/MacAboboo/Projects", isDirectory: true)
            let candidateURL = globalProjects.appendingPathComponent(projectBaseName(for: mediaURL) + ".json")
            if candidateURL.path != metadataURL.path, let data = try? Data(contentsOf: candidateURL) {
                // 自动同步完整工程族：元数据、波形以及可恢复备份必须一起迁移。
                // 只复制 JSON 会令下一次启动在新目录找不到 waveform，并让
                // 删除播放历史时留下旧目录中的备份。
                try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
                let baseName = projectBaseName(for: mediaURL)
                var didMigrateCompleteFamily = false
                if let relatedItems = try? FileManager.default.contentsOfDirectory(
                    at: globalProjects,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter({ item in
                    item.lastPathComponent == baseName || item.lastPathComponent.hasPrefix(baseName + ".")
                }) {
                    var migrationCompleted = true
                    for sourceURL in relatedItems {
                        let destinationURL = projectsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                        do {
                            if FileManager.default.fileExists(atPath: destinationURL.path) {
                                try FileManager.default.removeItem(at: destinationURL)
                            }
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        } catch {
                            migrationCompleted = false
                            break
                        }
                    }
                    // Only remove the old project family after every item has
                    // reached the new directory. A failed copy remains fully
                    // recoverable from its original location.
                    if migrationCompleted {
                        for sourceURL in relatedItems {
                            try? FileManager.default.removeItem(at: sourceURL)
                        }
                        didMigrateCompleteFamily = true
                    } else {
                        // A partial destination must not mask the intact source
                        // on the next launch. Remove only the newly copied family.
                        for sourceURL in relatedItems {
                            let destinationURL = projectsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                            try? FileManager.default.removeItem(at: destinationURL)
                        }
                    }
                }
                guard didMigrateCompleteFamily else { return (data, globalProjects) }
                if !FileManager.default.fileExists(atPath: metadataURL.path) {
                    try? data.write(to: metadataURL, options: .atomic)
                }
                return ((try? Data(contentsOf: metadataURL)) ?? data, projectsDirectory)
            }
        }
        return nil
    }

    private func loadProjectResultDirect(for mediaURL: URL) -> ProjectLoadResult {
        guard let location = locateProjectData(for: mediaURL) else {
            if let recovered = loadLatestBackupProject(for: mediaURL) {
                persistedMetadataCache[mediaURL.standardizedFileURL.path] = recovered
                reportError("工程主文件不存在，已从最近备份恢复。")
                return .loaded(recovered, needsMigration: true)
            }
            return .missing
        }

        do {
            let decoded = try decodeStoredProject(location.data)
            let project = projectByHydratingWaveform(decoded.project, cacheDirectory: location.cacheDir)
            persistedMetadataCache[mediaURL.standardizedFileURL.path] = project
            return .loaded(project, needsMigration: decoded.needsMigration)
        } catch {
            if let recovered = loadLatestBackupProject(for: mediaURL) {
                persistedMetadataCache[mediaURL.standardizedFileURL.path] = recovered
                reportError("工程主文件无法读取，已从最近备份恢复。")
                return .loaded(recovered, needsMigration: true)
            }
            reportError("读取工程文件失败：\(error.localizedDescription)")
            return .unavailable(error.localizedDescription)
        }
    }

    /// 应用退出和测试断言前等待已排队写入完成。
    public func flush() {
        fileQueue.sync {
            drainPendingSaves()
        }
    }

    /// Asynchronously waits for all queued project writes to finish.  Closing a
    /// media window happens on the main actor; using the synchronous variant
    /// there would block AppKit until every JSON/backup write completed.
    public func flushAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            fileQueue.async { [weak self] in
                self?.drainPendingSaves()
                continuation.resume()
            }
        }
    }

    private func encodeWaveformCache(_ waveform: WaveformData) -> Data {
        var data = Data("MABWAVE2".utf8)
        data.appendLittleEndian(UInt32(2))
        data.appendLittleEndian(UInt64(waveform.peakCount))
        data.appendLittleEndian(waveform.duration.bitPattern)
        data.appendLittleEndian(waveform.sampleRate.bitPattern)
        for index in 0..<waveform.peakCount {
            data.appendLittleEndian(waveform.minPeaks[index].bitPattern)
            data.appendLittleEndian(waveform.maxPeaks[index].bitPattern)
        }
        return data
    }

    private func decodeWaveformCache(_ data: Data) -> WaveformData? {
        let magic = Data("MABWAVE2".utf8)
        guard data.count >= 36, data.prefix(magic.count) == magic else { return nil }
        var offset = magic.count

        func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            guard offset <= data.count - MemoryLayout<T>.size else { return nil }
            let value = data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }

        guard read(UInt32.self) == 2,
              let rawCount = read(UInt64.self),
              rawCount <= 50_000_000,
              let durationBits = read(UInt64.self),
              let sampleRateBits = read(UInt64.self) else { return nil }
        let count = Int(rawCount)
        guard count <= (Int.max - offset) / 8, data.count == offset + count * 8 else { return nil }

        var minimums: [Float] = []
        var maximums: [Float] = []
        minimums.reserveCapacity(count)
        maximums.reserveCapacity(count)
        for _ in 0..<count {
            guard let minimumBits = read(UInt32.self), let maximumBits = read(UInt32.self) else { return nil }
            let minimum = Float(bitPattern: minimumBits)
            let maximum = Float(bitPattern: maximumBits)
            guard minimum.isFinite, maximum.isFinite else { return nil }
            minimums.append(minimum)
            maximums.append(maximum)
        }

        let duration = Double(bitPattern: durationBits)
        let sampleRate = Double(bitPattern: sampleRateBits)
        guard duration.isFinite, duration > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        return WaveformData(
            uncheckedPeaks: [],
            minPeaks: minimums,
            maxPeaks: maximums,
            duration: duration,
            sampleRate: sampleRate
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
