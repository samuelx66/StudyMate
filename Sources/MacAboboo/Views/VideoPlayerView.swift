import SwiftUI
import AppKit

/// 视频画面与音频可视化视图（纯原生 GPU 硬件直通加速渲染，0 延迟、0 窗口干扰）
public struct VideoPlayerView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var lang = LanguageManager.shared
    
    @State private var isHovering: Bool = false
    @State private var isScrubbing: Bool = false
    
    // 自由拖拽定位坐标
    @State private var positionOffset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    private var shouldShowOverlay: Bool {
        guard engine.currentMedia != nil else { return false }
        // 跟读停顿期间音频已暂停但倒计时仍在进行，避免控制面板遮挡状态提示；
        // 倒计时结束或用户普通暂停时，仍按原有规则显示控制面板。
        if engine.isShadowingPaused {
            return false
        }
        // 只要鼠标在画面内、或者未在播放、或者正在拖拽进度条，就一直显示
        if isHovering || !engine.isPlaying || isScrubbing || dragTranslation != .zero {
            return true
        }
        return false
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                
                if let media = engine.currentMedia {
                    if media.isVideo {
                        // 智能多媒体双引擎硬件加速视频渲染视图（AVFoundation / libmpv 无缝直通）
                        NativeVideoPlayerRepresentable(
                            playerView: engine.activeBackend.playerView,
                            onHoverChanged: { hovering in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isHovering = hovering
                                }
                            }
                        )
                        .id("\(ObjectIdentifier(engine.activeBackend))_\(media.id)")
                        .onTapGesture {
                            engine.togglePlayPause()
                        }
                    } else {
                        // 纯音频模式下的视觉占位
                        AudioVisualPlaceholder(
                            title: media.title,
                            isPlaying: engine.isPlaying,
                            duration: media.formattedDuration
                        )
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isHovering = hovering
                            }
                        }
                        .onTapGesture {
                            engine.togglePlayPause()
                        }
                    }
                } else {
                    // 未打开媒体文件时的空状态
                    EmptyMediaPlaceholder()
                }

                // 当前断句的原文与译文覆盖层。它独立于播放控制面板，
                // 两行字幕可分别拖动，位置和字体由工具栏设置持久化管理。
                VideoSubtitleOverlay(engine: engine)

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
                            .stroke(MacAbobooMediaStyle.separator.opacity(0.5), lineWidth: 0.7)
                    )
                }
                
                // 悬浮式播放控制面板（IINA 风格，支持在画面区域内随意拖放）
                if engine.currentMedia != nil {
                    VStack {
                        Spacer()
                        FloatingVideoOSDView(
                            engine: engine,
                            isScrubbing: $isScrubbing
                        )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                            .offset(
                                x: positionOffset.width + dragTranslation.width,
                                y: positionOffset.height + dragTranslation.height
                            )
                            .gesture(
                                DragGesture(minimumDistance: 4)
                                    .onChanged { value in
                                        dragTranslation = value.translation
                                    }
                                    .onEnded { value in
                                        let maxOffsetX = max(0, (geometry.size.width - 240) / 2)
                                        let maxOffsetY = max(0, geometry.size.height - 60)
                                        
                                        var newWidth = positionOffset.width + value.translation.width
                                        var newHeight = positionOffset.height + value.translation.height
                                        
                                        newWidth = max(-maxOffsetX, min(maxOffsetX, newWidth))
                                        newHeight = max(-maxOffsetY, min(0, newHeight))
                                        
                                        positionOffset = CGSize(width: newWidth, height: newHeight)
                                        dragTranslation = .zero
                                    }
                            )
                            .opacity(shouldShowOverlay ? 1.0 : 0.0)
                            .animation(.easeInOut(duration: 0.2), value: shouldShowOverlay)
                            .allowsHitTesting(shouldShowOverlay)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(MacAbobooMediaStyle.separator, lineWidth: 1)
            )
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isHovering {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHovering = true
                        }
                    }
                case .ended:
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isHovering = false
                    }
                }
            }
        }
        .frame(minHeight: 200)
    }
}

/// 纯原生 AppKit 视频渲染容器宿主（集成 NSTrackingArea 确保 100% 鼠标悬停感知）
public struct NativeVideoPlayerRepresentable: NSViewRepresentable {
    let playerView: NSView
    var onHoverChanged: ((Bool) -> Void)? = nil
    
    public func makeNSView(context: Context) -> TrackingVideoContainerView {
        let container = TrackingVideoContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.needsDisplayOnBoundsChange = false
        container.layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.onHoverChanged = onHoverChanged
        embed(playerView, in: container)
        return container
    }
    
    public func updateNSView(_ nsView: TrackingVideoContainerView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
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
