import AppKit
@testable import MacAbobooKit

@MainActor
final class TestMediaPlayerBackend: MediaPlayerBackend {
    let isAvailable = true
    private(set) var loadedURL: URL?
    private(set) var isPlaying = false
    private(set) var currentTime = 0.0
    private(set) var duration: Double
    private(set) var seekCount = 0
    private(set) var previewSeekCount = 0
    private(set) var loadCount = 0
    var automaticallyCompletesLoads: Bool
    var automaticallyCompletesSeeks: Bool
    var seekResultOffset: Double = 0
    private var pendingLoads: [(URL, @MainActor (Bool) -> Void)] = []
    private var pendingSeekCompletions: [(@Sendable () -> Void)?] = []
    var playbackRate: Float = 1
    var volume: Float = 1
    let playerView = NSView()
    var onTimeUpdate: (@MainActor (Double, Double) -> Void)?
    var onStateChanged: (@MainActor (Bool) -> Void)?
    var onFinished: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    init(
        duration: Double = 60,
        automaticallyCompletesLoads: Bool = true,
        automaticallyCompletesSeeks: Bool = true
    ) {
        self.duration = duration
        self.automaticallyCompletesLoads = automaticallyCompletesLoads
        self.automaticallyCompletesSeeks = automaticallyCompletesSeeks
    }

    func load(url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        loadCount += 1
        currentTime = 0
        if automaticallyCompletesLoads {
            loadedURL = url
            completion(true)
        } else {
            pendingLoads.append((url, completion))
        }
    }

    func play() {
        isPlaying = true
        onStateChanged?(true)
    }

    func pause() {
        isPlaying = false
        onStateChanged?(false)
    }

    func stop() {
        pause()
        currentTime = 0
    }

    func seek(to seconds: Double, completion: (@Sendable () -> Void)?) {
        seekCount += 1
        currentTime = max(0, min(seconds + seekResultOffset, duration))
        if automaticallyCompletesSeeks {
            completion?()
        } else {
            pendingSeekCompletions.append(completion)
        }
    }

    func previewSeek(to seconds: Double) {
        previewSeekCount += 1
        currentTime = max(0, min(seconds, duration))
    }

    func teardown() {
        loadedURL = nil
        currentTime = 0
        isPlaying = false
    }

    func completeLoad(at index: Int, success: Bool = true) {
        guard pendingLoads.indices.contains(index) else { return }
        let load = pendingLoads[index]
        if success { loadedURL = load.0 }
        load.1(success)
    }

    func completeNextSeek() {
        guard !pendingSeekCompletions.isEmpty else { return }
        let completion = pendingSeekCompletions.removeFirst()
        completion?()
    }

    func emitTime(_ time: Double) {
        currentTime = time
        onTimeUpdate?(time, duration)
    }

    func emitError(_ error: Error) {
        onError?(error)
    }
}

@MainActor
func makeTestPlaybackEngine() -> PlaybackEngine {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacAboboo-EngineTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    return PlaybackEngine(
        nativeBackend: TestMediaPlayerBackend(),
        mpvBackend: TestMediaPlayerBackend(),
        projectFileManager: ProjectFileManager(baseDirectory: directory)
    )
}
