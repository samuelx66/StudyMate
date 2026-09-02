import Foundation
import AVFoundation
import AppKit

/// Lightweight status projection used by the media window.  The main media
/// view must not observe the entire sentence-library manager (which publishes
/// every entry/filter change); only this small progress/error surface is needed
/// to decide whether the status bar should be mounted.
@MainActor
public final class SentenceLibraryStatusCenter: ObservableObject {
    public static let shared = SentenceLibraryStatusCenter()

    @Published public private(set) var isWorking = false
    @Published public private(set) var operationProgress: SentenceLibraryOperationProgress?
    @Published public private(set) var errorMessage: String?

    private init() {}

    fileprivate func update(
        isWorking: Bool,
        operationProgress: SentenceLibraryOperationProgress?,
        errorMessage: String?
    ) {
        self.isWorking = isWorking
        self.operationProgress = operationProgress
        self.errorMessage = errorMessage
    }
}

@MainActor
public final class SentenceLibraryManager: ObservableObject {
    public static let shared = SentenceLibraryManager()

    @Published public private(set) var libraries: [SentenceLibraryDescriptor] = []
    @Published public private(set) var currentLibraryID: UUID?
    @Published public private(set) var entries: [SentenceLibraryEntry] = []
    @Published public private(set) var availableSources: [String] = []
    @Published public private(set) var selectedSource = ""
    @Published public private(set) var sortOrder: SentenceLibrarySortOrder = .newestFirst
    @Published public private(set) var isWorking = false {
        didSet { publishStatusProjection() }
    }
    @Published public private(set) var operationProgress: SentenceLibraryOperationProgress? {
        didSet { publishStatusProjection() }
    }
    @Published public private(set) var lastErrorMessage: String? {
        didSet { publishStatusProjection() }
    }

    /// 由主窗口状态栏的小叉调用；仅关闭提示，不影响句库中的数据或后台任务。
    public func dismissErrorMessage() {
        lastErrorMessage = nil
    }

    private let store: SentenceLibraryStore
    private let defaults: UserDefaults
    private let currentLibraryKey = "StudyMate.CurrentSentenceLibraryID"
    private var searchText = ""
    private var dateFilter: SentenceLibraryDateFilter = .all
    private var selectedFilterDate = Date()
    private var queryTask: Task<Void, Never>?
    private var operationGeneration = UUID()

    private func publishStatusProjection() {
        SentenceLibraryStatusCenter.shared.update(
            isWorking: isWorking,
            operationProgress: operationProgress,
            errorMessage: lastErrorMessage
        )
    }

    public init(
        store: SentenceLibraryStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        publishStatusProjection()
        Self.cleanOrphanedTempFiles()
        Task { [weak self] in
            await self?.reloadLibraries(createDefaultIfNeeded: true)
        }
    }

    /// 清理 SentenceLibraryTemp 下超过 1 小时的孤立临时文件夹
    public static func cleanOrphanedTempFiles() {
        Task.detached(priority: .background) {
            let fileManager = FileManager.default
            guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let tempRoot = support
                .appendingPathComponent("StudyMate", isDirectory: true)
                .appendingPathComponent("SentenceLibraryTemp", isDirectory: true)
            guard fileManager.fileExists(atPath: tempRoot.path) else { return }

            guard let contents = try? fileManager.contentsOfDirectory(
                at: tempRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let now = Date()
            for folder in contents {
                if let attrs = try? folder.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate,
                   now.timeIntervalSince(modDate) > 3600 {
                    try? fileManager.removeItem(at: folder)
                }
            }
        }
    }

    public var currentLibrary: SentenceLibraryDescriptor? {
        libraries.first { $0.id == currentLibraryID }
    }

    public var canDeleteCurrentLibrary: Bool {
        guard let currentLibrary else { return false }
        return !currentLibrary.isDefault && !isWorking
    }

    public func createLibrary(name: String) async throws {
        do {
            let descriptor = try await Task.detached(priority: .utility) { [store] in
                try store.createLibrary(name: name)
            }.value
            await reloadLibraries(createDefaultIfNeeded: false)
            selectLibrary(descriptor.id)
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("句库“\(name)”创建成功", "Library “\(name)” created successfully")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
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
                .appendingPathComponent("StudyMate", isDirectory: true)
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
                let preview: Data?
                if let imageGenerator {
                    preview = await imageGenerator.jpegData(at: (segment.startTime + segment.endTime) / 2)
                } else {
                    preview = nil
                }
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
        MainStatusCenter.shared.showSuccess(
            LanguageManager.shared.text("已成功保存 \(prepared) 个句子到句库", "Successfully saved \(prepared) sentences to library")
        )
        return prepared
    }

    public func deleteEntries(ids: Set<UUID>) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        guard !ids.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let cleanupFailures = try await Task.detached(priority: .utility) { [store] in
                try store.deleteEntries(ids: ids, from: libraryID)
            }.value
            await reloadLibraries(createDefaultIfNeeded: false)
            reloadEntries()
            if !cleanupFailures.isEmpty {
                lastErrorMessage = "句子记录已删除，但部分文件未能清理：\(cleanupFailures.joined(separator: "、"))"
                MainStatusCenter.shared.showError(lastErrorMessage ?? "")
            } else {
                MainStatusCenter.shared.showSuccess(
                    LanguageManager.shared.text("已从句库删除 \(ids.count) 个句子", "Deleted \(ids.count) sentences from library")
                )
            }
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    public func deleteCurrentLibrary() async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        let libraryName = currentLibrary?.name ?? ""
        do {
            try await Task.detached(priority: .utility) { [store] in
                try store.deleteLibrary(id: libraryID)
            }.value
            currentLibraryID = nil
            await reloadLibraries(createDefaultIfNeeded: true)
            let msg = libraryName.isEmpty
                ? LanguageManager.shared.text("句库已删除", "Library deleted successfully")
                : LanguageManager.shared.text("句库“\(libraryName)”已删除", "Library “\(libraryName)” deleted successfully")
            MainStatusCenter.shared.showSuccess(msg)
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 将勾选的句子移动到另一个句库。目标句库收到独立媒体副本后，
    /// 源句库中的对应记录和文件才会被删除，播放不依赖原始媒体文件。
    public func moveEntries(ids: Set<UUID>, to destinationLibraryID: UUID) async throws {
        guard let sourceLibraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        guard !ids.isEmpty else { return }
        guard sourceLibraryID != destinationLibraryID else {
            throw SentenceLibraryError.database("源句库与目标句库不能相同。")
        }

        isWorking = true
        let generation = UUID()
        operationGeneration = generation
        operationProgress = SentenceLibraryOperationProgress(fraction: 0, phase: "准备移动句子")
        defer {
            if operationGeneration == generation {
                isWorking = false
                operationProgress = nil
            }
        }
        let report: @Sendable (Double, String) -> Void = { [weak self] fraction, phase in
            Task { @MainActor [weak self] in
                guard let self, self.operationGeneration == generation else { return }
                self.operationProgress = SentenceLibraryOperationProgress(fraction: fraction, phase: phase)
            }
        }

        do {
            let cleanupFailures = try await Task.detached(priority: .utility) { [store] in
                try store.moveEntries(
                    ids: ids,
                    from: sourceLibraryID,
                    to: destinationLibraryID,
                    progress: report
                )
            }.value
            await reloadLibraries(createDefaultIfNeeded: false)
            reloadEntries()
            if !cleanupFailures.isEmpty {
                lastErrorMessage = "句子已移动，但源句库部分文件未能清理：\(cleanupFailures.joined(separator: "、"))"
                MainStatusCenter.shared.showError(lastErrorMessage ?? "")
            } else {
                MainStatusCenter.shared.showSuccess(
                    LanguageManager.shared.text("已移动 \(ids.count) 个句子到目标句库", "Moved \(ids.count) sentences to destination library")
                )
            }
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
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
            if names.count == 1 { return names.first ?? "StudyMate" }
            return names.isEmpty ? "StudyMate" : "多个来源"
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

    func jpegData(at seconds: Double) async -> Data? {
        let safeTime = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            let result = try await generator.image(at: safeTime)
            let bitmap = NSBitmapImageRep(cgImage: result.image)
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78])
        } catch {
            return nil
        }
    }
}
