import Foundation

/// 句库窗口使用独立播放器，避免试听句库内容时替换主窗口当前工程。
/// 原生解码失败时才按需启用扩展解码，兼顾资源占用和媒体兼容性。
@MainActor
public final class SentenceLibraryPlayer: ObservableObject {
    @Published public private(set) var currentEntry: SentenceLibraryEntry?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime = 0.0
    @Published public private(set) var duration = 0.0
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var playbackMode: SentenceLibraryPlaybackMode = .single

    private let nativeBackend: MediaPlayerBackend
    private var extendedBackend: MediaPlayerBackend?
    private var activeBackend: MediaPlayerBackend
    private var playbackGeneration = UUID()
    private var playbackStartTime = 0.0
    private var playbackEndTime = 0.0
    private var playlist: [PlaylistItem] = []
    private var handledEndGeneration: UUID?
    private var isRestartSeeking = false
    /// Reject late clock/end events while the next independent clip is being
    /// loaded and seeks to zero. Without this gate a previous clip's final
    /// event can advance an all-loop playlist twice.
    private var isLoadingEntry = false
    private var loadTask: Task<Void, Never>?

    private struct PlaylistItem {
        let entry: SentenceLibraryEntry
        let mediaURL: URL?
    }

    public convenience init() {
        self.init(nativeBackend: AVFoundationPlayerBackend())
    }

    public init(nativeBackend: MediaPlayerBackend) {
        self.nativeBackend = nativeBackend
        self.activeBackend = nativeBackend
        configureCallbacks(for: nativeBackend)
        // The playback bar does not need 60 published updates per second.
        // Boundary handling remains on the independent high-frequency clock.
        nativeBackend.setHighFrequencyPresentationEnabled(false)
    }

    public func setPlaylist(entries: [SentenceLibraryEntry], mediaURLs: [UUID: URL]) {
        playlist = entries.map { PlaylistItem(entry: $0, mediaURL: mediaURLs[$0.id]) }
        if let currentEntry,
           !playlist.contains(where: { $0.entry.id == currentEntry.id }) {
            stop()
        }
    }

    public func setPlaybackMode(_ mode: SentenceLibraryPlaybackMode) {
        playbackMode = mode
    }

    public func play(_ entry: SentenceLibraryEntry, mediaURL: URL? = nil) {
        guard let sourceURL = mediaURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            stop()
            errorMessage = "找不到句库中的独立音频片段。"
            return
        }

        let generation = UUID()
        playbackGeneration = generation
        loadTask?.cancel()
        nativeBackend.pause()
        extendedBackend?.pause()
        currentEntry = entry
        duration = max(0.05, entry.endTime - entry.startTime)
        playbackStartTime = 0
        playbackEndTime = playbackStartTime + duration
        handledEndGeneration = nil
        isRestartSeeking = false
        isLoadingEntry = true
        currentTime = 0
        errorMessage = nil
        isPlaying = false

        loadAndPlay(
            entry: entry,
            sourceURL: sourceURL,
            backend: nativeBackend,
            generation: generation,
            mayUseExtendedFallback: true
        )
    }

    public func togglePlayback(for selectedEntry: SentenceLibraryEntry?, mediaURL: URL? = nil) {
        guard let selectedEntry else { return }
        if currentEntry?.id != selectedEntry.id {
            play(selectedEntry, mediaURL: mediaURL)
        } else if isPlaying {
            activeBackend.pause()
            isPlaying = false
        } else if currentTime >= duration - 0.01 {
            seek(to: 0)
            activeBackend.play()
            isPlaying = true
        } else {
            activeBackend.play()
            isPlaying = true
        }
    }

    public func seek(to relativeTime: Double) {
        guard currentEntry != nil else { return }
        let clamped = max(0, min(relativeTime, duration))
        currentTime = clamped
        activeBackend.seek(to: playbackStartTime + clamped, completion: nil)
    }

    public func stop() {
        playbackGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        nativeBackend.pause()
        extendedBackend?.pause()
        currentEntry = nil
        currentTime = 0
        duration = 0
        playbackStartTime = 0
        playbackEndTime = 0
        handledEndGeneration = nil
        isRestartSeeking = false
        isLoadingEntry = false
        isPlaying = false
        errorMessage = nil
    }

    private func loadAndPlay(
        entry: SentenceLibraryEntry,
        sourceURL: URL,
        backend: MediaPlayerBackend,
        generation: UUID,
        mayUseExtendedFallback: Bool
    ) {
        backend.load(url: sourceURL) { [weak self, weak backend] loaded in
            guard let self,
                  let backend,
                  self.playbackGeneration == generation,
                  self.currentEntry?.id == entry.id else { return }

            guard loaded else {
                if mayUseExtendedFallback, let fallback = self.makeExtendedBackendIfAvailable() {
                    self.loadAndPlay(
                        entry: entry,
                        sourceURL: sourceURL,
                        backend: fallback,
                        generation: generation,
                        mayUseExtendedFallback: false
                    )
                } else {
                    self.isLoadingEntry = false
                    self.errorMessage = "无法解码这个句库音频片段。"
                }
                return
            }

            self.activeBackend = backend
            self.synchronizePlaybackEnd(with: backend)
            backend.seek(to: self.playbackStartTime) { [weak self, weak backend] in
                Task { @MainActor [weak self, weak backend] in
                    guard let self,
                          let backend,
                          self.playbackGeneration == generation,
                          self.currentEntry?.id == entry.id,
                          self.activeBackend === backend else { return }
                    self.isLoadingEntry = false
                    backend.play()
                    self.isPlaying = true
                }
            }
        }
    }

    private func makeExtendedBackendIfAvailable() -> MediaPlayerBackend? {
        if let extendedBackend { return extendedBackend.isAvailable ? extendedBackend : nil }
        let backend = MPVPlayerBackend()
        guard backend.isAvailable else {
            backend.teardown()
            return nil
        }
        configureCallbacks(for: backend)
        backend.setHighFrequencyPresentationEnabled(false)
        extendedBackend = backend
        return backend
    }

    private func configureCallbacks(for backend: MediaPlayerBackend) {
        backend.onTimeUpdate = { [weak self, weak backend] absoluteTime, _ in
            guard let self,
                  let backend,
                  self.activeBackend === backend,
                  self.currentEntry != nil,
                  !self.isLoadingEntry,
                  !self.isRestartSeeking,
                  absoluteTime.isFinite else { return }
            let relativeTime = max(0, absoluteTime - self.playbackStartTime)
            self.currentTime = min(self.duration, relativeTime)
            if backend.supportsIndependentBoundaryTimeUpdates == false,
               self.hasReachedPlaybackEnd(backend: backend, absoluteTime: absoluteTime) {
                backend.pause()
                self.currentTime = self.duration
                self.handleCurrentEntryFinished()
            }
        }
        backend.onBoundaryTimeUpdate = { [weak self, weak backend] absoluteTime, _ in
            guard let self,
                  let backend,
                  self.activeBackend === backend,
                  self.currentEntry != nil,
                  !self.isLoadingEntry,
                  !self.isRestartSeeking,
                  absoluteTime.isFinite else { return }
            if self.hasReachedPlaybackEnd(backend: backend, absoluteTime: absoluteTime) {
                backend.pause()
                self.currentTime = self.duration
                self.handleCurrentEntryFinished()
            }
        }
        backend.onStateChanged = { [weak self, weak backend] playing in
            guard let self, let backend, self.activeBackend === backend else { return }
            self.isPlaying = playing
        }
        backend.onFinished = { [weak self, weak backend] in
            guard let self, let backend, self.activeBackend === backend else { return }
            // AVPlayer/MPV's end notification is authoritative for the
            // currently loaded item. Do not require a final periodic time
            // tick here: the callback can arrive before the backend's cached
            // currentTime reaches the duration, especially for short AAC
            // clips. Backend generations and the loading gate reject stale
            // callbacks from the previous item.
            guard !self.isLoadingEntry, !self.isRestartSeeking else { return }
            self.currentTime = self.duration
            self.handleCurrentEntryFinished()
        }
        backend.onError = { [weak self, weak backend] _ in
            guard let self, let backend, self.activeBackend === backend else { return }
            self.isPlaying = false
            self.errorMessage = "播放这个句子时发生了解码错误。"
        }
    }

    private func handleCurrentEntryFinished() {
        guard let currentEntry else {
            isPlaying = false
            return
        }
        let generation = playbackGeneration
        guard handledEndGeneration != generation else { return }
        handledEndGeneration = generation

        switch playbackMode {
        case .single:
            isPlaying = false
        case .singleLoop:
            restartCurrentEntry(entry: currentEntry)
        case .allLoop:
            guard !playlist.isEmpty,
                  let index = playlist.firstIndex(where: { $0.entry.id == currentEntry.id }) else {
                restartCurrentEntry(entry: currentEntry)
                return
            }
            let next = playlist[(index + 1) % playlist.count]
            play(next.entry, mediaURL: next.mediaURL)
        }
    }

    private func restartCurrentEntry(entry: SentenceLibraryEntry) {
        guard let sourceURL = playlist.first(where: { $0.entry.id == entry.id })?.mediaURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            isPlaying = false
            errorMessage = "找不到句库中的独立音频片段。"
            return
        }
        let generation = UUID()
        playbackGeneration = generation
        handledEndGeneration = nil
        isRestartSeeking = true
        isLoadingEntry = true
        activeBackend.pause()
        playbackStartTime = 0
        playbackEndTime = playbackStartTime + duration
        synchronizePlaybackEnd(with: activeBackend)
        currentTime = 0
        activeBackend.seek(to: playbackStartTime) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentEntry?.id == entry.id else { return }
                self.isLoadingEntry = false
                self.isRestartSeeking = false
                self.activeBackend.play()
                self.isPlaying = true
            }
        }
    }

    /// The sentence duration comes from the original project timestamp, while
    /// a self-contained AAC clip may expose a slightly different duration
    /// after decoding (encoder delay/padding and container rounding).  Keep
    /// the public sentence duration stable, but use the shorter real media
    /// duration as the playback boundary when it is available.
    private func synchronizePlaybackEnd(with backend: MediaPlayerBackend) {
        let backendDuration = backend.duration
        guard backendDuration.isFinite, backendDuration > 0 else { return }
        let requestedEnd = playbackStartTime + duration
        playbackEndTime = min(requestedEnd, playbackStartTime + backendDuration)
    }

    private func effectivePlaybackEnd(for backend: MediaPlayerBackend) -> Double {
        let backendDuration = backend.duration
        guard backendDuration.isFinite, backendDuration > 0 else {
            return playbackEndTime
        }
        return min(playbackEndTime, playbackStartTime + backendDuration)
    }

    private func hasReachedPlaybackEnd(
        backend: MediaPlayerBackend,
        absoluteTime: Double? = nil
    ) -> Bool {
        let end = effectivePlaybackEnd(for: backend)
        guard end.isFinite else { return false }

        // A small, duration-aware tolerance absorbs frame quantisation and AAC
        // priming without making a normal pause near the sentence end look
        // like an end event.  The backend's current position is preferred for
        // end notifications because the published UI position is throttled.
        let observedTime = max(
            absoluteTime ?? -.infinity,
            backend.currentTime
        )
        guard observedTime.isFinite else { return false }
        let tolerance = min(0.15, max(0.04, duration * 0.1))
        return observedTime >= end - tolerance
    }
}
