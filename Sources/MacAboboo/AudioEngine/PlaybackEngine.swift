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
    @Published public private(set) var segmentationWarningMessage: String?
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
    private let autoGenerateSubtitlesKey = "MacAboboo.AutoGenerateSubtitles"
    private let speechRecognitionLanguageKey = "MacAboboo.SpeechRecognitionLanguage"
    private let expectedSpeakerCountKey = "MacAboboo.ExpectedSpeakerCount"
    private let segmentationSentenceLengthKey = "MacAboboo.SegmentationSentenceLength"
    private let boundarySnapHapticFeedbackKey = "MacAboboo.BoundarySnapHapticFeedback"
    @Published public var autoGenerateSubtitles: Bool {
        didSet {
            UserDefaults.standard.set(autoGenerateSubtitles, forKey: autoGenerateSubtitlesKey)
        }
    }
    /// `auto` 会由 Whisper 从音频中检测语言；也可锁定常用语言以减少误判。
    @Published public var speechRecognitionLanguage: String {
        didSet {
            UserDefaults.standard.set(speechRecognitionLanguage, forKey: speechRecognitionLanguageKey)
        }
    }
    /// Optional known speaker count. Supplying it prevents noisy recordings
    /// from being over/under-clustered by automatic diarization.
    @Published public var expectedSpeakerCount: Int? {
        didSet {
            UserDefaults.standard.set(expectedSpeakerCount ?? 0, forKey: expectedSpeakerCountKey)
        }
    }
    /// 用户界面使用三种预设，内部仍映射到六个成熟 profile。
    @Published public var segmentationSentenceLength: SpeechSentenceLength {
        didSet {
            UserDefaults.standard.set(segmentationSentenceLength.rawValue, forKey: segmentationSentenceLengthKey)
        }
    }
    /// 在边界吸附成功时提供 macOS 触觉反馈；默认开启，可在设置中关闭。
    @Published public var boundarySnapHapticFeedback: Bool {
        didSet {
            UserDefaults.standard.set(boundarySnapHapticFeedback, forKey: boundarySnapHapticFeedbackKey)
        }
    }

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
    private var segmentationTask: Task<Void, Never>?
    private var modelIdleUnloadTask: Task<Void, Never>?
    private var previewSeekTask: Task<Void, Never>?
    private var pendingPreviewSeekTime: Double?
    private var segmentationRequestID = UUID()
    private var mediaSessionID = UUID()
    private var seekGeneration: UInt64 = 0
    /// AVPlayer/libmpv should always finish a seek, but a cancelled seek can
    /// occasionally lose its callback while switching sentences quickly. A
    /// bounded fallback keeps the engine from remaining in `isSeeking` forever.
    private var seekTimeoutTask: Task<Void, Never>?
    private struct BoundarySnapMarker: Equatable {
        let segmentID: UUID
        let isStart: Bool
        let timeMilliseconds: Int64
    }
    private var acousticBoundaryTimes: [Double] = []
    private var activeBoundarySnapMarker: BoundarySnapMarker?
    private struct ExplicitSegmentSelection {
        let segmentID: UUID
        var hasCompletedSeek: Bool
    }
    /// AVPlayer may complete an exact seek a fraction of a frame before a
    /// sentence boundary. Preserve an explicitly clicked sentence across that
    /// decoder rounding only; ordinary timeline seeks still follow real time.
    private var explicitSegmentSelection: ExplicitSegmentSelection?
    private var isBackendReady = false
    private var wantsPlayback = false
    /// 自然播放到最后一句后，允许用户点击任意断句重新开始播放。
    /// 该状态只在自然结束时保留；用户主动暂停/停止后必须清除，避免
    /// 普通的暂停状态在点击断句时意外自动播放。
    private var canResumePlaybackFromSegmentSelection = false
    private var pendingResumeTime: Double = 0
    private var pendingResumePlayback = false
    private var previewEndTime: Double?
    private var securityScopedMediaURL: URL?
    private let projectFileManager: ProjectFileManager
    private let playbackHistoryStore: PlaybackHistoryStore?
    private var suppressCurrentProjectPersistence = false
    private var hasCompletedSegmentation = false

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
            mpvBackend: LazyMPVPlayerBackend(),
            projectFileManager: .shared,
            playbackHistoryStore: .shared
        )
    }

    public init(
        nativeBackend: MediaPlayerBackend,
        mpvBackend: MediaPlayerBackend,
        projectFileManager: ProjectFileManager = .shared,
        playbackHistoryStore: PlaybackHistoryStore? = nil
    ) {
        self.nativeBackend = nativeBackend
        self.mpvBackend = mpvBackend
        self.activeBackend = nativeBackend
        self.projectFileManager = projectFileManager
        self.playbackHistoryStore = playbackHistoryStore
        self.autoGenerateSubtitles = (UserDefaults.standard.object(forKey: autoGenerateSubtitlesKey) as? Bool) ?? true
        self.speechRecognitionLanguage = UserDefaults.standard.string(forKey: speechRecognitionLanguageKey) ?? "auto"
        let savedSpeakerCount = UserDefaults.standard.integer(forKey: expectedSpeakerCountKey)
        self.expectedSpeakerCount = (2...8).contains(savedSpeakerCount) ? savedSpeakerCount : nil
        self.segmentationSentenceLength = UserDefaults.standard.string(forKey: segmentationSentenceLengthKey)
            .flatMap(SpeechSentenceLength.init(rawValue:)) ?? .standard
        self.boundarySnapHapticFeedback = (UserDefaults.standard.object(forKey: boundarySnapHapticFeedbackKey) as? Bool) ?? true
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
            guard let self,
                  self.activeBackend === backend,
                  self.isBackendReady,
                  !self.isSeeking else { return }
            self.updateMediaDurationIfNeeded(total)
            self.currentTime = current
            self.handlePlaybackBoundary(at: current)
            self.followPlaybackIfNeeded(at: current)
        }

        backend.onStateChanged = { [weak self, weak backend] playing in
            guard let self, let backend, self.activeBackend === backend else { return }
            if !self.isShadowingPaused {
                self.isPlaying = playing
            }
        }

        backend.onFinished = { [weak self, weak backend] in
            guard let self, self.activeBackend === backend else { return }
            let hadPlaybackIntent = self.wantsPlayback
            self.isPlaying = false
            if self.loopMode == .all {
                self.seek(to: 0.0) {
                    Task { @MainActor [weak self] in
                        self?.play()
                    }
                }
            } else {
                self.wantsPlayback = false
                // 保留一次“自然结束后点击断句即可继续播放”的意图。
                // 如果用户在结束回调前已经主动暂停，不能把普通暂停误判为自然结束。
                if hadPlaybackIntent {
                    self.canResumePlaybackFromSegmentSelection = true
                }
            }
        }

        backend.onError = { [weak self, weak backend] error in
            guard let self, self.activeBackend === backend else { return }
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
            guard let self,
                  let backend,
                  sessionID == self.mediaSessionID,
                  self.activeBackend === backend else { return }

            if success, backend.loadedURL?.standardizedFileURL == url.standardizedFileURL {
                self.isBackendReady = true
                self.isMediaLoading = false
                self.playbackHistoryStore?.recordPlayed(url)
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
        activeBoundarySnapMarker = nil
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

    public func setHighFrequencyPresentationEnabled(_ enabled: Bool) {
        nativeBackend.setHighFrequencyPresentationEnabled(enabled)
        mpvBackend.setHighFrequencyPresentationEnabled(enabled)
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

        suppressCurrentProjectPersistence = false
        if !isAlreadyScoped {
            securityScopedMediaURL?.stopAccessingSecurityScopedResource()
            securityScopedMediaURL = didStartSecurityScope ? mediaURL : nil
        }

        mediaSessionID = UUID()
        let sessionID = mediaSessionID
        seekGeneration &+= 1
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        previewSeekTask?.cancel()
        previewSeekTask = nil
        pendingPreviewSeekTime = nil
        shadowingTask?.cancel()
        waveformTask?.cancel()
        sidecarTask?.cancel()
        segmentationTask?.cancel()
        segmentationRequestID = UUID()
        isAITranscribing = false
        aiTranscriptionProgress = 0
        aiTranscriptionStatusText = ""
        activeBackend.pause()
        isShadowingPaused = false
        shadowingCountdownRemaining = 0
        previewEndTime = nil
        isSeeking = false
        isBackendReady = false
        pendingResumeTime = 0
        pendingResumePlayback = false
        lastErrorMessage = nil
        segmentationWarningMessage = nil
        currentRepeatCount = 1
        segmentOrigin = .none
        hasCompletedSegmentation = false
        acousticBoundaryTimes = []
        activeBoundarySnapMarker = nil
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
        canResumePlaybackFromSegmentSelection = false

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
            async let savedProjectResult = self.projectFileManager.loadProjectAsync(for: mediaURL)
            async let sidecarItemsResult = self.loadSidecarItems(for: mediaURL)
            let (savedProject, sidecarItems) = await (savedProjectResult, sidecarItemsResult)
            guard !Task.isCancelled,
                  sessionID == self.mediaSessionID,
                  self.currentMedia?.url.standardizedFileURL == mediaURL else { return }

            let compatibleProject = savedProject.flatMap { project in
                project.isCompatible(with: mediaURL) ? project : nil
            }
            if let compatibleProject {
                self.restoreProject(compatibleProject, for: mediaURL)
            }

            // 同名字幕始终接管断句时间轴，但仍复用工程中的播放位置和波形。
            if let sidecarItems, !sidecarItems.isEmpty {
                self.applySubtitleItems(sidecarItems, origin: .sidecar, persist: true)
                if let compatibleProject,
                   let savedWaveform = compatibleProject.waveformData,
                   !savedWaveform.isEmpty {
                    self.waveformData = savedWaveform
                    self.waveformExtractionProgress = 1
                    if self.duration <= 0 { self.updateMediaDurationIfNeeded(savedWaveform.duration) }
                    if compatibleProject.schemaVersion < MediaProjectFile.currentSchemaVersion || compatibleProject.waveformCacheFile == nil {
                        self.persistCurrentProject(includeWaveform: true)
                    }
                    return
                }
                self.extractWaveform(from: mediaURL, sessionID: sessionID)
                return
            }

            if let compatibleProject {
                if let savedWaveform = compatibleProject.waveformData, !savedWaveform.isEmpty {
                    self.waveformData = savedWaveform
                    self.waveformExtractionProgress = 1
                    if self.duration <= 0 { self.updateMediaDurationIfNeeded(savedWaveform.duration) }
                    if self.segments.isEmpty && !self.hasCompletedSegmentation {
                        self.performSmartSegmentation(using: savedWaveform)
                    }
                    if compatibleProject.schemaVersion < MediaProjectFile.currentSchemaVersion || compatibleProject.waveformCacheFile == nil {
                        self.persistCurrentProject(includeWaveform: true)
                    }
                    return
                }
            }

            self.extractWaveform(from: mediaURL, sessionID: sessionID)
        }
    }

    private func restoreProject(_ project: MediaProjectFile, for mediaURL: URL) {
        segmentOrigin = .project
        hasCompletedSegmentation = project.hasCompletedSegmentation
        if duration <= 0 { updateMediaDurationIfNeeded(project.duration) }
        let effectiveDuration = duration > 0 ? duration : project.duration
        acousticBoundaryTimes = project.acousticBoundaryTimes.filter { boundary in
            boundary.isFinite
                && boundary >= 0
                && (effectiveDuration <= 0 || boundary <= effectiveDuration)
        }
        activeBoundarySnapMarker = nil
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
                    cancelSegmentation()
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
                    if !interimData.isEmpty {
                        self.waveformData = interimData
                    }
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
                        // 备用解码器也失败时保留真实的空时间轴，禁止伪造固定时长断句。
                    }
                }
            }
        )
    }

    /// 面向用户的三种断句预设入口。媒体切换或再次启动断句时，旧请求会被取消且不能回写结果。
    public func performSegmentation(
        preset: SpeechSegmentationPreset,
        showProgress: Bool = true,
        languageOverride: String? = nil
    ) {
        performSegmentation(
            mode: internalMode(for: preset),
            showProgress: showProgress,
            languageOverride: languageOverride
        )
    }

    private func internalMode(for preset: SpeechSegmentationPreset) -> SpeechSegmentationMode {
        preset.mode(for: segmentationSentenceLength)
    }

    /// 六个内部 profile 的统一断句入口。兼容旧菜单与外部调用方。
    public func performSegmentation(
        mode: SpeechSegmentationMode,
        showProgress: Bool = true,
        languageOverride: String? = nil,
        completion: (@MainActor ([SentenceSegment]) -> Void)? = nil,
        waveformData suppliedWaveform: WaveformData? = nil
    ) {
        guard let media = currentMedia else { return }
        let mediaURL = media.url.standardizedFileURL
        let sessionID = mediaSessionID
        let requestID = UUID()
        segmentationRequestID = requestID
        segmentationTask?.cancel()
        modelIdleUnloadTask?.cancel()
        acousticBoundaryTimes = []
        activeBoundarySnapMarker = nil

        let modelManager = WhisperModelManager.shared
        let modelURL = mode.requiresTranscription
            ? modelManager.modelFileURL(for: modelManager.selectedModelLevel)
            : nil
        let request = SpeechSegmentationRequest(
            mediaURL: mediaURL,
            mode: mode,
            whisperModelURL: modelURL,
            recognitionLanguage: languageOverride ?? speechRecognitionLanguage,
            includeRecognizedText: autoGenerateSubtitles,
            numberOfSpeakers: expectedSpeakerCount,
            waveformData: suppliedWaveform ?? (waveformData.isEmpty ? nil : waveformData)
        )

        if showProgress {
            isAITranscribing = true
            aiTranscriptionProgress = 0
            aiTranscriptionStatusText = localizedSegmentationStatus(for: .decodingAudio(0), mode: mode)
        }
        lastErrorMessage = nil
        segmentationWarningMessage = nil

        segmentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await SpeechSegmentationPipeline.shared.run(
                    request: request,
                    stageChanged: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  sessionID == self.mediaSessionID,
                                  requestID == self.segmentationRequestID,
                                  self.currentMedia?.url.standardizedFileURL == mediaURL else { return }
                            if showProgress {
                                self.aiTranscriptionProgress = self.segmentationProgress(for: stage)
                                self.aiTranscriptionStatusText = self.localizedSegmentationStatus(for: stage, mode: mode)
                            }
                        }
                    },
                    preview: { [weak self] previewSegments in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  !Task.isCancelled,
                                  sessionID == self.mediaSessionID,
                                  requestID == self.segmentationRequestID,
                                  self.currentMedia?.url.standardizedFileURL == mediaURL,
                                  !previewSegments.isEmpty else { return }
                            let effectiveDuration = self.duration > 0
                                ? self.duration
                                : (previewSegments.last?.endTime ?? 0)
                            self.segments = self.normalizedSegments(previewSegments, duration: effectiveDuration)
                            self.segmentOrigin = .vad
                            self.activeSegmentIndex = self.segments.isEmpty ? nil : 0
                        }
                    }
                )

                try Task.checkCancellation()
                guard sessionID == self.mediaSessionID,
                      requestID == self.segmentationRequestID,
                      self.currentMedia?.url.standardizedFileURL == mediaURL else { return }
                let effectiveDuration = self.duration > 0
                    ? self.duration
                    : (output.segments.last?.endTime ?? 0)
                self.segments = self.normalizedSegments(output.segments, duration: effectiveDuration)
                self.segmentOrigin = mode.requiresTranscription ? .ai : .vad
                self.hasCompletedSegmentation = true
                self.acousticBoundaryTimes = output.acousticBoundaryTimes
                self.activeBoundarySnapMarker = nil
                self.activeSegmentIndex = self.segments.isEmpty ? nil : 0
                self.segmentationWarningMessage = output.warnings.first
                self.persistCurrentProject()
                completion?(self.segments)
                if showProgress {
                    self.aiTranscriptionProgress = 1
                    self.isAITranscribing = false
                    self.aiTranscriptionStatusText = ""
                }
                self.scheduleIdleModelRelease()
            } catch is CancellationError {
                guard requestID == self.segmentationRequestID else { return }
                if showProgress {
                    self.isAITranscribing = false
                    self.aiTranscriptionStatusText = ""
                }
                self.scheduleIdleModelRelease()
            } catch {
                guard sessionID == self.mediaSessionID,
                      requestID == self.segmentationRequestID,
                      self.currentMedia?.url.standardizedFileURL == mediaURL else { return }
                self.lastErrorMessage = error.localizedDescription
                self.isAITranscribing = false
                self.aiTranscriptionStatusText = ""
                self.scheduleIdleModelRelease()
            }
        }
    }

    public func cancelSegmentation() {
        segmentationTask?.cancel()
        segmentationTask = nil
        segmentationRequestID = UUID()
        isAITranscribing = false
        aiTranscriptionStatusText = ""
        segmentationWarningMessage = nil
        scheduleIdleModelRelease()
    }

    private func scheduleIdleModelRelease() {
        modelIdleUnloadTask?.cancel()
        modelIdleUnloadTask = Task(priority: .background) {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            await SpeechSegmentationPipeline.shared.clearCaches()
            await AudioPCMExtractor.shared.purgeMemoryCache()
            WaveformExtractor.shared.purgeMemoryCache()
            await SpeakerDiarizationEngine.shared.unloadModels()
            await NativeSpeechRuntime.shared.unloadModels()
        }
    }

    /// 兼容原菜单与调用方；配置仅用于映射到三种统一 Silero 模式。
    public func performSmartSegmentation(
        using data: WaveformData? = nil,
        config: SileroVADEngine.Config = .standard,
        showProgress: Bool = true
    ) {
        let mode: SpeechSegmentationMode
        switch config.minSilenceDuration {
        case ..<0.28: mode = .vadSensitive
        case 0.40...: mode = .vadRelaxed
        default: mode = .vadStandard
        }
        performSegmentation(
            mode: mode,
            showProgress: showProgress,
            waveformData: data
        )
    }

    /// 执行智能语音停顿断句（兼容老配置）
    public func performSmartSegmentation(using data: WaveformData? = nil, config: VADSegmenter.Config) {
        let mode: SpeechSegmentationMode
        switch config.minSilenceDuration {
        case ..<0.28: mode = .vadSensitive
        case 0.40...: mode = .vadRelaxed
        default: mode = .vadStandard
        }
        performSegmentation(
            mode: mode,
            showProgress: true,
            waveformData: data
        )
    }

    public func performDualEngineAISegmentation(locale: Locale? = nil) {
        performSegmentation(
            mode: .semanticAcousticFusion,
            languageOverride: locale.flatMap(Self.whisperLanguageCode)
        )
    }

    /// 兼容旧 profile：执行 Silero + Whisper 联合双模断句。
    public func performSileroWhisperCascadeSegmentation(
        vadConfig: SileroVADEngine.Config = .cascade,
        locale: Locale? = nil
    ) {
        _ = vadConfig
        performSegmentation(
            mode: .sileroWhisperCascade,
            languageOverride: locale.flatMap(Self.whisperLanguageCode)
        )
    }

    /// 兼容旧 profile：执行纯 Whisper 独立高精断句。
    public func performPureWhisperSegmentation(locale: Locale? = nil) {
        performSegmentation(
            mode: .whisperSemantic,
            languageOverride: locale.flatMap(Self.whisperLanguageCode)
        )
    }

    private static func whisperLanguageCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier
    }

    private func segmentationProgress(for stage: SpeechSegmentationStage) -> Double {
        switch stage {
        case .decodingAudio(let progress): return min(0.20, max(0, progress) * 0.20)
        case .detectingVoice: return 0.22
        case .diarizing(let progress): return 0.24 + min(1, max(0, progress)) * 0.12
        case .transcribing(let progress): return 0.38 + min(1, max(0, progress)) * 0.50
        case .optimizing: return 0.95
        }
    }

    private func localizedSegmentationStatus(
        for stage: SpeechSegmentationStage,
        mode: SpeechSegmentationMode
    ) -> String {
        let chinese = LanguageManager.shared.currentLanguage == .zh
        switch stage {
        case .decodingAudio:
            return chinese ? "正在统一解码为 16 kHz 音频…" : "Decoding unified 16 kHz audio…"
        case .detectingVoice:
            return chinese ? "Silero 正在检测真实人声与停顿…" : "Silero is detecting speech and pauses…"
        case .diarizing:
            return chinese ? "SpeakerKit 正在识别说话人与重叠语音…" : "SpeakerKit is identifying speakers and overlap…"
        case .transcribing:
            return chinese ? "Whisper 正在识别词级时间戳与语义…" : "Whisper is recognizing words and timestamps…"
        case .optimizing:
            if mode == .whisperSemantic {
                return chinese ? "正在全局优化语义边界…" : "Optimizing semantic boundaries…"
            }
            return chinese ? "正在融合语义、停顿与声学边界…" : "Fusing semantic, pause, and acoustic boundaries…"
        }
    }

    // MARK: - 字幕导入与应用

    public func importSubtitleItems(
        _ items: [ParsedSubtitleItem],
        target: SubtitleImportTarget = .automatic
    ) {
        let mappedItems = target.apply(to: items)
        guard !mappedItems.isEmpty else { return }
        sidecarTask?.cancel()
        sidecarTask = nil
        cancelSegmentation()
        segments = []
        activeSegmentIndex = nil
        segmentOrigin = .none
        hasCompletedSegmentation = false
        applySubtitleItems(mappedItems, origin: .imported, persist: true)
    }

    /// 字幕导入界面的撤销入口；同样经过时间轴清洗，不允许恢复出非法边界。
    public func replaceSegmentsForUndo(_ replacement: [SentenceSegment]) {
        segments = normalizedSegments(replacement, duration: duration)
        segmentOrigin = .imported
        hasCompletedSegmentation = true
        acousticBoundaryTimes = []
        activeBoundarySnapMarker = nil
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
        self.hasCompletedSegmentation = true
        self.acousticBoundaryTimes = []
        self.activeBoundarySnapMarker = nil
        self.activeSegmentIndex = 0
        if persist { persistCurrentProject() }
    }

    public func importPlainTextAndAlign(sentences: [String]) {
        guard !sentences.isEmpty else { return }
        guard !segments.isEmpty else {
            guard currentMedia != nil else {
                lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                    ? "请先打开音视频文件，再导入纯文本。"
                    : "Open an audio or video file before importing plain text."
                return
            }
            // Generate a real PCM + Silero/SpeakerKit timeline first. The old
            // waveform-only compatibility detector is intentionally not used
            // here because peak amplitude is not a VAD probability.
            performSegmentation(mode: .vadStandard, showProgress: true) { [weak self] generated in
                self?.alignImportedText(sentences, with: generated)
            }
            return
        }
        alignImportedText(sentences, with: segments)
    }

    private func alignImportedText(_ sentences: [String], with vadSegments: [SentenceSegment]) {
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
        self.hasCompletedSegmentation = true
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
                isBookmarked: source.isBookmarked,
                speakerID: source.speakerID,
                speakerIDs: source.speakerIDs,
                isSpeakerOverlap: source.isSpeakerOverlap
            ))
            previousEnd = end
        }
        return result
    }

    // MARK: - 独立项目工程文件持久化存储

    public func persistCurrentProject(includeWaveform: Bool = false) {
        guard let media = currentMedia, !suppressCurrentProjectPersistence else { return }

        projectFileManager.saveProject(
            for: media.url,
            title: media.title,
            duration: self.duration,
            lastPosition: self.currentTime,
            segments: self.segments,
            waveformData: includeWaveform ? self.waveformData : nil,
            persistWaveform: includeWaveform,
            hasCompletedSegmentation: hasCompletedSegmentation,
            acousticBoundaryTimes: acousticBoundaryTimes
        )
    }

    public func flushPendingPersistence() {
        debouncedSaveTask?.cancel()
        persistCurrentProject()
        projectFileManager.flush()
        playbackHistoryStore?.flush()
    }

    /// 从播放列表移除媒体并清理其工程记录；原始音视频文件保持不变。
    public func removeFromPlaybackHistory(_ mediaURL: URL) async {
        let standardizedURL = mediaURL.standardizedFileURL
        if currentMedia?.url.standardizedFileURL == standardizedURL {
            debouncedSaveTask?.cancel()
            suppressCurrentProjectPersistence = true
        }
        playbackHistoryStore?.remove(standardizedURL)
        do {
            try await projectFileManager.deleteProjectAsync(for: standardizedURL)
        } catch {
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "删除该文件的工程记录失败：\(error.localizedDescription)"
                : "Unable to delete project records for this file: \(error.localizedDescription)"
        }
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
        // A sentence selection starts an asynchronous seek. Starting the
        // backend while that seek is still in flight can cancel AVPlayer's
        // seek (especially for non-keyframe timestamps), leaving the player
        // showing the target time but not advancing. Keep the user's play
        // request as intent and resume only from the seek completion path.
        guard !isSeeking else {
            pendingResumeTime = currentTime
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
        canResumePlaybackFromSegmentSelection = false
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
        explicitSegmentSelection = nil
        performSeek(to: seconds, completion: completion)
    }

    /// Pauses active playback for the duration of a video timeline preview,
    /// while preserving `wantsPlayback` so the final exact seek can resume it.
    public func beginPreviewSeek() {
        previewSeekTask?.cancel()
        previewSeekTask = nil
        pendingPreviewSeekTime = nil
        guard isBackendReady else { return }
        if isPlaying || wantsPlayback {
            activeBackend.pause()
            isPlaying = false
        }
    }

    /// Sends the newest scrub target at most 30 times per second.  The
    /// backend's preview path is intentionally separate from exact sentence
    /// seeking and does not update the active segment or persistence state.
    public func previewSeek(to seconds: Double) {
        guard isBackendReady, seconds.isFinite else { return }
        let maximum = duration > 0 ? duration : max(0, seconds)
        pendingPreviewSeekTime = max(0, min(seconds, maximum))
        guard previewSeekTask == nil else { return }

        previewSeekTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let target = self.pendingPreviewSeekTime else { break }
                self.pendingPreviewSeekTime = nil
                self.activeBackend.previewSeek(to: target)
                do {
                    try await Task.sleep(nanoseconds: 33_000_000)
                } catch {
                    break
                }
            }
            self?.previewSeekTask = nil
        }
    }

    public func endPreviewSeek() {
        pendingPreviewSeekTime = nil
        previewSeekTask?.cancel()
        previewSeekTask = nil
    }

    /// Returns a nearby high-confidence acoustic boundary, or the original
    /// target when no safe snap exists.  Snapping is deliberately constrained
    /// by the same non-overlap bounds used by `updateSegmentAnchor`.
    public func snappedBoundaryTime(id: UUID, proposed: Double, isStart: Bool) -> Double {
        guard proposed.isFinite,
              let idx = segments.firstIndex(where: { $0.id == id }) else { return proposed }
        let segment = segments[idx]
        let lowerBound = isStart
            ? (idx > 0 ? segments[idx - 1].endTime : 0)
            : segment.startTime + 0.05
        let upperBound = isStart
            ? segment.endTime - 0.05
            : (idx < segments.count - 1
                ? min(duration > 0 ? duration : Double.greatestFiniteMagnitude, segments[idx + 1].startTime)
                : (duration > 0 ? duration : Double.greatestFiniteMagnitude))
        guard lowerBound <= upperBound else { return proposed }
        let clamped = max(lowerBound, min(proposed, upperBound))
        let snapWindow = 0.03

        let acousticCandidate = acousticBoundaryTimes
            .filter { abs($0 - clamped) <= snapWindow }
            .min { abs($0 - clamped) < abs($1 - clamped) }
        let candidate = acousticCandidate ?? localWaveformValley(near: clamped, window: snapWindow)
        guard let candidate,
              abs(candidate - clamped) <= snapWindow else {
            activeBoundarySnapMarker = nil
            return clamped
        }

        let snapped = max(lowerBound, min(candidate, upperBound))
        guard abs(snapped - clamped) <= snapWindow else {
            activeBoundarySnapMarker = nil
            return clamped
        }

        let marker = BoundarySnapMarker(
            segmentID: id,
            isStart: isStart,
            timeMilliseconds: Int64((snapped * 1000).rounded())
        )
        if activeBoundarySnapMarker != marker {
            activeBoundarySnapMarker = marker
            if boundarySnapHapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        return snapped
    }

    private func localWaveformValley(near time: Double, window: Double) -> Double? {
        guard !waveformData.isEmpty,
              waveformData.sampleRate.isFinite,
              waveformData.sampleRate > 0,
              time.isFinite else { return nil }
        let peaks = waveformData.peaks
        guard peaks.count >= 5 else { return nil }
        let center = Int((time * waveformData.sampleRate).rounded())
        let radius = max(1, Int((window * waveformData.sampleRate).rounded(.up)))
        let lower = max(1, center - radius)
        let upper = min(peaks.count - 2, center + radius)
        guard lower <= upper else { return nil }
        let index = (lower...upper).min { peaks[$0] < peaks[$1] }
        guard let index else { return nil }
        let flankRadius = max(2, radius)
        let left = peaks[max(0, index - flankRadius)]
        let right = peaks[min(peaks.count - 1, index + flankRadius)]
        let flank = max(left, right)
        let energy = peaks[index]
        guard energy <= 0.20 || energy <= flank * 0.72 else { return nil }
        return Double(index) / waveformData.sampleRate
    }

    private func seekToExplicitlySelectedSegment(
        _ segment: SentenceSegment,
        completion: (@Sendable () -> Void)? = nil
    ) {
        explicitSegmentSelection = ExplicitSegmentSelection(
            segmentID: segment.id,
            hasCompletedSeek: false
        )
        performSeek(to: segment.startTime, completion: completion)
    }

    private func performSeek(to seconds: Double, completion: (@Sendable () -> Void)?) {
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

        // Keep playback intent while the asynchronous seek is in flight.
        // `beginPlayback()` defers a Play request until this callback so it
        // cannot cancel an AVPlayer seek at a non-keyframe timestamp.
        isSeeking = true
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
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
                      self.activeBackend === backend,
                      self.isSeeking else { return }
                self.seekTimeoutTask?.cancel()
                self.seekTimeoutTask = nil
                let backendTime = backend.currentTime
                if backendTime.isFinite, backendTime >= 0 {
                    self.explicitSegmentSelection?.hasCompletedSeek = true
                    self.currentTime = backendTime
                    self.updateActiveSegment(for: backendTime)
                }
                self.isSeeking = false
                if self.wantsPlayback {
                    backend.playbackRate = self.playbackRate
                    backend.play()
                    self.isPlaying = true
                }
                completion?()
            }
        }

        // Do not let a backend callback omission permanently block time
        // updates. The normal callback wins; this path only runs when the
        // current seek is still pending after a generous decoder window.
        seekTimeoutTask = Task { @MainActor [weak self, weak backend] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self,
                  let backend,
                  generation == self.seekGeneration,
                  sessionID == self.mediaSessionID,
                  self.activeBackend === backend,
                  self.isSeeking else { return }
            self.seekTimeoutTask = nil
            self.isSeeking = false
            if self.wantsPlayback {
                backend.playbackRate = self.playbackRate
                backend.play()
                self.isPlaying = true
            }
            completion?()
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

        // 间隙中沿用既有的“预选下一句”状态，避免每个时钟 Tick 再进入查找。
        if isSilenceImmediatelyBeforeActiveSegment(time: time, index: activeIdx) {
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
        var targetIndex: Int?

        if onlyPlayBookmarked {
            var index = currentIndex + 1
            while index < segments.count {
                if segments[index].isBookmarked {
                    targetIndex = index
                    break
                }
                index += 1
            }
            if targetIndex == nil && loopMode == .all {
                targetIndex = segments.firstIndex(where: { $0.isBookmarked })
            }
        } else {
            targetIndex = currentIndex + 1 < segments.count ? currentIndex + 1 : nil
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
            if loopMode == .normal {
                // 连续播放模式：如果下一句紧贴当前句末尾，直接让 AVPlayer
                // 沿当前时间流自然前进，不再对“当前时间 == 下一句起点”
                // 发起一次零容差 Seek。AVPlayer 在这个边界上可能报告 Seek
                // 已完成，但实际 timeControlStatus 仍停在暂停，导致界面显示
                // 正在播放而时间永远停在下一句起点。
                let nextSegment = segments[nextIdx]
                let isAdjacentNaturalContinuation =
                    !onlyPlayBookmarked &&
                    nextIdx == currentIndex + 1 &&
                    abs(nextSegment.startTime - currentTime) <= 0.04

                if isAdjacentNaturalContinuation {
                    activeSegmentIndex = nextIdx
                    currentRepeatCount = 1
                    ensureSegmentVisibleInPrimaryViewport(at: nextIdx)
                    updateSecondaryViewportForActiveSegment(force: true)

                    // 正常情况下后端仍在播放；如果系统解码器在边界瞬间
                    // 报告了暂停，补发一次播放命令，但不再触发 Seek。
                    if wantsPlayback && !activeBackend.isPlaying {
                        activeBackend.playbackRate = playbackRate
                        activeBackend.play()
                        isPlaying = true
                    }
                } else {
                    // 两句之间存在可见间隔时，仍然 Seek 到下一句起点，
                    // 保持连续播放跳过空白区的既有行为。
                    jumpToSegment(at: nextIdx)
                }
            } else {
                let isNaturalContinuation = !onlyPlayBookmarked && nextIdx == currentIndex + 1
                if isNaturalContinuation {
                    // 全曲循环等模式下：按媒体真实时间流自然过渡
                    activeSegmentIndex = nextIdx
                    currentRepeatCount = 1
                    ensureSegmentVisibleInPrimaryViewport(at: nextIdx)
                } else {
                    jumpToSegment(at: nextIdx)
                }
            }
        } else {
            if loopMode == .normal {
                finishPlaybackAtNaturalEnd()
            } else {
                pause()
            }
        }
    }

    /// 断句连续播放自然到达最后一句末尾时停止，但保留一次由断句选择
    /// 触发的恢复意图。这样列表点击不会改变普通暂停的行为，同时可以
    /// 从最后一句结束后的任意断句重新开始播放。
    private func finishPlaybackAtNaturalEnd() {
        shadowingTask?.cancel()
        isShadowingPaused = false
        pendingResumePlayback = false
        wantsPlayback = false
        canResumePlaybackFromSegmentSelection = true
        activeBackend.pause()
        isPlaying = false
        if currentMedia != nil { scheduleDebouncedPersistence(delay: 0.2) }
    }

    public func updateActiveSegment(for time: Double) {
        guard time.isFinite else { return }
        guard !segments.isEmpty else { return }

        if let explicitSelection = explicitSegmentSelection {
            if let targetIndex = segments.firstIndex(where: { $0.id == explicitSelection.segmentID }) {
                let target = segments[targetIndex]
                // One 60 Hz UI frame plus a small decoder rounding margin.
                // This is deliberately far below a meaningful subtitle offset.
                let earlySeekTolerance = 0.025
                if time >= target.startTime - earlySeekTolerance, time < target.endTime {
                    if activeSegmentIndex != targetIndex {
                        activeSegmentIndex = targetIndex
                    }
                    if explicitSelection.hasCompletedSeek, time >= target.startTime {
                        explicitSegmentSelection = nil
                    }
                    return
                }
            }
            explicitSegmentSelection = nil
        }

        if let current = activeSegmentIndex, segments.indices.contains(current) {
            if segments[current].contains(time: time) { return }
            // 保持“静音间隙预选下一句”的既有语义，但一旦已经选中正确的
            // 下一句，就不再每个播放时钟 Tick 重复二分查找和发布相同索引。
            if isSilenceImmediatelyBeforeActiveSegment(time: time, index: current) { return }
            let next = current + 1
            if segments.indices.contains(next), segments[next].contains(time: time) {
                activeSegmentIndex = next
                return
            }
            let previous = current - 1
            if segments.indices.contains(previous), segments[previous].contains(time: time) {
                activeSegmentIndex = previous
                return
            }
        }

        // Segments are kept sorted and non-overlapping. Find the first range
        // whose end lies after the requested time; this is either the range
        // containing the time or the next sentence across a silent gap.
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].endTime > time {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let resolvedIndex = lower < segments.count ? lower : segments.count - 1
        if activeSegmentIndex != resolvedIndex {
            activeSegmentIndex = resolvedIndex
        }
    }

    private func isSilenceImmediatelyBeforeActiveSegment(time: Double, index: Int) -> Bool {
        guard segments.indices.contains(index), time >= 0, time < segments[index].startTime else {
            return false
        }
        return index == 0 || time >= segments[index - 1].endTime
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
        let resumeAfterNaturalEnd = canResumePlaybackFromSegmentSelection
        if resumeAfterNaturalEnd {
            canResumePlaybackFromSegmentSelection = false
            wantsPlayback = true
            if !isBackendReady {
                pendingResumePlayback = true
            }
        }
        activeSegmentIndex = index
        currentRepeatCount = 1
        ensureSegmentVisibleInPrimaryViewport(at: index)
        updateSecondaryViewportForActiveSegment(force: true)
        seekToExplicitlySelectedSegment(seg)
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
            var candidate = current - 1
            var found: Int?
            while candidate >= 0 {
                if segments[candidate].isBookmarked {
                    found = candidate
                    break
                }
                candidate -= 1
            }
            targetIndex = found ?? current
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
            var candidate = current + 1
            var found: Int?
            while candidate < segments.count {
                if segments[candidate].isBookmarked {
                    found = candidate
                    break
                }
                candidate += 1
            }
            targetIndex = found ?? current
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
        let minimumDuration = 0.05

        if let s = start, s.isFinite {
            // 起点只属于当前句。上一句的结束点是独立锚点，不能在这里被改写。
            // 仍然限制起点不越过上一句结束点，避免产生重叠或倒序。
            let lowerBound = idx > 0 ? segments[idx - 1].endTime : 0
            let upperBound = seg.endTime - minimumDuration
            guard lowerBound <= upperBound else { return }
            let adjusted = max(lowerBound, min(s, upperBound))
            seg.startTime = adjusted
        }
        if let e = end, e.isFinite {
            // 终点只属于当前句。下一句的起点保持原位，两个标线不再绑定移动。
            let mediaBound = duration > 0 ? duration : Double.greatestFiniteMagnitude
            let upperBound = idx < segments.count - 1
                ? min(mediaBound, segments[idx + 1].startTime)
                : mediaBound
            let lowerBound = seg.startTime + minimumDuration
            guard lowerBound <= upperBound else { return }
            let adjusted = min(upperBound, max(e, lowerBound))
            seg.endTime = adjusted
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
        hasCompletedSegmentation = true
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
            hasCompletedSegmentation = true
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
            isBookmarked: current.isBookmarked,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
        )

        let seg2 = SentenceSegment(
            index: current.index + 1,
            startTime: splitTime,
            endTime: current.endTime,
            text: "",
            translation: "",
            isBookmarked: false,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
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
            isBookmarked: current.isBookmarked,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
        )

        let seg2 = SentenceSegment(
            index: current.index + 1,
            startTime: splitTime,
            endTime: current.endTime,
            text: "",
            translation: "",
            isBookmarked: false,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
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
            isBookmarked: seg1.isBookmarked || seg2.isBookmarked,
            speakerID: nil,
            speakerIDs: Array(Set(seg1.speakerIDs + seg2.speakerIDs)).sorted(),
            isSpeakerOverlap: seg1.isSpeakerOverlap || seg2.isSpeakerOverlap
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
