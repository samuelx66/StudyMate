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
        nativeBackend.pause()
        extendedBackend?.pause()
        currentEntry = entry
        duration = max(0.05, entry.endTime - entry.startTime)
        playbackStartTime = 0
        playbackEndTime = playbackStartTime + duration
        handledEndGeneration = nil
        isRestartSeeking = false
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
        nativeBackend.pause()
        extendedBackend?.pause()
        currentEntry = nil
        currentTime = 0
        duration = 0
        playbackStartTime = 0
        playbackEndTime = 0
        handledEndGeneration = nil
        isRestartSeeking = false
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
                    self.errorMessage = "无法解码这个句库音频片段。"
                }
                return
            }

            self.activeBackend = backend
            backend.seek(to: self.playbackStartTime) { [weak self, weak backend] in
                Task { @MainActor [weak self, weak backend] in
                    guard let self,
                          let backend,
                          self.playbackGeneration == generation,
                          self.currentEntry?.id == entry.id,
                          self.activeBackend === backend else { return }
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
        extendedBackend = backend
        return backend
    }

    private func configureCallbacks(for backend: MediaPlayerBackend) {
        backend.onTimeUpdate = { [weak self, weak backend] absoluteTime, _ in
            guard let self,
                  let backend,
                  self.activeBackend === backend,
                  self.currentEntry != nil,
                  !self.isRestartSeeking,
                  absoluteTime.isFinite else { return }
            let relativeTime = max(0, absoluteTime - self.playbackStartTime)
            self.currentTime = min(self.duration, relativeTime)
            if absoluteTime >= self.playbackEndTime - 0.005 {
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
            guard !self.isRestartSeeking, self.currentTime >= self.duration - 0.05 else { return }
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
        activeBackend.pause()
        playbackStartTime = 0
        playbackEndTime = playbackStartTime + duration
        currentTime = 0
        activeBackend.seek(to: playbackStartTime) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentEntry?.id == entry.id else { return }
                self.isRestartSeeking = false
                self.activeBackend.play()
                self.isPlaying = true
            }
        }
    }
}
