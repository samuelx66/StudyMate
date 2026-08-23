import Foundation
import CryptoKit

/// 单个媒体的工程元数据。schema 1 的旧文件仍可直接读取；schema 2 将大体积波形拆分为二进制缓存。
public struct MediaProjectFile: Codable, Sendable {
    public static let currentSchemaVersion = 2

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
    public let updatedAt: Date

    public init(
        schemaVersion: Int = MediaProjectFile.currentSchemaVersion,
        mediaPath: String,
        mediaTitle: String,
        duration: Double,
        lastPosition: Double,
        segments: [SentenceSegment],
        waveformData: WaveformData? = nil,
        waveformCacheFile: String? = nil,
        mediaFileSize: Int64? = nil,
        mediaModificationDate: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.mediaPath = mediaPath
        self.mediaTitle = mediaTitle
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.lastPosition = lastPosition.isFinite ? max(0, lastPosition) : 0
        self.segments = segments
        self.waveformData = waveformData
        self.waveformCacheFile = waveformCacheFile
        self.mediaFileSize = mediaFileSize
        self.mediaModificationDate = mediaModificationDate
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
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        mediaPath = try container.decode(String.self, forKey: .mediaPath)
        mediaTitle = try container.decodeIfPresent(String.self, forKey: .mediaTitle) ?? URL(fileURLWithPath: mediaPath).deletingPathExtension().lastPathComponent
        let decodedDuration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        duration = decodedDuration.isFinite ? max(0, decodedDuration) : 0
        let decodedPosition = try container.decodeIfPresent(Double.self, forKey: .lastPosition) ?? 0
        lastPosition = decodedPosition.isFinite ? max(0, decodedPosition) : 0
        segments = try container.decodeIfPresent([SentenceSegment].self, forKey: .segments) ?? []
        waveformData = try container.decodeIfPresent(WaveformData.self, forKey: .waveformData)
        waveformCacheFile = try container.decodeIfPresent(String.self, forKey: .waveformCacheFile)
        mediaFileSize = try container.decodeIfPresent(Int64.self, forKey: .mediaFileSize)
        mediaModificationDate = try container.decodeIfPresent(Date.self, forKey: .mediaModificationDate)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
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
        try container.encode(updatedAt, forKey: .updatedAt)
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
    private var pendingSaves: [String: SaveRequest] = [:]
    private var isDrainScheduled = false

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
        persistWaveform: Bool = false
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
            modificationDate: modificationDate
        )
        pendingLock.lock()
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
                modificationDate: request.modificationDate
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
            var existingMetadataIsCompatible = false
            if let existingData = try? Data(contentsOf: metadataURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                existingMetadataIsCompatible = (try? decoder.decode(MediaProjectFile.self, from: existingData))?
                    .isCompatible(with: request.mediaURL) == true
            }
            var hasWaveformCache = existingMetadataIsCompatible
                && FileManager.default.fileExists(atPath: waveformURL.path)
            if request.persistWaveform,
               let waveformData = request.waveformData,
               !waveformData.isEmpty {
                let cacheData = encodeWaveformCache(waveformData)
                try cacheData.write(to: waveformURL, options: .atomic)
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
                updatedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            print("Failed to save project file: \(error)")
        }
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

            return MediaProjectFile(
                schemaVersion: metadata.schemaVersion,
                mediaPath: metadata.mediaPath,
                mediaTitle: metadata.mediaTitle,
                duration: metadata.duration,
                lastPosition: metadata.lastPosition,
                segments: metadata.segments,
                waveformData: waveform,
                waveformCacheFile: metadata.waveformCacheFile,
                mediaFileSize: metadata.mediaFileSize,
                mediaModificationDate: metadata.mediaModificationDate,
                updatedAt: metadata.updatedAt
            )
        } catch {
            print("Failed to load project file: \(error)")
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
        data.appendLittleEndian(UInt64(waveform.peaks.count))
        data.appendLittleEndian(waveform.duration.bitPattern)
        data.appendLittleEndian(waveform.sampleRate.bitPattern)
        for index in waveform.peaks.indices {
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
