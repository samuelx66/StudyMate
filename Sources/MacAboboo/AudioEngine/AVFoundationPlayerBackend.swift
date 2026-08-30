import Foundation
import AVFoundation
import AVKit
import AppKit

/// Apple 原生高性能硬件直通多媒体播放后端（支持 0ms 瞬间秒跳、原生 AVPlayerView 高清 Metal 渲染、timeDomain 变速不变调）
@MainActor
public final class AVFoundationPlayerBackend: NSObject, MediaPlayerBackend {
    public let isAvailable: Bool = true
    public private(set) var loadedURL: URL?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: Double = 0.0
    public private(set) var duration: Double = 0.0
    
    public var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying {
                player.rate = playbackRate
            }
        }
    }
    
    public var volume: Float = 1.0 {
        didSet {
            player.volume = volume
        }
    }
    
    public var playerView: NSView {
        return avPlayerView
    }
    
    public var onTimeUpdate: (@MainActor (Double, Double) -> Void)?
    public var onBoundaryTimeUpdate: (@MainActor (Double, Double) -> Void)?
    public let supportsIndependentBoundaryTimeUpdates = true
    public var onStateChanged: (@MainActor (Bool) -> Void)?
    public var onFinished: (@MainActor () -> Void)?
    public var onError: (@MainActor (Error) -> Void)?
    
    private let player = AVPlayer()
    private let avPlayerView: AVPlayerView = {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.showsFrameSteppingButtons = false
        return view
    }()
    
    private var timeObserverToken: Any?
    private var itemEndObserver: Any?
    private var itemFailObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var isSeekingInternal = false
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var seekGeneration: UInt64 = 0
    /// Exact AVPlayer seeks can fail for a valid compressed file when the
    /// target falls on an awkward sample/edit-list boundary. Keep the exact
    /// path first, then retry with a small and finally a broad tolerance so a
    /// sentence never becomes unplayable just because its generated start
    /// time is not a key frame.
    private var seekFallbackAttempt = 0
    private var seekRecoveryTask: Task<Void, Never>?
    private var highFrequencyPresentationEnabled = true
    private var presentationTick: UInt64 = 0
    
    public override init() {
        super.init()
        avPlayerView.player = player
        player.volume = volume
        player.isMuted = false
        setupTimeObserver()
        setupTimeControlObservation()
    }
    
    public func load(url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        loadTask?.cancel()
        loadGeneration = UUID()
        seekGeneration &+= 1
        seekRecoveryTask?.cancel()
        seekRecoveryTask = nil
        isSeekingInternal = false
        let generation = loadGeneration
        teardownItemObservations()
        setupTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 预检视频轨是否被原生 AVFoundation 硬件/软件解码器支持（例如 4K AV1 / 非标编码）
            do {
                let assetPlayable = try await asset.load(.isPlayable)
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                guard assetPlayable else {
                    completion(false)
                    return
                }

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                var hasUnplayableTrack = false
                for track in videoTracks {
                    let isPlayable = try await track.load(.isPlayable)
                    if !isPlayable {
                        hasUnplayableTrack = true
                        break
                    }
                }
                
                if hasUnplayableTrack {
                    print("[PlaybackEngine] Video track uses advanced codec (e.g. AV1), delegating to libmpv...")
                    guard !Task.isCancelled, generation == self.loadGeneration else { return }
                    completion(false)
                    return
                }
            } catch {
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                completion(false)
                return
            }

            let loadedDuration: Double
            if let durationTime = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(durationTime)
                loadedDuration = seconds.isFinite && seconds > 0 ? seconds : 0
            } else {
                loadedDuration = 0
            }

            guard !Task.isCancelled, generation == self.loadGeneration else { return }

            let item = AVPlayerItem(asset: asset)
                
            // 配置最高保真度的声音变速变调算法 (0.5x ~ 2.0x 声音极其纯净，无电音/杂音)
            item.audioTimePitchAlgorithm = .spectral
                
            self.statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self, weak item] playerItem, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self,
                          let item,
                          item === playerItem,
                          generation == self.loadGeneration else { return }
                    switch playerItem.status {
                    case .readyToPlay:
                        let itemDuration = CMTimeGetSeconds(playerItem.duration)
                        self.duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : loadedDuration
                        self.loadedURL = url
                        self.statusObservation?.invalidate()
                        self.statusObservation = nil
                        completion(true)
                    case .failed:
                        self.statusObservation?.invalidate()
                        self.statusObservation = nil
                        completion(false)
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
                
            self.itemEndObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              generation == self.loadGeneration,
                              self.player.currentItem === item else { return }
                        self.isPlaying = false
                        self.onStateChanged?(false)
                        self.onFinished?()
                    }
                }
                
            self.itemFailObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] notif in
                    Task { @MainActor [weak self] in
                        guard let self,
                              generation == self.loadGeneration,
                              self.player.currentItem === item else { return }
                        self.isPlaying = false
                        self.onStateChanged?(false)
                        let error = (notif.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) ?? NSError(domain: "AVFoundationPlayerBackend", code: -2, userInfo: nil)
                        self.onError?(error)
                    }
                }
                
            self.player.replaceCurrentItem(with: item)
            self.player.volume = self.volume
            self.player.isMuted = false
            self.currentTime = 0.0
        }
    }
    
    public func play() {
        guard player.currentItem?.status == .readyToPlay else { return }
        // Setting `rate` alone can leave AVPlayer in a paused/waiting state
        // after a precise seek. `playImmediately` explicitly resumes the
        // current item and is still hardware accelerated for native media.
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
        onStateChanged?(true)
    }
    
    public func pause() {
        player.pause()
        isPlaying = false
        onStateChanged?(false)
    }
    
    public func stop() {
        pause()
        seek(to: 0.0, completion: nil)
    }
    
    /// 尽量精确地定位到目标时间，并为 AVPlayer 的压缩媒体寻址失败提供
    /// 两级回退。首选零容差，不牺牲断句时间轴精度；只有系统无法在该
    /// 时间点完成精确寻址时，才允许一个很小的帧级误差，最后才使用
    /// 宽容差定位到最近可解码点。
    public func seek(to seconds: Double, completion: (@Sendable () -> Void)?) {
        let clamped = max(0, min(seconds, max(0.1, duration)))
        let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)

        seekRecoveryTask?.cancel()
        seekRecoveryTask = nil
        isSeekingInternal = true
        seekFallbackAttempt = 0
        currentTime = clamped
        seekGeneration &+= 1
        let generation = seekGeneration

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.seekGeneration,
                      self.seekFallbackAttempt == 0 else { return }
                if finished {
                    self.finishSeek(
                        generation: generation,
                        at: clamped,
                        completion: completion
                    )
                } else {
                    self.beginSeekFallback(
                        generation: generation,
                        target: targetTime,
                        at: clamped,
                        completion: completion
                    )
                }
            }
        }

        // A valid inter-frame seek can take a few hundred milliseconds. Give
        // the zero-tolerance request time to finish before replacing it with
        // a tolerant fallback; otherwise a slow-but-correct seek loses its
        // requested sentence boundary on complex MP4 files.
        seekRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard generation == self.seekGeneration, self.isSeekingInternal else { return }
            self.beginSeekFallback(
                generation: generation,
                target: targetTime,
                at: clamped,
                completion: completion
            )

            try? await Task.sleep(nanoseconds: 500_000_000)
            guard generation == self.seekGeneration, self.isSeekingInternal else { return }
            self.beginSeekFallback(
                generation: generation,
                target: targetTime,
                at: clamped,
                completion: completion
            )

            try? await Task.sleep(nanoseconds: 500_000_000)
            guard generation == self.seekGeneration, self.isSeekingInternal else { return }
            // Do not hold the engine in a seeking state forever if AVPlayer
            // loses every callback. The player has still been asked to seek
            // and the next time observer update will provide the real time.
            self.finishSeek(
                generation: generation,
                at: clamped,
                completion: completion
            )
        }
    }

    /// Lightweight timeline preview.  It deliberately skips the exact-seek
    /// recovery chain: another preview or the final exact seek will supersede
    /// it, which keeps rapid slider movement from building a seek backlog.
    public func previewSeek(to seconds: Double) {
        guard player.currentItem?.status == .readyToPlay else { return }
        let clamped = max(0, min(seconds, max(0.1, duration)))
        let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)

        seekRecoveryTask?.cancel()
        seekRecoveryTask = nil
        isSeekingInternal = true
        seekGeneration &+= 1
        let generation = seekGeneration
        player.seek(
            to: targetTime,
            toleranceBefore: CMTime(seconds: 0.08, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.08, preferredTimescale: 600)
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.seekGeneration else { return }
                self.isSeekingInternal = false
                let actualTime = CMTimeGetSeconds(self.player.currentTime())
                self.currentTime = actualTime.isFinite && actualTime >= 0 ? actualTime : clamped
            }
        }
    }

    private func beginSeekFallback(
        generation: UInt64,
        target: CMTime,
        at clamped: Double,
        completion: (@Sendable () -> Void)?
    ) {
        guard generation == seekGeneration,
              isSeekingInternal,
              seekFallbackAttempt < 2 else { return }

        seekFallbackAttempt += 1
        let attempt = seekFallbackAttempt
        let tolerance: CMTime = attempt == 1
            ? CMTime(seconds: 0.12, preferredTimescale: 600)
            : .positiveInfinity

        player.seek(
            to: target,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.seekGeneration,
                      self.isSeekingInternal,
                      self.seekFallbackAttempt == attempt else { return }

                if finished || attempt >= 2 {
                    self.finishSeek(
                        generation: generation,
                        at: clamped,
                        completion: completion
                    )
                } else {
                    self.beginSeekFallback(
                        generation: generation,
                        target: target,
                        at: clamped,
                        completion: completion
                    )
                }
            }
        }
    }

    private func finishSeek(
        generation: UInt64,
        at clamped: Double,
        completion: (@Sendable () -> Void)?
    ) {
        guard generation == seekGeneration, isSeekingInternal else { return }
        seekRecoveryTask?.cancel()
        seekRecoveryTask = nil
        isSeekingInternal = false
        // AVPlayer can reject a non-keyframe seek while still invoking a
        // fallback completion. Publish the decoder's real position instead of
        // claiming that the requested timestamp was reached.
        let actualTime = CMTimeGetSeconds(player.currentTime())
        currentTime = actualTime.isFinite && actualTime >= 0 ? actualTime : clamped
        if isPlaying {
            player.playImmediately(atRate: playbackRate)
        }
        completion?()
    }
    
    public func teardown() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration = UUID()
        seekGeneration &+= 1
        seekRecoveryTask?.cancel()
        seekRecoveryTask = nil
        isSeekingInternal = false
        teardownItemObservations()
        teardownTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }
    
    private func setupTimeObserver() {
        guard timeObserverToken == nil else { return }
        let interval = CMTime(value: 1, timescale: 60) // 60fps 平滑时间回调
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, !self.isSeekingInternal else { return }
                let current = CMTimeGetSeconds(time)
                if current >= 0, !current.isNaN {
                    let total = self.duration
                    self.onBoundaryTimeUpdate?(current, total)
                    self.presentationTick &+= 1
                    if self.highFrequencyPresentationEnabled || self.presentationTick % 4 == 0 {
                        self.currentTime = current
                        self.onTimeUpdate?(current, total)
                    }
                }
            }
        }
    }

    public func setHighFrequencyPresentationEnabled(_ enabled: Bool) {
        highFrequencyPresentationEnabled = enabled
    }

    private func setupTimeControlObservation() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // AVPlayer briefly reports `.paused` while it resolves a
                // precise seek. Exposing that transient state would make the
                // engine mark a sentence as stopped and race the seek
                // completion that resumes playback.
                guard !self.isSeekingInternal else { return }
                let playing = player.timeControlStatus != .paused
                if self.isPlaying != playing {
                    self.isPlaying = playing
                    self.onStateChanged?(playing)
                }
            }
        }
    }
    
    private func teardownTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
    
    private func teardownItemObservations() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObs = itemEndObserver {
            NotificationCenter.default.removeObserver(endObs)
            itemEndObserver = nil
        }
        if let failObs = itemFailObserver {
            NotificationCenter.default.removeObserver(failObs)
            itemFailObserver = nil
        }
    }

    deinit {
        loadTask?.cancel()
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let endObs = itemEndObserver {
            NotificationCenter.default.removeObserver(endObs)
        }
        if let failObs = itemFailObserver {
            NotificationCenter.default.removeObserver(failObs)
        }
    }
}
