import SwiftUI
import AppKit

/// 悬浮式播放控制面板（单行紧凑轻量 HUD，包含核心播放控制、时间轴与音量）
public struct FloatingVideoOSDView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var lang = LanguageManager.shared
    @Binding var isScrubbing: Bool
    
    public init(
        engine: PlaybackEngine,
        isScrubbing: Binding<Bool>
    ) {
        self.engine = engine
        self._isScrubbing = isScrubbing
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            // 1. 重播当前句
            Button(action: { engine.repeatCurrentSegment() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(lang.localized(.repeatSentence))
            
            // 2. 上一句
            Button(action: { engine.previousSegment() }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(lang.localized(.previousSentence))
            
            // 3. 播放 / 暂停 大按钮（实心强调色背景 + 白色图标）
            Button(action: { engine.togglePlayPause() }) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .shadow(color: Color.accentColor.opacity(0.30), radius: 3, x: 0, y: 1)
                    
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .help(engine.isPlaying ? lang.localized(.pause) : lang.localized(.play))
            
            // 4. 下一句
            Button(action: { engine.nextSegment() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(lang.localized(.nextSentence))
            
            // 5. 播放时间
            Text(SentenceSegment.formatTimecode(isScrubbing ? engine.clock.currentTime : engine.currentTime))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundColor(.primary)
                .frame(minWidth: 54, alignment: .trailing)
            
            // 6. 播放进度条（横向自适应扩展）
            OSDTimelineSlider(
                clock: engine.clock,
                duration: engine.duration,
                previewEnabled: engine.currentMedia?.isVideo == true,
                isScrubbing: $isScrubbing,
                onPreviewBegan: { engine.beginPreviewSeek() },
                onPreviewSeek: { engine.previewSeek(to: $0) },
                onPreviewEnded: { engine.endPreviewSeek() },
                onSeek: { engine.seek(to: $0) }
            )
            .frame(minWidth: 80)
            
            // 7. 总时间
            Text(SentenceSegment.formatTimecode(engine.duration))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 54, alignment: .leading)
            
            // 分隔小竖线
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)
            
            // 8. 音量调节
            HStack(spacing: 4) {
                Button(action: {
                    engine.volume = engine.volume > 0 ? 0 : 1.0
                }) {
                    Image(systemName: engine.volume == 0 ? "speaker.slash.fill" : (engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                
                Slider(
                    value: Binding(
                        get: { Double(engine.volume) },
                        set: { engine.volume = Float($0) }
                    ),
                    in: 0...1.0
                )
                .labelsHidden()
                .frame(width: 52)
            }
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
        .frame(maxWidth: 540)
    }
}

/// OSD 时间轴滑块组件
private struct OSDTimelineSlider: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let previewEnabled: Bool
    @Binding var isScrubbing: Bool
    let onPreviewBegan: () -> Void
    let onPreviewSeek: (Double) -> Void
    let onPreviewEnded: () -> Void
    let onSeek: (Double) -> Void

    @State private var scrubTime = 0.0

    var body: some View {
        Slider(
            value: Binding(
                get: { isScrubbing ? scrubTime : min(clock.currentTime, max(0.1, duration)) },
                set: { newTime in
                    scrubTime = newTime
                    if isScrubbing {
                        if previewEnabled { onPreviewSeek(newTime) }
                    } else {
                        onSeek(newTime)
                    }
                }
            ),
            in: 0...max(0.1, duration),
            onEditingChanged: { editing in
                isScrubbing = editing
                if editing {
                    scrubTime = min(clock.currentTime, max(0.1, duration))
                    if previewEnabled { onPreviewBegan() }
                } else {
                    if previewEnabled { onPreviewEnded() }
                    onSeek(scrubTime)
                }
            }
        )
    }
}
