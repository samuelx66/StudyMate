import SwiftUI
import AppKit

/// 底部播放与精听复读控制栏
public struct PlaybackControlView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    
    // 快捷倍速预设
    private let speedPresets: [Float] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0]
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // 上层：高精度时间轴滑块与时间码 + 跟读提示
            PlaybackTimelineControl(
                clock: engine.clock,
                duration: engine.duration,
                onSeek: { engine.seek(to: $0) }
            )
            
            // 下层：主要控制按钮区
            HStack(spacing: 14) {
                // 1. 复读模式选择器
                Menu {
                    ForEach(PlaybackLoopMode.allCases) { mode in
                        Button(action: { engine.loopMode = mode }) {
                            Label(mode.localized(with: lang), systemImage: mode.iconName)
                        }
                    }
                } label: {
                    Label(engine.loopMode.localized(with: lang), systemImage: engine.loopMode.iconName)
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                
                // 2. 定次复读与跟读状态标签
                if engine.repeatCountLimit > 1 || engine.repeatCountLimit == 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "repeat")
                            .font(.system(size: 9))
                        Text(engine.repeatCountLimit == 0 ? "[\(engine.currentRepeatCount)/∞]" : "[\(engine.currentRepeatCount)/\(engine.repeatCountLimit)]")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(4)
                }
                
                // 句末开口跟读倒计时指示
                if engine.isShadowingPaused {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 10))
                        Text(String(
                            format: lang.text("跟读中 %.1f 秒", "Shadowing %.1fs"),
                            engine.shadowingCountdownRemaining
                        ))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
                }
                
                if engine.onlyPlayBookmarked {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                        Text(lang.text("难句专练", "Bookmarks"))
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
                }
                
                Divider().frame(height: 20)
                
                // 3. 核心导航与播放按钮
                HStack(spacing: 14) {
                    // 上一句
                    Button(action: { engine.previousSegment() }) {
                        Image(systemName: "backward.end.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(lang.localized(.previousSentence))
                    
                    // 播放 / 暂停 大按钮
                    Button(action: { engine.togglePlayPause() }) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 44, height: 44)
                                .shadow(color: Color.blue.opacity(0.4), radius: 6)
                            
                            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(engine.isPlaying ? lang.localized(.pause) : lang.localized(.play))
                    
                    // 下一句
                    Button(action: { engine.nextSegment() }) {
                        Image(systemName: "forward.end.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(lang.localized(.nextSentence))
                    
                    // 重复当前句
                    Button(action: { engine.repeatCurrentSegment() }) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(lang.localized(.repeatSentence))
                }
                
                Spacer()
                
                // 4. 变速不变调调节区 (0.5x ~ 2.0x)
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.caption)
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
                            .font(.caption.monospacedDigit().bold())
                            .frame(width: 48)
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    
                    Slider(
                        value: Binding(
                            get: { Double(engine.playbackRate) },
                            set: { engine.playbackRate = Float($0) }
                        ),
                        in: 0.5...2.0,
                        step: 0.05
                    )
                    .frame(width: 65)
                }
                
                Divider().frame(height: 20)
                
                // 6. 音量控制
                HStack(spacing: 4) {
                    Button(action: {
                        engine.volume = engine.volume > 0 ? 0 : 1.0
                    }) {
                        Image(systemName: engine.volume == 0 ? "speaker.slash.fill" : (engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                            .font(.caption)
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
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(nsColor: .separatorColor)),
            alignment: .top
        )
    }
}

/// 将高频时间轴更新限制在进度条自身，避免整排菜单、按钮和弹窗每帧重算。
private struct PlaybackTimelineControl: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubTime = 0.0

    var body: some View {
        HStack(spacing: 12) {
            let displayTime = isScrubbing ? scrubTime : clock.currentTime
            Text(SentenceSegment.formatTimecode(displayTime))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(.blue)
                .frame(width: 80, alignment: .leading)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : min(clock.currentTime, max(0.1, duration)) },
                    set: { newTime in
                        scrubTime = newTime
                        if !isScrubbing { onSeek(newTime) }
                    }
                ),
                in: 0...max(0.1, duration),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubTime = min(clock.currentTime, max(0.1, duration))
                    } else {
                        onSeek(scrubTime)
                    }
                }
            )
            .accentColor(.blue)

            Text(SentenceSegment.formatTimecode(duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

#Preview("播放控制栏") {
    PlaybackControlView(engine: PlaybackEngine.shared)
        .frame(width: 800)
}
