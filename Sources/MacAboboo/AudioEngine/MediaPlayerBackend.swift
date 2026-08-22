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
    
    var onTimeUpdate: ((Double, Double) -> Void)? { get set }
    var onStateChanged: ((Bool) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    
    func load(url: URL, completion: @escaping (Bool) -> Void)
    func play()
    func pause()
    func seek(to seconds: Double, completion: (@Sendable () -> Void)?)
    func stop()
    func teardown()
}
