import Foundation
import CryptoKit

/// 单个媒体的当前工程元数据。工程文件只接受当前 schema，
/// 不读取或迁移旧版本工程。
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
                debugDescription: "不支持的工程文件版本。"
            )
        }
        schemaVersion = decodedSchemaVersion
        mediaPath = try container.decode(String.self, forKey: .mediaPath)
        mediaTitle = try container.decode(String.self, forKey: .mediaTitle)
        let decodedDuration = try container.decode(Double.self, forKey: .duration)
        duration = decodedDuration.isFinite ? max(0, decodedDuration) : 0
        let decodedPosition = try container.decode(Double.self, forKey: .lastPosition)
        lastPosition = decodedPosition.isFinite ? max(0, decodedPosition) : 0
        segments = try container.decode([SentenceSegment].self, forKey: .segments)
        waveformData = try container.decodeIfPresent(WaveformData.self, forKey: .waveformData)
        waveformCacheFile = try container.decodeIfPresent(String.self, forKey: .waveformCacheFile)
        mediaFileSize = try container.decodeIfPresent(Int64.self, forKey: .mediaFileSize)
        mediaModificationDate = try container.decodeIfPresent(Date.self, forKey: .mediaModificationDate)
        hasCompletedSegmentation = try container.decode(Bool.self, forKey: .hasCompletedSegmentation)
        acousticBoundaryTimes = Self.normalizedAcousticBoundaryTimes(
            try container.decode([Double].self, forKey: .acousticBoundaryTimes)
        )
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
        guard mediaPath == mediaURL.standardizedFileURL.path else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: mediaURL.path) else {
            return mediaFileSize == nil && mediaModificationDate == nil
        }
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value
        if let expectedSize = mediaFileSize, actualSize != expectedSize {
            return false
        }
        if let expectedDate = mediaModificationDate,
           let actualDate = attributes[.modificationDate] as? Date,
           abs(actualDate.timeIntervalSince(expectedDate)) > 1.0 {
            return false
        }
        return true
    }
}

/// 工程元数据与波形缓存采用独立文件存储，避免每次改一行字幕都重写整份波形。
public final class ProjectFileManager: @unchecked Sendable {
    public static let shared = ProjectFileManager()

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

    private func writeProject(_ request: SaveRequest) {
        let metadataURL = projectFileURL(for: request.mediaURL)
        let waveformURL = waveformFileURL(for: request.mediaURL)
        do {
            var existingMetadata = persistedMetadataCache[request.mediaURL.path]
            if existingMetadata == nil, let existingData = try? Data(contentsOf: metadataURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                existingMetadata = try? decoder.decode(MediaProjectFile.self, from: existingData)
                if let existingMetadata {
                    persistedMetadataCache[request.mediaURL.path] = existingMetadata
                }
            }
            let existingMetadataIsCompatible = existingMetadata?.isCompatible(with: request.mediaURL) == true
            var hasWaveformCache = existingMetadataIsCompatible
                && FileManager.default.fileExists(atPath: waveformURL.path)
            var waveformCacheChanged = false
            if request.persistWaveform,
               let waveformData = request.waveformData,
               !waveformData.isEmpty {
                let cacheData = encodeWaveformCache(waveformData)
                let existingCacheData = try? Data(contentsOf: waveformURL)
                if existingCacheData != cacheData {
                    try cacheData.write(to: waveformURL, options: .atomic)
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

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
            try data.write(to: metadataURL, options: .atomic)
            persistedMetadataCache[request.mediaURL.path] = project
        } catch {
            reportError("保存工程文件失败：\(error.localizedDescription)")
        }
    }

    private func metadataMatches(
        _ existing: MediaProjectFile,
        _ desired: MediaProjectFile,
        datesMatch: (Date?, Date?) -> Bool
    ) -> Bool {
        existing.schemaVersion == desired.schemaVersion
            && existing.mediaPath == desired.mediaPath
            && existing.mediaTitle == desired.mediaTitle
            && abs(existing.duration - desired.duration) <= 0.000001
            && abs(existing.lastPosition - desired.lastPosition) <= 0.000001
            && existing.segments == desired.segments
            && existing.waveformData == desired.waveformData
            && existing.waveformCacheFile == desired.waveformCacheFile
            && existing.mediaFileSize == desired.mediaFileSize
            && datesMatch(existing.mediaModificationDate, desired.mediaModificationDate)
            && existing.hasCompletedSegmentation == desired.hasCompletedSegmentation
            && existing.acousticBoundaryTimes == desired.acousticBoundaryTimes
    }

    public func loadProjectAsync(for mediaURL: URL) async -> MediaProjectFile? {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                continuation.resume(returning: self.loadProjectDirect(for: mediaURL))
            }
        }
    }

    public func loadProject(for mediaURL: URL) -> MediaProjectFile? {
        fileQueue.sync {
            loadProjectDirect(for: mediaURL)
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

    private func loadProjectDirect(for mediaURL: URL) -> MediaProjectFile? {
        let metadataURL = projectFileURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(MediaProjectFile.self, from: data)

            var waveform = metadata.waveformData
            if waveform == nil, let cacheName = metadata.waveformCacheFile {
                // 只接受纯文件名，避免损坏或篡改的工程文件越出 Projects 目录。
                let safeName = URL(fileURLWithPath: cacheName).lastPathComponent
                if safeName == cacheName {
                    let cacheURL = projectsDirectory.appendingPathComponent(safeName)
                    if let cacheData = try? Data(contentsOf: cacheURL) {
                        waveform = decodeWaveformCache(cacheData)
                            ?? (try? PropertyListDecoder().decode(WaveformData.self, from: cacheData))
                    }
                }
            }

            let project = MediaProjectFile(
                mediaPath: metadata.mediaPath,
                mediaTitle: metadata.mediaTitle,
                duration: metadata.duration,
                lastPosition: metadata.lastPosition,
                segments: metadata.segments,
                waveformData: waveform,
                waveformCacheFile: metadata.waveformCacheFile,
                mediaFileSize: metadata.mediaFileSize,
                mediaModificationDate: metadata.mediaModificationDate,
                hasCompletedSegmentation: metadata.hasCompletedSegmentation,
                acousticBoundaryTimes: metadata.acousticBoundaryTimes,
                updatedAt: metadata.updatedAt
            )
            persistedMetadataCache[mediaURL.standardizedFileURL.path] = project
            return project
        } catch {
            reportError("读取工程文件失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 应用退出和测试断言前等待已排队写入完成。
    public func flush() {
        fileQueue.sync {
            drainPendingSaves()
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
        var peaks: [Float] = []
        minimums.reserveCapacity(count)
        maximums.reserveCapacity(count)
        peaks.reserveCapacity(count)
        for _ in 0..<count {
            guard let minimumBits = read(UInt32.self), let maximumBits = read(UInt32.self) else { return nil }
            let minimum = Float(bitPattern: minimumBits)
            let maximum = Float(bitPattern: maximumBits)
            guard minimum.isFinite, maximum.isFinite else { return nil }
            minimums.append(minimum)
            maximums.append(maximum)
            peaks.append(min(1, max(abs(minimum), abs(maximum))))
        }

        let duration = Double(bitPattern: durationBits)
        let sampleRate = Double(bitPattern: sampleRateBits)
        guard duration.isFinite, duration > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        return WaveformData(
            uncheckedPeaks: peaks,
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
