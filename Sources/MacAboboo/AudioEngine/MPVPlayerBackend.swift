import Foundation
import AppKit
import OpenGL.GL3
import CoreVideo
import Darwin


@MainActor
public final class MPVPlayerBackend: NSObject, MediaPlayerBackend {
    public var isAvailable: Bool { mpvHandle != nil && MPVClient.shared.isAvailable }
    public private(set) var loadedURL: URL?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: Double = 0.0
    public private(set) var duration: Double = 0.0
    public var playbackRate: Float = 1.0 {
        didSet {
            if let handle = mpvHandle {
                let handleBits = UInt(bitPattern: handle)
                let value = playbackRate
                commandQueue.async {
                    guard let handle = OpaquePointer(bitPattern: handleBits) else { return }
                    _ = MPVClient.shared.setPropertyString(handle, name: "speed", value: "\(value)")
                }
            }
        }
    }
    public var volume: Float = 1.0 {
        didSet {
            if let handle = mpvHandle {
                let mpvVol = max(0.0, min(100.0, Double(volume) * 100.0))
                let muted = volume == 0
                let handleBits = UInt(bitPattern: handle)
                commandQueue.async {
                    guard let handle = OpaquePointer(bitPattern: handleBits) else { return }
                    _ = MPVClient.shared.setPropertyString(handle, name: "volume", value: "\(mpvVol)")
                    _ = MPVClient.shared.setPropertyString(handle, name: "mute", value: muted ? "yes" : "no")
                }
            }
        }
    }
    
    private let hostView = MPVHostView(frame: .zero)
    public var playerView: NSView { return hostView }
    
    public var onTimeUpdate: (@MainActor (Double, Double) -> Void)?
    public var onStateChanged: (@MainActor (Bool) -> Void)?
    public var onFinished: (@MainActor () -> Void)?
    public var onError: (@MainActor (Error) -> Void)?
    
    private var mpvHandle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var pollTimer: Timer?
    private var isSeekingInternal = false
    private var isPollingActive = false
    private var pollTick: UInt64 = 0
    private var timerTick: UInt64 = 0
    private var highFrequencyPresentationEnabled = true
    private var loadGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private let commandQueue = DispatchQueue(label: "com.macaboboo.mpv.commands", qos: .userInitiated)
    private var loadCancellationToken: MPVCancellationToken?
    private var seekCancellationToken: MPVCancellationToken?
    
    private static let openGLFrameworkHandle: UnsafeMutableRawPointer? = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_GLOBAL)
    
    public override init() {
        super.init()
        
        let handle = MPVClient.shared.create()
        
        _ = MPVClient.shared.setOptionString(handle, name: "vo", value: "libmpv")
        _ = MPVClient.shared.setOptionString(handle, name: "hwdec", value: "auto")
        _ = MPVClient.shared.setOptionString(handle, name: "audio-pitch-correction", value: "yes")
        _ = MPVClient.shared.setOptionString(handle, name: "mute", value: "no")

        _ = MPVClient.shared.setOptionString(handle, name: "terminal", value: "no")
        _ = MPVClient.shared.setOptionString(handle, name: "msg-level", value: "all=warn")
        _ = MPVClient.shared.setOptionString(handle, name: "input-vo-keyboard", value: "no")
        _ = MPVClient.shared.setOptionString(handle, name: "input-cursor", value: "no")
        _ = MPVClient.shared.setOptionString(handle, name: "osc", value: "no")
        _ = MPVClient.shared.setOptionString(handle, name: "osd-level", value: "0")
        
        let status = MPVClient.shared.initialize(handle)
        guard status >= 0 else {
            MPVClient.shared.destroy(handle)
            print("[MPVPlayerBackend] MPV initialization failed with code: \(status)")
            return
        }
        self.mpvHandle = handle
        
        let glGetProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { ctx, name in
            guard let name = name else { return nil }
            if let h = MPVPlayerBackend.openGLFrameworkHandle, let sym = dlsym(h, name) { return sym }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        
        if let glCtx = hostView.mpvLayer.cglContextObj {
            CGLSetCurrentContext(glCtx)
        }

        if let rCtx = MPVClient.shared.createRenderContext(handle, glGetProcAddress: glGetProcAddress) {
            self.renderContext = rCtx
            hostView.mpvLayer.renderContext = rCtx
            
            let layerPtr = Unmanaged.passUnretained(hostView.mpvLayer).toOpaque()
            MPVClient.shared.setRenderUpdateCallback(rCtx, callback: { ctx in
                guard let c = ctx else { return }
                let layer = Unmanaged<MPVOpenGLLayer>.fromOpaque(c).takeUnretainedValue()
                layer.requestDisplay()
            }, ctx: layerPtr)
            print("[MPVPlayerBackend] Shared mpv_render_context initialized successfully at startup.")
        }
    }
    
    public func load(url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        guard let handle = mpvHandle else {
            completion(false)
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        seekGeneration &+= 1
        loadCancellationToken?.cancel()
        let cancellationToken = MPVCancellationToken()
        loadCancellationToken = cancellationToken
        stopPolling()
        loadedURL = nil
        duration = 0
        currentTime = 0
        isPlaying = false
        isSeekingInternal = false
        isPollingActive = false
        pollTick = 0
        
        let handleBits = UInt(bitPattern: handle)
        let path = url.standardizedFileURL.path
        let requestedVolume = volume
        let requestedRate = playbackRate
        commandQueue.async {
            guard !cancellationToken.isCancelled else { return }
            guard let h = OpaquePointer(bitPattern: handleBits) else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            _ = MPVClient.shared.command(h, args: ["stop"])
            _ = MPVClient.shared.setPropertyString(h, name: "pause", value: "yes")
            let res = MPVClient.shared.command(h, args: ["loadfile", path, "replace"])
            guard res >= 0 else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    completion(false)
                }
                return
            }

            // loadfile 成功只表示命令已接收；继续等待真实媒体属性出现。
            var loadedDuration: Double = 0
            var loadedPath: String?
            var retries = 100
            while retries > 0 {
                guard !cancellationToken.isCancelled else { return }
                _ = MPVClient.shared.setPropertyString(h, name: "pause", value: "yes")
                loadedDuration = MPVClient.shared.getPropertyDouble(h, name: "duration") ?? 0
                loadedPath = MPVClient.shared.getPropertyString(h, name: "path")
                if loadedDuration > 0, loadedPath != nil {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
                retries -= 1
            }

            let loadedStandardPath = loadedPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            guard !cancellationToken.isCancelled else { return }
            let success = loadedDuration > 0 && loadedStandardPath == path
            if success {
                let mpvVol = max(0.0, min(100.0, Double(requestedVolume) * 100.0))
                _ = MPVClient.shared.setPropertyString(h, name: "volume", value: "\(mpvVol)")
                _ = MPVClient.shared.setPropertyString(h, name: "mute", value: requestedVolume == 0 ? "yes" : "no")
                _ = MPVClient.shared.setPropertyString(h, name: "speed", value: "\(requestedRate)")
                _ = MPVClient.shared.setPropertyString(h, name: "pause", value: "yes")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                if success {
                    self.duration = loadedDuration
                    self.currentTime = 0
                    self.loadedURL = url
                    self.isPlaying = false
                    self.onStateChanged?(false)
                    self.hostView.mpvLayer.setNeedsDisplay()
                    completion(true)
                } else {
                    self.loadedURL = nil
                    self.duration = 0
                    completion(false)
                }
            }
        }
    }
    
    public func play() {
        guard let handle = mpvHandle, loadedURL != nil else { return }
        let mpvVol = max(0.0, min(100.0, Double(volume) * 100.0))
        let speed = playbackRate
        let muted = volume == 0
        let handleBits = UInt(bitPattern: handle)
        commandQueue.async {
            guard let h = OpaquePointer(bitPattern: handleBits) else { return }
            _ = MPVClient.shared.setPropertyString(h, name: "volume", value: "\(mpvVol)")
            _ = MPVClient.shared.setPropertyString(h, name: "mute", value: muted ? "yes" : "no")
            _ = MPVClient.shared.setPropertyString(h, name: "speed", value: "\(speed)")
            _ = MPVClient.shared.setPropertyString(h, name: "pause", value: "no")
        }
        isPlaying = true
        startPolling()
        hostView.mpvLayer.setNeedsDisplay()
        onStateChanged?(true)
    }
    
    public func pause() {
        guard let handle = mpvHandle else { return }
        let handleBits = UInt(bitPattern: handle)
        commandQueue.async {
            guard let h = OpaquePointer(bitPattern: handleBits) else { return }
            _ = MPVClient.shared.setPropertyString(h, name: "pause", value: "yes")
        }
        isPlaying = false
        stopPolling()
        onStateChanged?(false)
    }
    
    public func stop() {
        pause()
        seek(to: 0.0, completion: nil)
    }
    
    public func seek(to seconds: Double, completion: (@Sendable () -> Void)?) {
        guard let handle = mpvHandle else {
            completion?()
            return
        }
        
        let clamped = max(0, min(seconds, max(0.1, duration)))
        seekCancellationToken?.cancel()
        let cancellationToken = MPVCancellationToken()
        seekCancellationToken = cancellationToken
        isSeekingInternal = true
        currentTime = clamped
        seekGeneration &+= 1
        let generation = seekGeneration
        
        let handleBits = UInt(bitPattern: handle)
        commandQueue.async { [weak self] in
            guard let h = OpaquePointer(bitPattern: handleBits) else {
                DispatchQueue.main.async {
                    self?.isSeekingInternal = false
                    completion?()
                }
                return
            }
            let status = MPVClient.shared.command(h, args: ["seek", "\(clamped)", "absolute", "exact"])
            var confirmedPosition: Double?
            if status >= 0 {
                // `mpv_command` returning success only means the seek command
                // was accepted. Wait until the decoder's real clock reaches
                // the requested position before releasing PlaybackEngine's
                // seek lock and allowing playback to resume.
                let deadline = CFAbsoluteTimeGetCurrent() + 1.0
                repeat {
                    guard !cancellationToken.isCancelled else { return }
                    if let position = MPVClient.shared.getPropertyDouble(h, name: "time-pos") {
                        confirmedPosition = position
                        if abs(position - clamped) <= 0.10 { break }
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                } while CFAbsoluteTimeGetCurrent() < deadline
            }
            
            DispatchQueue.main.async {
                guard let self = self,
                      generation == self.seekGeneration,
                      !cancellationToken.isCancelled else { return }
                self.seekCancellationToken = nil
                self.isSeekingInternal = false
                if let confirmedPosition, confirmedPosition.isFinite, confirmedPosition >= 0 {
                    self.currentTime = confirmedPosition
                }
                self.hostView.mpvLayer.setNeedsDisplay()
                completion?()
            }
        }

        // A command queue or a torn-down handle must not leave polling
        // disabled forever. Recover the backend-side seek state if its normal
        // completion path is lost.
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self,
                  generation == self.seekGeneration,
                  self.isSeekingInternal else { return }
            self.seekCancellationToken?.cancel()
            self.seekCancellationToken = nil
            self.isSeekingInternal = false
            self.hostView.mpvLayer.setNeedsDisplay()
            completion?()
        }
    }

    /// Best-effort preview seek for timeline scrubbing.  Unlike the exact
    /// sentence seek above it does not wait for mpv's clock to converge; a
    /// newer preview or the final exact seek supersedes this request.
    public func previewSeek(to seconds: Double) {
        guard let handle = mpvHandle, loadedURL != nil else { return }
        let clamped = max(0, min(seconds, max(0.1, duration)))
        seekCancellationToken?.cancel()
        let cancellationToken = MPVCancellationToken()
        seekCancellationToken = cancellationToken
        isSeekingInternal = true
        currentTime = clamped
        seekGeneration &+= 1
        let generation = seekGeneration
        let handleBits = UInt(bitPattern: handle)

        commandQueue.async { [weak self] in
            guard !cancellationToken.isCancelled,
                  let h = OpaquePointer(bitPattern: handleBits) else { return }
            _ = MPVClient.shared.command(h, args: ["seek", "\(clamped)", "absolute"])
            let position = MPVClient.shared.getPropertyDouble(h, name: "time-pos")
            DispatchQueue.main.async {
                guard let self,
                      generation == self.seekGeneration,
                      !cancellationToken.isCancelled else { return }
                self.seekCancellationToken = nil
                self.isSeekingInternal = false
                if let position, position.isFinite, position >= 0 {
                    self.currentTime = position
                }
                self.hostView.mpvLayer.setNeedsDisplay()
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self,
                  generation == self.seekGeneration,
                  self.isSeekingInternal else { return }
            self.seekCancellationToken?.cancel()
            self.seekCancellationToken = nil
            self.isSeekingInternal = false
            self.hostView.mpvLayer.setNeedsDisplay()
        }
    }

    public func teardown() {
        loadGeneration &+= 1
        loadCancellationToken?.cancel()
        loadCancellationToken = nil
        seekCancellationToken?.cancel()
        seekCancellationToken = nil
        seekGeneration &+= 1
        stopPolling()
        if let handle = mpvHandle {
            let handleBits = UInt(bitPattern: handle)
            commandQueue.async {
                guard let h = OpaquePointer(bitPattern: handleBits) else { return }
                _ = MPVClient.shared.command(h, args: ["stop"])
            }
        }
        loadedURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isPollingActive = false
    }
    
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPlaybackState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
    
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    private func pollPlaybackState() {
        timerTick &+= 1
        if !highFrequencyPresentationEnabled, timerTick % 4 != 0 { return }
        guard !isSeekingInternal, !isPollingActive, let handle = mpvHandle else { return }
        isPollingActive = true
        pollTick &+= 1
        let shouldRefreshDuration = duration <= 0 || pollTick % 60 == 0
        let generation = loadGeneration
        
        let handleBits = UInt(bitPattern: handle)
        commandQueue.async { [weak self] in
            guard let h = OpaquePointer(bitPattern: handleBits) else {
                DispatchQueue.main.async {
                    guard let self, generation == self.loadGeneration else { return }
                    self.isPollingActive = false
                }
                return
            }
            let pos = MPVClient.shared.getPropertyDouble(h, name: "time-pos") ?? -1
            let dur = shouldRefreshDuration
                ? (MPVClient.shared.getPropertyDouble(h, name: "duration") ?? 0)
                : 0
            let eof = MPVClient.shared.getPropertyFlag(h, name: "eof-reached") ?? false
            
            DispatchQueue.main.async {
                guard let self = self, generation == self.loadGeneration else { return }
                self.isPollingActive = false
                
                if pos >= 0 {
                    self.currentTime = pos
                    if dur > 0 && abs(self.duration - dur) > 0.01 {
                        self.duration = dur
                    }
                    self.onTimeUpdate?(pos, self.duration)
                }
                
                if eof && self.isPlaying {
                    self.isPlaying = false
                    self.stopPolling()
                    self.onStateChanged?(false)
                    self.onFinished?()
                }
            }
        }
    }

    public func setHighFrequencyPresentationEnabled(_ enabled: Bool) {
        highFrequencyPresentationEnabled = enabled
    }
    
    deinit {
        loadCancellationToken?.cancel()
        seekCancellationToken?.cancel()
        pollTimer?.invalidate()
        if let r = renderContext {
            MPVClient.shared.freeRenderContext(r)
        }
        if let h = mpvHandle {
            let handleBits = UInt(bitPattern: h)
            commandQueue.sync {
                guard let handle = OpaquePointer(bitPattern: handleBits) else { return }
                MPVClient.shared.destroy(handle)
            }
        }
    }
}

private final class MPVCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class MPVOpenGLLayer: CAOpenGLLayer {
    let cglPixelFormatObj: CGLPixelFormatObj?
    let cglContextObj: CGLContextObj?
    var renderContext: OpaquePointer?
    private let displayRequestLock = NSLock()
    private var isDisplayRequestPending = false

    func requestDisplay() {
        displayRequestLock.lock()
        guard !isDisplayRequestPending else {
            displayRequestLock.unlock()
            return
        }
        isDisplayRequestPending = true
        displayRequestLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayRequestLock.lock()
            self.isDisplayRequestPending = false
            self.displayRequestLock.unlock()
            self.setNeedsDisplay()
        }
    }
    
    override init() {
        var pixAttrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAColorSize, CGLPixelFormatAttribute(24),
            kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            CGLPixelFormatAttribute(0)
        ]
        var pixFormat: CGLPixelFormatObj?
        var numPixFormats: GLint = 0
        CGLChoosePixelFormat(&pixAttrs, &pixFormat, &numPixFormats)
        
        if pixFormat == nil {
            var fallbackAttrs: [CGLPixelFormatAttribute] = [
                kCGLPFAColorSize, CGLPixelFormatAttribute(24),
                kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
                CGLPixelFormatAttribute(0)
            ]
            CGLChoosePixelFormat(&fallbackAttrs, &pixFormat, &numPixFormats)
        }
        self.cglPixelFormatObj = pixFormat
        
        var glCtx: CGLContextObj?
        if let pf = pixFormat {
            CGLCreateContext(pf, nil, &glCtx)
        }
        self.cglContextObj = glCtx
        
        super.init()
        // libmpv 的更新回调会在有新帧时调用 requestDisplay()。这里必须使用
        // 按需绘制；isAsynchronous=true 会让 CAOpenGLLayer 周期性调用
        // canDraw，而 canDraw 一旦返回 true 就会在暂停时也持续重绘上一帧。
        self.isAsynchronous = false
        self.needsDisplayOnBoundsChange = true
        self.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }
    
    override init(layer: Any) {
        if let other = layer as? MPVOpenGLLayer {
            self.cglPixelFormatObj = other.cglPixelFormatObj != nil ? CGLRetainPixelFormat(other.cglPixelFormatObj!) : nil
            self.cglContextObj = other.cglContextObj != nil ? CGLRetainContext(other.cglContextObj!) : nil
            self.renderContext = other.renderContext
        } else {
            self.cglPixelFormatObj = nil
            self.cglContextObj = nil
        }
        super.init(layer: layer)
        self.isAsynchronous = false
        self.needsDisplayOnBoundsChange = true
        self.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }
    
    required init?(coder: NSCoder) {
        self.cglPixelFormatObj = nil
        self.cglContextObj = nil
        self.renderContext = nil
        super.init(coder: coder)
        self.isAsynchronous = false
        self.needsDisplayOnBoundsChange = true
        self.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }
    
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        if let pf = cglPixelFormatObj {
            return CGLRetainPixelFormat(pf)
        }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }
    
    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        if let ctx = cglContextObj {
            return CGLRetainContext(ctx)
        }
        return super.copyCGLContext(forPixelFormat: pixelFormat)
    }
    
    override func canDraw(inCGLContext glContext: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime timeInterval: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?) -> Bool {
        return renderContext != nil
    }
    
    override func draw(inCGLContext glContext: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime timeInterval: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?) {
        guard let ctx = renderContext else { return }
        
        _ = MPVClient.shared.updateRenderContext(ctx)

        let scale = contentsScale > 0 ? contentsScale : (NSScreen.main?.backingScaleFactor ?? 2.0)
        let w = Int32(bounds.width * scale)
        let h = Int32(bounds.height * scale)
        
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        
        _ = MPVClient.shared.renderFrame(ctx, fbo: fbo, width: w, height: h)

        super.draw(inCGLContext: glContext, pixelFormat: pixelFormat, forLayerTime: timeInterval, displayTime: displayTime)
        
        MPVClient.shared.reportSwap(ctx)
    }
    
    deinit {
        if let ctx = cglContextObj { CGLReleaseContext(ctx) }
        if let pf = cglPixelFormatObj { CGLReleasePixelFormat(pf) }
    }
}

final class MPVHostView: NSView {
    let mpvLayer = MPVOpenGLLayer()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        self.wantsLayer = true
        self.layer = mpvLayer
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        mpvLayer.needsDisplayOnBoundsChange = true
        mpvLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        mpvLayer.frame = NSRect(origin: .zero, size: newSize)
        mpvLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        mpvLayer.setNeedsDisplay()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let win = window {
            mpvLayer.contentsScale = win.backingScaleFactor
            mpvLayer.setNeedsDisplay()
        }
    }
    
    override func layout() {
        super.layout()
        mpvLayer.frame = self.bounds
        mpvLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        mpvLayer.setNeedsDisplay()
    }
}
