import Foundation
import AVFoundation
import Combine
import SwiftUI
import AppKit

/// 高频播放时钟与低频工程状态分离，避免 60fps 时间更新使整个界面重算。
@MainActor
public final class PlaybackClock: ObservableObject {
    @Published public fileprivate(set) var currentTime: Double = 0
}

/// 只由波形相关视图观察的展示状态。
@MainActor
public final class WaveformPresentationState: ObservableObject {
    @Published public fileprivate(set) var primaryViewport: (start: Double, end: Double) = (0, 15)
    @Published public fileprivate(set) var secondaryViewport: (start: Double, end: Double) = (0, 5)
    @Published public fileprivate(set) var waveformData: WaveformData = .empty
    @Published public fileprivate(set) var isExtracting: Bool = false
    @Published public fileprivate(set) var extractionProgress: Double = 0
}

/// 核心音视频播放与学习控制引擎（智能双引擎架构：AVFoundation 原生直通 + libmpv 全格式全能兜底）
@MainActor
public final class PlaybackEngine: NSObject, ObservableObject {
    public enum BoundaryDragSource: Equatable {
        case primary
        case secondary
    }

    public static let shared = PlaybackEngine()
    
    // MARK: - 智能多媒体双引擎架构
    public let nativeBackend: MediaPlayerBackend
    public let mpvBackend: MediaPlayerBackend
    @Published public private(set) var activeBackend: MediaPlayerBackend

    public let clock = PlaybackClock()
    public let waveformState = WaveformPresentationState()
    
    // MARK: - 基础播放状态
    @Published public var currentMedia: MediaItem?
    @Published public var isPlaying: Bool = false
    public private(set) var currentTime: Double {
        get { clock.currentTime }
        set { clock.currentTime = max(0, newValue.isFinite ? newValue : 0) }
    }
    @Published public var duration: Double = 0.0
    @Published public private(set) var isMediaLoading: Bool = false
    @Published public var lastErrorMessage: String?
    @Published public var playbackRate: Float = 1.0 {
        didSet {
            activeBackend.playbackRate = playbackRate
        }
    }
    @Published public var loopMode: PlaybackLoopMode = .normal
    @Published public var volume: Float = 1.0 {
        didSet {
            activeBackend.volume = volume
        }
    }
    
    // MARK: - 解码引擎配置模式 (系统解码 / libmpv 解码 / 混合解码)
    @Published public var decoderMode: DecoderEngineMode = {
        if let saved = UserDefaults.standard.string(forKey: "MacAboboo_DecoderEngineMode"),
           let mode = DecoderEngineMode(rawValue: saved) {
            return mode
        }
        return .hybrid
    }()
    
    // MARK: - 智能精听与复读系统状态
    /// 单句定次复读上限 (1, 2, 3, 5, 10，0 表示无限单句循环)
    @Published public var repeatCountLimit: Int = 1
    /// 当前句已播放/复读次数
    @Published public var currentRepeatCount: Int = 1
    /// 跟读停顿倍率 (0.0x 表示不停顿，1.0x 表示停顿当前句相同时长供用户开口跟读)
    @Published public var shadowingPauseRatio: Double = 0.0
    /// 是否正处于句末开口跟读倒计时中
    @Published public var isShadowingPaused: Bool = false
    /// 跟读倒计时剩余秒数
    @Published public var shadowingCountdownRemaining: Double = 0.0
    /// 仅复读收藏难句模式
    @Published public var onlyPlayBookmarked: Bool = false
    
    // MARK: - AI 语音识词与双引擎断句状态
    @Published public var isAITranscribing: Bool = false
    @Published public var aiTranscriptionProgress: Double = 0.0
    @Published public var aiTranscriptionStatusText: String = ""
    
    // MARK: - 断句与波形数据
    @Published public var segments: [SentenceSegment] = []
    @Published public var activeSegmentIndex: Int? {
        didSet {
            if activeSegmentIndex != oldValue {
                currentRepeatCount = 1
                updateSecondaryViewportForActiveSegment()
            }
        }
    }
    
    // 统一波形图视口状态管理
    public private(set) var primaryViewport: (start: Double, end: Double) {
        get { waveformState.primaryViewport }
        set { waveformState.primaryViewport = newValue }
    }
    public private(set) var secondaryViewport: (start: Double, end: Double) {
        get { waveformState.secondaryViewport }
        set { waveformState.secondaryViewport = newValue }
    }
    private var lastSecondarySegmentId: UUID? = nil
    
    public private(set) var waveformData: WaveformData {
        get { waveformState.waveformData }
        set { waveformState.waveformData = newValue }
    }
    public private(set) var isExtractingWaveform: Bool {
        get { waveformState.isExtracting }
        set { waveformState.isExtracting = newValue }
    }
    public private(set) var waveformExtractionProgress: Double {
        get { waveformState.extractionProgress }
        set { waveformState.extractionProgress = newValue }
    }
    
    // 交互辅助状态
    @Published public var isSeeking: Bool = false
    @Published public var isPreviewingAnchor: Bool = false
    @Published public private(set) var isBoundaryDragging: Bool = false
    @Published public private(set) var boundaryDragSource: BoundaryDragSource? = nil
    private var shadowingTask: Task<Void, Never>?
    private var debouncedSaveTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var sidecarTask: Task<Void, Never>?
    private var mediaSessionID = UUID()
    private var seekGeneration: UInt64 = 0
    private var isBackendReady = false
    private var wantsPlayback = false
    private var pendingResumeTime: Double = 0
    private var pendingResumePlayback = false
    private var previewEndTime: Double?
    private var securityScopedMediaURL: URL?
    private let projectFileManager: ProjectFileManager

    private enum SegmentOrigin {
        case none
        case project
        case sidecar
        case vad
        case ai
        case imported
        case fallback
    }
    private var segmentOrigin: SegmentOrigin = .none

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "avi", "webm", "flv", "wmv", "ts", "vob", "ogv", "rmvb", "3gp"
    ]
    private static let nonNativeExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "ts", "vob", "ogv", "rmvb", "3gp", "ape", "wma"
    ]
    
    public override convenience init() {
        self.init(
            nativeBackend: AVFoundationPlayerBackend(),
            mpvBackend: MPVPlayerBackend(),
            projectFileManager: .shared
        )
    }

    public init(
        nativeBackend: MediaPlayerBackend,
        mpvBackend: MediaPlayerBackend,
        projectFileManager: ProjectFileManager = .shared
    ) {
        self.nativeBackend = nativeBackend
        self.mpvBackend = mpvBackend
        self.activeBackend = nativeBackend
        self.projectFileManager = projectFileManager
        super.init()
        self.nativeBackend.volume = self.volume
        self.nativeBackend.playbackRate = self.playbackRate
        self.mpvBackend.volume = self.volume
        self.mpvBackend.playbackRate = self.playbackRate
        setupBackendCallbacks(for: nativeBackend)
        setupBackendCallbacks(for: mpvBackend)
    }
    
    private func setupBackendCallbacks(for backend: MediaPlayerBackend) {
        backend.onTimeUpdate = { [weak self, weak backend] current, total in
            Task { @MainActor [weak self] in
                guard let self = self,
                      self.activeBackend === backend,
                      self.isBackendReady,
                      !self.isSeeking else { return }
                self.updateMediaDurationIfNeeded(total)
                self.currentTime = current
                self.handlePlaybackBoundary(at: current)
                self.followPlaybackIfNeeded(at: current)
            }
        }
        
        backend.onStateChanged = { [weak self, weak backend] playing in
            Task { @MainActor [weak self] in
                guard let self = self, self.activeBackend === backend else { return }
                if !self.isShadowingPaused {
                    self.isPlaying = playing
                }
            }
        }
        
        backend.onFinished = { [weak self, weak backend] in
            Task { @MainActor [weak self] in
                guard let self = self, self.activeBackend === backend else { return }
                self.isPlaying = false
                if self.loopMode == .all {
                    self.seek(to: 0.0) {
                        Task { @MainActor [weak self] in
                            self?.play()
                        }
                    }
                } else {
                    self.wantsPlayback = false
                }
            }
        }
        
        backend.onError = { [weak self, weak backend] error in
            Task { @MainActor [weak self] in
                guard let self = self, self.activeBackend === backend else { return }
                print("[PlaybackEngine] Active backend reported error: \(error.localizedDescription)")
                
                if backend === self.nativeBackend,
                   self.decoderMode == .hybrid,
                   self.mpvBackend.isAvailable,
                   let media = self.currentMedia {
                    self.loadBackend(
                        self.mpvBackend,
                        url: media.url,
                        sessionID: self.mediaSessionID,
                        resumeTime: self.currentTime,
                        shouldPlay: self.wantsPlayback,
                        allowHybridFallback: false
                    )
                } else {
                    self.isPlaying = false
                    self.wantsPlayback = false
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func targetBackend(for url: URL, mode: DecoderEngineMode) -> MediaPlayerBackend {
        switch mode {
        case .system:
            return nativeBackend
        case .mpv:
            return mpvBackend
        case .hybrid:
            return Self.nonNativeExtensions.contains(url.pathExtension.lowercased()) ? mpvBackend : nativeBackend
        }
    }

    private func loadBackend(
        _ backend: MediaPlayerBackend,
        url: URL,
        sessionID: UUID,
        resumeTime: Double,
        shouldPlay: Bool,
        allowHybridFallback: Bool
    ) {
        guard sessionID == mediaSessionID else { return }
        guard backend.isAvailable else {
            isBackendReady = false
            isMediaLoading = false
            isPlaying = false
            wantsPlayback = false
            pendingResumePlayback = false
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "所选解码引擎不可用。请安装或随应用打包 libmpv。"
                : "The selected decoding engine is unavailable. Bundle or install libmpv."
            return
        }

        pendingResumeTime = max(0, resumeTime)
        pendingResumePlayback = shouldPlay
        isBackendReady = false
        isMediaLoading = true

        if activeBackend !== backend {
            activeBackend.pause()
            activeBackend.teardown()
            activeBackend = backend
        } else {
            activeBackend.pause()
        }
        activeBackend.playbackRate = playbackRate
        activeBackend.volume = volume

        backend.load(url: url) { [weak self, weak backend] success in
            Task { @MainActor [weak self] in
                guard let self,
                      let backend,
                      sessionID == self.mediaSessionID,
                      self.activeBackend === backend else { return }

                if success, backend.loadedURL?.standardizedFileURL == url.standardizedFileURL {
                    self.isBackendReady = true
                    self.isMediaLoading = false
                    self.updateMediaDurationIfNeeded(backend.duration)
                    self.applyPendingPlaybackRestore()
                    return
                }

                if allowHybridFallback,
                   backend === self.nativeBackend,
                   self.decoderMode == .hybrid,
                   self.mpvBackend.isAvailable {
                    self.loadBackend(
                        self.mpvBackend,
                        url: url,
                        sessionID: sessionID,
                        resumeTime: self.pendingResumeTime,
                        shouldPlay: self.pendingResumePlayback,
                        allowHybridFallback: false
                    )
                } else {
                    self.isBackendReady = false
                    self.isMediaLoading = false
                    self.isPlaying = false
                    self.wantsPlayback = false
                    self.pendingResumePlayback = false
                    self.lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                        ? "无法加载媒体文件：\(url.lastPathComponent)"
                        : "Unable to load media: \(url.lastPathComponent)"
                }
            }
        }
    }

    private func applyPendingPlaybackRestore() {
        guard isBackendReady else { return }
        let resumeTime = min(max(0, pendingResumeTime), max(0, duration))
        let shouldPlay = pendingResumePlayback
        pendingResumePlayback = false

        if resumeTime > 0.001 {
            seek(to: resumeTime) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, shouldPlay else { return }
                    self.beginPlayback()
                }
            }
        } else if shouldPlay {
            beginPlayback()
        }
    }

    private func updateMediaDurationIfNeeded(_ newDuration: Double) {
        guard newDuration.isFinite, newDuration > 0 else { return }
        if abs(duration - newDuration) > 0.01 {
            duration = newDuration
        }
        if let media = currentMedia, abs(media.duration - newDuration) > 0.01 {
            currentMedia = MediaItem(
                id: media.id,
                url: media.url,
                title: media.title,
                duration: newDuration,
                isVideo: media.isVideo,
                fileSize: media.fileSize
            )
        }
    }

    public func beginBoundaryDrag(from source: BoundaryDragSource) {
        isBoundaryDragging = true
        boundaryDragSource = source
    }

    public func endBoundaryDrag() {
        isBoundaryDragging = false
        boundaryDragSource = nil
        debouncedSaveTask?.cancel()
        persistCurrentProject()
    }
    
    public func scheduleDebouncedPersistence(delay: TimeInterval = 0.5) {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.persistCurrentProject()
        }
    }
    
    /// 当切换活跃断句时，计算次波形图的固定基准放大视口（拖动起止标线时保持此视口绝对固定，波形底图不动）
    public func updateSecondaryViewportForActiveSegment(force: Bool = false) {
        guard let idx = activeSegmentIndex, idx >= 0, idx < segments.count else { return }
        let seg = segments[idx]
        if lastSecondarySegmentId != seg.id || force {
            lastSecondarySegmentId = seg.id
            let padding = max(0.8, seg.duration * 0.35)
            let vStart = max(0, seg.startTime - padding)
            let maxDuration = duration > 0 ? duration : (seg.endTime + padding + 1.0)
            let vEnd = min(maxDuration, seg.endTime + padding)
            secondaryViewport = (vStart, vEnd)
        }
    }
    
    /// 主波形图左右拖拽平移浏览时间轴
    public func panPrimaryViewport(by deltaTime: Double) {
        guard duration > 0 else { return }
        let span = max(1.0, primaryViewport.end - primaryViewport.start)
        var newStart = primaryViewport.start + deltaTime
        let maxStart = max(0, duration - span)
        newStart = max(0, min(maxStart, newStart))
        let newEnd = min(duration, newStart + span)
        primaryViewport = (newStart, newEnd)
    }
    
    /// 主波形图缩放控制
    public func setPrimaryViewportZoom(zoomLevel: Double) {
        guard duration > 0 else { return }
        let currentCenter = (primaryViewport.start + primaryViewport.end) / 2.0
        let newSpan = max(3.0, min(duration, 15.0 / zoomLevel))
        let halfSpan = newSpan / 2.0
        let idealStart = max(0, currentCenter - halfSpan)
        let idealEnd = min(duration, idealStart + newSpan)
        let finalStart = max(0, idealEnd - newSpan)
        primaryViewport = (finalStart, idealEnd)
    }
    
    /// 播放时主波形图自动跟随平移（当游标接近右侧或在视口外时，视口平滑向右推进）
    public func followPlaybackIfNeeded(at current: Double) {
        guard isPlaying, !isBoundaryDragging, duration > 0 else { return }
        let span = primaryViewport.end - primaryViewport.start
        guard span > 0, span < duration else { return }
        
        if current >= (primaryViewport.end - span * 0.3) || current < primaryViewport.start {
            let newStart = max(0, current - span * 0.3)
            let newEnd = min(duration, newStart + span)
            if abs(newStart - primaryViewport.start) > 0.05 {
                primaryViewport = (newStart, newEnd)
            }
        }
    }
    
    public func setDecoderMode(_ mode: DecoderEngineMode) {
        guard self.decoderMode != mode else { return }
        if mode == .mpv && !mpvBackend.isAvailable {
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "libmpv 不可用，无法切换到扩展解码。"
                : "libmpv is unavailable, so extended decoding cannot be selected."
            return
        }
        self.decoderMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "MacAboboo_DecoderEngineMode")
        print("[PlaybackEngine] Decoder engine mode set to: \(mode.rawValue)")
        
        // 如果当前已打开媒体文件，立即无缝无损热切换至对应后端并恢复进度与播放状态
        if let media = currentMedia {
            let savedTime = self.currentTime
            let wasPlaying = self.wantsPlayback
            
            let target = targetBackend(for: media.url, mode: mode)
            guard target !== activeBackend else { return }
            loadBackend(
                target,
                url: media.url,
                sessionID: mediaSessionID,
                resumeTime: savedTime,
                shouldPlay: wasPlaying,
                allowHybridFallback: mode == .hybrid
            )
        }
    }
    
    // MARK: - 媒体加载与独立工程恢复
    
    /// 加载音视频文件（优先从 ~/Library/Application Support/MacAboboo/Projects/ 独立工程文件瞬间读取）
    public func loadMedia(from url: URL) {
        let mediaURL = url.standardizedFileURL
        let isAlreadyScoped = securityScopedMediaURL?.standardizedFileURL == mediaURL
        let didStartSecurityScope = !isAlreadyScoped && mediaURL.startAccessingSecurityScopedResource()
        let values = try? mediaURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard mediaURL.isFileURL,
              FileManager.default.fileExists(atPath: mediaURL.path),
              values?.isRegularFile == true,
              values?.isReadable != false else {
            if didStartSecurityScope { mediaURL.stopAccessingSecurityScopedResource() }
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "请选择一个可读取的音频或视频文件。"
                : "Choose a readable audio or video file."
            return
        }

        if currentMedia != nil {
            debouncedSaveTask?.cancel()
            persistCurrentProject()
        }

        if !isAlreadyScoped {
            securityScopedMediaURL?.stopAccessingSecurityScopedResource()
            securityScopedMediaURL = didStartSecurityScope ? mediaURL : nil
        }

        mediaSessionID = UUID()
        let sessionID = mediaSessionID
        seekGeneration &+= 1
        shadowingTask?.cancel()
        waveformTask?.cancel()
        sidecarTask?.cancel()
        activeBackend.pause()
        isShadowingPaused = false
        shadowingCountdownRemaining = 0
        previewEndTime = nil
        isSeeking = false
        isBackendReady = false
        pendingResumeTime = 0
        pendingResumePlayback = false
        lastErrorMessage = nil
        currentRepeatCount = 1
        segmentOrigin = .none
        segments = []
        activeSegmentIndex = nil
        lastSecondarySegmentId = nil
        waveformData = .empty
        isExtractingWaveform = false
        waveformExtractionProgress = 0
        primaryViewport = (0, 15)
        secondaryViewport = (0, 5)
        currentTime = 0
        duration = 0
        isPlaying = false
        wantsPlayback = false

        let ext = mediaURL.pathExtension.lowercased()
        let fileSize = (try? mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        currentMedia = MediaItem(
            url: mediaURL,
            title: mediaURL.deletingPathExtension().lastPathComponent,
            duration: 0,
            isVideo: Self.videoExtensions.contains(ext),
            fileSize: fileSize
        )

        let backend = targetBackend(for: mediaURL, mode: decoderMode)
        loadBackend(
            backend,
            url: mediaURL,
            sessionID: sessionID,
            resumeTime: 0,
            shouldPlay: false,
            allowHybridFallback: decoderMode == .hybrid && backend === nativeBackend
        )

        sidecarTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let savedProject = await self.projectFileManager.loadProjectAsync(for: mediaURL)
            guard !Task.isCancelled,
                  sessionID == self.mediaSessionID,
                  self.currentMedia?.url.standardizedFileURL == mediaURL else { return }

            if let savedProject, savedProject.isCompatible(with: mediaURL) {
                self.restoreProject(savedProject, for: mediaURL)
                if let savedWaveform = savedProject.waveformData, !savedWaveform.isEmpty {
                    self.waveformData = savedWaveform
                    self.waveformExtractionProgress = 1
                    if self.duration <= 0 { self.updateMediaDurationIfNeeded(savedWaveform.duration) }
                    if self.segments.isEmpty {
                        self.performSmartSegmentation(using: savedWaveform)
                    }
                    if savedProject.schemaVersion < MediaProjectFile.currentSchemaVersion || savedProject.waveformCacheFile == nil {
                        self.persistCurrentProject(includeWaveform: true)
                    }
                    return
                }
            } else {
                let items = await self.loadSidecarItems(for: mediaURL)
                guard !Task.isCancelled, sessionID == self.mediaSessionID else { return }
                if let items, !items.isEmpty {
                    self.applySubtitleItems(items, origin: .sidecar, persist: false)
                }
            }

            self.extractWaveform(from: mediaURL, sessionID: sessionID)
        }
    }

    private func restoreProject(_ project: MediaProjectFile, for mediaURL: URL) {
        segmentOrigin = .project
        if duration <= 0 { updateMediaDurationIfNeeded(project.duration) }
        let effectiveDuration = duration > 0 ? duration : project.duration
        segments = normalizedSegments(project.segments, duration: effectiveDuration)

        let restoredPosition = min(max(0, project.lastPosition), effectiveDuration)
        pendingResumeTime = restoredPosition
        currentTime = restoredPosition
        updateActiveSegment(for: restoredPosition)
        if activeSegmentIndex == nil, !segments.isEmpty {
            activeSegmentIndex = segments.firstIndex(where: { $0.startTime >= restoredPosition }) ?? (segments.count - 1)
        }

        if duration > 0 {
            let span = min(15, duration)
            let start = min(max(0, restoredPosition - span * 0.3), max(0, duration - span))
            primaryViewport = (start, start + span)
        }

        if isBackendReady {
            seek(to: restoredPosition)
        }
    }

    private func loadSidecarItems(for mediaURL: URL) async -> [ParsedSubtitleItem]? {
        let base = mediaURL.deletingPathExtension()
        return await Task.detached(priority: .utility) {
            for ext in ["srt", "lrc", "vtt"] {
                guard !Task.isCancelled else { return nil }
                let subtitleURL = base.appendingPathExtension(ext)
                guard FileManager.default.fileExists(atPath: subtitleURL.path) else { continue }
                if let items = try? SubtitleParser.shared.parse(from: subtitleURL), !items.isEmpty {
                    return items
                }
            }
            return nil
        }.value
    }
    
    /// 自动检测并加载同名侧边字幕文件
    public func detectAndLoadSidecarSubtitle(for mediaUrl: URL) -> Bool {
        let base = mediaUrl.deletingPathExtension()
        let candidates = ["srt", "lrc", "vtt"]
        
        for ext in candidates {
            let subURL = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: subURL.path) {
                if let items = try? SubtitleParser.shared.parse(from: subURL), !items.isEmpty {
                    applySubtitleItems(items, origin: .sidecar, persist: true)
                    return true
                }
            }
        }
        return false
    }
    
    /// 异步提取波形数据（支持断点增量更新与取消保护）
    private func extractWaveform(from url: URL, sessionID: UUID) {
        waveformTask?.cancel()
        isExtractingWaveform = true
        waveformExtractionProgress = 0.0
        
        waveformTask = WaveformExtractor.shared.extractWaveform(
            from: url,
            onProgress: { [weak self] progress, interimData in
                Task { @MainActor [weak self] in
                    guard let self,
                          sessionID == self.mediaSessionID,
                          self.currentMedia?.url.standardizedFileURL == url.standardizedFileURL else { return }
                    self.waveformExtractionProgress = progress
                    self.waveformData = interimData
                    if self.duration <= 0 && interimData.duration > 0 {
                        self.updateMediaDurationIfNeeded(interimData.duration)
                    }
                }
            },
            completion: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self,
                          sessionID == self.mediaSessionID,
                          self.currentMedia?.url.standardizedFileURL == url.standardizedFileURL else { return }
                    self.isExtractingWaveform = false
                    switch result {
                    case .success(let data):
                        self.waveformData = data
                        self.waveformExtractionProgress = 1.0
                        if data.duration > 0, self.duration <= 0 {
                            self.updateMediaDurationIfNeeded(data.duration)
                        }
                        
                        if self.segments.isEmpty && self.segmentOrigin == .none {
                            self.performSmartSegmentation(using: data)
                        }
                        
                        self.persistCurrentProject(includeWaveform: true)
                    case .failure(let error):
                        print("Waveform extraction failed: \(error.localizedDescription)")
                        self.lastErrorMessage = error.localizedDescription
                        if self.segments.isEmpty, self.duration > 0 {
                            self.segments = self.fallbackSegments(totalDuration: self.duration)
                            self.segmentOrigin = .fallback
                            self.activeSegmentIndex = self.segments.isEmpty ? nil : 0
                            self.persistCurrentProject()
                        }
                    }
                }
            }
        )
    }
    
    /// 执行智能语音停顿断句（基于 Silero VAD 毫秒级声学防吞音模型）
    public func performSmartSegmentation(using data: WaveformData? = nil, config: SileroVADEngine.Config = .standard) {
        let targetData = data ?? self.waveformData
        guard !targetData.isEmpty else { return }
        
        let smartSegments = SileroVADEngine.shared.detectSegments(from: targetData, config: config)
        if !smartSegments.isEmpty {
            self.segments = normalizedSegments(smartSegments, duration: targetData.duration)
            self.segmentOrigin = .vad
            self.activeSegmentIndex = 0
            persistCurrentProject()
        }
    }

    /// 执行智能语音停顿断句（兼容老配置）
    public func performSmartSegmentation(using data: WaveformData? = nil, config: VADSegmenter.Config) {
        let targetData = data ?? self.waveformData
        guard !targetData.isEmpty else { return }
        
        let smartSegments = VADSegmenter.shared.detectSegments(from: targetData, config: config)
        if !smartSegments.isEmpty {
            self.segments = normalizedSegments(smartSegments, duration: targetData.duration)
            self.segmentOrigin = .vad
            self.activeSegmentIndex = 0
            persistCurrentProject()
        }
    }
    
    /// 执行双引擎（Whisper / Speech.framework + Silero VAD）深度 AI 识别与断句，自动提取原文台词与防吞音时间轴
    public func performDualEngineAISegmentation(locale: Locale = Locale(identifier: "en-US")) {
        guard let media = currentMedia else { return }
        let targetData = self.waveformData
        
        isAITranscribing = true
        aiTranscriptionProgress = 0.1
        aiTranscriptionStatusText = LanguageManager.shared.currentLanguage == .zh ? "AI 语音识别中..." : "AI Transcribing..."
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let transcribedSentences = try await SpeechAlignmentEngine.shared.transcribeAudio(
                    from: media.url,
                    locale: locale
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.aiTranscriptionProgress = 0.1 + progress * 0.7
                    }
                }
                
                self.aiTranscriptionProgress = 0.85
                self.aiTranscriptionStatusText = LanguageManager.shared.currentLanguage == .zh ? "声学边界校准中..." : "Calibrating Boundaries..."
                
                let fusedSegments = DualEngineFusionSegmenter.shared.fuse(
                    sentences: transcribedSentences,
                    waveform: targetData
                )
                
                self.segments = self.normalizedSegments(fusedSegments, duration: targetData.duration > 0 ? targetData.duration : self.duration)
                self.segmentOrigin = .ai
                self.activeSegmentIndex = self.segments.isEmpty ? nil : 0
                self.persistCurrentProject()
                
                self.aiTranscriptionProgress = 1.0
                self.isAITranscribing = false
                self.aiTranscriptionStatusText = ""
            } catch {
                // 若离线识别不可用，优雅降级为 Silero VAD 极速断句
                self.performSmartSegmentation(using: targetData)
                self.isAITranscribing = false
                self.aiTranscriptionStatusText = ""
            }
        }
    }
    
    // MARK: - 字幕导入与应用
    
    public func importSubtitleItems(_ items: [ParsedSubtitleItem]) {
        applySubtitleItems(items, origin: .imported, persist: true)
    }

    /// 字幕导入界面的撤销入口；同样经过时间轴清洗，不允许恢复出非法边界。
    public func replaceSegmentsForUndo(_ replacement: [SentenceSegment]) {
        segments = normalizedSegments(replacement, duration: duration)
        segmentOrigin = .imported
        activeSegmentIndex = segments.isEmpty ? nil : 0
        persistCurrentProject()
    }

    private func applySubtitleItems(_ items: [ParsedSubtitleItem], origin: SegmentOrigin, persist: Bool) {
        guard !items.isEmpty else { return }
        let newSegments = items.map { item in
            SentenceSegment(
                index: item.index,
                startTime: item.startTime,
                endTime: item.endTime,
                text: item.text,
                translation: item.translation
            )
        }
        self.segments = normalizedSegments(newSegments, duration: duration)
        self.segmentOrigin = origin
        self.activeSegmentIndex = 0
        if persist { persistCurrentProject() }
    }
    
    public func importPlainTextAndAlign(sentences: [String]) {
        guard !sentences.isEmpty else { return }
        let vadSegments = segments.isEmpty ? VADSegmenter.shared.detectSegments(from: waveformData) : segments
        let alignmentDuration = max(duration, vadSegments.last?.endTime ?? 0)
        guard alignmentDuration > 0, alignmentDuration >= Double(sentences.count) * 0.05 else {
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "媒体时长尚未就绪，暂时无法对齐纯文本。"
                : "The media duration is not ready, so plain text cannot be aligned yet."
            return
        }
        let aligned = TextAlignmentEngine.shared.alignSentences(sentences, with: vadSegments, totalDuration: alignmentDuration)
        self.segments = normalizedSegments(aligned, duration: duration)
        self.segmentOrigin = .imported
        self.activeSegmentIndex = 0
        persistCurrentProject()
    }
    
    public func importPlainText(_ text: String) {
        let sentences = TextAlignmentEngine.shared.splitTextIntoSentences(text)
        importPlainTextAndAlign(sentences: sentences)
    }
    
    public func previewInterval(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        previewEndTime = min(end, duration > 0 ? duration : end)
        seek(to: start) { [weak self] in
            Task { @MainActor [weak self] in
                self?.beginPlayback()
            }
        }
    }
    
    public func shiftAllTimeline(by offsetSeconds: Double) {
        shiftAllSegments(by: offsetSeconds)
    }
    
    private func fallbackSegments(totalDuration: Double) -> [SentenceSegment] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        var result = [SentenceSegment]()
        let step = min(6, max(3, totalDuration / 8))
        var current: Double = 0.0
        var idx = 1
        
        while current < totalDuration {
            let end = min(totalDuration, current + step)
            result.append(SentenceSegment(
                index: idx,
                startTime: current,
                endTime: end,
                text: LanguageManager.shared.currentLanguage == .zh ? "第 \(idx) 句" : "Sentence \(idx)",
                translation: ""
            ))
            current = end
            idx += 1
        }
        return result
    }

    /// 对来自旧工程或外部字幕的时间轴做一次原子清洗，避免 NaN、越界、倒序和重叠导致播放状态失控。
    private func normalizedSegments(_ input: [SentenceSegment], duration: Double) -> [SentenceSegment] {
        let upperBound = duration.isFinite && duration > 0 ? duration : Double.greatestFiniteMagnitude
        let sorted = input.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        var result: [SentenceSegment] = []
        result.reserveCapacity(sorted.count)
        var previousEnd = 0.0

        for source in sorted {
            let start = min(upperBound, max(previousEnd, source.startTime.isFinite ? max(0, source.startTime) : previousEnd))
            let proposedEnd = source.endTime.isFinite ? source.endTime : start + 0.05
            guard proposedEnd > start, start + 0.05 <= upperBound else { continue }
            let end = min(upperBound, max(start + 0.05, proposedEnd))
            guard end > start, start < upperBound else { continue }
            result.append(SentenceSegment(
                id: source.id,
                index: result.count + 1,
                startTime: start,
                endTime: end,
                text: source.text,
                translation: source.translation,
                note: source.note,
                isBookmarked: source.isBookmarked
            ))
            previousEnd = end
        }
        return result
    }
    
    // MARK: - 独立项目工程文件持久化存储
    
    public func persistCurrentProject(includeWaveform: Bool = false) {
        guard let media = currentMedia else { return }
        
        projectFileManager.saveProject(
            for: media.url,
            title: media.title,
            duration: self.duration,
            lastPosition: self.currentTime,
            segments: self.segments,
            waveformData: includeWaveform ? self.waveformData : nil,
            persistWaveform: includeWaveform
        )
    }

    public func flushPendingPersistence() {
        debouncedSaveTask?.cancel()
        persistCurrentProject()
        projectFileManager.flush()
    }
    
    // MARK: - 播放控制与极速 Seek
    
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    public func play() {
        guard currentMedia != nil else { return }
        shadowingTask?.cancel()
        isShadowingPaused = false
        previewEndTime = nil
        beginPlayback()
    }

    private func beginPlayback() {
        guard currentMedia != nil else { return }
        wantsPlayback = true
        guard isBackendReady else {
            pendingResumeTime = currentTime
            pendingResumePlayback = true
            return
        }
        activeBackend.playbackRate = playbackRate
        activeBackend.play()
        isPlaying = true
    }
    
    public func pause() {
        shadowingTask?.cancel()
        isShadowingPaused = false
        pendingResumePlayback = false
        wantsPlayback = false
        activeBackend.pause()
        isPlaying = false
        if currentMedia != nil { scheduleDebouncedPersistence(delay: 0.2) }
    }
    
    public func stop() {
        pause()
        previewEndTime = nil
        seek(to: 0.0)
    }
    
    /// 毫秒级极速精准 Seek（实时刷新视频画面与音频时间戳）
    public func seek(to seconds: Double, completion: (@Sendable () -> Void)? = nil) {
        guard seconds.isFinite else {
            completion?()
            return
        }
        let maximum = duration > 0 ? duration : max(0, seconds)
        let clampedTime = max(0, min(seconds, maximum))
        
        self.currentTime = clampedTime
        updateActiveSegment(for: clampedTime)

        guard isBackendReady else {
            pendingResumeTime = clampedTime
            completion?()
            return
        }

        isSeeking = true
        seekGeneration &+= 1
        let generation = seekGeneration
        let sessionID = mediaSessionID
        let backend = activeBackend
        backend.seek(to: clampedTime) { [weak self, weak backend] in
            Task { @MainActor [weak self] in
                guard let self,
                      let backend,
                      generation == self.seekGeneration,
                      sessionID == self.mediaSessionID,
                      self.activeBackend === backend else { return }
                self.isSeeking = false
                if self.isPlaying {
                    backend.playbackRate = self.playbackRate
                }
                completion?()
            }
        }
    }
    
    public func seekBy(offset: Double) {
        seek(to: currentTime + offset)
    }
    
    // MARK: - 智能复读、跟读停顿与断句边界判定
    
    private func handlePlaybackBoundary(at time: Double) {
        if let previewEndTime, time >= previewEndTime {
            self.previewEndTime = nil
            pause()
            return
        }

        guard let activeIdx = activeSegmentIndex, activeIdx >= 0, activeIdx < segments.count else {
            updateActiveSegment(for: time)
            return
        }
        
        let currentSeg = segments[activeIdx]
        
        // 1. 优先判定当前活跃句是否播完到达末尾（防止时间戳刚过界就被 updateActiveSegment 提前切句导致复读失效）
        if time >= currentSeg.endTime - 0.005 && isPlaying && !isShadowingPaused {
            let needsRepeat = (repeatCountLimit == 0) || (currentRepeatCount < repeatCountLimit) || (loopMode == .singleSegment)
            
            if needsRepeat {
                triggerSentenceRepeat(for: currentSeg)
            } else {
                currentRepeatCount = 1
                advanceToNextSentence(from: activeIdx)
            }
            return
        }
        
        // 2. 如果还在当前句的时间区间内，无需做任何切换
        if currentSeg.contains(time: time) {
            return
        }
        
        // 3. 游标在静音区间或外部时更新活跃句
        updateActiveSegment(for: time)
    }
    
    private func triggerSentenceRepeat(for segment: SentenceSegment) {
        if shadowingPauseRatio > 0 {
            let pauseDuration = max(0.5, segment.duration * shadowingPauseRatio)
            startShadowingPause(duration: pauseDuration) { [weak self] in
                guard let self = self else { return }
                self.currentRepeatCount += 1
                self.seek(to: segment.startTime) {
                    Task { @MainActor [weak self] in
                        self?.play()
                    }
                }
            }
        } else {
            currentRepeatCount += 1
            seek(to: segment.startTime)
        }
    }
    
    private func startShadowingPause(duration: Double, onFinished: @escaping @MainActor () -> Void) {
        activeBackend.pause()
        isShadowingPaused = true
        shadowingCountdownRemaining = duration
        
        shadowingTask?.cancel()
        shadowingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var remaining = duration
            let step = 0.1
            
            while remaining > 0 && !Task.isCancelled {
                self.shadowingCountdownRemaining = remaining
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                remaining -= step
            }
            
            if !Task.isCancelled {
                self.isShadowingPaused = false
                self.shadowingCountdownRemaining = 0
                onFinished()
            }
        }
    }
    
    private func advanceToNextSentence(from currentIndex: Int) {
        let candidateIndices = Array((currentIndex + 1)..<segments.count)
        var targetIndex: Int?
        
        if onlyPlayBookmarked {
            targetIndex = candidateIndices.first(where: { segments[$0].isBookmarked })
            if targetIndex == nil && loopMode == .all {
                targetIndex = segments.firstIndex(where: { $0.isBookmarked })
            }
        } else {
            targetIndex = candidateIndices.first
            if targetIndex == nil && loopMode == .all {
                targetIndex = 0
            }
        }
        
        if loopMode == .pauseAfterSegment {
            pause()
            if let nextIdx = targetIndex {
                jumpToSegment(at: nextIdx)
            } else {
                seek(to: segments[currentIndex].endTime)
            }
            return
        }
        
        if let nextIdx = targetIndex {
            let isNaturalContinuation = !onlyPlayBookmarked && nextIdx == currentIndex + 1
            if isNaturalContinuation {
                // 正常连续播放不再在每个句界做 exact seek，消除音频咔顿和视频掉帧。
                activeSegmentIndex = nextIdx
                currentRepeatCount = 1
                ensureSegmentVisibleInPrimaryViewport(at: nextIdx)
            } else {
                jumpToSegment(at: nextIdx)
            }
        } else {
            pause()
        }
    }
    
    public func updateActiveSegment(for time: Double) {
        guard time.isFinite else { return }
        if let index = segments.firstIndex(where: { $0.contains(time: time) }) {
            if activeSegmentIndex != index {
                activeSegmentIndex = index
            }
        } else if let next = segments.firstIndex(where: { $0.startTime > time }) {
            activeSegmentIndex = next
        } else if !segments.isEmpty {
            activeSegmentIndex = segments.count - 1
        }
    }
    
    // MARK: - 断句快捷操作与难句收藏
    
    /// 确保目标断句在主波形图视口内完整展现（若处于边缘或在视口外，自动平滑移动视口）
    public func ensureSegmentVisibleInPrimaryViewport(at index: Int) {
        guard index >= 0, index < segments.count else { return }
        let seg = segments[index]
        let span = max(1.0, primaryViewport.end - primaryViewport.start)
        
        let padding = span * 0.1
        if seg.startTime < (primaryViewport.start + padding) || seg.endTime > (primaryViewport.end - padding) {
            let segCenter = (seg.startTime + seg.endTime) / 2.0
            let newStart = max(0, segCenter - span / 2.0)
            let maxStart = duration > 0 ? max(0, duration - span) : newStart
            let clampedStart = min(maxStart, newStart)
            let newEnd = min(duration > 0 ? duration : (clampedStart + span), clampedStart + span)
            withAnimation(.easeInOut(duration: 0.25)) {
                primaryViewport = (clampedStart, newEnd)
            }
        }
    }
    
    public func jumpToSegment(at index: Int) {
        guard index >= 0, index < segments.count else { return }
        let seg = segments[index]
        activeSegmentIndex = index
        currentRepeatCount = 1
        ensureSegmentVisibleInPrimaryViewport(at: index)
        updateSecondaryViewportForActiveSegment(force: true)
        seek(to: seg.startTime)
    }

    public func jumpToSegment(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        jumpToSegment(at: idx)
    }
    
    public func previousSegment() {
        guard !segments.isEmpty else { return }
        let current = activeSegmentIndex ?? 0
        let targetIndex: Int
        
        if onlyPlayBookmarked {
            let prevIndices = Array(0..<current).reversed()
            targetIndex = prevIndices.first(where: { segments[$0].isBookmarked }) ?? current
        } else {
            targetIndex = max(0, current - 1)
        }
        jumpToSegment(at: targetIndex)
    }
    
    public func nextSegment() {
        guard !segments.isEmpty else { return }
        let current = activeSegmentIndex ?? 0
        let targetIndex: Int
        
        if onlyPlayBookmarked {
            let nextIndices = Array((current + 1)..<segments.count)
            targetIndex = nextIndices.first(where: { segments[$0].isBookmarked }) ?? current
        } else {
            targetIndex = min(segments.count - 1, current + 1)
        }
        jumpToSegment(at: targetIndex)
    }
    
    public func repeatCurrentSegment() {
        guard let idx = activeSegmentIndex, idx >= 0, idx < segments.count else { return }
        currentRepeatCount = 1
        seek(to: segments[idx].startTime) {
            Task { @MainActor [weak self] in
                self?.play()
            }
        }
    }
    
    public func toggleBookmark(for segmentId: UUID) {
        if let idx = segments.firstIndex(where: { $0.id == segmentId }) {
            segments[idx].isBookmarked.toggle()
            scheduleDebouncedPersistence()
        }
    }
    
    public func updateSegmentAnchor(id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        var seg = segments[idx]
        
        if let s = start, s.isFinite {
            let lowerBound = idx > 0 ? segments[idx - 1].startTime + 0.05 : 0
            let adjusted = max(lowerBound, min(s, seg.endTime - 0.05))
            seg.startTime = adjusted
            if idx > 0 {
                // 相邻边界作为一个事务一起移动，且不允许把前一句压成负时长。
                segments[idx - 1].endTime = adjusted
            }
        }
        if let e = end, e.isFinite {
            let mediaBound = duration > 0 ? duration : Double.greatestFiniteMagnitude
            let upperBound = idx < segments.count - 1
                ? min(mediaBound, segments[idx + 1].endTime - 0.05)
                : mediaBound
            let adjusted = min(upperBound, max(e, seg.startTime + 0.05))
            seg.endTime = adjusted
            if idx < segments.count - 1 {
                segments[idx + 1].startTime = adjusted
            }
        }
        segments[idx] = seg
        scheduleDebouncedPersistence()
    }
    
    public func addSegment(startTime: Double, endTime: Double) {
        guard startTime.isFinite, endTime.isFinite else { return }
        let start = max(0, startTime)
        let mediaBound = duration > 0 ? duration : endTime
        let end = min(mediaBound, endTime)
        guard end >= start + 0.05 else { return }
        guard !segments.contains(where: { start < $0.endTime && end > $0.startTime }) else {
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "新断句不能与现有断句重叠。"
                : "A new sentence cannot overlap an existing sentence."
            return
        }
        let newSeg = SentenceSegment(
            index: segments.count + 1,
            startTime: start,
            endTime: end,
            text: LanguageManager.shared.currentLanguage == .zh
                ? "第 \(segments.count + 1) 句"
                : "Sentence \(segments.count + 1)"
        )
        segments.append(newSeg)
        segments.sort { $0.startTime < $1.startTime }
        reindexSegments()
        activeSegmentIndex = segments.firstIndex(where: { $0.id == newSeg.id })
        persistCurrentProject()
    }
    
    public func deleteSegment(at index: Int) {
        guard index >= 0 && index < segments.count else { return }
        segments.remove(at: index)
        reindexSegments()
        if segments.isEmpty {
            activeSegmentIndex = nil
        } else {
            activeSegmentIndex = min(index, segments.count - 1)
        }
        persistCurrentProject()
    }

    public func deleteSegment(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        deleteSegment(at: idx)
    }
    
    public func splitSegment(at splitTime: Double) {
        var targetIndex = activeSegmentIndex
        if let idx = targetIndex, idx >= 0, idx < segments.count {
            let seg = segments[idx]
            if !(splitTime > seg.startTime + 0.05 && splitTime < seg.endTime - 0.05) {
                targetIndex = segments.firstIndex(where: { splitTime > $0.startTime + 0.05 && splitTime < $0.endTime - 0.05 })
            }
        } else {
            targetIndex = segments.firstIndex(where: { splitTime > $0.startTime + 0.05 && splitTime < $0.endTime - 0.05 })
        }
        guard let idx = targetIndex, idx >= 0, idx < segments.count else { return }
        let current = segments[idx]
        guard splitTime > current.startTime + 0.05 && splitTime < current.endTime - 0.05 else { return }
        
        let seg1 = SentenceSegment(
            id: current.id,
            index: current.index,
            startTime: current.startTime,
            endTime: splitTime,
            text: current.text,
            translation: current.translation,
            note: current.note,
            isBookmarked: current.isBookmarked
        )
        
        let seg2 = SentenceSegment(
            index: current.index + 1,
            startTime: splitTime,
            endTime: current.endTime,
            text: "",
            translation: "",
            isBookmarked: false
        )
        
        segments.remove(at: idx)
        segments.insert(contentsOf: [seg1, seg2], at: idx)
        reindexSegments()
        activeSegmentIndex = idx
        persistCurrentProject()
    }

    public func splitSegment(id: UUID, at splitTime: Double) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let current = segments[idx]
        guard splitTime > current.startTime + 0.05 && splitTime < current.endTime - 0.05 else { return }
        
        let seg1 = SentenceSegment(
            id: current.id,
            index: current.index,
            startTime: current.startTime,
            endTime: splitTime,
            text: current.text,
            translation: current.translation,
            note: current.note,
            isBookmarked: current.isBookmarked
        )
        
        let seg2 = SentenceSegment(
            index: current.index + 1,
            startTime: splitTime,
            endTime: current.endTime,
            text: "",
            translation: "",
            isBookmarked: false
        )
        
        segments.remove(at: idx)
        segments.insert(contentsOf: [seg1, seg2], at: idx)
        reindexSegments()
        activeSegmentIndex = idx
        persistCurrentProject()
    }
    
    public func mergeSegmentWithNext(at index: Int) {
        guard index >= 0 && index < segments.count - 1 else { return }
        let seg1 = segments[index]
        let seg2 = segments[index + 1]
        
        let merged = SentenceSegment(
            id: seg1.id,
            index: seg1.index,
            startTime: seg1.startTime,
            endTime: seg2.endTime,
            text: [seg1.text, seg2.text].filter { !$0.isEmpty }.joined(separator: " "),
            translation: [seg1.translation, seg2.translation].filter { !$0.isEmpty }.joined(separator: " "),
            note: [seg1.note, seg2.note].filter { !$0.isEmpty }.joined(separator: "\n"),
            isBookmarked: seg1.isBookmarked || seg2.isBookmarked
        )
        
        segments.remove(at: index + 1)
        segments[index] = merged
        reindexSegments()
        activeSegmentIndex = index
        persistCurrentProject()
    }

    public func mergeSegmentWithNext(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        mergeSegmentWithNext(at: idx)
    }
    
    public func updateSegmentText(id: UUID, text: String, translation: String? = nil) {
        if let idx = segments.firstIndex(where: { $0.id == id }) {
            segments[idx].text = text
            if let t = translation {
                segments[idx].translation = t
            }
            scheduleDebouncedPersistence()
        }
    }
    
    public func shiftAllSegments(by offsetSeconds: Double) {
        guard offsetSeconds.isFinite, offsetSeconds != 0, !segments.isEmpty else { return }
        segments = normalizedSegments(segments, duration: duration)
        guard !segments.isEmpty else { return }
        let lowerBound = -segments[0].startTime
        let upperBound = duration > 0 ? duration - (segments.last?.endTime ?? duration) : offsetSeconds
        guard duration <= 0 || upperBound >= lowerBound else { return }
        let effectiveOffset = duration > 0
            ? min(max(offsetSeconds, lowerBound), upperBound)
            : max(offsetSeconds, lowerBound)
        for i in 0..<segments.count {
            segments[i].startTime += effectiveOffset
            segments[i].endTime += effectiveOffset
        }
        persistCurrentProject()
    }
    
    private func reindexSegments() {
        for i in 0..<segments.count {
            segments[i].index = i + 1
        }
    }
}
