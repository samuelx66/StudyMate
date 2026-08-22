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
    
    public var onTimeUpdate: ((Double, Double) -> Void)?
    public var onStateChanged: ((Bool) -> Void)?
    public var onFinished: (() -> Void)?
    public var onError: ((Error) -> Void)?
    
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
    
    public override init() {
        super.init()
        avPlayerView.player = player
        player.volume = volume
        player.isMuted = false
        setupTimeObserver()
        setupTimeControlObservation()
    }
    
    public func load(url: URL, completion: @escaping (Bool) -> Void) {
        loadTask?.cancel()
        loadGeneration = UUID()
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
        player.rate = playbackRate
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
    
    /// 0ms 瞬间秒跳定位（零容差精准锁定目标帧，绝无延迟）
    public func seek(to seconds: Double, completion: (@Sendable () -> Void)?) {
        let clamped = max(0, min(seconds, max(0.1, duration)))
        let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
        
        isSeekingInternal = true
        currentTime = clamped
        seekGeneration &+= 1
        let generation = seekGeneration
        
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self = self, finished, generation == self.seekGeneration else { return }
                self.isSeekingInternal = false
                self.currentTime = clamped
                if self.isPlaying {
                    self.player.rate = self.playbackRate
                }
                completion?()
            }
        }
    }
    
    public func teardown() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration = UUID()
        teardownItemObservations()
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
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSeekingInternal else { return }
                let current = CMTimeGetSeconds(time)
                if current >= 0, !current.isNaN {
                    self.currentTime = current
                    let total = self.duration
                    self.onTimeUpdate?(current, total)
                }
            }
        }
    }

    private func setupTimeControlObservation() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
