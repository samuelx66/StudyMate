import AppKit
import Foundation

/// 只在真正需要扩展解码时创建 libmpv 和 OpenGL 上下文。
/// teardown 会释放内部实例，系统解码模式不再长期持有 MPV 资源。
@MainActor
public final class LazyMPVPlayerBackend: MediaPlayerBackend {
    private var backend: MPVPlayerBackend?
    private var configuredRate: Float = 1
    private var configuredVolume: Float = 1
    private var highFrequencyPresentationEnabled = true

    public init() {}

    public var isAvailable: Bool { MPVClient.shared.isAvailable }
    public var loadedURL: URL? { backend?.loadedURL }
    public var isPlaying: Bool { backend?.isPlaying ?? false }
    public var currentTime: Double { backend?.currentTime ?? 0 }
    public var duration: Double { backend?.duration ?? 0 }

    public var playbackRate: Float {
        get { backend?.playbackRate ?? configuredRate }
        set {
            configuredRate = newValue
            backend?.playbackRate = newValue
        }
    }

    public var volume: Float {
        get { backend?.volume ?? configuredVolume }
        set {
            configuredVolume = newValue
            backend?.volume = newValue
        }
    }

    public var playerView: NSView { resolveBackend().playerView }

    public var onTimeUpdate: (@MainActor (Double, Double) -> Void)? {
        didSet { backend?.onTimeUpdate = onTimeUpdate }
    }
    public var onStateChanged: (@MainActor (Bool) -> Void)? {
        didSet { backend?.onStateChanged = onStateChanged }
    }
    public var onFinished: (@MainActor () -> Void)? {
        didSet { backend?.onFinished = onFinished }
    }
    public var onError: (@MainActor (Error) -> Void)? {
        didSet { backend?.onError = onError }
    }

    public func load(url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        resolveBackend().load(url: url, completion: completion)
    }

    public func play() { backend?.play() }
    public func pause() { backend?.pause() }
    public func seek(to seconds: Double, completion: (@Sendable () -> Void)?) {
        backend?.seek(to: seconds, completion: completion)
    }
    public func previewSeek(to seconds: Double) {
        // Do not resolve the backend just for a slider preview.  The wrapper
        // is intentionally lazy, but once MPV has been loaded the preview
        // path must reach MPV's non-exact seek implementation instead of the
        // protocol's exact-seek fallback.
        backend?.previewSeek(to: seconds)
    }
    public func stop() { backend?.stop() }

    public func teardown() {
        backend?.teardown()
        backend = nil
    }

    public func setHighFrequencyPresentationEnabled(_ enabled: Bool) {
        highFrequencyPresentationEnabled = enabled
        backend?.setHighFrequencyPresentationEnabled(enabled)
    }

    private func resolveBackend() -> MPVPlayerBackend {
        if let backend { return backend }
        let created = MPVPlayerBackend()
        created.playbackRate = configuredRate
        created.volume = configuredVolume
        created.onTimeUpdate = onTimeUpdate
        created.onStateChanged = onStateChanged
        created.onFinished = onFinished
        created.onError = onError
        created.setHighFrequencyPresentationEnabled(highFrequencyPresentationEnabled)
        backend = created
        return created
    }
}
