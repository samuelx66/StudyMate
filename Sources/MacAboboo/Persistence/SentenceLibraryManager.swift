import Foundation
import AVFoundation
import AppKit

@MainActor
public final class SentenceLibraryManager: ObservableObject {
    public static let shared = SentenceLibraryManager()

    @Published public private(set) var libraries: [SentenceLibraryDescriptor] = []
    @Published public private(set) var currentLibraryID: UUID?
    @Published public private(set) var entries: [SentenceLibraryEntry] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var lastErrorMessage: String?

    private let store: SentenceLibraryStore
    private let defaults: UserDefaults
    private let currentLibraryKey = "MacAboboo.CurrentSentenceLibraryID"
    private var searchText = ""
    private var dateFilter: SentenceLibraryDateFilter = .all
    private var selectedFilterDate = Date()
    private var queryTask: Task<Void, Never>?

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
        reloadEntries()
    }

    public func updateFilter(
        searchText: String,
        dateFilter: SentenceLibraryDateFilter,
        selectedDate: Date? = nil
    ) {
        self.searchText = searchText
        self.dateFilter = dateFilter
        if let selectedDate { selectedFilterDate = selectedDate }
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
                        createdBefore: upperBound
                    )
                }
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.currentLibraryID == libraryID,
                  self.searchText == query else { return }
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
        defer { isWorking = false }

        let timestamp = Date()
        let ordered = segments.sorted {
            if $0.startTime == $1.startTime { return $0.index < $1.index }
            return $0.startTime < $1.startTime
        }
        let prepared = try await Task.detached(priority: .userInitiated) {
            var entries: [SentenceLibraryEntry] = []
            var previews: [UUID: Data] = [:]
            let imageGenerator = media.isVideo ? SentencePreviewGenerator(mediaURL: media.url) : nil
            for segment in ordered {
                try Task.checkCancellation()
                let id = UUID()
                let preview = imageGenerator?.jpegData(at: (segment.startTime + segment.endTime) / 2)
                if let preview { previews[id] = preview }
                entries.append(SentenceLibraryEntry(
                    id: id,
                    originalText: segment.text,
                    translation: segment.translation,
                    note: segment.note,
                    sourceMediaName: media.title,
                    sourceMediaPath: media.url.path,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    createdAt: timestamp,
                    previewFilename: preview == nil ? nil : "\(id.uuidString).jpg"
                ))
            }
            return (entries, previews)
        }.value

        try await Task.detached(priority: .utility) { [store] in
            try store.add(entries: prepared.0, previewData: prepared.1, to: libraryID)
        }.value
        await reloadLibraries(createDefaultIfNeeded: false)
        reloadEntries()
        return prepared.0.count
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

    public func exportCurrentLibrary(to destinationURL: URL) async throws {
        guard let libraryID = currentLibraryID else { throw SentenceLibraryError.libraryUnavailable }
        isWorking = true
        defer { isWorking = false }
        try await Task.detached(priority: .utility) { [store] in
            try store.exportLibrary(id: libraryID, to: destinationURL)
        }.value
    }

    public func importLibrary(from sourceURL: URL) async throws {
        isWorking = true
        defer { isWorking = false }
        let descriptor = try await Task.detached(priority: .utility) { [store] in
            try store.importLibrary(from: sourceURL)
        }.value
        await reloadLibraries(createDefaultIfNeeded: false)
        selectLibrary(descriptor.id)
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
        }
        reloadEntries()
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
