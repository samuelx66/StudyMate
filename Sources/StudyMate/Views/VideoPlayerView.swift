import SwiftUI
import AppKit

/// 视频画面与音频可视化视图（纯原生 GPU 硬件直通加速渲染，0 延迟、0 窗口干扰）
public struct VideoPlayerView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var lang = LanguageManager.shared
    
    @State private var isHovering: Bool = false
    /// 播放时由指针活动维持控制面板可见；超过延迟后仅隐藏面板，鼠标再次
    /// 移动时立即恢复。暂停状态仍保持面板可见，方便用户继续操作。
    @State private var isPointerActive: Bool = false
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var isScrubbing: Bool = false
    /// Continuous hover can arrive at display-refresh frequency. Keep the
    /// deadline in a reference value so refreshing it does not invalidate the
    /// whole video view on every mouse move.
    @State private var pointerActivityMarker = PointerActivityMarker()
    
    // 自由拖拽定位坐标
    @State private var positionOffset: CGSize = .zero
    @State private var controlPanelSize: CGSize = CGSize(width: 572, height: 74)

    // 时间码微调 HUD 状态（触控板双指横滑 Seek）
    @State private var isSeekingHUDVisible: Bool = false
    @State private var seekingTargetTime: Double = 0
    @State private var seekingDeltaSeconds: Double = 0
    @State private var seekingHUDHideTask: Task<Void, Never>?

    // 音量调节 HUD 状态（触控板双指纵滑调节音量）
    @State private var isVolumeHUDVisible: Bool = false
    @State private var currentHUDVolume: Float = 1.0
    @State private var volumeHUDHideTask: Task<Void, Never>?

    private static let controlPanelAutoHideDelay: UInt64 = 10_000_000_000
    private static let controlPanelAnimation = Animation.easeInOut(duration: 0.2)
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }

    private func showSeekingHUD(targetTime: Double, deltaSeconds: Double) {
        seekingHUDHideTask?.cancel()
        seekingHUDHideTask = nil
        seekingTargetTime = targetTime
        seekingDeltaSeconds = deltaSeconds
        if !isSeekingHUDVisible {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isSeekingHUDVisible = true
            }
        }
    }

    private func scheduleHideSeekingHUD() {
        seekingHUDHideTask?.cancel()
        seekingHUDHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                isSeekingHUDVisible = false
            }
            seekingHUDHideTask = nil
        }
    }

    private func showVolumeHUD(volume: Float) {
        volumeHUDHideTask?.cancel()
        volumeHUDHideTask = nil
        currentHUDVolume = volume
        if !isVolumeHUDVisible {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isVolumeHUDVisible = true
            }
        }
    }

    private func scheduleHideVolumeHUD() {
        volumeHUDHideTask?.cancel()
        volumeHUDHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                isVolumeHUDVisible = false
            }
            volumeHUDHideTask = nil
        }
    }
    
    private var shouldShowOverlay: Bool {
        guard engine.currentMedia != nil else { return false }
        // 暂停时保留控制面板；播放时只由指针活动、时间轴操作维持可见
        if !engine.isPlaying || isScrubbing {
            return true
        }
        return isHovering && isPointerActive
    }

    /// 当前指针进入/移动到视频区域时显示面板，并重新开始 10 秒无活动计时。
    private func handlePointerActivity() {
        guard engine.currentMedia != nil else { return }
        pointerActivityMarker.lastActivityUptime = ProcessInfo.processInfo.systemUptime
        if !isHovering {
            withAnimation(Self.controlPanelAnimation) {
                isHovering = true
            }
        }
        if !isPointerActive {
            withAnimation(Self.controlPanelAnimation) {
                isPointerActive = true
            }
        }
        scheduleOverlayAutoHide()
    }

    private func handlePointerExit() {
        pointerActivityMarker.lastActivityUptime = 0
        overlayHideTask?.cancel()
        overlayHideTask = nil
        withAnimation(Self.controlPanelAnimation) {
            isHovering = false
            isPointerActive = false
        }
    }

    private func scheduleOverlayAutoHide() {
        pointerActivityMarker.lastActivityUptime = ProcessInfo.processInfo.systemUptime
        guard engine.isPlaying, overlayHideTask == nil else { return }

        let marker = pointerActivityMarker
        overlayHideTask = Task { @MainActor in
            do {
                while !Task.isCancelled {
                    let elapsed = ProcessInfo.processInfo.systemUptime - marker.lastActivityUptime
                    let remaining = Double(Self.controlPanelAutoHideDelay) / 1_000_000_000 - elapsed
                    if remaining > 0 {
                        try await Task.sleep(nanoseconds: UInt64(max(0.001, remaining) * 1_000_000_000))
                        continue
                    }

                    guard isHovering, engine.isPlaying else {
                        overlayHideTask = nil
                        return
                    }

                    withAnimation(Self.controlPanelAnimation) {
                        isPointerActive = false
                    }
                    overlayHideTask = nil
                    return
                }
            } catch {
                return
            }
        }
    }

    /// 将面板的相对偏移限制在视频区域内。面板的默认位置是底部居中，
    /// 因而其垂直偏移范围为“刚好贴顶”到 0（贴住底部）。
    private func boundedPanelOffset(_ offset: CGSize, in containerSize: CGSize) -> CGSize {
        let panelWidth = max(1, controlPanelSize.width)
        let panelHeight = max(1, controlPanelSize.height)
        let horizontalLimit = max(0, (containerSize.width - panelWidth) / 2)
        let topLimit = min(0, -(containerSize.height - panelHeight))

        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(0, max(topLimit, offset.height))
        )
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                
                if let media = engine.currentMedia {
                    if media.isVideo {
                        // 智能多媒体双引擎硬件加速视频渲染视图（AVFoundation / libmpv 无缝直通）
                        NativeVideoPlayerRepresentable(
                            playerView: engine.activeBackend.playerView
                        )
                        .id("\(ObjectIdentifier(engine.activeBackend))_\(media.id)")
                    } else {
                        // 纯音频模式下的视觉占位
                        AudioVisualPlaceholder(
                            title: media.title,
                            isPlaying: engine.isPlaying,
                            duration: media.formattedDuration
                        )
                    }
                } else {
                    // 未打开媒体文件时的空状态
                    EmptyMediaPlaceholder()
                }

                // 触控板原生手势感知与微调层 (双指横滑 Seek + 双指上下滑动调节音量)
                if engine.currentMedia != nil {
                    VideoGestureOverlayRepresentable(
                        engine: engine,
                        onSeekBegan: {
                            showSeekingHUD(targetTime: engine.clock.currentTime, deltaSeconds: 0)
                        },
                        onSeekChanged: { targetTime, delta in
                            showSeekingHUD(targetTime: targetTime, deltaSeconds: delta)
                        },
                        onSeekEnded: {
                            scheduleHideSeekingHUD()
                        },
                        onVolumeChanged: { newVolume in
                            showVolumeHUD(volume: newVolume)
                        },
                        onVolumeEnded: {
                            scheduleHideVolumeHUD()
                        },
                        onPointerActivity: {
                            handlePointerActivity()
                        },
                        onHoverChanged: { hovering in
                            if hovering {
                                handlePointerActivity()
                            } else {
                                handlePointerExit()
                            }
                        },
                        onSingleTap: {
                            engine.togglePlayPause()
                        }
                    )
                }

                // 当前断句的原文与译文覆盖层（支持随底部 OSD 呼出智能上浮避让）
                VideoSubtitleOverlay(
                    engine: engine,
                    isOSDVisible: shouldShowOverlay && abs(positionOffset.height) < 40
                )

                // 左上角触控板手势微调 HUD 浮层（双指横滑 Seek / 双指纵向滑动调节音量）
                if isSeekingHUDVisible || isVolumeHUDVisible {
                    VStack {
                        HStack {
                            if isSeekingHUDVisible {
                                VideoSeekingHUDView(
                                    targetTime: seekingTargetTime,
                                    duration: engine.duration,
                                    deltaSeconds: seekingDeltaSeconds
                                )
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.95, anchor: .topLeading).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            } else if isVolumeHUDVisible {
                                VideoVolumeHUDView(volume: currentHUDVolume)
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.95, anchor: .topLeading).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .zIndex(10)
                    .allowsHitTesting(false)
                }

                if engine.isMediaLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(lang.text("正在加载媒体…", "Loading media…"))
                            .font(.caption)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(StudyMateMediaStyle.separator.opacity(0.5), lineWidth: 0.7)
                    )
                }
                
                // 悬浮式播放控制面板（IINA 风格，支持在画面区域内随意拖放）
                if engine.currentMedia != nil {
                    VStack {
                        Spacer()
                        DraggableFloatingOSDContainer(
                            engine: engine,
                            containerSize: geometry.size,
                            controlPanelSize: $controlPanelSize,
                            positionOffset: $positionOffset,
                            isScrubbing: $isScrubbing,
                            shouldShowOverlay: shouldShowOverlay,
                            onPointerActivity: { handlePointerActivity() },
                            onDragEnded: { scheduleOverlayAutoHide() }
                        )
                    }
                    .zIndex(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(StudyMateMediaStyle.separator, lineWidth: 1)
            )
            .onPreferenceChange(FloatingOSDSizePreferenceKey.self) { size in
                guard size.width > 0, size.height > 0 else { return }
                if controlPanelSize != size {
                    controlPanelSize = size
                    // 窗口缩放后立即重新约束已保存的位置，避免面板留在新的
                    // 视频边界之外。
                    positionOffset = boundedPanelOffset(positionOffset, in: geometry.size)
                }
            }
        }
        .frame(minHeight: 200)
        .onChange(of: engine.isPlaying) { _, isPlaying in
            if isPlaying {
                if isHovering { scheduleOverlayAutoHide() }
            } else {
                overlayHideTask?.cancel()
                overlayHideTask = nil
                withAnimation(Self.controlPanelAnimation) {
                    isPointerActive = false
                }
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if !scrubbing, isHovering { scheduleOverlayAutoHide() }
        }
        .onDisappear {
            pointerActivityMarker.lastActivityUptime = 0
            overlayHideTask?.cancel()
            overlayHideTask = nil
            seekingHUDHideTask?.cancel()
            seekingHUDHideTask = nil
            volumeHUDHideTask?.cancel()
            volumeHUDHideTask = nil
        }
    }
}

/// 独立的浮动控制面板拖拽容器，隔离 dragTranslation 状态，避免拖动时上层视频渲染器和字幕层反复重绘
private struct DraggableFloatingOSDContainer: View {
    @ObservedObject var engine: PlaybackEngine
    let containerSize: CGSize
    @Binding var controlPanelSize: CGSize
    @Binding var positionOffset: CGSize
    @Binding var isScrubbing: Bool
    let shouldShowOverlay: Bool
    let onPointerActivity: () -> Void
    let onDragEnded: () -> Void

    @State private var dragTranslation: CGSize = .zero
    @State private var isVolumeScrubbing: Bool = false
    @State private var panelDragActive = false

    var body: some View {
        FloatingVideoOSDView(
            engine: engine,
            isScrubbing: $isScrubbing,
            isVolumeScrubbing: $isVolumeScrubbing
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .offset(
            x: positionOffset.width + dragTranslation.width,
            y: positionOffset.height + dragTranslation.height
        )
        .background(
            GeometryReader { panelGeometry in
                Color.clear
                    .preference(
                        key: FloatingOSDSizePreferenceKey.self,
                        value: panelGeometry.size
                    )
            }
        )
        .onHover { hovering in
            if hovering { onPointerActivity() }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard !isScrubbing, !isVolumeScrubbing else {
                        if panelDragActive {
                            panelDragActive = false
                            dragTranslation = .zero
                        }
                        return
                    }
                    if !panelDragActive {
                        panelDragActive = true
                        onPointerActivity()
                    }
                    let candidate = CGSize(
                        width: positionOffset.width + value.translation.width,
                        height: positionOffset.height + value.translation.height
                    )
                    let bounded = boundedPanelOffset(candidate, panelSize: controlPanelSize, in: containerSize)
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        dragTranslation = CGSize(
                            width: bounded.width - positionOffset.width,
                            height: bounded.height - positionOffset.height
                        )
                    }
                }
                .onEnded { value in
                    guard panelDragActive else {
                        dragTranslation = .zero
                        return
                    }
                    panelDragActive = false
                    guard !isScrubbing, !isVolumeScrubbing else {
                        dragTranslation = .zero
                        return
                    }
                    let candidate = CGSize(
                        width: positionOffset.width + value.translation.width,
                        height: positionOffset.height + value.translation.height
                    )
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        positionOffset = boundedPanelOffset(candidate, panelSize: controlPanelSize, in: containerSize)
                        dragTranslation = .zero
                    }
                    onDragEnded()
                },
                including: .gesture
        )
        .opacity(shouldShowOverlay ? 1.0 : 0.0)
        .allowsHitTesting(shouldShowOverlay)
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                panelDragActive = false
                dragTranslation = .zero
            }
        }
        .onChange(of: isVolumeScrubbing) { _, scrubbing in
            if scrubbing {
                panelDragActive = false
                dragTranslation = .zero
            }
        }
    }

    private func boundedPanelOffset(_ offset: CGSize, panelSize: CGSize, in containerSize: CGSize) -> CGSize {
        let panelWidth = max(1, panelSize.width)
        let panelHeight = max(1, panelSize.height)
        let horizontalLimit = max(0, (containerSize.width - panelWidth) / 2)
        let topLimit = min(0, -(containerSize.height - panelHeight))

        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(0, max(topLimit, offset.height))
        )
    }
}

private final class PointerActivityMarker {
    var lastActivityUptime: TimeInterval = 0
}

private struct FloatingOSDSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 纯原生 AppKit 视频渲染容器宿主（集成 NSTrackingArea 确保 100% 鼠标悬停感知）
public struct NativeVideoPlayerRepresentable: NSViewRepresentable {
    let playerView: NSView
    var onHoverChanged: ((Bool) -> Void)? = nil
    var onPointerActivity: (() -> Void)? = nil
    
    public func makeNSView(context: Context) -> TrackingVideoContainerView {
        let container = TrackingVideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.needsDisplayOnBoundsChange = false
        container.layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.onHoverChanged = onHoverChanged
        container.onPointerActivity = onPointerActivity
        embed(playerView, in: container)
        return container
    }
    
    public func updateNSView(_ nsView: TrackingVideoContainerView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onPointerActivity = onPointerActivity
        embed(playerView, in: nsView)
    }
    
    private func embed(_ view: NSView, in container: NSView) {
        if view.superview != container {
            container.subviews.forEach { $0.removeFromSuperview() }
            view.wantsLayer = true
            view.layer?.needsDisplayOnBoundsChange = false
            view.layerContentsRedrawPolicy = .onSetNeedsDisplay
            view.autoresizingMask = [.width, .height]
            view.frame = container.bounds
            container.addSubview(view)
        } else if view.frame != container.bounds {
            view.frame = container.bounds
        }
    }
}

/// 带有完整鼠标悬停与移动追踪的容器视图
public final class TrackingVideoContainerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onPointerActivity: (() -> Void)?
    
    private var trackingArea: NSTrackingArea?
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInActiveApp,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    
    public override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        onPointerActivity?()
    }

    public override func mouseMoved(with event: NSEvent) {
        onPointerActivity?()
    }
    
    public override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

/// 纯音频模式占位图
struct AudioVisualPlaceholder: View {
    let title: String
    let isPlaying: Bool
    let duration: String
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.7), Color.purple.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.blue.opacity(isPlaying ? 0.5 : 0.2), radius: isPlaying ? 16 : 8)
                    .scaleEffect(isPlaying ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPlaying)
                
                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// 空媒体状态视图
struct EmptyMediaPlaceholder: View {
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            
            Text(lang.localized(.noFileLoaded))
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(lang.text(
                "支持 MP4、MKV、WebM、AVI、MOV、FLV、MP3、WAV 等格式及字幕导入",
                "Supports MP4, MKV, WebM, AVI, MOV, FLV, MP3, WAV and subtitle imports"
            ))
            .font(.caption)
            .foregroundColor(.secondary.opacity(0.8))
        }
        .padding()
    }
}

// MARK: - 触控板微调 HUD 浮层

/// 触控板横滑微调 Seek 时间码 HUD（左上角紧凑小长方形）
struct VideoSeekingHUDView: View {
    let targetTime: Double
    let duration: Double
    let deltaSeconds: Double

    private func formatCompactTimecode(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSec = Int(seconds)
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        if duration >= 3600 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            let tenths = Int((seconds - Double(totalSec)) * 10)
            return String(format: "%02d:%02d.%d", m, s, tenths)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: deltaSeconds >= 0 ? "goforward" : "gobackward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudyMateMediaStyle.accent)

                Text(String(format: "%@%.1fs", deltaSeconds >= 0 ? "+" : "", deltaSeconds))
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)

                Spacer(minLength: 6)

                Text("\(formatCompactTimecode(targetTime)) / \(formatCompactTimecode(duration))")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 紧凑进度指示条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(StudyMateMediaStyle.accent)
                        .frame(width: geo.size.width * CGFloat(max(0.0, min(1.0, duration > 0 ? targetTime / duration : 0.0))))
                }
            }
            .frame(height: 2.5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 172)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.28), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }
}

/// 触控板纵滑音量调节 HUD（左上角紧凑小长方形）
struct VideoVolumeHUDView: View {
    let volume: Float

    private var volumeIconName: String {
        if volume <= 0.001 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: volumeIconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudyMateMediaStyle.accent)
                    .frame(width: 14)

                Text("\(Int(round(volume * 100)))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)

                Spacer(minLength: 4)
            }

            // 音量进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(StudyMateMediaStyle.accent)
                        .frame(width: geo.size.width * CGFloat(max(0.0, min(1.0, volume))))
                }
            }
            .frame(height: 2.5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 86)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.28), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }
}

// MARK: - 触控板原生手势感知与微调层

/// 触控板原生手势与指针感知覆盖层
struct VideoGestureOverlayRepresentable: NSViewRepresentable {
    let engine: PlaybackEngine
    let onSeekBegan: () -> Void
    let onSeekChanged: (Double, Double) -> Void
    let onSeekEnded: () -> Void
    let onVolumeChanged: (Float) -> Void
    let onVolumeEnded: () -> Void
    let onPointerActivity: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onSingleTap: () -> Void

    func makeNSView(context: Context) -> VideoGestureOverlayView {
        let view = VideoGestureOverlayView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: VideoGestureOverlayView, context: Context) {
        nsView.engine = engine
        nsView.onSeekBegan = onSeekBegan
        nsView.onSeekChanged = onSeekChanged
        nsView.onSeekEnded = onSeekEnded
        nsView.onVolumeChanged = onVolumeChanged
        nsView.onVolumeEnded = onVolumeEnded
        nsView.onPointerActivity = onPointerActivity
        nsView.onHoverChanged = onHoverChanged
        nsView.onSingleTap = onSingleTap
    }
}

/// 支持双指横滑微调 Seek、双指纵滑调节音量及指针感知的 NSView
final class VideoGestureOverlayView: NSView {
    var engine: PlaybackEngine?
    var onSeekBegan: (() -> Void)?
    var onSeekChanged: ((Double, Double) -> Void)?
    var onSeekEnded: (() -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    var onVolumeEnded: (() -> Void)?
    var onPointerActivity: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onSingleTap: (() -> Void)?

    private enum GestureAxis {
        case none
        case seek
        case volume
    }

    private var activeAxis: GestureAxis = .none
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var seekStartTime: Double = 0
    private var initialVolume: Float = 1.0
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }

    private func setupGestures() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let tapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.numberOfClicksRequired = 1
        addGestureRecognizer(tapGesture)
    }

    @objc private func handleTap(_ gesture: NSClickGestureRecognizer) {
        if gesture.state == .ended {
            onPointerActivity?()
            onSingleTap?()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let newTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(newTrackingArea)
        self.trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerActivity?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func scrollWheel(with event: NSEvent) {
        onPointerActivity?()

        guard let engine = engine else {
            super.scrollWheel(with: event)
            return
        }

        // 精准触控板双指手势
        if event.hasPreciseScrollingDeltas {
            // 忽略惯性滚动阶段，防止手指离开触控板后时间码或音量剧烈飘移
            if !event.momentumPhase.isEmpty {
                return
            }

            switch event.phase {
            case .began:
                activeAxis = .none
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
                seekStartTime = engine.clock.currentTime
                initialVolume = engine.volume

            case .changed:
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY

                if activeAxis == .none {
                    accumulatedDeltaX += dx
                    accumulatedDeltaY += dy

                    let absX = abs(accumulatedDeltaX)
                    let absY = abs(accumulatedDeltaY)

                    // 阈值判定：一旦锁定主轴，手势期间互不干扰
                    if absX >= 3.0 && absX > absY {
                        activeAxis = .seek
                        engine.beginPreviewSeek()
                        onSeekBegan?()
                    } else if absY >= 3.0 && absY > absX {
                        activeAxis = .volume
                    }
                }

                if activeAxis == .seek {
                    accumulatedDeltaX += dx
                    // 触控板横滑微调敏感度：时长比例自适应，保证短视频精确到秒/帧，长视频适中
                    let duration = max(engine.duration, 1.0)
                    let sensitivity = min(0.25, max(0.05, duration / 1200.0))
                    let deltaSeconds = Double(accumulatedDeltaX) * sensitivity
                    let targetTime = min(max(0.0, seekStartTime + deltaSeconds), engine.duration)

                    engine.previewSeek(to: targetTime)
                    onSeekChanged?(targetTime, deltaSeconds)

                } else if activeAxis == .volume {
                    accumulatedDeltaY += dy
                    // 纵向滑动：向上增加音量，向下降低音量
                    let volumeDelta = Float(accumulatedDeltaY) * 0.0035
                    let newVolume = min(1.0, max(0.0, initialVolume + volumeDelta))
                    engine.volume = newVolume
                    onVolumeChanged?(newVolume)
                }

            case .ended, .cancelled:
                if activeAxis == .seek {
                    let duration = max(engine.duration, 1.0)
                    let sensitivity = min(0.25, max(0.05, duration / 1200.0))
                    let deltaSeconds = Double(accumulatedDeltaX) * sensitivity
                    let targetTime = min(max(0.0, seekStartTime + deltaSeconds), engine.duration)

                    engine.endPreviewSeek()
                    engine.seek(to: targetTime)
                    onSeekEnded?()
                } else if activeAxis == .volume {
                    onVolumeEnded?()
                }

                activeAxis = .none
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0

            default:
                break
            }
        } else {
            // 普通滚轮鼠标垂直滚轮微调音量
            let delta = Float(event.deltaY)
            if abs(delta) > 0.1 {
                let step: Float = delta > 0 ? 0.05 : -0.05
                let newVolume = min(1.0, max(0.0, engine.volume + step))
                engine.volume = newVolume
                onVolumeChanged?(newVolume)
                onVolumeEnded?()
            }
        }
    }
}
