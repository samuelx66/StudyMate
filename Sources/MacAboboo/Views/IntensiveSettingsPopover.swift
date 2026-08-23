import SwiftUI

/// 专业精听与复读设置浮窗面板
public struct IntensiveSettingsPopover: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    @ObservedObject var modelManager = WhisperModelManager.shared

    private var repeatOptions: [(label: String, count: Int)] {
        [(lang.text("1次", "1×"), 1), (lang.text("2次", "2×"), 2),
         (lang.text("3次", "3×"), 3), (lang.text("5次", "5×"), 5),
         (lang.text("10次", "10×"), 10), (lang.text("无限", "∞"), 0)]
    }

    public init(engine: PlaybackEngine) {
        self.engine = engine
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // 顶部标题
                HStack {
                    Label(lang.text("精听与播放参数设置", "Listening & Playback Settings"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                }

                Divider()

                // 1. 定次复读控制
                VStack(alignment: .leading, spacing: 6) {
                    Label(lang.text("单句复读次数（定次复读）", "Sentence Repeat Count"), systemImage: "repeat.1")
                        .font(.caption.bold())

                    HStack(spacing: 5) {
                        ForEach(repeatOptions, id: \.count) { opt in
                            Button(action: {
                                engine.repeatCountLimit = opt.count
                                engine.currentRepeatCount = 1
                            }) {
                                Text(opt.label)
                                    .font(.caption2.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 3)
                                    .background(engine.repeatCountLimit == opt.count ? Color.blue : Color.gray.opacity(0.15))
                                    .foregroundColor(engine.repeatCountLimit == opt.count ? .white : .primary)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                // 2. 跟读停顿模式 (Shadowing Pause)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(lang.text("句末跟读停顿", "Shadowing Pause"), systemImage: "mic.badge.plus")
                            .font(.caption.bold())

                        Spacer()

                        Text(engine.shadowingPauseRatio == 0
                            ? lang.text("已关闭", "Off")
                            : String(format: lang.text("%.1fx 时长", "%.1fx duration"), engine.shadowingPauseRatio))
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundColor(engine.shadowingPauseRatio == 0 ? .secondary : .green)
                    }

                    Slider(value: $engine.shadowingPauseRatio, in: 0...2.0, step: 0.25)
                        .accentColor(.green)

                    Text(lang.text(
                        "每句播完后自动静音停顿对应倍率时长，留出开口跟读时间后自动继续",
                        "After each sentence, pause for the selected duration so you can speak, then continue automatically."
                    ))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // 3. 难句专练模式
                Toggle(isOn: $engine.onlyPlayBookmarked) {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                        Text(lang.text("仅复读星标难句模式", "Practice bookmarked sentences only"))
                            .font(.caption.bold())
                    }
                }
                .toggleStyle(.switch)

                Divider()

                // 4. 时间轴批量平移校准
                VStack(alignment: .leading, spacing: 6) {
                    Label(lang.text("时间轴批量平移（校准字幕提前/滞后）", "Shift Timeline (Subtitle Sync)"), systemImage: "clock.arrow.2.circlepath")
                        .font(.caption.bold())

                    HStack(spacing: 4) {
                        Button("-1.0s") { engine.shiftAllTimeline(by: -1.0) }
                            .controlSize(.mini)
                        Button("-500ms") { engine.shiftAllTimeline(by: -0.5) }
                            .controlSize(.mini)
                        Button("-100ms") { engine.shiftAllTimeline(by: -0.1) }
                            .controlSize(.mini)

                        Spacer()

                        Button("+100ms") { engine.shiftAllTimeline(by: 0.1) }
                            .controlSize(.mini)
                        Button("+500ms") { engine.shiftAllTimeline(by: 0.5) }
                            .controlSize(.mini)
                        Button("+1.0s") { engine.shiftAllTimeline(by: 1.0) }
                            .controlSize(.mini)
                    }
                }

                Divider()

                // 5. 解码引擎切换
                VStack(alignment: .leading, spacing: 6) {
                    Label(lang.localized(.decoderEngine), systemImage: "cpu")
                        .font(.caption.bold())

                    Picker("", selection: Binding(
                        get: { engine.decoderMode },
                        set: { engine.setDecoderMode($0) }
                    )) {
                        Text(lang.text("系统解码", "System")).tag(DecoderEngineMode.system)
                        Text(lang.text("扩展解码", "Extended")).tag(DecoderEngineMode.mpv)
                        Text(lang.text("智能混合", "Hybrid")).tag(DecoderEngineMode.hybrid)
                    }
                    .pickerStyle(.segmented)

                    Text(decoderDescription)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // 6. AI 语音识别与 Whisper 模型管理
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(lang.text("Whisper AI 离线模型", "Whisper AI Offline Model"), systemImage: "waveform.badge.magnifyingglass")
                            .font(.caption.bold())
                        Spacer()
                    }

                    // 模型级别切换器
                    Picker("", selection: $modelManager.selectedModelLevel) {
                        ForEach(WhisperModelLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    // 模型描述与大小
                    Text(modelManager.selectedModelLevel.description)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 当前模型下载与存储状态
                    let currentLevel = modelManager.selectedModelLevel
                    let status = modelManager.modelStatuses[currentLevel] ?? .notDownloaded

                    HStack(spacing: 8) {
                        switch status {
                        case .notDownloaded:
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.blue)
                                Text(lang.text("未下载（约 \(currentLevel.approximateSize)）", "Not Downloaded (\(currentLevel.approximateSize))"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button(action: {
                                modelManager.startDownload(for: currentLevel)
                            }) {
                                Text(lang.text("下载模型", "Download"))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)

                        case .downloading(let progress):
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(lang.text("正在下载...", "Downloading..."))
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2.monospacedDigit().bold())
                                        .foregroundColor(.blue)
                                }
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                            }

                            Button(action: {
                                modelManager.cancelDownload(for: currentLevel)
                            }) {
                                Text(lang.text("取消", "Cancel"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)

                        case .ready(let fileSize):
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(lang.text("已就绪 (\(fileSize))", "Ready (\(fileSize))"))
                                    .font(.caption2.bold())
                                    .foregroundColor(.green)
                            }

                            Spacer()

                            Button(action: {
                                modelManager.deleteModel(for: currentLevel)
                            }) {
                                Text(lang.text("删除模型", "Delete"))
                                    .font(.caption2)
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)

                        case .error(let msg):
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(msg)
                                    .font(.system(size: 9))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button(action: {
                                modelManager.startDownload(for: currentLevel)
                            }) {
                                Text(lang.text("重试", "Retry"))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)

                    Divider()
                        .padding(.vertical, 2)

                    HStack {
                        Text(lang.text("识别语言", "Recognition Language"))
                            .font(.caption.bold())
                        Spacer()
                        Picker("", selection: $engine.speechRecognitionLanguage) {
                            Text(lang.text("自动检测", "Auto Detect")).tag("auto")
                            Text(lang.text("中文", "Chinese")).tag("zh")
                            Text(lang.text("英语", "English")).tag("en")
                            Text(lang.text("日语", "Japanese")).tag("ja")
                            Text(lang.text("韩语", "Korean")).tag("ko")
                        }
                        .labelsHidden()
                        .frame(width: 125)
                    }

                    HStack {
                        Text(lang.text("已知说话人数", "Known Speaker Count"))
                            .font(.caption.bold())
                        Spacer()
                        Picker("", selection: $engine.expectedSpeakerCount) {
                            Text(lang.text("自动", "Auto")).tag(nil as Int?)
                            ForEach(2...8, id: \.self) { count in
                                Text("\(count)").tag(Optional(count))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }

                    HStack {
                        Text(lang.text("句子长度", "Sentence Length"))
                            .font(.caption.bold())
                        Spacer()
                        Picker("", selection: $engine.segmentationSentenceLength) {
                            Text(lang.text("短句", "Short")).tag(SpeechSentenceLength.short)
                            Text(lang.text("标准", "Standard")).tag(SpeechSentenceLength.standard)
                            Text(lang.text("长句", "Long")).tag(SpeechSentenceLength.long)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    Text(lang.text(
                        "已知人数可减少嘈杂多人录音中的错误聚类；句子长度主要影响高精度和快速预设。",
                        "A known speaker count reduces clustering errors; sentence length mainly affects the high-precision and fast presets."
                    ))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                    // 该开关只控制识别文本是否写入字幕；AI 模式仍使用语义信息优化时间轴。
                    Toggle(isOn: $engine.autoGenerateSubtitles) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.text("保存 AI 识别原文字幕", "Save AI transcript as subtitles"))
                                .font(.caption.bold())
                            Text(lang.text(
                                "关闭后不保存识别文字，但高精度和纯语义预设仍会用 Whisper 优化边界；快速预设不运行 Whisper。",
                                "When off, text is not saved, but high-precision and semantic presets still use Whisper for boundaries; the fast preset skips Whisper."
                            ))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(14)
        }
        .frame(width: 360)
        .frame(maxHeight: 560)
    }

    private var decoderDescription: String {
        switch engine.decoderMode {
        case .system:
            return lang.text("使用系统原生硬件解码，适合标准 MP4、MOV、MP3、M4A。", "Uses native system decoding for standard MP4, MOV, MP3, and M4A media.")
        case .mpv:
            return lang.text("使用 libmpv 扩展格式解码，适合 MKV、WebM、AVI、TS、FLV、WMV。", "Uses libmpv for formats such as MKV, WebM, AVI, TS, FLV, and WMV.")
        case .hybrid:
            return lang.text("优先使用系统解码；遇到不支持的格式时自动切换到 libmpv。", "Prefers native decoding and automatically falls back to libmpv for unsupported formats.")
        }
    }
}

#Preview("精听复读参数设置") {
    IntensiveSettingsPopover(engine: PlaybackEngine.shared)
        .padding()
}
