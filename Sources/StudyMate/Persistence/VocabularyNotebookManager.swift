import Foundation
import Combine

@MainActor
public final class VocabularyNotebookManager: ObservableObject {
    public static let shared = VocabularyNotebookManager()

    @Published public private(set) var notebooks: [VocabularyNotebookDescriptor] = []
    @Published public private(set) var currentNotebookID: UUID?
    @Published public private(set) var entries: [VocabularyWordEntry] = []
    @Published public private(set) var availableSources: [String] = []
    @Published public private(set) var selectedSource = ""
    @Published public private(set) var sortOrder: SentenceLibrarySortOrder = .newestFirst
    @Published public private(set) var isWorking = false
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var lastErrorMessage: String?

    private let store: VocabularyNotebookStore
    private let defaults: UserDefaults
    private let currentNotebookKey = "StudyMate.CurrentVocabularyNotebookID"
    private var searchText = ""
    private var dateFilter: SentenceLibraryDateFilter = .all
    private var selectedFilterDate = Date()
    private var queryTask: Task<Void, Never>?
    private var savedWordsTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var statusToken = UUID()
    @Published public private(set) var savedWordKeys: Set<String> = []

    public init(
        store: VocabularyNotebookStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        Task { [weak self] in
            await self?.reloadNotebooks(createDefaultIfNeeded: true)
        }
    }

    public var currentNotebook: VocabularyNotebookDescriptor? {
        notebooks.first { $0.id == currentNotebookID }
    }

    public var canDeleteCurrentNotebook: Bool {
        guard let currentNotebook else { return false }
        return !currentNotebook.isDefault && !isWorking
    }

    public func isWordSaved(_ word: String) -> Bool {
        savedWordKeys.contains(VocabularyNotebookStore.normalizedWord(word))
    }

    public func dismissErrorMessage() {
        lastErrorMessage = nil
    }

    public func createNotebook(name: String) async throws {
        isWorking = true
        defer { isWorking = false }
        do {
            let descriptor = try await Task.detached(priority: .utility) { [store] in
                try store.createNotebook(name: name)
            }.value
            await reloadNotebooks(createDefaultIfNeeded: false)
            selectNotebook(descriptor.id)
            publishSuccess("已创建生词本“" + descriptor.name + "”")
        } catch {
            publishFailure(error)
            throw error
        }
    }

    public func selectNotebook(_ id: UUID) {
        guard notebooks.contains(where: { $0.id == id }) else { return }
        currentNotebookID = id
        defaults.set(id.uuidString, forKey: currentNotebookKey)
        selectedSource = ""
        availableSources = []
        savedWordKeys = []
        reloadSources(for: id)
        reloadSavedWords(for: id)
        reloadEntries()
    }

    public func deleteCurrentNotebook() async throws {
        guard let notebook = currentNotebook else { throw VocabularyNotebookError.notebookUnavailable }
        guard !notebook.isDefault else { throw VocabularyNotebookError.defaultNotebookCannotBeDeleted }
        isWorking = true
        defer { isWorking = false }
        do {
            try await Task.detached(priority: .utility) { [store] in
                try store.deleteNotebook(id: notebook.id)
            }.value
            await reloadNotebooks(createDefaultIfNeeded: true)
            publishSuccess("已删除生词本“" + notebook.name + "”")
        } catch {
            publishFailure(error)
            throw error
        }
    }

    public func updateFilter(
        searchText: String,
        dateFilter: SentenceLibraryDateFilter,
        selectedDate: Date? = nil,
        source: String = "",
        sortOrder: SentenceLibrarySortOrder = .newestFirst
    ) {
        self.searchText = searchText
        self.dateFilter = dateFilter
        if let selectedDate { selectedFilterDate = selectedDate }
        selectedSource = source
        self.sortOrder = sortOrder
        reloadEntries(debounceNanoseconds: 150_000_000)
    }

    public func reloadEntries(debounceNanoseconds: UInt64 = 0) {
        queryTask?.cancel()
        guard let notebookID = currentNotebookID else {
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
            do {
                let result = try await Task.detached(priority: .utility) {
                    try store.entries(
                        notebookID: notebookID,
                        searchText: query,
                        createdAfter: lowerBound,
                        createdBefore: upperBound,
                        source: source,
                        sortOrder: order
                    )
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.currentNotebookID == notebookID,
                      self.searchText == query,
                      self.selectedSource == source,
                      self.sortOrder == order else { return }
                self.entries = result
                self.lastErrorMessage = nil
            } catch {
                guard !Task.isCancelled, let self, self.currentNotebookID == notebookID else { return }
                self.entries = []
                self.publishFailure(error)
            }
        }
    }

    @discardableResult
    public func toggleWord(
        word: String,
        exampleSentence: String = "",
        source: String = ""
    ) async throws -> Bool {
        if currentNotebookID == nil {
            await reloadNotebooks(createDefaultIfNeeded: true)
        }
        guard let notebookID = currentNotebookID else { throw VocabularyNotebookError.notebookUnavailable }
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { throw VocabularyNotebookError.emptyWord }
        isWorking = true
        defer { isWorking = false }
        do {
            let added = try await Task.detached(priority: .userInitiated) { [store] in
                if try store.contains(word: trimmedWord, in: notebookID) {
                    _ = try store.remove(word: trimmedWord, from: notebookID)
                    return false
                }
                _ = try store.add(
                    VocabularyWordEntry(
                        word: trimmedWord,
                        exampleSentence: exampleSentence,
                        source: source
                    ),
                    to: notebookID
                )
                return true
            }.value
            let wordKey = VocabularyNotebookStore.normalizedWord(trimmedWord)
            if added {
                savedWordKeys.insert(wordKey)
            } else {
                savedWordKeys.remove(wordKey)
            }
            await refreshAfterWrite(notebookID: notebookID)
            publishSuccess(added ? "已加入生词本" : "已从生词本移除")
            return added
        } catch {
            publishFailure(error)
            throw error
        }
    }

    @discardableResult
    public func deleteEntries(ids: Set<UUID>) async throws -> Int {
        guard let notebookID = currentNotebookID else { throw VocabularyNotebookError.notebookUnavailable }
        guard !ids.isEmpty else { return 0 }
        isWorking = true
        defer { isWorking = false }
        do {
            let count = try await Task.detached(priority: .userInitiated) { [store] in
                try store.deleteEntries(ids: ids, from: notebookID)
            }.value
            await refreshAfterWrite(notebookID: notebookID)
            publishSuccess("已删除 " + String(count) + " 个生词")
            return count
        } catch {
            publishFailure(error)
            throw error
        }
    }

    @discardableResult
    public func moveEntries(ids: Set<UUID>, to destinationNotebookID: UUID) async throws -> Int {
        guard let sourceNotebookID = currentNotebookID else { throw VocabularyNotebookError.notebookUnavailable }
        guard !ids.isEmpty else { return 0 }
        isWorking = true
        defer { isWorking = false }
        do {
            let count = try await Task.detached(priority: .userInitiated) { [store] in
                try store.moveEntries(
                    ids: ids,
                    from: sourceNotebookID,
                    to: destinationNotebookID
                )
            }.value
            await refreshAfterWrite(notebookID: sourceNotebookID)
            publishSuccess("已移动 " + String(count) + " 个生词")
            return count
        } catch {
            publishFailure(error)
            throw error
        }
    }

    private func reloadNotebooks(createDefaultIfNeeded: Bool) async {
        do {
            let available = try await Task.detached(priority: .utility) { [store] in
                var result = store.listNotebooks()
                if result.isEmpty, createDefaultIfNeeded {
                    result = [try store.createNotebook(name: VocabularyNotebookStore.defaultNotebookName)]
                }
                return result
            }.value
            notebooks = available
            let savedID = defaults.string(forKey: currentNotebookKey).flatMap(UUID.init(uuidString:))
            if let currentNotebookID, available.contains(where: { $0.id == currentNotebookID }) {
                // Keep the current selection when a write causes the list to reload.
            } else if let savedID, available.contains(where: { $0.id == savedID }) {
                currentNotebookID = savedID
            } else {
                currentNotebookID = available.first?.id
            }
            if let currentNotebookID {
                defaults.set(currentNotebookID.uuidString, forKey: currentNotebookKey)
                reloadSources(for: currentNotebookID)
                await reloadSavedWordsAndWait(for: currentNotebookID)
            } else {
                savedWordKeys = []
            }
            reloadEntries()
        } catch {
            publishFailure(error)
        }
    }

    private func reloadSources(for notebookID: UUID) {
        Task { [weak self, store] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try store.sourceNames(notebookID: notebookID)
                }.value
                guard let self, self.currentNotebookID == notebookID else { return }
                self.availableSources = result
                if !self.selectedSource.isEmpty, !result.contains(self.selectedSource) {
                    self.selectedSource = ""
                    self.reloadEntries()
                }
            } catch {
                guard let self, self.currentNotebookID == notebookID else { return }
                self.publishFailure(error)
            }
        }
    }

    private func reloadSavedWords(for notebookID: UUID) {
        savedWordsTask?.cancel()
        savedWordsTask = makeSavedWordsTask(for: notebookID)
    }

    private func reloadSavedWordsAndWait(for notebookID: UUID) async {
        savedWordsTask?.cancel()
        let task = makeSavedWordsTask(for: notebookID)
        savedWordsTask = task
        await task.value
    }

    private func makeSavedWordsTask(for notebookID: UUID) -> Task<Void, Never> {
        Task { [weak self, store] in
            do {
                let allEntries = try await Task.detached(priority: .utility) {
                    try store.entries(notebookID: notebookID, sortOrder: .newestFirst)
                }.value
                try Task.checkCancellation()
                guard let self, self.currentNotebookID == notebookID else { return }
                self.savedWordKeys = Set(allEntries.map { VocabularyNotebookStore.normalizedWord($0.word) })
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentNotebookID == notebookID else { return }
                self.publishFailure(error)
            }
        }
    }

    private func refreshAfterWrite(notebookID: UUID) async {
        guard currentNotebookID == notebookID else { return }
        reloadSources(for: notebookID)
        await reloadSavedWordsAndWait(for: notebookID)
        reloadEntries()
    }

    private func publishSuccess(_ message: String) {
        lastErrorMessage = nil
        statusMessage = message
        statusToken = UUID()
        let token = statusToken
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.statusToken == token else { return }
            self.statusMessage = nil
        }
        MainStatusCenter.shared.showSuccess(message)
    }

    private func publishFailure(_ error: Error) {
        let message = error.localizedDescription
        lastErrorMessage = message
        statusMessage = nil
        MainStatusCenter.shared.showError(message)
    }
}
