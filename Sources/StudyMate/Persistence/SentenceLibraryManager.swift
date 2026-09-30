import Foundation
import AVFoundation
import AppKit
import NaturalLanguage
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

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

/// Keeps rapid inline edits in submission order. A field blur can start an
/// update immediately before the user presses Return in the next field; the
/// newest payload must never be overwritten by that earlier request.
private actor SentenceLibraryEntryUpdateQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let predecessor = tail
        let work = Task<Void, Error> {
            await predecessor?.value
            try await operation()
        }
        tail = Task<Void, Never> {
            _ = try? await work.value
        }
        try await work.value
    }
}

@MainActor
public final class SentenceLibraryManager: ObservableObject {
    public static let shared = SentenceLibraryManager()

    @Published public private(set) var libraries: [SentenceLibraryDescriptor] = []
    @Published public private(set) var currentLibraryID: UUID?
    @Published public private(set) var entries: [SentenceLibraryEntry] = []
    @Published public private(set) var availableSources: [String] = []
    @Published public private(set) var availableTags: [String] = []
    @Published public private(set) var selectedSource = ""
    @Published public private(set) var selectedTag: String? = nil
    @Published public private(set) var typeFilter: SentenceLibraryTypeFilter = .all
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
    private let entryUpdateQueue = SentenceLibraryEntryUpdateQueue()
    private let currentLibraryKey = "StudyMate.CurrentSentenceLibraryID"
    private var searchText = ""
    private var dateFilter: SentenceLibraryDateFilter = .all
    private var selectedFilterDate = Date()
    private var queryTask: Task<Void, Never>?
    private var entryQueryGeneration: UInt64 = 0
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
            let currentProcessID = ProcessInfo.processInfo.processIdentifier
            for folder in contents {
                let activeMarker = folder.appendingPathComponent(
                    ".active-\(currentProcessID)",
                    isDirectory: false
                )
                if fileManager.fileExists(atPath: activeMarker.path) { continue }
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
        guard !isWorking else { throw SentenceLibraryError.operationInProgress }
        isWorking = true
        defer { isWorking = false }
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
        availableTags = []
        selectedTag = nil
        reloadSources(for: id)
        reloadEntries()
    }

    public func updateFilter(
        searchText: String,
        dateFilter: SentenceLibraryDateFilter,
        selectedDate: Date? = nil,
        sourceMediaName: String = "",
        typeFilter: SentenceLibraryTypeFilter = .all,
        selectedTag: String? = nil,
        sortOrder: SentenceLibrarySortOrder = .newestFirst
    ) {
        self.searchText = searchText
        self.dateFilter = dateFilter
        if let selectedDate { selectedFilterDate = selectedDate }
        self.selectedSource = sourceMediaName
        self.typeFilter = typeFilter
        self.selectedTag = selectedTag
        self.sortOrder = sortOrder
        reloadEntries(debounceNanoseconds: 150_000_000)
    }

    public func setTypeFilter(_ filter: SentenceLibraryTypeFilter) {
        self.typeFilter = filter
        reloadEntries(debounceNanoseconds: 50_000_000)
    }

    public func setSelectedTag(_ tag: String?) {
        self.selectedTag = tag
        reloadEntries(debounceNanoseconds: 50_000_000)
    }

    public func setSortOrder(_ order: SentenceLibrarySortOrder) {
        self.sortOrder = order
        reloadEntries(debounceNanoseconds: 50_000_000)
    }

    public func reloadEntries(debounceNanoseconds: UInt64 = 0) {
        queryTask?.cancel()
        entryQueryGeneration &+= 1
        let generation = entryQueryGeneration
        guard let libraryID = currentLibraryID else {
            entries = []
            return
        }
        let query = searchText
        let filter = dateFilter
        let filterDate = selectedFilterDate
        let lowerBound = filter.lowerBound(selectedDate: filterDate)
        let upperBound = filter.upperBound(selectedDate: filterDate)
        let source = selectedSource
        let currentTypeFilter = typeFilter
        let tag = selectedTag
        let order = sortOrder
        queryTask = Task { [weak self, store] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let queryTypeFilter = currentTypeFilter == .withVocabularyOnly ? SentenceLibraryTypeFilter.all : currentTypeFilter
            let result = await Task.detached(priority: .utility) {
                Result {
                    try store.entries(
                        libraryID: libraryID,
                        searchText: query,
                        createdAfter: lowerBound,
                        createdBefore: upperBound,
                        sourceMediaName: source,
                        typeFilter: queryTypeFilter,
                        selectedTag: tag,
                        sortOrder: order
                    )
                }
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.entryQueryGeneration == generation,
                  self.currentLibraryID == libraryID,
                  self.searchText == query,
                  self.dateFilter.rawValue == filter.rawValue,
                  self.selectedFilterDate == filterDate,
                  self.selectedSource == source,
                  self.typeFilter == currentTypeFilter,
                  self.selectedTag == tag,
                  self.sortOrder == order else { return }
            switch result {
            case let .success(foundEntries):
                var synchronizedEntries = foundEntries
                var needsStoreUpdate: [UUID: [StudyMatePackageVocabularyCard]] = [:]
                let knownWords = PackageVocabularyService.shared.allKnownVocabularyWords()
                if !knownWords.isEmpty {
                    for i in 0..<synchronizedEntries.count {
                        let text = synchronizedEntries[i].originalText
                        let matched = PackageVocabularyService.shared.findMatchingVocabulary(for: text)
                        let currentWords = synchronizedEntries[i].associatedWords ?? []
                        if matched != currentWords {
                            synchronizedEntries[i].associatedWords = matched.isEmpty ? nil : matched
                            needsStoreUpdate[synchronizedEntries[i].id] = matched
                        }
                    }
                }
                if currentTypeFilter == .withVocabularyOnly {
                    self.entries = synchronizedEntries.filter { ($0.associatedWords?.isEmpty == false) }
                } else {
                    self.entries = synchronizedEntries
                }
                self.lastErrorMessage = nil
                if !needsStoreUpdate.isEmpty {
                    Task.detached(priority: .utility) { [store] in
                        try? store.batchUpdateAssociatedWords(needsStoreUpdate, in: libraryID)
                    }
                }
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

        // 检测视频画幅比例 (16:9 / 9:16)
        var detectedAspectRatio: String? = nil
        if sourceIsVideo {
            let asset = AVURLAsset(url: sourceURL)
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                if let size = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let transformedSize = size.applying(transform)
                    let w = abs(transformedSize.width)
                    let h = abs(transformedSize.height)
                    if w > 0 && h > 0 {
                        detectedAspectRatio = w >= h ? "16:9" : "9:16"
                    }
                }
            }
        }

        // 检测主要语种
        var detectedSourceLanguage: String? = nil
        let sampleText = ordered.prefix(5).map(\.text).joined(separator: " ")
        if !sampleText.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sampleText)
            if let dominant = recognizer.dominantLanguage {
                detectedSourceLanguage = dominant.rawValue
            }
        }

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
            let activeMarker = workDirectory.appendingPathComponent(
                ".active-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: false
            )
            try Data().write(to: activeMarker, options: .atomic)
            defer {
                try? fileManager.removeItem(at: activeMarker)
                try? fileManager.removeItem(at: workDirectory)
            }

            let exporter = SegmentMediaExporter()
            var entries: [SentenceLibraryEntry] = []
            var previews: [UUID: Data] = [:]
            var mediaURLs: [UUID: URL] = [:]
            var missingAlignmentTargets: [SentenceLibraryAlignmentTarget] = []
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

                // 语境快照
                let beforeText = offset > 0 ? ordered[offset - 1].text : nil
                let afterText = offset + 1 < ordered.count ? ordered[offset + 1].text : nil

                // 自动注音引擎
                let phonetic = PhoneticEngine.shared.phoneticText(for: segment.text)

                // 自动匹配关联生词
                let matchingVocab = PackageVocabularyService.shared.findMatchingVocabulary(for: segment.text)

                if segment.wordTokens == nil || segment.wordTokens?.isEmpty == true {
                    missingAlignmentTargets.append(SentenceLibraryAlignmentTarget(
                        segmentID: segment.id,
                        entryID: id,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        originalText: segment.text
                    ))
                }

                entries.append(SentenceLibraryEntry(
                    id: id,
                    originalIndex: (segment.originalIndex != nil && segment.originalIndex! > 0) ? segment.originalIndex! : segment.index,
                    originalText: segment.text,
                    translation: segment.translation,
                    phoneticText: phonetic,
                    note: segment.note,
                    isBookmarked: segment.isBookmarked,
                    tags: [],
                    associatedWords: matchingVocab.isEmpty ? nil : matchingVocab,
                    contextBefore: beforeText,
                    contextAfter: afterText,
                    sourceMediaName: sourceTitle,
                    sourceMediaPath: sourceURL.path,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    createdAt: timestamp,
                    mediaFilename: mediaFilename,
                    previewFilename: preview == nil ? nil : "\(id.uuidString).jpg",
                    speakerRole: segment.speakerRole,
                    speakerID: segment.speakerID,
                    speakerIDs: segment.speakerIDs,
                    isSpeakerOverlap: segment.isSpeakerOverlap,
                    wordTokens: segment.wordTokens,
                    shadowing: nil
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

            // 更新画幅与语言元数据
            try? store.updateMetadata(
                sourceLanguage: detectedSourceLanguage,
                targetLanguage: nil,
                videoAspectRatio: detectedAspectRatio,
                in: libraryID
            )

            return (count: entries.count, missingTargets: missingAlignmentTargets)
        }.value

        operationProgress = SentenceLibraryOperationProgress(fraction: 1, phase: "句库保存完成")
        await reloadLibraries(createDefaultIfNeeded: false)
        reloadSources(for: libraryID)
        reloadEntries()
        MainStatusCenter.shared.showSuccess(
            LanguageManager.shared.text("已成功保存 \(prepared.count) 个句子到句库", "Successfully saved \(prepared.count) sentences to library")
        )

        // 若存在缺少词级时间戳的句子，在后台静默发起 Whisper 自动对齐
        if !prepared.missingTargets.isEmpty {
            SentenceLibraryAlignmentService.shared.alignWordTokens(
                targets: prepared.missingTargets,
                audioURL: sourceURL,
                libraryID: libraryID
            )
        }

        return prepared.count
    }

    /// 星标难句切换
    public func toggleBookmark(id: UUID) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        do {
            let isBookmarked = try await Task.detached(priority: .userInitiated) { [store] in
                try store.toggleBookmark(id: id, in: libraryID)
            }.value
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].isBookmarked = isBookmarked
            }
            let msg = isBookmarked
                ? LanguageManager.shared.text("已加入星标难句", "Added to starred sentences")
                : LanguageManager.shared.text("已取消星标难句", "Removed from starred sentences")
            MainStatusCenter.shared.showSuccess(msg)
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 从播放会话同步更新内存中句子的星标难句状态
    public func setBookmarkFromPlayback(id: UUID, isBookmarked: Bool) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].isBookmarked = isBookmarked
        }
    }

    /// 更新单句的分类标签
    public func updateTags(id: UUID, tags: [String]) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        do {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.updateTags(id: id, tags: tags, in: libraryID)
            }.value
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].tags = tags
            }
            reloadSources(for: libraryID)
            if selectedTag != nil {
                reloadEntries()
            }
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("标签已更新", "Tags updated")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 批量为句子添加标签
    public func batchAddTags(to ids: Set<UUID>, tags: [String]) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        guard !ids.isEmpty, !tags.isEmpty else { return }
        do {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.batchAddTags(ids: ids, tags: tags, in: libraryID)
            }.value
            reloadSources(for: libraryID)
            reloadEntries()
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("已为 \(ids.count) 个句子添加标签", "Added tags to \(ids.count) sentences")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 批量覆盖设置句子标签
    public func batchSetTags(for ids: Set<UUID>, tags: [String]) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        guard !ids.isEmpty else { return }
        do {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.batchSetTags(ids: ids, tags: tags, in: libraryID)
            }.value
            reloadSources(for: libraryID)
            reloadEntries()
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("已更新 \(ids.count) 个句子的标签", "Updated tags for \(ids.count) sentences")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 更新单句的独立说话人角色显示
    public func updateSpeakerRole(id: UUID, speakerRole: String?) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        do {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.updateSpeakerRole(id: id, speakerRole: speakerRole, in: libraryID)
            }.value
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].speakerRole = speakerRole
            }
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("说话人角色已更新", "Speaker role updated")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 修改单句或同来源所有句子的来源名称
    public func updateSourceMediaName(
        entryID: UUID,
        oldSourceName: String,
        newSourceName: String,
        applyToAllWithSameSource: Bool
    ) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        let trimmedNew = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updatedCount = try await Task.detached(priority: .userInitiated) { [store] in
                try store.updateSourceMediaName(
                    entryID: entryID,
                    oldSourceName: oldSourceName,
                    newSourceName: trimmedNew,
                    applyToAllWithSameSource: applyToAllWithSameSource,
                    in: libraryID
                )
            }.value

            if selectedSource == oldSourceName && applyToAllWithSameSource {
                selectedSource = trimmedNew
            }
            reloadSources(for: libraryID)
            reloadEntries()

            let msg = LanguageManager.shared.text(
                "已成功更新 \(updatedCount) 个句子的来源名称",
                "Successfully updated source name for \(updatedCount) sentence(s)"
            )
            MainStatusCenter.shared.showSuccess(msg)
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 批量修改选定句子的来源名称
    public func batchUpdateSourceMediaName(
        for ids: Set<UUID>,
        newSourceName: String
    ) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        guard !ids.isEmpty else { return }
        let trimmedNew = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let count = try await Task.detached(priority: .userInitiated) { [store] in
                try store.batchUpdateSourceMediaName(ids: ids, newSourceName: trimmedNew, in: libraryID)
            }.value

            reloadSources(for: libraryID)
            reloadEntries()

            let msg = LanguageManager.shared.text(
                "已成功更新 \(count) 个句子的来源名称",
                "Successfully updated source name for \(count) sentence(s)"
            )
            MainStatusCenter.shared.showSuccess(msg)
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 说话人重命名与合并排重
    public func batchMergeSpeaker(
        sourceSpeakerID: Int,
        targetSpeakerID: Int,
        targetName: String?
    ) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        do {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.batchMergeSpeaker(
                    sourceSpeakerID: sourceSpeakerID,
                    targetSpeakerID: targetSpeakerID,
                    targetName: targetName,
                    in: libraryID
                )
            }.value
            await reloadLibraries(createDefaultIfNeeded: false)
            reloadEntries()
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("说话人已成功合并排重", "Speaker successfully merged and deduplicated")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 保存学习断点与复习状态
    public func updateSessionState(_ sessionState: StudyMatePackageSessionState) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        do {
            try await Task.detached(priority: .utility) { [store] in
                try store.updateSessionState(sessionState, in: libraryID)
            }.value
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
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
            reloadSources(for: libraryID)
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

    /// 保存句库中一条句子的原文和译文。编辑过程中由视图在字段失焦、
    /// 回车确认或点击完成时调用，成功与失败均通过主窗口状态栏反馈。
    public func updateEntry(
        id: UUID,
        originalText: String,
        translation: String
    ) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        do {
            let phonetic = PhoneticEngine.shared.phoneticText(for: originalText)
            try await entryUpdateQueue.enqueue { [store] in
                try await Task.detached(priority: .utility) {
                    try store.updateEntry(
                        id: id,
                        originalText: originalText,
                        translation: translation,
                        phoneticText: phonetic,
                        in: libraryID
                    )
                }.value
            }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].originalText = originalText
                entries[index].translation = translation
                entries[index].phoneticText = phonetic
            }
            await reloadLibraries(createDefaultIfNeeded: false)
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("句子原文和译文已保存", "Sentence text and translation saved")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 从播放学习会话同步更新句库条目的原文和译文。
    /// 无论当前句库视图停留在哪个句库，均能精确写回目标句库，并在主窗口状态栏显示操作结果。
    public func updateEntryFromPlayback(
        id: UUID,
        originalText: String,
        translation: String,
        sentenceIndex: Int? = nil,
        in libraryID: UUID
    ) async throws {
        do {
            let phonetic = PhoneticEngine.shared.phoneticText(for: originalText)
            try await entryUpdateQueue.enqueue { [store] in
                try await Task.detached(priority: .utility) {
                    try store.updateEntry(
                        id: id,
                        originalText: originalText,
                        translation: translation,
                        phoneticText: phonetic,
                        in: libraryID
                    )
                }.value
            }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].originalText = originalText
                entries[index].translation = translation
                entries[index].phoneticText = phonetic
            }
            await reloadLibraries(createDefaultIfNeeded: false)
            let successMessage: String
            if let sentenceIndex {
                successMessage = LanguageManager.shared.text(
                    "已将第 #\(sentenceIndex) 句修改同步至句库",
                    "Synced changes for sentence #\(sentenceIndex) to library"
                )
            } else {
                successMessage = LanguageManager.shared.text(
                    "已同步修改至句库",
                    "Synced changes to sentence library"
                )
            }
            MainStatusCenter.shared.showSuccess(successMessage)
        } catch {
            let errorText = LanguageManager.shared.text(
                "同步修改至句库失败: \(error.localizedDescription)",
                "Failed to sync changes to sentence library: \(error.localizedDescription)"
            )
            MainStatusCenter.shared.showError(errorText)
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
            reloadSources(for: sourceLibraryID)
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

    /// 将当前句库中筛选后可见的句子导出为 M4A 与 LRC
    public func exportEntries(
        _ entries: [SentenceLibraryEntry],
        merged: Bool,
        destinationURL: URL,
        progress: @escaping @Sendable (SegmentMediaExportProgress) -> Void = { _ in }
    ) async throws -> SegmentMediaExportResult {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
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

    /// 导出跨端原生学习包（.mablib 格式或压缩包）
    public func exportLearningPackage(
        _ entries: [SentenceLibraryEntry],
        destinationURL: URL
    ) async throws {
        guard let libraryID = currentLibraryID,
              let libraryTitle = currentLibrary?.name else {
            throw SentenceLibraryError.libraryUnavailable
        }
        guard !entries.isEmpty else { throw SentenceLibraryError.database("没有可导出的句子。") }
        guard !isWorking else { throw SentenceLibraryError.operationInProgress }
        isWorking = true
        let generation = UUID()
        operationGeneration = generation
        operationProgress = SentenceLibraryOperationProgress(fraction: 0, phase: "生成学习包")
        defer {
            if operationGeneration == generation {
                isWorking = false
                operationProgress = nil
            }
        }
        do {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.writeLearningPackage(
                    entries: entries,
                    libraryID: libraryID,
                    libraryTitle: libraryTitle,
                    destinationURL: destinationURL
                )
            }.value
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text("学习包已导出", "Learning package exported")
            )
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    /// 将移动端返回的学习包落入当前句库，并按稳定句子 ID 处理新增、更新和幂等重复。
    @discardableResult
    public func importLearningPackage(from packageURL: URL) async throws -> StudyMateLearningPackageImportReport {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        guard !isWorking else { throw SentenceLibraryError.operationInProgress }
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try await Task.detached(priority: .userInitiated) { [store] in
                try store.importLearningPackage(from: packageURL, into: libraryID)
            }.value
            await reloadLibraries(createDefaultIfNeeded: false)
            reloadSources(for: libraryID)
            reloadEntries()
            MainStatusCenter.shared.showSuccess(
                LanguageManager.shared.text(
                    "学习包已导入：新增 \(report.added)，更新 \(report.updated)，跳过 \(report.skipped)",
                    "Package imported: \(report.added) added, \(report.updated) updated, \(report.skipped) skipped"
                )
            )
            return report
        } catch {
            MainStatusCenter.shared.showError(error.localizedDescription)
            throw error
        }
    }

    private func reloadLibraries(createDefaultIfNeeded: Bool) async {
        let available: [SentenceLibraryDescriptor]
        do {
            available = try await Task.detached(priority: .utility) { [store] in
                var result = store.listLibraries()
                if result.isEmpty, createDefaultIfNeeded {
                    result = [try store.createLibrary(name: "默认句库")]
                }
                return result
            }.value
        } catch {
            libraries = []
            currentLibraryID = nil
            entries = []
            availableSources = []
            availableTags = []
            lastErrorMessage = error.localizedDescription
            MainStatusCenter.shared.showError(error.localizedDescription)
            return
        }
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
            do {
                let sources = try await Task.detached(priority: .utility) {
                    try store.sourceMediaNames(libraryID: libraryID)
                }.value
                let tags = try await Task.detached(priority: .utility) {
                    try store.allTags(libraryID: libraryID)
                }.value
                guard let self, self.currentLibraryID == libraryID else { return }
                self.availableSources = sources
                self.availableTags = tags
                if !self.selectedSource.isEmpty, !sources.contains(self.selectedSource) {
                    self.selectedSource = ""
                    self.reloadEntries()
                }
                if let tag = self.selectedTag, !tags.contains(tag) {
                    self.selectedTag = nil
                    self.reloadEntries()
                }
            } catch {
                guard let self, self.currentLibraryID == libraryID else { return }
                self.lastErrorMessage = error.localizedDescription
                MainStatusCenter.shared.showError(error.localizedDescription)
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
