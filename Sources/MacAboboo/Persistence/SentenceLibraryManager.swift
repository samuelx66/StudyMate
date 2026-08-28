import Foundation
import AVFoundation
import AppKit

@MainActor
public final class SentenceLibraryManager: ObservableObject {
    public static let shared = SentenceLibraryManager()

    @Published public private(set) var libraries: [SentenceLibraryDescriptor] = []
    @Published public private(set) var currentLibraryID: UUID?
    @Published public private(set) var entries: [SentenceLibraryEntry] = []
    @Published public private(set) var availableSources: [String] = []
    @Published public private(set) var selectedSource = ""
    @Published public private(set) var sortOrder: SentenceLibrarySortOrder = .newestFirst
    @Published public private(set) var isWorking = false
    @Published public private(set) var operationProgress: SentenceLibraryOperationProgress?
    @Published public private(set) var lastErrorMessage: String?

    /// 由主窗口状态栏的小叉调用；仅关闭提示，不影响句库中的数据或后台任务。
    public func dismissErrorMessage() {
        lastErrorMessage = nil
    }

    private let store: SentenceLibraryStore
    private let defaults: UserDefaults
    private let currentLibraryKey = "MacAboboo.CurrentSentenceLibraryID"
    private var searchText = ""
    private var dateFilter: SentenceLibraryDateFilter = .all
    private var selectedFilterDate = Date()
    private var queryTask: Task<Void, Never>?
    private var operationGeneration = UUID()

    public init(
        store: SentenceLibraryStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        Task { [weak self] in
            await self?.reloadLibraries(createDefaultIfNeeded: true)
        }
    }

    public var currentLibrary: SentenceLibraryDescriptor? {
        libraries.first { $0.id == currentLibraryID }
    }

    public func createLibrary(name: String) async throws {
        let descriptor = try await Task.detached(priority: .utility) { [store] in
            try store.createLibrary(name: name)
        }.value
        await reloadLibraries(createDefaultIfNeeded: false)
        selectLibrary(descriptor.id)
    }

    public func selectLibrary(_ id: UUID) {
        guard libraries.contains(where: { $0.id == id }) else { return }
        currentLibraryID = id
        defaults.set(id.uuidString, forKey: currentLibraryKey)
        selectedSource = ""
        availableSources = []
        reloadSources(for: id)
        reloadEntries()
    }

    public func updateFilter(
        searchText: String,
        dateFilter: SentenceLibraryDateFilter,
        selectedDate: Date? = nil,
        sourceMediaName: String = "",
        sortOrder: SentenceLibrarySortOrder = .newestFirst
    ) {
        self.searchText = searchText
        self.dateFilter = dateFilter
        if let selectedDate { selectedFilterDate = selectedDate }
        self.selectedSource = sourceMediaName
        self.sortOrder = sortOrder
        reloadEntries(debounceNanoseconds: 150_000_000)
    }

    public func reloadEntries(debounceNanoseconds: UInt64 = 0) {
        queryTask?.cancel()
        guard let libraryID = currentLibraryID else {
            entries = []
            return
        }
        let query = searchText
        let filterDate = selectedFilterDate
        let lowerBound = dateFilter.lowerBound(selectedDate: filterDate)
        let upperBound = dateFilter.upperBound(selectedDate: filterDate)
        let source = selectedSource
        let order = sortOrder
        queryTask = Task { [weak self, store] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                Result {
                    try store.entries(
                        libraryID: libraryID,
                        searchText: query,
                        createdAfter: lowerBound,
                        createdBefore: upperBound,
                        sourceMediaName: source,
                        sortOrder: order
                    )
                }
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.currentLibraryID == libraryID,
                  self.searchText == query,
                  self.selectedSource == source,
                  self.sortOrder == order else { return }
            switch result {
            case let .success(foundEntries):
                self.entries = foundEntries
                self.lastErrorMessage = nil
            case let .failure(error):
                self.entries = []
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func add(segments: [SentenceSegment], from media: MediaItem) async throws -> Int {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        guard !segments.isEmpty else { return 0 }
        isWorking = true
        let generation = UUID()
        operationGeneration = generation
        operationProgress = SentenceLibraryOperationProgress(fraction: 0, phase: "准备导出句库音频")
        defer {
            if operationGeneration == generation {
                isWorking = false
                operationProgress = nil
            }
        }

        let timestamp = Date()
        let ordered = segments.sorted {
            if $0.startTime == $1.startTime { return $0.index < $1.index }
            return $0.startTime < $1.startTime
        }
        let sourceURL = media.url
        let sourceTitle = media.title
        let sourceIsVideo = media.isVideo
        let report: @Sendable (Double, String, String) -> Void = { [weak self] fraction, phase, currentItem in
            Task { @MainActor [weak self] in
                guard let self, self.operationGeneration == generation else { return }
                self.operationProgress = SentenceLibraryOperationProgress(
                    fraction: fraction,
                    phase: phase,
                    currentItem: currentItem
                )
            }
        }
        let prepared = try await Task.detached(priority: .userInitiated) { [store] in
            let fileManager = FileManager.default
            guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw SentenceLibraryError.database("无法找到应用支持目录。")
            }
            let tempRoot = support
                .appendingPathComponent("MacAboboo", isDirectory: true)
                .appendingPathComponent("SentenceLibraryTemp", isDirectory: true)
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let workDirectory = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: workDirectory) }

            let exporter = SegmentMediaExporter()
            var entries: [SentenceLibraryEntry] = []
            var previews: [UUID: Data] = [:]
            var mediaURLs: [UUID: URL] = [:]
            let imageGenerator = sourceIsVideo ? SentencePreviewGenerator(mediaURL: sourceURL) : nil
            let total = max(1, ordered.count)
            for (offset, segment) in ordered.enumerated() {
                try Task.checkCancellation()
                let id = UUID()
                let mediaFilename = "\(id.uuidString).m4a"
                let mediaOutputURL = workDirectory.appendingPathComponent(mediaFilename)
                try exporter.exportAudioClip(
                    mediaURL: sourceURL,
                    segment: segment,
                    outputURL: mediaOutputURL,
                    progress: { exportProgress in
                        let itemFraction = (Double(offset) + exportProgress.fraction) / Double(total)
                        report(itemFraction * 0.82, "导出句库音频", mediaFilename)
                    }
                )
                mediaURLs[id] = mediaOutputURL
                let preview = imageGenerator?.jpegData(at: (segment.startTime + segment.endTime) / 2)
                if let preview { previews[id] = preview }
                report(
                    0.82 * Double(offset + 1) / Double(total),
                    sourceIsVideo ? "生成预览并整理音频" : "整理音频片段",
                    mediaFilename
                )
                entries.append(SentenceLibraryEntry(
                    id: id,
                    originalText: segment.text,
                    translation: segment.translation,
                    note: segment.note,
                    sourceMediaName: sourceTitle,
                    sourceMediaPath: sourceURL.path,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    createdAt: timestamp,
                    mediaFilename: mediaFilename,
                    previewFilename: preview == nil ? nil : "\(id.uuidString).jpg"
                ))
            }
            try Task.checkCancellation()
            try store.add(
                entries: entries,
                previewData: previews,
                to: libraryID,
                mediaURLs: mediaURLs,
                progress: { fraction in
                    report(0.82 + fraction * 0.18, "写入句库索引", "")
                }
            )
            return entries.count
        }.value

        operationProgress = SentenceLibraryOperationProgress(fraction: 1, phase: "句库保存完成")
        await reloadLibraries(createDefaultIfNeeded: false)
        reloadEntries()
        return prepared
    }

    public func deleteEntries(ids: Set<UUID>) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        isWorking = true
        defer { isWorking = false }
        try await Task.detached(priority: .utility) { [store] in
            try store.deleteEntries(ids: ids, from: libraryID)
        }.value
        await reloadLibraries(createDefaultIfNeeded: false)
        reloadEntries()
    }

    public func deleteCurrentLibrary() async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        try await Task.detached(priority: .utility) { [store] in
            try store.deleteLibrary(id: libraryID)
        }.value
        currentLibraryID = nil
        await reloadLibraries(createDefaultIfNeeded: true)
    }

    public func previewURL(for entry: SentenceLibraryEntry) -> URL? {
        guard let libraryID = currentLibraryID else { return nil }
        return store.previewURL(for: entry, libraryID: libraryID)
    }

    public func mediaURL(for entry: SentenceLibraryEntry) -> URL? {
        guard let libraryID = currentLibraryID else { return nil }
        return store.mediaURL(for: entry, libraryID: libraryID)
    }

    /// 将当前句库中筛选后可见的句子导出为 M4A 与 LRC。媒体文件均来自
    /// `.mablib/Media`，因此导出不依赖当前主窗口是否还打开原始媒体。
    public func exportEntries(
        _ entries: [SentenceLibraryEntry],
        merged: Bool,
        destinationURL: URL,
        progress: @escaping @Sendable (SegmentMediaExportProgress) -> Void = { _ in }
    ) async throws -> SegmentMediaExportResult {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        // 调用方传入的顺序就是当前筛选结果在界面上的顺序；导出时保留它，
        // 这样“最新入库”排序下的合并音频与用户看到的列表一致。
        let ordered = entries
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }

        var mediaURLs: [UUID: URL] = [:]
        for entry in ordered {
            guard let url = store.mediaURL(for: entry, libraryID: libraryID) else {
                throw SentenceLibraryError.database("句库中缺少句子音频：\(entry.originalText.isEmpty ? entry.id.uuidString : entry.originalText)")
            }
            mediaURLs[entry.id] = url
        }

        let sourceTag: String = {
            let names = Set(ordered.map(\.sourceMediaName).filter { !$0.isEmpty })
            if names.count == 1 { return names.first ?? "MacAboboo" }
            return names.isEmpty ? "MacAboboo" : "多个来源"
        }()

        isWorking = true
        let generation = UUID()
        operationGeneration = generation
        operationProgress = SentenceLibraryOperationProgress(fraction: 0, phase: "准备导出句库")
        defer {
            if operationGeneration == generation {
                isWorking = false
                operationProgress = nil
            }
        }
        let report: @Sendable (SegmentMediaExportProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.operationGeneration == generation else { return }
                self.operationProgress = SentenceLibraryOperationProgress(
                    fraction: progress.fraction,
                    phase: progress.phase,
                    currentItem: progress.currentItem
                )
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            if merged {
                return try SegmentMediaExporter.shared.exportLibraryEntriesMerged(
                    entries: ordered,
                    mediaURLs: mediaURLs,
                    outputAudioURL: destinationURL,
                    album: sourceTag,
                    artist: sourceTag,
                    progress: { value in
                        report(value)
                        progress(value)
                    }
                )
            }
            return try SegmentMediaExporter.shared.exportLibraryEntriesIndividually(
                entries: ordered,
                mediaURLs: mediaURLs,
                destinationDirectory: destinationURL,
                baseName: sourceTag,
                album: sourceTag,
                artist: sourceTag,
                progress: { value in
                    report(value)
                    progress(value)
                }
            )
        }.value
    }

    private func reloadLibraries(createDefaultIfNeeded: Bool) async {
        let available = await Task.detached(priority: .utility) { [store] in
            var result = store.listLibraries()
            if result.isEmpty, createDefaultIfNeeded,
               let created = try? store.createLibrary(name: "默认句库") {
                result = [created]
            }
            return result
        }.value
        libraries = available
        let savedID = defaults.string(forKey: currentLibraryKey).flatMap(UUID.init(uuidString:))
        if let currentLibraryID, available.contains(where: { $0.id == currentLibraryID }) {
            // Keep the current selection.
        } else if let savedID, available.contains(where: { $0.id == savedID }) {
            currentLibraryID = savedID
        } else {
            currentLibraryID = available.first?.id
        }
        if let currentLibraryID {
            defaults.set(currentLibraryID.uuidString, forKey: currentLibraryKey)
            reloadSources(for: currentLibraryID)
        }
        reloadEntries()
    }

    private func reloadSources(for libraryID: UUID) {
        Task { [weak self, store] in
            let result = await Task.detached(priority: .utility) {
                (try? store.sourceMediaNames(libraryID: libraryID)) ?? []
            }.value
            guard let self, self.currentLibraryID == libraryID else { return }
            self.availableSources = result
            if !self.selectedSource.isEmpty, !result.contains(self.selectedSource) {
                self.selectedSource = ""
                self.reloadEntries()
            }
        }
    }
}

private final class SentencePreviewGenerator {
    private let generator: AVAssetImageGenerator

    init(mediaURL: URL) {
        let asset = AVURLAsset(url: mediaURL)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
    }

    func jpegData(at seconds: Double) -> Data? {
        let safeTime = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: safeTime, actualTime: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }
}
