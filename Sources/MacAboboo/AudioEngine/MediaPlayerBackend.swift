import Foundation
import AppKit

/// 统一多媒体播放后端接口协议
@MainActor
public protocol MediaPlayerBackend: AnyObject {
    var isAvailable: Bool { get }
    var loadedURL: URL? { get }
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var playbackRate: Float { get set }
    var volume: Float { get set }
    var playerView: NSView { get }
    
    var onTimeUpdate: (@MainActor (Double, Double) -> Void)? { get set }
    var onStateChanged: (@MainActor (Bool) -> Void)? { get set }
    var onFinished: (@MainActor () -> Void)? { get set }
    var onError: (@MainActor (Error) -> Void)? { get set }
    
    func load(url: URL, completion: @escaping @MainActor (Bool) -> Void)
    func play()
    func pause()
    func seek(to seconds: Double, completion: (@Sendable () -> Void)?)
    func stop()
    func teardown()
    func setHighFrequencyPresentationEnabled(_ enabled: Bool)
}

public extension MediaPlayerBackend {
    func setHighFrequencyPresentationEnabled(_ enabled: Bool) {}
}
