import SwiftUI
import AppKit

/// 悬浮式播放控制面板（包含第1行核心播放控制与第2行四种播放模式、复读/跟读状态 + 变速）
public struct FloatingVideoOSDView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var lang = LanguageManager.shared
    @Binding var isScrubbing: Bool
    
    private let speedPresets: [Float] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0]
    
    public init(
        engine: PlaybackEngine,
        isScrubbing: Binding<Bool>
    ) {
        self.engine = engine
        self._isScrubbing = isScrubbing
    }
    
    public var body: some View {
        VStack(spacing: 5) {
            // 第 1 行：核心播放控制与时间轴
            HStack(spacing: 8) {
                // 1. 重播当前句
                Button(action: { engine.repeatCurrentSegment() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(lang.localized(.repeatSentence))
                
                // 2. 上一句
                Button(action: { engine.previousSegment() }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(lang.localized(.previousSentence))
                
                // 3. 播放 / 暂停 大按钮
                Button(action: { engine.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 28, height: 28)
                            .shadow(color: Color.accentColor.opacity(0.28), radius: 3, x: 0, y: 1)
                        
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .help(engine.isPlaying ? lang.localized(.pause) : lang.localized(.play))
                
                // 4. 下一句
                Button(action: { engine.nextSegment() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(lang.localized(.nextSentence))
                
                // 5. 播放时间
                Text(SentenceSegment.formatTimecode(isScrubbing ? engine.clock.currentTime : engine.currentTime))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(.primary)
                    .frame(minWidth: 56, alignment: .trailing)
                
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
                .frame(minWidth: 120)
                
                // 7. 总时间
                Text(SentenceSegment.formatTimecode(engine.duration))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(minWidth: 56, alignment: .leading)
                
                // 分隔小竖线
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)
                
                // 8. 音量调节
                HStack(spacing: 4) {
                    Button(action: {
                        engine.volume = engine.volume > 0 ? 0 : 1.0
                    }) {
                        Image(systemName: engine.volume == 0 ? "speaker.slash.fill" : (engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                            .font(.system(size: 10.5, weight: .medium))
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
                    .frame(width: 55)
                }
                .padding(.trailing, 2)
            }
            
            // 第 2 行：左侧 4 种播放模式与状态指示（左对齐），右侧变速控制（右对齐）
            HStack(spacing: 6) {
                // 四种播放模式按钮 (左对齐)
                ForEach(PlaybackLoopMode.allCases) { mode in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            engine.loopMode = mode
                        }
                    }) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(engine.loopMode == mode ? .accentColor : .primary)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(engine.loopMode == mode ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(mode.localized(with: lang))
                }
                
                // 单句复读次数显示标签
                if engine.repeatCountLimit > 1 || engine.repeatCountLimit == 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "repeat")
                            .font(.system(size: 8.5))
                        Text(engine.repeatCountLimit == 0 ? "[\(engine.currentRepeatCount)/∞]" : "[\(engine.currentRepeatCount)/\(engine.repeatCountLimit)]")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(4)
                }
                
                // 句末开口跟读倒计时指示
                if engine.isShadowingPaused {
                    HStack(spacing: 3) {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 9))
                        Text(String(
                            format: lang.text("跟读中 %.1f 秒", "Shadowing %.1fs"),
                            engine.shadowingCountdownRemaining
                        ))
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
                }
                
                // 难句专练状态指示
                if engine.onlyPlayBookmarked {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8.5))
                        Text(lang.text("难句专练", "Bookmarks"))
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2.5)
                    .background(Color.yellow.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
                }
                
                Spacer()
                
                // 变速控制（右对齐，与上一行右侧对齐）
                HStack(spacing: 5) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Menu {
                        ForEach(speedPresets, id: \.self) { speed in
                            Button(action: { engine.playbackRate = speed }) {
                                if engine.playbackRate == speed {
                                    Label(String(format: "%.2fx", speed), systemImage: "checkmark")
                                } else {
                                    Text(String(format: "%.2fx", speed))
                                }
                            }
                        }
                    } label: {
                        Text(String(format: "%.2fx", engine.playbackRate))
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .frame(width: 46)
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.mini)
                    
                    Slider(
                        value: Binding(
                            get: { Double(engine.playbackRate) },
                            set: { engine.playbackRate = Float($0) }
                        ),
                        in: 0.5...2.0,
                        step: 0.05
                    )
                    .frame(width: 70)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 4)
        .frame(maxWidth: 720)
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
