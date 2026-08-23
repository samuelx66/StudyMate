import Foundation

public struct PlaybackHistoryEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let mediaPath: String
    public let addedAt: Date

    public init(id: UUID = UUID(), mediaPath: String, addedAt: Date = Date()) {
        self.id = id
        self.mediaPath = URL(fileURLWithPath: mediaPath).standardizedFileURL.path
        self.addedAt = addedAt
    }

    public var mediaURL: URL {
        URL(fileURLWithPath: mediaPath).standardizedFileURL
    }

    public var filename: String {
        mediaURL.lastPathComponent
    }
}

/// 按首次加入顺序保存播放过或手动添加的媒体文件，重复打开不会产生重复条目。
@MainActor
public final class PlaybackHistoryStore: ObservableObject {
    public static let shared = PlaybackHistoryStore()

    @Published public private(set) var entries: [PlaybackHistoryEntry] = []

    private let storageURL: URL

    /// 注入目录仅用于测试；正式数据保存在 Application Support/MacAboboo。
    public init(storageDirectory: URL? = nil) {
        let directory: URL
        if let storageDirectory {
            directory = storageDirectory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            directory = applicationSupport.appendingPathComponent("MacAboboo", isDirectory: true)
        }
        storageURL = directory.appendingPathComponent("PlaybackHistory.json")
        entries = Self.loadEntries(from: storageURL)
    }

    public func recordPlayed(_ mediaURL: URL) {
        appendIfNeeded(mediaURL)
    }

    public func add(_ mediaURLs: [URL]) {
        var changed = false
        var knownPaths = Set(entries.map(\.mediaPath))
        for url in mediaURLs {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.isFileURL,
                  FileManager.default.fileExists(atPath: standardizedURL.path),
                  knownPaths.insert(standardizedURL.path).inserted else { continue }
            entries.append(PlaybackHistoryEntry(mediaPath: standardizedURL.path))
            changed = true
        }
        if changed { persist() }
    }

    public func remove(_ mediaURL: URL) {
        let path = mediaURL.standardizedFileURL.path
        let previousCount = entries.count
        entries.removeAll { $0.mediaPath == path }
        if entries.count != previousCount { persist() }
    }

    private func appendIfNeeded(_ mediaURL: URL) {
        add([mediaURL])
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: storageURL, options: .atomic)
        } catch {
            print("Failed to save playback history: \(error)")
        }
    }

    private static func loadEntries(from url: URL) -> [PlaybackHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([PlaybackHistoryEntry].self, from: data) else { return [] }

        var seenPaths = Set<String>()
        return decoded.filter { seenPaths.insert($0.mediaPath).inserted }
    }
}
