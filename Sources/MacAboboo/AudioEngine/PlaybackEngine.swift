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
    /// During the native window zoom animation the media window is laid out
    /// repeatedly.  This flag only controls presentation refresh frequency and
    /// waveform rendering quality while that animation is in progress; it
    /// never pauses playback or changes the playback/segmentation state.
    @Published public private(set) var isWindowResizing: Bool = false
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
    /// 单句定次重复上限 (1, 2, 3, 5, 10，0 表示无限单句重复)
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
    /// 翻译任务状态。任务只由用户在翻译确认面板中明确启动。
    @Published public private(set) var isAutoTranslating: Bool = false
    @Published public private(set) var autoTranslationProgress: Double = 0.0
    @Published public private(set) var autoTranslationStatusText: String = ""
    @Published public private(set) var translationErrorMessage: String?

    /// 状态栏右侧显示的当前错误/警告。保留三类来源的独立状态，方便任务
    /// 完成或媒体切换时分别清理；用户点击状态栏的小叉时统一关闭当前提示。
    public var statusErrorMessage: String? {
        lastErrorMessage ?? translationErrorMessage ?? segmentationWarningMessage
    }

    // MARK: - 断句与波形数据
    private let autoGenerateSubtitlesKey = "MacAboboo.AutoGenerateSubtitles"
    private let speechRecognitionLanguageKey = "MacAboboo.SpeechRecognitionLanguage"
    private let expectedSpeakerCountKey = "MacAboboo.ExpectedSpeakerCount"
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

    @Published public var segments: [SentenceSegment] = []
    /// Increments for every explicit user sentence selection (keyboard, list,
    /// waveform or playback controls).  SubtitleEditView uses this separate
    /// signal to distinguish an intentional jump from natural playback, so a
    /// focused editor can load the newly selected sentence without allowing
    /// the playback clock to overwrite text while the user is typing.
    @Published public private(set) var explicitSegmentSelectionRevision: Int = 0
    @Published public var activeSegmentIndex: Int? {
        didSet {
            if activeSegmentIndex != oldValue {
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
    /// The video subtitle overlay keeps this lock while its position is being
    /// dragged. In single-sentence repeat mode the media clock must not be
    /// allowed to advance the active sentence during that interaction.
    @Published public private(set) var isVideoSubtitleDragging: Bool = false
    private var videoSubtitleDragSegmentID: UUID?
    /// During a marker drag keep the working boundaries off the published
    /// `segments` array.  Publishing a new full array for every NSEvent makes
    /// SwiftUI rebuild the waveform tree and is the main source of the
    /// visible marker lag.  The working copy is committed once on release.
    private final class BoundaryDragSession {
        /// 拖动期间只保存被触及的一个或两个句子。此前即使没有发布
        /// `segments`，每个 mouseDragged 仍会因 Array 写时复制而复制整份
        /// 句子和字幕数组；长材料下这仍会造成标线落后于指针。
        let baseSegments: [SentenceSegment]
        var overrides: [Int: SentenceSegment] = [:]

        init(segments: [SentenceSegment]) {
            self.baseSegments = segments
        }

        func segment(at index: Int) -> SentenceSegment {
            overrides[index] ?? baseSegments[index]
        }

        func resolvedSegments() -> [SentenceSegment] {
            guard !overrides.isEmpty else { return baseSegments }
            var result = baseSegments
            for (index, segment) in overrides where result.indices.contains(index) {
                result[index] = segment
            }
            return result
        }
    }
    private var boundaryDragSession: BoundaryDragSession?
    private var shadowingTask: Task<Void, Never>?
    private var debouncedSaveTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var sidecarTask: Task<Void, Never>?
    private var segmentationTask: Task<Void, Never>?
    private var automaticTranslationTask: Task<Void, Never>?
    private var modelIdleUnloadTask: Task<Void, Never>?
    private var previewSeekTask: Task<Void, Never>?
    private var pendingPreviewSeekTime: Double?
    private var segmentationRequestID = UUID()
    private var translationRequestID = UUID()
    private var mediaSessionID = UUID()
    private var seekGeneration: UInt64 = 0
    /// AVPlayer/libmpv should always finish a seek, but a cancelled seek can
    /// occasionally lose its callback while switching sentences quickly. A
    /// bounded fallback keeps the engine from remaining in `isSeeking` forever.
    private var seekTimeoutTask: Task<Void, Never>?
    private var acousticBoundaryTimes: [Double] = []
    private struct ExplicitSegmentSelection {
        let segmentID: UUID
        var hasCompletedSeek: Bool
        var seekCompletedAtUptime: TimeInterval?
        /// A repeated sentence cannot legitimately reach its end before this
        /// uptime. AVPlayer can deliver a queued pre-seek end timestamp well
        /// after the first valid post-seek frame, so a short fixed debounce is
        /// insufficient for protecting the repeat counter.
        var minimumValidEndUptime: TimeInterval?
        /// Highest in-range media timestamp observed after a repeat seek.
        /// A single queued old end frame must not qualify as real playback.
        var maximumObservedTargetTime: Double
    }
    /// AVPlayer may complete an exact seek a fraction of a frame before a
    /// sentence boundary. Preserve an explicitly clicked sentence across that
    /// decoder rounding only; ordinary timeline seeks still follow real time.
    private var explicitSegmentSelection: ExplicitSegmentSelection?
    private var isBackendReady = false
    private var wantsPlayback = false
    /// The user's normal presentation preference.  A temporary window resize
    /// throttle must not overwrite it, otherwise hiding/showing the waveforms
    /// during a resize could accidentally leave playback at the reduced rate.
    private var highFrequencyPresentationEnabled = true
    /// 自然播放到最后一句后，允许用户点击任意断句重新开始播放。
    /// 该状态只在自然结束时保留；用户主动暂停/停止后必须清除，避免
    /// 普通的暂停状态在点击断句时意外自动播放。
    private var canResumePlaybackFromSegmentSelection = false
    /// 最后一句自然结束后，后端偶尔还会发出一个滞后的时间回调。
    /// 在用户明确执行新的播放/Seek/选句操作前，冻结波形相关的播放状态，
    /// 避免主波形跟随到尾部或次波形被切换到错误的断句。
    private var isWaveformFrozenAtNaturalEnd = false
    private var pendingResumeTime: Double = 0
    private var pendingResumePlayback = false
    private var previewEndTime: Double?
    private var securityScopedMediaURL: URL?
    private let projectFileManager: ProjectFileManager
    private let playbackHistoryStore: PlaybackHistoryStore?
    /// Prevents repeated scene/view appearance callbacks from starting a
    /// second automatic restore, and also marks an explicit open as taking
    /// precedence over startup recovery.
    private var didAttemptAutomaticStartupRestore = false
    private var suppressCurrentProjectPersistence = false
    private var hasCompletedSegmentation = false
    /// 工程文件存在但无法安全恢复时置为 true。此状态只允许用户明确
    /// 发起新的断句，禁止波形解析完成后静默覆盖原工程。
    private var projectRecoveryRequired = false
    /// 媒体信息变化时暂存的旧工程。只有用户在提示中明确选择“继续使用
    /// 原工程”后才会应用，避免任何自动绕过兼容性保护。
    private var pendingProjectForExplicitRecovery: MediaProjectFile?
    @Published public private(set) var canUseExistingProject = false

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
        super.init()
        self.nativeBackend.volume = self.volume
        self.nativeBackend.playbackRate = self.playbackRate
        self.mpvBackend.volume = self.volume
        self.mpvBackend.playbackRate = self.playbackRate
        setupBackendCallbacks(for: nativeBackend)
        setupBackendCallbacks(for: mpvBackend)
        projectFileManager.setErrorHandler { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastErrorMessage = message
            }
        }
        playbackHistoryStore?.setPersistenceErrorHandler { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastErrorMessage = message
            }
        }
    }

    private func setupBackendCallbacks(for backend: MediaPlayerBackend) {
        backend.onTimeUpdate = { [weak self, weak backend] current, total in
            guard let self,
                  self.activeBackend === backend,
                  self.isBackendReady,
                  !self.isSeeking else { return }
            // AVFoundation/libmpv 在 pause 或 finished 后可能再送出一帧
            // 滞后的时间。自然结束时保持最后一句的波形视口与活动句不变。
            guard !self.isWaveformFrozenAtNaturalEnd else { return }
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

            // Some backends deliver `onFinished` without a final time tick,
            // and their last reported time can still be a stale frame.  In
            // single-sentence mode the end callback itself is authoritative:
            // repeat the currently active sentence instead of relying on a
            // fragile timestamp comparison before entering the natural-end
            // stop path.
            if self.loopMode == .singleSegment,
               hadPlaybackIntent,
               !self.segments.isEmpty {
                let targetIndex: Int
                if let activeIndex = self.activeSegmentIndex,
                   self.segments.indices.contains(activeIndex) {
                    targetIndex = activeIndex
                } else {
                    targetIndex = self.segments.count - 1
                }
                self.isWaveformFrozenAtNaturalEnd = false
                self.canResumePlaybackFromSegmentSelection = false
                self.wantsPlayback = true
                self.isPlaying = false
                self.triggerSentenceRepeat(for: self.segments[targetIndex])
                return
            }

            self.isPlaying = false
            if self.loopMode == .all {
                // 全篇循环是一次不连续的时间跳转。媒体结束时主波形通常还停在
                // 文件尾部视口；如果只 Seek 而不先重置视口，回到 0 秒后波形
                // 仍会按尾部时间范围映射，直到用户缩放才被动触发正确重绘。
                self.resetPrimaryViewportForLoopRestart()
                self.seek(to: 0.0) {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Seek 完成后再做一次兜底，覆盖解码器异步回调期间对
                        // duration/活动句状态的更新，确保首句与主波形始终一致。
                        self.resetPrimaryViewportForLoopRestart()
                        self.updateSecondaryViewportForActiveSegment(force: true)
                        self.play()
                    }
                }
            } else {
                self.wantsPlayback = false
                // 保留一次“自然结束后点击断句即可继续播放”的意图。
                // 如果用户在结束回调前已经主动暂停，不能把普通暂停误判为自然结束。
                if hadPlaybackIntent {
                    self.canResumePlaybackFromSegmentSelection = true
                    // 只在时间确实已经到达最后一条字幕末尾时兜底冻结。
                    // 这样用户刚点击其它句子、旧的 finished 回调随后到达时，
                    // 不会把新的播放状态错误冻结。
                    let finalSegmentEnd = self.segments.last?.endTime ?? 0
                    let backendTime = backend?.currentTime ?? self.currentTime
                    if finalSegmentEnd > 0,
                       max(self.currentTime, backendTime) >= finalSegmentEnd - 0.05 {
                        self.isWaveformFrozenAtNaturalEnd = true
                    }
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

    /// Pins playback to the sentence whose subtitle is being repositioned.
    /// This is deliberately separate from boundary-marker editing: moving a
    /// subtitle is a video-overlay interaction and must not alter its saved
    /// timestamp or trigger a sentence selection by itself.
    public func beginVideoSubtitleDrag(segmentID: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        isVideoSubtitleDragging = true
        videoSubtitleDragSegmentID = segmentID
        isWaveformFrozenAtNaturalEnd = false
        if activeSegmentIndex != index {
            activeSegmentIndex = index
        }
    }

    /// Releases the subtitle drag lock after the overlay has committed its
    /// final position.  Playback then resumes normal active-sentence updates.
    public func endVideoSubtitleDrag(segmentID: UUID) {
        guard isVideoSubtitleDragging,
              videoSubtitleDragSegmentID == segmentID else { return }
        isVideoSubtitleDragging = false
        videoSubtitleDragSegmentID = nil
    }

    public func beginBoundaryDrag(from source: BoundaryDragSource) {
        boundaryDragSession = BoundaryDragSession(segments: segments)
        isBoundaryDragging = true
        boundaryDragSource = source
        // Keep the current playback state while the boundary is dragged.  The
        // playback clock is suppressed separately in `handlePlaybackBoundary`
        // so a temporary marker position cannot advance/repeat a sentence,
        // while the audio/video stream itself continues uninterrupted.
    }

    public func endBoundaryDrag() {
        commitBoundaryDragIfNeeded()
        isBoundaryDragging = false
        boundaryDragSource = nil
        debouncedSaveTask?.cancel()
        persistCurrentProject()
    }

    /// Selects the sentence whose marker is being edited without seeking or
    /// starting playback.  Marker hit-testing uses this path so a drag never
    /// becomes an implicit sentence jump; ordinary waveform/list clicks keep
    /// using `jumpToSegment(id:)` and retain their playback behavior.
    public func selectSegmentForBoundaryEditing(id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        isWaveformFrozenAtNaturalEnd = false
        activeSegmentIndex = index
        markExplicitSegmentSelection()
        currentRepeatCount = 1
        updateSecondaryViewportForActiveSegment(force: true)
    }

    /// Selects and immediately plays the sentence whose marker was just
    /// released.  Unlike ordinary marker-target selection this is an explicit
    /// user playback command, so it always starts playback even when the
    /// player was paused before the drag.
    public func playSegmentAfterBoundaryEditing(id: UUID) {
        // The release callback invokes this before ending the drag.  Commit
        // the final working copy first so the seek and the next redraw use the
        // exact boundaries under the pointer.
        commitBoundaryDragIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        isWaveformFrozenAtNaturalEnd = false
        canResumePlaybackFromSegmentSelection = false
        activeSegmentIndex = index
        markExplicitSegmentSelection()
        currentRepeatCount = 1
        updateSecondaryViewportForActiveSegment(force: true)
        seekToTargetSegment(segments[index])
        play()
    }

    /// Applies one interactive marker update without persisting on every
    /// mouse event.  When a boundary reaches its neighbour, the two touching
    /// markers move as one, preserving their shared boundary while allowing
    /// the user to keep dragging past the original position.
    public func updateSegmentBoundaryFromDrag(
        id: UUID,
        proposed: Double,
        isStart: Bool
    ) {
        guard proposed.isFinite else { return }

        // A direct programmatic call keeps the historical immediate-update
        // behavior.  Only the live mouse-drag path uses the un-published
        // working copy to avoid a SwiftUI rebuild on every pointer event.
        if let session = boundaryDragSession {
            updateBoundaryDrag(session: session, id: id, proposed: proposed, isStart: isStart)
            return
        }
        var editedSegments = segments
        guard let index = editedSegments.firstIndex(where: { $0.id == id }) else { return }

        let minimumDuration = 0.05
        let mediaBound = duration > 0 ? duration : Double.greatestFiniteMagnitude
        var current = editedSegments[index]

        if isStart {
            let raw = max(0, min(proposed, current.endTime - minimumDuration))
            let crossesPreviousBoundary = index > 0 && raw < editedSegments[index - 1].endTime
            // Dragging is a direct manipulation gesture: do not apply
            // acoustic snapping or haptic feedback to the pointer's target.
            let target = raw

            if crossesPreviousBoundary {
                var previous = editedSegments[index - 1]
                let lowerBound = previous.startTime + minimumDuration
                let upperBound = current.endTime - minimumDuration
                guard lowerBound <= upperBound else { return }
                let boundary = max(lowerBound, min(target, upperBound))
                previous.endTime = boundary
                current.startTime = boundary
                editedSegments[index - 1] = previous
            } else {
                let lowerBound = index > 0 ? editedSegments[index - 1].endTime : 0
                let upperBound = current.endTime - minimumDuration
                guard lowerBound <= upperBound else { return }
                current.startTime = max(lowerBound, min(target, upperBound))
            }
        } else {
            let raw = min(mediaBound, max(current.startTime + minimumDuration, proposed))
            let crossesNextBoundary = index + 1 < editedSegments.count && raw > editedSegments[index + 1].startTime
            // Dragging is a direct manipulation gesture: do not apply
            // acoustic snapping or haptic feedback to the pointer's target.
            let target = raw

            if crossesNextBoundary {
                var next = editedSegments[index + 1]
                let lowerBound = current.startTime + minimumDuration
                let upperBound = next.endTime - minimumDuration
                guard lowerBound <= upperBound else { return }
                let boundary = min(upperBound, max(target, lowerBound))
                current.endTime = boundary
                next.startTime = boundary
                editedSegments[index + 1] = next
            } else {
                let lowerBound = current.startTime + minimumDuration
                let upperBound = index + 1 < editedSegments.count
                    ? min(mediaBound, editedSegments[index + 1].startTime)
                    : mediaBound
                guard lowerBound <= upperBound else { return }
                current.endTime = min(upperBound, max(target, lowerBound))
            }
        }

        editedSegments[index] = current
        segments = editedSegments
    }

    private func updateBoundaryDrag(
        session: BoundaryDragSession,
        id: UUID,
        proposed: Double,
        isStart: Bool
    ) {
        guard let index = session.baseSegments.firstIndex(where: { $0.id == id }) else { return }
        let minimumDuration = 0.05
        let mediaBound = duration > 0 ? duration : Double.greatestFiniteMagnitude
        var current = session.segment(at: index)

        if isStart {
            let target = max(0, min(proposed, current.endTime - minimumDuration))
            let crossesPreviousBoundary = index > 0 && target < session.segment(at: index - 1).endTime
            if crossesPreviousBoundary {
                var previous = session.segment(at: index - 1)
                let lowerBound = previous.startTime + minimumDuration
                let upperBound = current.endTime - minimumDuration
                guard lowerBound <= upperBound else { return }
                let boundary = max(lowerBound, min(target, upperBound))
                previous.endTime = boundary
                current.startTime = boundary
                session.overrides[index - 1] = previous
            } else {
                let lowerBound = index > 0 ? session.segment(at: index - 1).endTime : 0
                let upperBound = current.endTime - minimumDuration
                guard lowerBound <= upperBound else { return }
                current.startTime = max(lowerBound, min(target, upperBound))
            }
        } else {
            let target = min(mediaBound, max(current.startTime + minimumDuration, proposed))
            let crossesNextBoundary = index + 1 < session.baseSegments.count && target > session.segment(at: index + 1).startTime
            if crossesNextBoundary {
                var next = session.segment(at: index + 1)
                let lowerBound = current.startTime + minimumDuration
                let upperBound = next.endTime - minimumDuration
                guard lowerBound <= upperBound else { return }
                let boundary = min(upperBound, max(target, lowerBound))
                current.endTime = boundary
                next.startTime = boundary
                session.overrides[index + 1] = next
            } else {
                let lowerBound = current.startTime + minimumDuration
                let upperBound = index + 1 < session.baseSegments.count
                    ? min(mediaBound, session.segment(at: index + 1).startTime)
                    : mediaBound
                guard lowerBound <= upperBound else { return }
                current.endTime = min(upperBound, max(target, lowerBound))
            }
        }
        session.overrides[index] = current
    }

    /// Publishes the final marker positions once, after the pointer is
    /// released.  This keeps persistence and all downstream views consistent
    /// without paying the cost of publishing an entire segment array per
    /// mouseDragged event.
    private func commitBoundaryDragIfNeeded() {
        guard let session = boundaryDragSession else { return }
        boundaryDragSession = nil
        let working = session.resolvedSegments()
        if segments != working {
            segments = working
        }
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
            let effectiveDuration = max(0.2, seg.duration)
            let padding = max(0.8, effectiveDuration * 0.35)
            let vStart = max(0, seg.startTime - padding)
            let maxDuration = duration > 0 ? duration : (seg.endTime + padding + 1.0)
            let vEnd = min(maxDuration, max(vStart + 0.5, seg.endTime + padding))
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
        guard isPlaying,
              !isWaveformFrozenAtNaturalEnd,
              !isBoundaryDragging,
              duration > 0,
              // 边界处理可能在同一时钟回调内完成一次 Seek。此时传入的
              // `current` 仍是旧句末尾时间，不能再用它把已重置的视口推回尾部。
              abs(current - currentTime) <= 0.001 else { return }
        // 最后一条断句没有可继续跟随的下一条内容。保持当前主波形视口
        // 不动，避免播放尾句时无意义地把视口推进到文件末端。
        if let activeSegmentIndex,
           segments.indices.contains(activeSegmentIndex),
           activeSegmentIndex == segments.count - 1 {
            return
        }
        let span = primaryViewport.end - primaryViewport.start
        guard span > 0, span < duration else { return }

        if current >= (primaryViewport.end - span * 0.3) || current < primaryViewport.start {
            // 右端贴住媒体末尾时，必须先把起点限制到 duration - span，
            // 再按完整 span 计算终点；不能只截断终点，否则视口会被缩窄，
            // 波形看起来就像突然放大。
            let maxStart = max(0, duration - span)
            let idealStart = max(0, current - span * 0.3)
            let newStart = min(maxStart, idealStart)
            let newEnd = newStart + span
            if abs(newStart - primaryViewport.start) > 0.05 {
                primaryViewport = (newStart, newEnd)
            }
        }
    }

    /// 将主波形恢复到全篇循环重启后的起始视口，同时保留用户当前缩放级别。
    /// 循环边界是时间轴的不连续点，不能依赖下一帧播放时钟来触发跟随，否则
    /// 在解码器暂时不发送 0 秒时间回调时会留下尾部视口。
    private func resetPrimaryViewportForLoopRestart() {
        guard duration.isFinite, duration > 0 else { return }
        let currentSpan = primaryViewport.end - primaryViewport.start
        let fallbackSpan = min(15.0, duration)
        let span = currentSpan.isFinite && currentSpan > 0
            ? min(currentSpan, duration)
            : fallbackSpan
        primaryViewport = (0, span)
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
        highFrequencyPresentationEnabled = enabled
        applyPresentationRefreshPolicy()
    }

    /// Temporarily lower presentation refresh work while AppKit animates a
    /// window zoom.  Audio playback, decoder state and sentence boundaries are
    /// intentionally untouched; only high-frequency UI callbacks are reduced.
    public func setWindowResizing(_ resizing: Bool) {
        guard isWindowResizing != resizing else { return }
        isWindowResizing = resizing
        applyPresentationRefreshPolicy()
    }

    private func applyPresentationRefreshPolicy() {
        let enabled = highFrequencyPresentationEnabled && !isWindowResizing
        nativeBackend.setHighFrequencyPresentationEnabled(enabled)
        mpvBackend.setHighFrequencyPresentationEnabled(enabled)
    }

    // MARK: - 媒体加载与独立工程恢复

    /// 在应用首次显示主窗口时恢复上次实际打开的媒体。
    ///
    /// 仅从播放历史中选择文件仍然存在且可读取的条目；空播放列表、首次
    /// 启动或原文件已被移走时保持空界面，不会创建虚假的媒体工程。
    /// 该操作只尝试一次，避免 SwiftUI 多次触发 `onAppear` 时重复加载。
    public func restoreLastOpenedMediaIfNeeded() {
        guard !didAttemptAutomaticStartupRestore else { return }
        didAttemptAutomaticStartupRestore = true
        guard currentMedia == nil,
              let historyStore = playbackHistoryStore,
              !historyStore.entries.isEmpty,
              let mediaURL = historyStore.lastOpenedMediaURL else { return }

        let values = try? mediaURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard mediaURL.isFileURL,
              FileManager.default.fileExists(atPath: mediaURL.path),
              values?.isRegularFile == true,
              values?.isReadable != false else { return }

        loadMedia(from: mediaURL)
    }

    /// 关闭当前媒体工作区并回到欢迎首屏。播放历史和已保存工程保留，
    /// 因而用户仍可从首屏的“继续播放”或历史条目重新打开媒体。
    public func closeCurrentMedia() async {
        guard currentMedia != nil else { return }

        debouncedSaveTask?.cancel()
        modelIdleUnloadTask?.cancel()
        modelIdleUnloadTask = nil

        // 先让所有旧媒体任务失效并取消，避免它们在保存或窗口销毁之后
        // 又把旧媒体的异步结果写回当前工程。
        mediaSessionID = UUID()
        segmentationRequestID = UUID()
        seekGeneration &+= 1
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        previewSeekTask?.cancel()
        previewSeekTask = nil
        shadowingTask?.cancel()
        shadowingTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        sidecarTask?.cancel()
        sidecarTask = nil
        segmentationTask?.cancel()
        segmentationTask = nil
        cancelAutomaticTranslation()

        // 关闭前强制完成工程与播放历史写入，确保后续资源拆除不会丢失
        // 当前断句、书签、播放位置或工程状态。
        persistCurrentProject()
        projectFileManager.flush()
        playbackHistoryStore?.flush()

        isBackendReady = false
        isMediaLoading = false
        isSeeking = false
        isPreviewingAnchor = false
        isBoundaryDragging = false
        boundaryDragSource = nil
        isVideoSubtitleDragging = false
        videoSubtitleDragSegmentID = nil
        pendingPreviewSeekTime = nil
        previewEndTime = nil
        pendingResumePlayback = false
        pendingResumeTime = 0
        activeBackend.pause()
        nativeBackend.teardown()
        mpvBackend.teardown()

        securityScopedMediaURL?.stopAccessingSecurityScopedResource()
        securityScopedMediaURL = nil
        currentMedia = nil
        segments = []
        waveformData = .empty
        acousticBoundaryTimes = []
        activeSegmentIndex = nil
        explicitSegmentSelection = nil
        lastSecondarySegmentId = nil
        boundaryDragSession = nil
        currentTime = 0
        duration = 0
        primaryViewport = (0, 15)
        secondaryViewport = (0, 5)
        currentRepeatCount = 1
        isPlaying = false
        wantsPlayback = false
        isShadowingPaused = false
        shadowingCountdownRemaining = 0
        isWaveformFrozenAtNaturalEnd = false
        canResumePlaybackFromSegmentSelection = false
        isExtractingWaveform = false
        waveformExtractionProgress = 0
        isAITranscribing = false
        aiTranscriptionProgress = 0
        aiTranscriptionStatusText = ""
        hasCompletedSegmentation = false
        segmentOrigin = .none
        projectRecoveryRequired = false
        pendingProjectForExplicitRecovery = nil
        canUseExistingProject = false
        lastErrorMessage = nil
        segmentationWarningMessage = nil
        translationErrorMessage = nil

        // 这些推理器与 PCM/波形缓存是进程级共享资源，不会随着 SwiftUI
        // 窗口场景自动释放；关闭媒体时明确清理，欢迎页阶段不继续占用它们。
        await SpeechSegmentationPipeline.shared.clearCaches()
        await AudioPCMExtractor.shared.purgeMemoryCache()
        WaveformExtractor.shared.purgeMemoryCache()
        await SpeakerDiarizationEngine.shared.unloadModels()
        await NativeSpeechRuntime.shared.unloadModels()
    }

    /// 加载音视频文件（优先从 ~/Library/Application Support/MacAboboo/Projects/ 独立工程文件瞬间读取）
    public func loadMedia(from url: URL) {
        // An explicit open (including a URL supplied by Finder) always wins
        // over a pending startup restore, even when the URL is invalid.
        didAttemptAutomaticStartupRestore = true
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
        cancelAutomaticTranslation()
        segmentationRequestID = UUID()
        isAITranscribing = false
        aiTranscriptionProgress = 0
        aiTranscriptionStatusText = ""
        translationErrorMessage = nil
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
        projectRecoveryRequired = false
        pendingProjectForExplicitRecovery = nil
        canUseExistingProject = false
        acousticBoundaryTimes = []
        boundaryDragSession = nil
        isVideoSubtitleDragging = false
        videoSubtitleDragSegmentID = nil
        segments = []
        activeSegmentIndex = nil
        lastSecondarySegmentId = nil
        isWaveformFrozenAtNaturalEnd = false
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
            async let sidecarItemsResult = self.loadSidecarItems(for: mediaURL)
            async let projectLoadResult = self.projectFileManager.loadProjectResultAsync(for: mediaURL)
            let (sidecarItems, projectResult) = await (sidecarItemsResult, projectLoadResult)
            guard !Task.isCancelled,
                  sessionID == self.mediaSessionID,
                  self.currentMedia?.url.standardizedFileURL == mediaURL else { return }

            var compatibleProject: MediaProjectFile?
            switch projectResult {
            case .missing:
                // 没有任何工程记录，波形完成后才允许首次自动断句。
                self.projectRecoveryRequired = false
                self.pendingProjectForExplicitRecovery = nil
                self.canUseExistingProject = false
            case .loaded(let project, let needsMigration):
                if project.isCompatible(with: mediaURL) {
                    compatibleProject = project
                    self.projectRecoveryRequired = false
                    self.pendingProjectForExplicitRecovery = nil
                    self.canUseExistingProject = false
                    self.restoreProject(project, for: mediaURL)
                    if needsMigration {
                        // 迁移只在工程已经成功恢复且媒体匹配时执行，
                        // 旧文件会先由 ProjectFileManager 自动备份。
                        self.projectFileManager.saveProject(
                            for: mediaURL,
                            title: project.mediaTitle,
                            duration: project.duration,
                            lastPosition: project.lastPosition,
                            segments: project.segments,
                            waveformData: project.waveformData,
                            persistWaveform: project.waveformData?.isEmpty == false,
                            hasCompletedSegmentation: project.hasCompletedSegmentation,
                            acousticBoundaryTimes: project.acousticBoundaryTimes
                        )
                    }
                } else {
                    self.projectRecoveryRequired = true
                    self.pendingProjectForExplicitRecovery = project
                    self.canUseExistingProject = true
                    self.lastErrorMessage = self.projectChangedRecoveryMessage()
                }
            case .unavailable(let reason):
                self.projectRecoveryRequired = true
                self.pendingProjectForExplicitRecovery = nil
                self.canUseExistingProject = false
                self.lastErrorMessage = self.projectRecoveryMessage(
                    "工程文件无法安全读取，已停止自动断句。\n\(reason)"
                )
            }

            // 同名字幕始终接管断句时间轴，但仍复用工程中的播放位置和波形。
            if let sidecarItems, !sidecarItems.isEmpty {
                self.projectRecoveryRequired = false
                self.pendingProjectForExplicitRecovery = nil
                self.canUseExistingProject = false
                self.applySubtitleItems(sidecarItems, origin: .sidecar, persist: true)
                if let compatibleProject,
                   let savedWaveform = compatibleProject.waveformData,
                   !savedWaveform.isEmpty {
                    self.waveformData = savedWaveform
                    self.waveformExtractionProgress = 1
                    if self.duration <= 0 { self.updateMediaDurationIfNeeded(savedWaveform.duration) }
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
                        self.performSegmentation(
                            mode: .fast,
                            showProgress: true,
                            waveformData: savedWaveform
                        )
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
        let standardizedURL = mediaURL.standardizedFileURL
        return await Task.detached(priority: .utility) {
            let didAccess = standardizedURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
            }

            let validExtensions = Set(["srt", "vtt", "lrc", "txt", "ass", "ssa"])
            let baseName = standardizedURL.deletingPathExtension().lastPathComponent
            let parentDir = standardizedURL.deletingLastPathComponent()

            var candidateURLs: [URL] = []

            // 1. 精确同名匹配（如 video.srt, video.vtt, video.lrc, video.txt, video.ass, video.ssa）
            for ext in ["srt", "vtt", "lrc", "txt", "ass", "ssa"] {
                let directURL = parentDir.appendingPathComponent("\(baseName).\(ext)")
                if FileManager.default.fileExists(atPath: directURL.path) {
                    candidateURLs.append(directURL)
                }
            }

            // 2. 扫描同目录及 Subs/Subtitles 子目录下的多语言同名文件（如 video.zh.srt, video.en.vtt, video_chs.srt 等）
            let searchDirs = [
                parentDir,
                parentDir.appendingPathComponent("Subtitles", isDirectory: true),
                parentDir.appendingPathComponent("subs", isDirectory: true),
                parentDir.appendingPathComponent("sub", isDirectory: true)
            ]

            for dir in searchDirs {
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for fileURL in contents {
                    let ext = fileURL.pathExtension.lowercased()
                    guard validExtensions.contains(ext) else { continue }
                    let fileName = fileURL.deletingPathExtension().lastPathComponent
                    // 必须以媒体文件名开头（例如 video.zh, video.chs, video.en, video_1）
                    if fileName == baseName || fileName.hasPrefix(baseName + ".") || fileName.hasPrefix(baseName + "_") || fileName.hasPrefix(baseName + "-") {
                        if !candidateURLs.contains(fileURL) {
                            candidateURLs.append(fileURL)
                        }
                    }
                }
            }

            // 格式优先级：SRT 拥有最明确的标准起止时间戳，最高优先级；其次为 VTT, ASS, SSA, LRC, TXT
            func formatPriority(_ url: URL) -> Int {
                switch url.pathExtension.lowercased() {
                case "srt": return 0
                case "vtt": return 1
                case "ass": return 2
                case "ssa": return 3
                case "lrc": return 4
                case "txt": return 5
                default: return 6
                }
            }

            // 3. 排序候选字幕：
            // ① 优先精确同名（baseName.ext）
            // ② 优先 SRT 等区间格式（SRT > VTT > ASS > SSA > LRC > TXT）
            // ③ 优先中文/双语标签（zh, chs, chi, zho）
            // ④ 字典序兜底
            candidateURLs.sort { lhs, rhs in
                let lhsName = lhs.lastPathComponent.lowercased()
                let rhsName = rhs.lastPathComponent.lowercased()
                let lhsExact = lhs.deletingPathExtension().lastPathComponent == baseName
                let rhsExact = rhs.deletingPathExtension().lastPathComponent == baseName
                if lhsExact != rhsExact { return lhsExact }

                let lhsPriority = formatPriority(lhs)
                let rhsPriority = formatPriority(rhs)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

                let lhsZh = lhsName.contains("zh") || lhsName.contains("chs") || lhsName.contains("chi") || lhsName.contains("zho")
                let rhsZh = rhsName.contains("zh") || rhsName.contains("chs") || rhsName.contains("chi") || rhsName.contains("zho")
                if lhsZh != rhsZh { return lhsZh }

                return lhsName < rhsName
            }

            for candidate in candidateURLs {
                guard !Task.isCancelled else { return nil }
                if let items = try? SubtitleParser.shared.parse(from: candidate), !items.isEmpty {
                    return items
                }
            }
            return nil
        }.value
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

                        if self.segments.isEmpty,
                           self.segmentOrigin == .none,
                           !self.hasCompletedSegmentation,
                           !self.projectRecoveryRequired {
                            self.performSegmentation(
                                mode: .fast,
                                showProgress: true,
                                waveformData: data
                            )
                        }

                        self.persistCurrentProject(includeWaveform: true)
                        self.preloadNextPlaylistItemWaveformIfNeeded()
                    case .failure(let error):
                        print("Waveform extraction failed: \(error.localizedDescription)")
                        self.lastErrorMessage = error.localizedDescription
                        // 备用解码器也失败时保留真实的空时间轴，禁止伪造固定时长断句。
                    }
                }
            }
        )
    }

    private func preloadNextPlaylistItemWaveformIfNeeded() {
        guard let currentMedia else { return }
        let entries = PlaybackHistoryStore.shared.entries
        guard let currentIndex = entries.firstIndex(where: { $0.mediaPath == currentMedia.url.standardizedFileURL.path }),
              entries.indices.contains(currentIndex + 1) else { return }
        let nextURL = entries[currentIndex + 1].mediaURL
        Task.detached(priority: .background) {
            _ = try? await AudioPCMExtractor.shared.extract(from: nextURL, progress: nil)
        }
    }

    /// 快速与智能两种模式的统一断句入口。媒体切换或再次启动断句时，
    /// 旧请求会被取消且不能回写结果。
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
        cancelAutomaticTranslation()
        modelIdleUnloadTask?.cancel()
        projectRecoveryRequired = false
        pendingProjectForExplicitRecovery = nil
        canUseExistingProject = false
        acousticBoundaryTimes = []

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

    /// Re-runs Whisper against the existing sentence time ranges without
    /// changing sentence boundaries, translations, bookmarks, or notes.
    /// Passing nil (or an empty set) processes every sentence; otherwise only
    /// the checked sentence IDs are overwritten.
    public func regenerateOriginalText(segmentIDs: Set<UUID>? = nil) {
        guard let media = currentMedia, !segments.isEmpty else { return }
        guard !isAITranscribing else { return }
        guard !isAutoTranslating else {
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "请先等待当前翻译任务完成或取消翻译。"
                : "Wait for the current translation task to finish or cancel it first."
            return
        }

        let requestedIDs: Set<UUID>?
        if let segmentIDs, !segmentIDs.isEmpty {
            requestedIDs = segmentIDs
        } else {
            requestedIDs = nil
        }
        let targets = segments.filter { requestedIDs == nil || requestedIDs?.contains($0.id) == true }
        guard !targets.isEmpty else { return }

        let modelManager = WhisperModelManager.shared
        let modelLevel = modelManager.selectedModelLevel
        guard modelManager.isModelDownloaded(modelLevel) else {
            lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                ? "所选 Whisper 模型尚未下载，请先在设置中下载模型。"
                : "The selected Whisper model has not been downloaded. Download it in Settings first."
            return
        }

        let mediaURL = media.url.standardizedFileURL
        let modelURL = modelManager.modelFileURL(for: modelLevel)
        let sessionID = mediaSessionID
        let requestID = UUID()
        let targetIDs = Set(targets.map(\.id))
        let recognitionLanguage = speechRecognitionLanguage
        let isChinese = LanguageManager.shared.currentLanguage == .zh
        let preparingStatus = isChinese
            ? "正在准备重新生成原文…"
            : "Preparing to regenerate original text…"
        let recognizingStatus = isChinese
            ? "Whisper 正在重新生成原文…"
            : "Whisper is regenerating original text…"

        segmentationTask?.cancel()
        segmentationRequestID = requestID
        modelIdleUnloadTask?.cancel()
        lastErrorMessage = nil
        segmentationWarningMessage = nil
        isAITranscribing = true
        aiTranscriptionProgress = 0
        aiTranscriptionStatusText = preparingStatus

        segmentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pcm = try await AudioPCMExtractor.shared.extract(from: mediaURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.mediaSessionID == sessionID,
                              self.segmentationRequestID == requestID else { return }
                        self.aiTranscriptionProgress = min(0.18, max(0, progress) * 0.18)
                    }
                }
                try Task.checkCancellation()
                guard self.mediaSessionID == sessionID,
                      self.segmentationRequestID == requestID,
                      self.currentMedia?.url.standardizedFileURL == mediaURL else { return }

                self.aiTranscriptionStatusText = recognizingStatus
                let speechWindows = targets.map {
                    VoiceActivitySegment(
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        confidence: 1
                    )
                }
                // Every existing sentence edge is a hard recognition-window
                // boundary. Regeneration uses strict isolation: Whisper reads
                // only the samples inside each current sentence, clears its
                // context for every sentence, and never deduplicates against a
                // previously recognized sentence.
                let hardBoundaries = Array(Set(targets.flatMap { [$0.startTime, $0.endTime] })).sorted()
                let timeline = try await NativeSpeechRuntime.shared.transcribe(
                    pcm: pcm,
                    modelURL: modelURL,
                    language: recognitionLanguage,
                    configuration: SpeechSegmentationMode.intelligent.profile.vad,
                    speechWindows: speechWindows,
                    hardWindowBoundaries: hardBoundaries,
                    isolatedSpeechWindows: true
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.mediaSessionID == sessionID,
                              self.segmentationRequestID == requestID else { return }
                        self.aiTranscriptionProgress = 0.18 + min(1, max(0, progress)) * 0.80
                    }
                }
                try Task.checkCancellation()
                guard self.mediaSessionID == sessionID,
                      self.segmentationRequestID == requestID,
                      self.currentMedia?.url.standardizedFileURL == mediaURL else { return }

                // If a target boundary changed while Whisper was running, its
                // result describes an obsolete time range and must not be
                // written into the edited timeline.
                let timelineStillMatches = targets.allSatisfy { target in
                    guard let current = self.segments.first(where: { $0.id == target.id }) else { return false }
                    return abs(current.startTime - target.startTime) <= 0.001
                        && abs(current.endTime - target.endTime) <= 0.001
                }
                guard timelineStillMatches else {
                    self.lastErrorMessage = isChinese
                        ? "识别期间目标句子的时间轴发生变化，未覆盖原文，请重新执行。"
                        : "The target sentence timeline changed during recognition. Original text was not overwritten; run it again."
                    self.isAITranscribing = false
                    self.aiTranscriptionStatusText = ""
                    self.segmentationTask = nil
                    self.scheduleIdleModelRelease()
                    return
                }

                let recognizedTexts = Self.recognizedOriginalTexts(
                    for: targets,
                    tokens: timeline.tokens
                )
                self.segments = Self.replacingOriginalTexts(
                    in: self.segments,
                    targetIDs: targetIDs,
                    recognizedTexts: recognizedTexts
                )
                self.persistCurrentProject()
                self.aiTranscriptionProgress = 1
                self.isAITranscribing = false
                self.aiTranscriptionStatusText = ""
                self.segmentationTask = nil
                self.scheduleIdleModelRelease()
            } catch is CancellationError {
                guard self.segmentationRequestID == requestID else { return }
                self.isAITranscribing = false
                self.aiTranscriptionStatusText = ""
                self.segmentationTask = nil
                self.scheduleIdleModelRelease()
            } catch {
                guard self.mediaSessionID == sessionID,
                      self.segmentationRequestID == requestID else { return }
                self.lastErrorMessage = error.localizedDescription
                self.isAITranscribing = false
                self.aiTranscriptionStatusText = ""
                self.segmentationTask = nil
                self.scheduleIdleModelRelease()
            }
        }
    }

    /// Assigns each Whisper token to the target sentence with the greatest
    /// source-time overlap, then formats it using the normal subtitle rules.
    /// The dictionary deliberately contains an empty value for targets where
    /// Whisper found no text so confirmed regeneration truly overwrites them.
    static func recognizedOriginalTexts(
        for targets: [SentenceSegment],
        tokens: [SpeechToken]
    ) -> [UUID: String] {
        let orderedTargets = targets.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        var grouped = Dictionary(uniqueKeysWithValues: orderedTargets.map { ($0.id, [SpeechToken]()) })

        for token in tokens.sorted(by: {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }) {
            let midpoint = (token.startTime + token.endTime) / 2
            var bestTarget: SentenceSegment?
            var bestScore = 0.0
            for target in orderedTargets {
                let overlap = max(
                    0,
                    min(token.endTime, target.endTime) - max(token.startTime, target.startTime)
                )
                let containsPointToken = token.endTime - token.startTime <= 0.001
                    && midpoint >= target.startTime - 0.001
                    && midpoint <= target.endTime + 0.001
                let score = overlap > 0 ? overlap : (containsPointToken ? 0.000_001 : 0)
                if score > bestScore {
                    bestScore = score
                    bestTarget = target
                }
            }
            if let bestTarget, bestScore > 0 {
                grouped[bestTarget.id, default: []].append(token)
            }
        }

        return Dictionary(uniqueKeysWithValues: orderedTargets.map { target in
            let text = SpeechBoundaryOptimizer.shared.joinedRecognizedText(grouped[target.id] ?? [])
            return (target.id, text)
        })
    }

    static func replacingOriginalTexts(
        in segments: [SentenceSegment],
        targetIDs: Set<UUID>,
        recognizedTexts: [UUID: String]
    ) -> [SentenceSegment] {
        var updated = segments
        for index in updated.indices where targetIDs.contains(updated[index].id) {
            updated[index].text = recognizedTexts[updated[index].id] ?? ""
        }
        return updated
    }

    /// 取消当前自动翻译请求。媒体切换、重新断句和字幕重新导入时调用，
    /// 防止旧请求返回后把译文写入新的工程。
    public func cancelAutomaticTranslation() {
        automaticTranslationTask?.cancel()
        automaticTranslationTask = nil
        translationRequestID = UUID()
        isAutoTranslating = false
        autoTranslationProgress = 0
        autoTranslationStatusText = ""
    }

    /// 关闭状态栏右侧的错误或断句警告提示，不影响播放、断句和翻译任务。
    public func dismissStatusError() {
        lastErrorMessage = nil
        translationErrorMessage = nil
        segmentationWarningMessage = nil
        // 关闭“处理工程”提示视为放弃本次恢复选择，但不会解除保护状态；
        // 后续只能由用户明确发起重新断句或重新导入字幕。
        pendingProjectForExplicitRecovery = nil
        canUseExistingProject = false
    }

    /// 按用户确认过的服务配置，翻译当前工程中符合范围的句子。
    ///
    /// `segmentIDs` 为空时处理整个工程；传入集合时只处理指定句子。这个方法
    /// 只由明确的“开始翻译”操作调用，断句、导入字幕和恢复工程不会自动触发。
    public func translateMissingTranslations(
        configuration suppliedConfiguration: TranslationConfiguration? = nil,
        segmentIDs: Set<UUID>? = nil,
        overwriteExistingTranslations: Bool = false,
        batchSize: Int = 100
    ) {
        let settings = TranslationSettings.shared
        guard settings.isAutomaticTranslationEnabled else {
            translationErrorMessage = "请先在设置中启用翻译功能。"
            return
        }
        guard !isAITranscribing else { return }
        guard let configuration = suppliedConfiguration ?? settings.configuration() else {
            translationErrorMessage = TranslationProviderError.missingAPIKey.localizedDescription
            return
        }

        let units = segments.compactMap { segment -> TranslationUnit? in
            let source = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingTranslation = segment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty,
                  (overwriteExistingTranslations || existingTranslation.isEmpty),
                  segmentIDs == nil || segmentIDs?.contains(segment.id) == true else { return nil }
            return TranslationUnit(id: segment.id, sourceText: source)
        }
        guard !units.isEmpty else {
            translationErrorMessage = overwriteExistingTranslations
                ? "没有找到包含原文的句子。"
                : "没有找到需要翻译的空译文句子。"
            return
        }

        automaticTranslationTask?.cancel()
        let requestID = UUID()
        translationRequestID = requestID
        let sessionID = mediaSessionID
        let sourceLanguage = speechRecognitionLanguage
        let sourceByID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0.sourceText) })
        isAutoTranslating = true
        autoTranslationProgress = 0
        autoTranslationStatusText = "正在使用 \(configuration.provider.displayName) 生成译文…"
        translationErrorMessage = nil

        automaticTranslationTask = Task { @MainActor [weak self] in
            do {
                _ = try await TranslationService.shared.translate(
                    units: units,
                    configuration: configuration,
                    sourceLanguage: sourceLanguage,
                    batchSize: batchSize,
                    progress: { [weak self] completed, total in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.translationRequestID == requestID,
                                  self.mediaSessionID == sessionID else { return }
                            self.autoTranslationProgress = total > 0
                                ? min(1, max(0, Double(completed) / Double(total)))
                                : 1
                        }
                    },
                    onBatchCompleted: { [weak self] batchResults in
                        await MainActor.run { [weak self] in
                            guard let self,
                                  self.translationRequestID == requestID,
                                  self.mediaSessionID == sessionID else { return }
                            var hasChanges = false
                            for result in batchResults {
                                guard let index = self.segments.firstIndex(where: { $0.id == result.id }),
                                      self.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines) == sourceByID[result.id],
                                      (overwriteExistingTranslations
                                       || self.segments[index].translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                      !result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                                self.segments[index].translation = result.translatedText
                                hasChanges = true
                            }
                            if hasChanges {
                                self.persistCurrentProject()
                            }
                        }
                    }
                )
                try Task.checkCancellation()
                guard let self,
                      self.translationRequestID == requestID,
                      self.mediaSessionID == sessionID else { return }

                self.autoTranslationProgress = 1
                self.isAutoTranslating = false
                self.autoTranslationStatusText = ""
            } catch is CancellationError {
                guard let self, self.translationRequestID == requestID else { return }
                self.isAutoTranslating = false
                self.autoTranslationStatusText = ""
            } catch {
                guard let self,
                      self.translationRequestID == requestID,
                      self.mediaSessionID == sessionID else { return }
                self.isAutoTranslating = false
                self.autoTranslationStatusText = ""
                self.translationErrorMessage = error.localizedDescription
            }
        }
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
            return mode == .intelligent
                ? (chinese ? "正在自适应融合语义、说话人与声学边界…" : "Adaptively fusing semantic, speaker, and acoustic boundaries…")
                : (chinese ? "正在优化语音与停顿边界…" : "Optimizing speech and pause boundaries…")
        }
    }

    private func projectRecoveryMessage(_ detail: String) -> String {
        if LanguageManager.shared.currentLanguage == .zh {
            return "为保护已编辑的原文和译文，\(detail)请手动确认后再重新断句。"
        }
        return "To protect edited subtitles, \(detail) Automatic segmentation was stopped. Start a new segmentation manually if needed."
    }

    private func projectChangedRecoveryMessage() -> String {
        if LanguageManager.shared.currentLanguage == .zh {
            return "为保护已编辑的原文和译文，工程对应的媒体文件信息已变化。请点击“处理工程”，选择“继续使用原工程”或“重新断句”。"
        }
        return "To protect edited subtitles, the media file information no longer matches the project. Click “Handle Project” and choose “Use Existing Project” or “Re-segment”."
    }

    /// 打开工程时检测到媒体大小或修改时间变化后，等待用户明确选择。
    /// 选择继续使用时只重新绑定媒体信息，不运行 Silero、SpeakerKit 或 Whisper。
    public func continueUsingExistingProject() {
        guard let media = currentMedia,
              let pendingProject = pendingProjectForExplicitRecovery,
              projectRecoveryRequired else { return }

        let mediaURL = media.url.standardizedFileURL
        let sessionID = mediaSessionID
        // 先禁用按钮，避免用户在后台备份期间重复提交相同操作。
        canUseExistingProject = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.projectFileManager.adoptProjectIgnoringMediaMetadataAsync(
                for: mediaURL
            )
            guard sessionID == self.mediaSessionID,
                  self.currentMedia?.url.standardizedFileURL == mediaURL else { return }

            switch result {
            case .adopted(let adoptedProject, let backupPath):
                self.projectRecoveryRequired = false
                self.pendingProjectForExplicitRecovery = nil
                self.canUseExistingProject = false
                self.restoreProject(adoptedProject, for: mediaURL)
                if let savedWaveform = adoptedProject.waveformData, !savedWaveform.isEmpty {
                    self.waveformData = savedWaveform
                    self.waveformExtractionProgress = 1
                }
                let pathText = backupPath.isEmpty
                    ? "Projects 目录"
                    : backupPath
                self.lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                    ? "已继续使用原工程。原工程文件已备份到：\(pathText)"
                    : "The existing project is now in use. A backup was saved at: \(pathText)"
            case .failed(let reason):
                self.projectRecoveryRequired = true
                self.pendingProjectForExplicitRecovery = pendingProject
                self.canUseExistingProject = true
                self.lastErrorMessage = self.projectRecoveryMessage(
                    "继续使用原工程失败：\(reason)"
                )
            }
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
        cancelAutomaticTranslation()
        segments = []
        activeSegmentIndex = nil
        segmentOrigin = .none
        hasCompletedSegmentation = false
        projectRecoveryRequired = false
        pendingProjectForExplicitRecovery = nil
        canUseExistingProject = false
        applySubtitleItems(mappedItems, origin: .imported, persist: true)
    }

    /// 字幕导入界面的撤销入口；同样经过时间轴清洗，不允许恢复出非法边界。
    public func replaceSegmentsForUndo(_ replacement: [SentenceSegment]) {
        segments = normalizedSegments(replacement, duration: duration)
        segmentOrigin = .imported
        hasCompletedSegmentation = true
        acousticBoundaryTimes = []
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
        if duration <= 0, let maxTime = newSegments.last?.endTime, maxTime > 0 {
            updateMediaDurationIfNeeded(maxTime)
        }
        self.segments = normalizedSegments(newSegments, duration: duration)
        self.segmentOrigin = origin
        self.hasCompletedSegmentation = true
        self.acousticBoundaryTimes = []
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
            performSegmentation(mode: .fast, showProgress: true) { [weak self] generated in
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

    /// 对来自旧工程或外部字幕的时间轴做一次原子清洗，保证时间戳合法、有序且不越界，同时保留字幕原生起止范围。
    private func normalizedSegments(_ input: [SentenceSegment], duration: Double) -> [SentenceSegment] {
        let upperBound = duration.isFinite && duration > 0 ? duration : Double.greatestFiniteMagnitude
        let sorted = input.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        var result: [SentenceSegment] = []
        result.reserveCapacity(sorted.count)

        for source in sorted {
            let rawStart = source.startTime.isFinite ? max(0, source.startTime) : 0
            guard rawStart < upperBound else { continue }
            let start = min(upperBound, rawStart)
            let proposedEnd = source.endTime.isFinite ? source.endTime : start + 0.05
            let end = min(upperBound, max(start + 0.05, proposedEnd))
            guard end > start else { continue }
            result.append(SentenceSegment(
                id: source.id,
                index: result.count + 1,
                startTime: start,
                endTime: end,
                text: source.text,
                translation: source.translation,
                note: source.note,
                isNavigationBookmarked: source.isNavigationBookmarked,
                isBookmarked: source.isBookmarked,
                speakerID: source.speakerID,
                speakerIDs: source.speakerIDs,
                isSpeakerOverlap: source.isSpeakerOverlap
            ))
        }
        return result
    }

    // MARK: - 独立项目工程文件持久化存储

    public func persistCurrentProject(includeWaveform: Bool = false) {
        guard let media = currentMedia,
              !suppressCurrentProjectPersistence,
              !projectRecoveryRequired else { return }

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
            // 删除当前媒体的历史记录时，同时中止仍可能写入 PCMCache 的
            // 波形/断句任务，避免缓存清理完成后又被后台解码任务生成。
            waveformTask?.cancel()
            waveformTask = nil
            sidecarTask?.cancel()
            sidecarTask = nil
            segmentationTask?.cancel()
            segmentationTask = nil
            segmentationRequestID = UUID()
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
        // PCMCache 是可再生的派生数据，删除历史记录时清理当前缓存；
        // 原始音视频文件本身不会受到影响。
        await AudioPCMExtractor.shared.removeCache(for: standardizedURL)
    }

    /// 清空播放列表时也清除每个媒体的工程文件、波形文件与 PCM 派生缓存。
    /// 原始音视频不会被触碰；当前媒体的后台任务会先取消，防止清理后又写回。
    public func clearPlaybackHistory() async {
        guard let playbackHistoryStore else { return }
        let mediaURLs = playbackHistoryStore.entries.map(\.mediaURL)
        guard !mediaURLs.isEmpty else { return }

        if let currentURL = currentMedia?.url.standardizedFileURL,
           mediaURLs.contains(currentURL) {
            debouncedSaveTask?.cancel()
            waveformTask?.cancel()
            waveformTask = nil
            sidecarTask?.cancel()
            sidecarTask = nil
            segmentationTask?.cancel()
            segmentationTask = nil
            segmentationRequestID = UUID()
            suppressCurrentProjectPersistence = true
        }

        playbackHistoryStore.removeAll()
        for mediaURL in mediaURLs {
            do {
                try await projectFileManager.deleteProjectAsync(for: mediaURL)
            } catch {
                lastErrorMessage = LanguageManager.shared.currentLanguage == .zh
                    ? "删除工程记录失败：\(error.localizedDescription)"
                    : "Unable to delete project records: \(error.localizedDescription)"
            }
            await AudioPCMExtractor.shared.removeCache(for: mediaURL)
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
        isWaveformFrozenAtNaturalEnd = false
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
        isWaveformFrozenAtNaturalEnd = false
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
        isWaveformFrozenAtNaturalEnd = false
        explicitSegmentSelection = nil
        // A user/timeline seek starts a new repeat cycle. Internal repeat
        // seeks deliberately bypass this public entry so decoder callbacks
        // cannot reset the in-progress 2/3 or 3/3 count merely by making the
        // active sentence index flicker across an adjacent boundary.
        currentRepeatCount = 1
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

    /// Seek to a sentence start while preserving that sentence as the active
    /// target until the decoder reaches it. This is used both for an explicit
    /// row selection and for sentence-repeat seeks: at an adjacent boundary,
    /// a frame-rounded timestamp can be a few milliseconds before the target
    /// and would otherwise resolve back to the previous sentence.
    private func seekToTargetSegment(
        _ segment: SentenceSegment,
        protectRepeatCycle: Bool = false,
        completion: (@Sendable () -> Void)? = nil
    ) {
        explicitSegmentSelection = ExplicitSegmentSelection(
            segmentID: segment.id,
            hasCompletedSeek: false,
            seekCompletedAtUptime: nil,
            minimumValidEndUptime: protectRepeatCycle ? .infinity : nil,
            maximumObservedTargetTime: segment.startTime
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
                self.markExplicitSelectionSeekCompleted()
                if backendTime.isFinite, backendTime >= 0 {
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
            self.markExplicitSelectionSeekCompleted()
            self.isSeeking = false
            if self.wantsPlayback {
                backend.playbackRate = self.playbackRate
                backend.play()
                self.isPlaying = true
            }
            completion?()
        }
    }

    private func markExplicitSelectionSeekCompleted() {
        guard var selection = explicitSegmentSelection else { return }
        let completedAt = ProcessInfo.processInfo.systemUptime
        selection.hasCompletedSeek = true
        selection.seekCompletedAtUptime = completedAt
        if selection.minimumValidEndUptime != nil,
           let target = segments.first(where: { $0.id == selection.segmentID }) {
            let effectiveRate = max(0.5, Double(playbackRate))
            let expectedPlaybackDuration = target.duration / effectiveRate
            selection.minimumValidEndUptime =
                completedAt + max(0.12, expectedPlaybackDuration - 0.12)
        }
        explicitSegmentSelection = selection
    }

    public func seekBy(offset: Double) {
        seek(to: currentTime + offset)
    }

    // MARK: - 智能复读、跟读停顿与断句边界判定

    private func handlePlaybackBoundary(at time: Double) {
        guard !isWaveformFrozenAtNaturalEnd else { return }

        // Repositioning a subtitle must not let the media clock select a
        // different sentence. In single-sentence mode it also needs to keep
        // wrapping the clock to the dragged sentence, so holding the subtitle
        // does not accidentally play through subsequent sentences.
        if isVideoSubtitleDragging,
           loopMode == .singleSegment,
           let dragID = videoSubtitleDragSegmentID,
           let dragIndex = segments.firstIndex(where: { $0.id == dragID }) {
            if activeSegmentIndex != dragIndex {
                activeSegmentIndex = dragIndex
                updateSecondaryViewportForActiveSegment(force: true)
            }
            guard isPlaying, !isShadowingPaused else { return }
            let draggedSegment = segments[dragIndex]
            if time >= draggedSegment.endTime - 0.005 {
                triggerSentenceRepeat(for: draggedSegment)
            }
            return
        }

        // Boundary editing must not change the active sentence while the
        // pointer is down.  In single-sentence mode, however, the raw media
        // clock must still be wrapped back to the same sentence; otherwise
        // the backend would naturally run into the following sentence while
        // the user is dragging.  This repeat keeps playback continuous and
        // never selects or seeks to the next sentence.
        if isBoundaryDragging {
            guard loopMode == .singleSegment,
                  let activeIdx = activeSegmentIndex,
                  (boundaryDragSession?.baseSegments ?? segments).indices.contains(activeIdx),
                  isPlaying,
                  !isShadowingPaused else { return }
            let currentSeg = boundaryDragSession?.segment(at: activeIdx) ?? segments[activeIdx]
            guard time >= currentSeg.endTime - 0.005 else { return }
            currentRepeatCount += 1
            seekToTargetSegment(currentSeg)
            return
        }

        // A shadowing pause intentionally freezes the current sentence while
        // the decoder is paused.  AVPlayer/libmpv can still deliver one or
        // more queued end-time frames during that interval; treating those
        // stale frames as normal timeline progress would briefly select the
        // next sentence and make both waveforms flicker before the repeat
        // seek starts.
        if isShadowingPaused {
            return
        }

        if let previewEndTime, time >= previewEndTime {
            self.previewEndTime = nil
            pause()
            return
        }

        // This check must run before the ordinary sentence-end branch below:
        // a queued pre-seek frame already carries the target's end timestamp,
        // so consulting it only from updateActiveSegment would be too late.
        recordRepeatSeekPlaybackProgress(at: time)
        settleExplicitSelectionAfterPlaybackProgress(at: time)
        if shouldIgnoreStaleSentenceEndAfterSeek(at: time) { return }

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
                if shadowingPauseRatio > 0 {
                    let pauseDuration = max(0.5, currentSeg.duration * shadowingPauseRatio)
                    startShadowingPause(duration: pauseDuration) { [weak self] in
                        guard let self = self else { return }
                        self.advanceToNextSentence(from: activeIdx)
                    }
                } else {
                    advanceToNextSentence(from: activeIdx)
                }
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
                self.seekToTargetSegment(segment, protectRepeatCycle: true) {
                    Task { @MainActor [weak self] in
                        self?.play()
                    }
                }
            }
        } else {
            currentRepeatCount += 1
            seekToTargetSegment(segment, protectRepeatCycle: true)
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
                self.wantsPlayback = true
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
                    shadowingPauseRatio == 0 &&
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
                    // 全篇循环等模式下：按媒体真实时间流自然过渡
                    activeSegmentIndex = nextIdx
                    currentRepeatCount = 1
                    ensureSegmentVisibleInPrimaryViewport(at: nextIdx)
                } else {
                    // 最后一条断句结束时，全篇循环可能先于媒体的 finished
                    // 回调直接跳回第一条；同步重置主波形，避免仍保留文件尾部视口。
                    if loopMode == .all,
                       nextIdx == 0,
                       currentIndex == segments.count - 1 {
                        resetPrimaryViewportForLoopRestart()
                    }
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
        // 在暂停后端之前设置冻结标记，因为部分后端会从 pause() 同步发出
        // 一次状态或时间回调。
        isWaveformFrozenAtNaturalEnd = true
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

        // A subtitle drag is a presentation-only interaction. Pin the active
        // sentence while it is held so queued decoder timestamps cannot make
        // the list or either waveform jump to a neighbouring sentence. The
        // boundary handler above performs the repeat seek when needed.
        if isVideoSubtitleDragging,
           loopMode == .singleSegment,
           let dragID = videoSubtitleDragSegmentID,
           let targetIndex = segments.firstIndex(where: { $0.id == dragID }) {
            if activeSegmentIndex != targetIndex {
                activeSegmentIndex = targetIndex
            }
            return
        }

        if let explicitSelection = explicitSegmentSelection {
            if let targetIndex = segments.firstIndex(where: { $0.id == explicitSelection.segmentID }) {
                let target = segments[targetIndex]
                // One 60 Hz UI frame plus a small decoder rounding margin.
                // This is deliberately far below a meaningful subtitle offset.
                let earlySeekTolerance = 0.025
                // A backend may finish an asynchronous seek before its next
                // time callback has caught up.  In that short window it can
                // report the previous sentence's timestamp (this is common
                // when pressing Next near a sentence boundary).  Keep the
                // explicitly selected sentence active while the decoder is
                // still before its start; otherwise the stale callback would
                // immediately select the previous sentence again.
                if time < target.startTime - earlySeekTolerance {
                    if activeSegmentIndex != targetIndex {
                        activeSegmentIndex = targetIndex
                    }
                    return
                }
                if time >= target.startTime - earlySeekTolerance, time < target.endTime {
                    if activeSegmentIndex != targetIndex {
                        activeSegmentIndex = targetIndex
                    }
                    // Keep a small settling window after the target is
                    // reached.  It prevents a late, queued pre-seek time
                    // callback from undoing the user's explicit selection.
                    let settleTolerance = 0.08
                    if explicitSelection.hasCompletedSeek,
                       time >= target.startTime + settleTolerance,
                       explicitSelection.minimumValidEndUptime == nil {
                        explicitSegmentSelection = nil
                    }
                    return
                }

                // AVPlayer can deliver one queued pre-seek timestamp from the
                // old sentence end immediately after a repeat seek completes.
                // With a shadowing pause that stale frame otherwise looks like
                // a freshly completed repeat and starts the same sentence's
                // pause again forever. A repeat target remains the visual
                // active sentence until `handlePlaybackBoundary` accepts a
                // real completion; paused/seek callbacks must never switch
                // the list or either waveform to the adjacent sentence.
                if explicitSelection.minimumValidEndUptime != nil,
                   time >= target.endTime {
                    return
                }
                if shouldIgnoreStaleSentenceEndAfterSeek(at: time) { return }
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

    private func shouldIgnoreStaleSentenceEndAfterSeek(at time: Double) -> Bool {
        guard shadowingPauseRatio > 0,
              let selection = explicitSegmentSelection,
              selection.hasCompletedSeek,
              let completedAt = selection.seekCompletedAtUptime,
              let target = segments.first(where: { $0.id == selection.segmentID }),
              time >= target.endTime else { return false }
        let elapsed = ProcessInfo.processInfo.systemUptime - completedAt
        if let minimumValidEndUptime = selection.minimumValidEndUptime {
            let effectiveRate = max(0.5, Double(playbackRate))
            let expectedPlaybackDuration = target.duration / effectiveRate
            // A genuine completion needs both enough real playback time and
            // an in-range progress sample close to the target end. The latter
            // rejects AVPlayer's isolated queued pre-seek end frames, which
            // otherwise make the UI jump to the adjacent sentence mid-repeat.
            let progressTolerance = min(0.06, max(0.015, target.duration * 0.08))
            let hasReachedTargetEnd =
                selection.maximumObservedTargetTime >= target.endTime - progressTolerance
            let hasPlayedLongEnough =
                ProcessInfo.processInfo.systemUptime >= minimumValidEndUptime &&
                elapsed >= max(0.05, expectedPlaybackDuration - 0.04)
            return !(hasPlayedLongEnough && hasReachedTargetEnd)
        }
        let effectiveRate = max(0.5, Double(playbackRate))
        let expectedPlaybackDuration = target.duration / effectiveRate
        let staleCallbackWindow = min(0.40, max(0.12, expectedPlaybackDuration * 0.40))
        return elapsed >= 0 && elapsed < staleCallbackWindow
    }

    private func recordRepeatSeekPlaybackProgress(at time: Double) {
        guard var selection = explicitSegmentSelection,
              selection.minimumValidEndUptime != nil,
              selection.hasCompletedSeek,
              let target = segments.first(where: { $0.id == selection.segmentID }),
              time >= target.startTime - 0.025,
              time < target.endTime else { return }
        if time > selection.maximumObservedTargetTime {
            selection.maximumObservedTargetTime = time
            explicitSegmentSelection = selection
        }
    }

    private func settleExplicitSelectionAfterPlaybackProgress(at time: Double) {
        guard let selection = explicitSegmentSelection,
              selection.hasCompletedSeek,
              let target = segments.first(where: { $0.id == selection.segmentID }) else { return }
        // Repeat seeks retain their target through the whole playback cycle.
        // This makes late AVPlayer frames presentation-inert: the boundary
        // state machine may decide whether they are real completions, but
        // they can never make the list or waveform flicker to the next row.
        if selection.minimumValidEndUptime != nil {
            return
        }
        let settleTolerance = min(0.08, target.duration * 0.25)
        if time >= target.startTime + settleTolerance, time < target.endTime {
            explicitSegmentSelection = nil
        }
    }

    // MARK: - 断句快捷操作、难句收藏与书签

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
        isWaveformFrozenAtNaturalEnd = false
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
        markExplicitSegmentSelection()
        currentRepeatCount = 1
        ensureSegmentVisibleInPrimaryViewport(at: index)
        updateSecondaryViewportForActiveSegment(force: true)
        seekToTargetSegment(seg)
    }

    public func jumpToSegment(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        jumpToSegment(at: idx)
    }

    private func markExplicitSegmentSelection() {
        explicitSegmentSelectionRevision &+= 1
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

    /// 切换用于“显示 > 书签”快速跳转的独立书签。
    /// 它与难句收藏星标分开保存，避免改变既有的复读筛选语义。
    public func toggleNavigationBookmark(for segmentId: UUID) {
        if let idx = segments.firstIndex(where: { $0.id == segmentId }) {
            segments[idx].isNavigationBookmarked.toggle()
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
        refreshSecondaryViewportAfterSegmentMutation()
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
        refreshSecondaryViewportAfterSegmentMutation()
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
            isNavigationBookmarked: current.isNavigationBookmarked,
            isBookmarked: current.isBookmarked,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
        )

        let seg2 = SentenceSegment(
            index: current.index + 1,
            startTime: splitTime,
            endTime: current.endTime,
            text: current.text,
            translation: current.translation,
            isBookmarked: false,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
        )

        segments.remove(at: idx)
        segments.insert(contentsOf: [seg1, seg2], at: idx)
        reindexSegments()
        activeSegmentIndex = idx
        refreshSecondaryViewportAfterSegmentMutation()
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
            isNavigationBookmarked: current.isNavigationBookmarked,
            isBookmarked: current.isBookmarked,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
        )

        let seg2 = SentenceSegment(
            index: current.index + 1,
            startTime: splitTime,
            endTime: current.endTime,
            text: current.text,
            translation: current.translation,
            isBookmarked: false,
            speakerID: current.speakerID,
            speakerIDs: current.speakerIDs,
            isSpeakerOverlap: current.isSpeakerOverlap
        )

        segments.remove(at: idx)
        segments.insert(contentsOf: [seg1, seg2], at: idx)
        reindexSegments()
        activeSegmentIndex = idx
        refreshSecondaryViewportAfterSegmentMutation()
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
            isNavigationBookmarked: seg1.isNavigationBookmarked || seg2.isNavigationBookmarked,
            isBookmarked: seg1.isBookmarked || seg2.isBookmarked,
            speakerID: nil,
            speakerIDs: Array(Set(seg1.speakerIDs + seg2.speakerIDs)).sorted(),
            isSpeakerOverlap: seg1.isSpeakerOverlap || seg2.isSpeakerOverlap
        )

        segments.remove(at: index + 1)
        segments[index] = merged
        reindexSegments()
        activeSegmentIndex = index
        refreshSecondaryViewportAfterSegmentMutation()
        persistCurrentProject()
    }

    public func mergeSegmentWithNext(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        mergeSegmentWithNext(at: idx)
    }

    public func mergeSegmentWithPrevious(at index: Int) {
        guard index > 0 && index < segments.count else { return }
        mergeSegmentWithNext(at: index - 1)
    }

    public func mergeSegmentWithPrevious(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        mergeSegmentWithPrevious(at: idx)
    }

    /// 删除、拆分或合并后，即使活动句仍然使用同一个 UUID，也必须重新
    /// 计算次波形图视口，因为该句的起止时间可能已经发生变化。
    private func refreshSecondaryViewportAfterSegmentMutation() {
        guard activeSegmentIndex != nil else {
            lastSecondarySegmentId = nil
            secondaryViewport = (0, 5)
            return
        }
        updateSecondaryViewportForActiveSegment(force: true)
    }

    public func updateSegmentText(id: UUID, text: String, translation: String? = nil) {
        if let idx = segments.firstIndex(where: { $0.id == id }) {
            var changed = false
            if segments[idx].text != text {
                segments[idx].text = text
                changed = true
            }
            if let t = translation, segments[idx].translation != t {
                segments[idx].translation = t
                changed = true
            }
            guard changed else { return }
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
