import Foundation

public struct PlaybackHistoryEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let mediaPath: String
    public let addedAt: Date
    /// The last time this entry was successfully loaded for playback.
    /// Manually added entries leave this nil; tracked entries are preferred
    /// when selecting the automatic startup restore target.
    public let lastOpenedAt: Date?

    public init(
        id: UUID = UUID(),
        mediaPath: String,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.mediaPath = URL(fileURLWithPath: mediaPath).standardizedFileURL.path
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case mediaPath
        case addedAt
        case lastOpenedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let rawPath = try container.decode(String.self, forKey: .mediaPath)
        mediaPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mediaPath, forKey: .mediaPath)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
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
    @Published public private(set) var reachableEntries: [PlaybackHistoryEntry] = []

    private let storageURL: URL
    private let ioQueue = DispatchQueue(label: "com.studymate.playback-history", qos: .utility)
    private var persistenceErrorHandler: (@Sendable (String) -> Void)?
    private var reachabilityTask: Task<Void, Never>?
    private var reachabilityRevision: UInt64 = 0

    /// 注入目录仅用于测试；正式数据保存在 Application Support/StudyMate。
    public init(storageDirectory: URL? = nil) {
        let directory: URL
        if let storageDirectory {
            directory = storageDirectory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            directory = applicationSupport.appendingPathComponent("StudyMate", isDirectory: true)
        }
        storageURL = directory.appendingPathComponent("PlaybackHistory.json")
        entries = Self.loadEntries(from: storageURL)
        refreshReachableEntries()
    }

    public func refreshReachableEntries() {
        let snapshot = entries
        reachabilityRevision &+= 1
        let revision = reachabilityRevision
        reachabilityTask?.cancel()
        reachabilityTask = Task.detached(priority: .utility) {
            var valid: [PlaybackHistoryEntry] = []
            valid.reserveCapacity(snapshot.count)
            for entry in snapshot {
                guard !Task.isCancelled else { return }
                if FileManager.default.fileExists(atPath: entry.mediaPath) {
                    valid.append(entry)
                }
            }
            valid.sort { entry1, entry2 in
                let date1 = entry1.lastOpenedAt ?? entry1.addedAt
                let date2 = entry2.lastOpenedAt ?? entry2.addedAt
                return date1 > date2
            }
            guard !Task.isCancelled else { return }
            let resolvedEntries = valid
            await MainActor.run { [weak self] in
                guard let self, self.reachabilityRevision == revision else { return }
                self.reachableEntries = resolvedEntries
            }
        }
    }

    public func recordPlayed(_ mediaURL: URL) {
        let standardizedURL = mediaURL.standardizedFileURL
        guard standardizedURL.isFileURL,
              FileManager.default.fileExists(atPath: standardizedURL.path) else { return }

        let openedAt = Date()
        if let index = entries.firstIndex(where: { $0.mediaPath == standardizedURL.path }) {
            let existing = entries[index]
            entries[index] = PlaybackHistoryEntry(
                id: existing.id,
                mediaPath: existing.mediaPath,
                addedAt: existing.addedAt,
                lastOpenedAt: openedAt
            )
        } else {
            entries.append(PlaybackHistoryEntry(
                mediaPath: standardizedURL.path,
                lastOpenedAt: openedAt
            ))
        }
        persist()
        refreshReachableEntries()
    }

    /// The most recently opened media. Entries without an explicit successful
    /// open are not used as the automatic restore target.
    public var lastOpenedMediaURL: URL? {
        entries
            .compactMap({ entry -> (Date, URL)? in
                guard let lastOpenedAt = entry.lastOpenedAt else { return nil }
                return (lastOpenedAt, entry.mediaURL)
            })
            .max(by: { $0.0 < $1.0 })?.1
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
        if changed {
            persist()
            refreshReachableEntries()
        }
    }

    public func remove(_ mediaURL: URL) {
        let path = mediaURL.standardizedFileURL.path
        let previousCount = entries.count
        entries.removeAll { $0.mediaPath == path }
        if entries.count != previousCount {
            persist()
            refreshReachableEntries()
        }
    }

    public func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
        refreshReachableEntries()
    }

    /// 历史记录在后台写入；失败时由播放引擎转交状态栏，而不是静默打印。
    public func setPersistenceErrorHandler(_ handler: (@Sendable (String) -> Void)?) {
        persistenceErrorHandler = handler
    }

    private func persist() {
        let snapshot = entries
        let destination = storageURL
        let errorHandler = persistenceErrorHandler
        ioQueue.async {
            Self.persist(snapshot, to: destination, errorHandler: errorHandler)
        }
    }

    /// 用于退出和测试等待已排队的历史记录写入；普通界面操作不调用。
    public func flush() {
        ioQueue.sync {}
    }

    /// Main-actor friendly counterpart to `flush()`.  The synchronous method
    /// remains for termination/tests, while media-window closing can await the
    /// utility queue without freezing the UI.
    public func flushAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                continuation.resume()
            }
        }
    }

    private nonisolated static func persist(
        _ entries: [PlaybackHistoryEntry],
        to storageURL: URL,
        errorHandler: (@Sendable (String) -> Void)?
    ) {
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
            errorHandler?("保存播放历史失败：\(error.localizedDescription)")
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
