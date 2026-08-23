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

    private let nativeBackend: MediaPlayerBackend
    private var extendedBackend: MediaPlayerBackend?
    private var activeBackend: MediaPlayerBackend
    private var playbackGeneration = UUID()

    public convenience init() {
        self.init(nativeBackend: AVFoundationPlayerBackend())
    }

    public init(nativeBackend: MediaPlayerBackend) {
        self.nativeBackend = nativeBackend
        self.activeBackend = nativeBackend
        configureCallbacks(for: nativeBackend)
    }

    public func play(_ entry: SentenceLibraryEntry) {
        let sourceURL = URL(fileURLWithPath: entry.sourceMediaPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            stop()
            errorMessage = "找不到句子的来源媒体文件。"
            return
        }

        let generation = UUID()
        playbackGeneration = generation
        nativeBackend.pause()
        extendedBackend?.pause()
        currentEntry = entry
        duration = max(0.05, entry.endTime - entry.startTime)
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

    public func togglePlayback(for selectedEntry: SentenceLibraryEntry?) {
        guard let selectedEntry else { return }
        if currentEntry?.id != selectedEntry.id {
            play(selectedEntry)
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
        guard let entry = currentEntry else { return }
        let clamped = max(0, min(relativeTime, duration))
        currentTime = clamped
        activeBackend.seek(to: entry.startTime + clamped, completion: nil)
    }

    public func stop() {
        playbackGeneration = UUID()
        nativeBackend.pause()
        extendedBackend?.pause()
        currentEntry = nil
        currentTime = 0
        duration = 0
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
                    self.errorMessage = "无法解码这个句子的来源媒体文件。"
                }
                return
            }

            self.activeBackend = backend
            backend.seek(to: entry.startTime) { [weak self, weak backend] in
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
                  let entry = self.currentEntry,
                  absoluteTime.isFinite else { return }
            let relativeTime = max(0, absoluteTime - entry.startTime)
            self.currentTime = min(self.duration, relativeTime)
            if absoluteTime >= entry.endTime - 0.005 {
                backend.pause()
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
        backend.onStateChanged = { [weak self, weak backend] playing in
            guard let self, let backend, self.activeBackend === backend else { return }
            self.isPlaying = playing
        }
        backend.onFinished = { [weak self, weak backend] in
            guard let self, let backend, self.activeBackend === backend else { return }
            self.isPlaying = false
        }
        backend.onError = { [weak self, weak backend] _ in
            guard let self, let backend, self.activeBackend === backend else { return }
            self.isPlaying = false
            self.errorMessage = "播放这个句子时发生了解码错误。"
        }
    }
}
