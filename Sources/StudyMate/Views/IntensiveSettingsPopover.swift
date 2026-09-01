import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case playback
    case segmentation
    case translation
    case decoder

    var id: String { rawValue }
}

/// 专业精听与复读设置独立窗口内容。
///
/// 设置采用 macOS 原生的左侧分类导航，右侧只显示当前分类的内容。
/// 各分类仍直接绑定现有设置对象；翻译页额外提供可管理服务配置，翻译执行
/// 改为由用户从断句列表明确确认后启动。
public struct IntensiveSettingsPopover: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    @ObservedObject var modelManager = WhisperModelManager.shared
    @ObservedObject var translationSettings = TranslationSettings.shared

    @AppStorage("StudyMate.ShowStatusBar") private var isStatusBarVisible = false
    @State private var selectedSection: SettingsSection = .general
    @State private var translationAPIKey = ""
    @State private var showAddTranslationService = false
    @State private var serviceToDelete: TranslationServiceProfile?
    @State private var showDeleteConfirmation = false

    public init(engine: PlaybackEngine) {
        self.engine = engine
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sectionTitle(section))
                                    .font(.body)
                                Text(sectionSubtitle(section))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: sectionIcon(section))
                                .frame(width: 20)
                        }
                        .tag(section)
                        .padding(.vertical, 3)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(lang.text("设置", "Settings"))
            .navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 270)
        } detail: {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sectionTitle(selectedSection))
                            .font(.system(size: 22, weight: .bold))
                        Text(sectionDescription(selectedSection))
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    settingsContent(for: selectedSection)
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(sectionTitle(selectedSection))
        }
        .frame(minWidth: 880, idealWidth: 960, minHeight: 640, idealHeight: 720)
        .onAppear {
            translationAPIKey = translationSettings.apiKey()
        }
        .onChange(of: translationSettings.selectedServiceID) { _, _ in
            translationAPIKey = translationSettings.apiKey()
        }
        .onChange(of: translationAPIKey) { _, value in
            translationSettings.setAPIKey(value)
        }
        .onChange(of: translationSettings.isAutomaticTranslationEnabled) { _, enabled in
            if !enabled {
                engine.cancelAutomaticTranslation()
            }
        }
        }

    @ViewBuilder
    private func settingsContent(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            generalSettings
        case .playback:
            playbackSettings
        case .segmentation:
            segmentationSettings
        case .translation:
            translationSettingsView
        case .decoder:
            decoderSettings
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroupTitle(
                lang.text("界面语言", "App Language"),
                systemImage: "globe"
            )

            Picker("", selection: $lang.currentLanguage) {
                ForEach(AppLanguage.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            settingsGroupTitle(
                lang.text("界面显示", "Interface Display"),
                systemImage: "rectangle.3.group"
            )

            Toggle(isOn: $isStatusBarVisible) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang.text("显示状态栏", "Show Status Bar"))
                        .font(.body.weight(.medium))
                    Text(lang.text(
                        "在主窗口底部显示当前句、复读次数、播放模式和跟读倒计时。也可以通过“显示”菜单快速切换。",
                        "Shows the current sentence, repeat count, playback mode, and shadowing countdown at the bottom of the main window. It can also be toggled from the View menu."
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            settingsNote(lang.text(
                "播放列表、断句列表、波形图和字幕编辑区仍通过主窗口工具栏控制，不在这里重复设置。",
                "The playlist, sentence list, waveforms, and subtitle editor remain controlled from the main toolbar rather than duplicated here."
            ))
        }
    }

    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroupTitle(
                lang.text("练习模式", "Practice Mode"),
                systemImage: "star.fill"
            )

            Toggle(isOn: $engine.onlyPlayBookmarked) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang.text("仅复读星标难句模式", "Practice bookmarked sentences only"))
                        .font(.body.weight(.medium))
                    Text(lang.text(
                        "开启后，播放和复读导航会优先使用已标记为难句的内容。",
                        "When enabled, playback and repeat navigation prioritize sentences marked as difficult."
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            settingsGroupTitle(
                lang.text("即时播放控制", "Immediate Playback Controls"),
                systemImage: "play.circle"
            )

            settingsNote(lang.text(
                "播放模式、播放倍速、单句复读次数和句末跟读停顿属于播放过程中的即时控制，统一放在主窗口工具栏中。",
                "Playback mode, speed, repeat count, and the pause after a sentence are immediate controls kept in the main toolbar."
            ))
        }
    }

    private var segmentationSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroupTitle(
                lang.text("时间轴校准", "Timeline Calibration"),
                systemImage: "clock.arrow.2.circlepath"
            )

            Text(lang.text(
                "整体调整所有断句的起止时间，用于校准字幕整体提前或滞后的情况。",
                "Shift every sentence together when the imported subtitles are consistently early or late."
            ))
            .font(.caption)
            .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Button("-1.0s") { engine.shiftAllTimeline(by: -1.0) }
                    .controlSize(.small)
                Button("-500ms") { engine.shiftAllTimeline(by: -0.5) }
                    .controlSize(.small)
                Button("-100ms") { engine.shiftAllTimeline(by: -0.1) }
                    .controlSize(.small)

                Spacer()

                Button("+100ms") { engine.shiftAllTimeline(by: 0.1) }
                    .controlSize(.small)
                Button("+500ms") { engine.shiftAllTimeline(by: 0.5) }
                    .controlSize(.small)
                Button("+1.0s") { engine.shiftAllTimeline(by: 1.0) }
                    .controlSize(.small)
            }

            Divider()

            settingsGroupTitle(
                lang.text("字幕生成", "Subtitle Generation"),
                systemImage: "captions.bubble"
            )

            Toggle(isOn: $engine.autoGenerateSubtitles) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang.text("保存 AI 识别原文字幕", "Save AI transcript as subtitles"))
                        .font(.body.weight(.medium))
                    Text(lang.text(
                        "关闭后不会自动生成原文。快速断句也不会生成原文，智能断句则会生成原文并保存。",
                        "When disabled, original text is not generated automatically. Fast segmentation also does not generate original text; intelligent segmentation generates and saves it."
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            settingsGroupTitle(
                lang.text("Whisper 离线模型", "Whisper Offline Model"),
                systemImage: "waveform.badge.magnifyingglass"
            )

            Picker("", selection: $modelManager.selectedModelLevel) {
                ForEach(WhisperModelLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)

            Text(modelManager.selectedModelLevel.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            whisperModelStatus

            Divider()

            settingsGroupTitle(
                lang.text("识别参数", "Recognition Parameters"),
                systemImage: "person.wave.2"
            )

            HStack {
                Text(lang.text("识别语言", "Recognition Language"))
                    .font(.body.weight(.medium))
                Spacer()
                Picker("", selection: $engine.speechRecognitionLanguage) {
                    Text(lang.text("自动检测", "Auto Detect")).tag("auto")
                    Text(lang.text("中文", "Chinese")).tag("zh")
                    Text(lang.text("英语", "English")).tag("en")
                    Text(lang.text("日语", "Japanese")).tag("ja")
                    Text(lang.text("韩语", "Korean")).tag("ko")
                }
                .labelsHidden()
                .frame(width: 140)
            }

            HStack {
                Text(lang.text("已知说话人数", "Known Speaker Count"))
                    .font(.body.weight(.medium))
                Spacer()
                Picker("", selection: $engine.expectedSpeakerCount) {
                    Text(lang.text("自动", "Auto")).tag(nil as Int?)
                    ForEach(2...8, id: \.self) { count in
                        Text("\(count)").tag(Optional(count))
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            settingsNote(lang.text(
                "已知人数可减少嘈杂多人录音中的错误聚类；智能断句会自动分析语速、停顿、语义和说话人变化。",
                "A known speaker count reduces clustering errors; intelligent segmentation analyzes speech rate, pauses, semantics, and speaker changes automatically."
            ))
        }
    }

    @ViewBuilder
    private var whisperModelStatus: some View {
        let currentLevel = modelManager.selectedModelLevel
        let status = modelManager.modelStatuses[currentLevel] ?? .notDownloaded

        HStack(spacing: 10) {
            switch status {
            case .notDownloaded:
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(StudyMateMediaStyle.informational)
                    Text(lang.text(
                        "未下载（约 \(currentLevel.approximateSize)）",
                        "Not downloaded (about \(currentLevel.approximateSize))"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    modelManager.startDownload(for: currentLevel)
                } label: {
                    Text(lang.text("下载模型", "Download model"))
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(lang.text("正在下载…", "Downloading…"))
                            .font(.caption)
                            .foregroundStyle(StudyMateMediaStyle.informational)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(StudyMateMediaStyle.informational)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }

                Button(lang.text("取消", "Cancel")) {
                    modelManager.cancelDownload(for: currentLevel)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

            case .ready(let fileSize):
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StudyMateMediaStyle.success)
                    Text(lang.text("已就绪（\(fileSize)）", "Ready (\(fileSize))"))
                        .font(.caption.bold())
                        .foregroundStyle(StudyMateMediaStyle.success)
                }

                Spacer()

                Button(lang.text("删除模型", "Delete model")) {
                    modelManager.deleteModel(for: currentLevel)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(StudyMateMediaStyle.destructive.opacity(0.85))
                .controlSize(.small)

            case .error(let message):
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StudyMateMediaStyle.destructive)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(StudyMateMediaStyle.destructive)
                        .lineLimit(2)
                }

                Spacer()

                Button(lang.text("重试", "Retry")) {
                    modelManager.startDownload(for: currentLevel)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var translationSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroupTitle(
                lang.text("翻译功能", "Translation"),
                systemImage: "translate"
            )

            Toggle(isOn: $translationSettings.isAutomaticTranslationEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang.text("启用翻译功能（手动执行）", "Enable translation (manual)"))
                        .font(.body.weight(.medium))
                    Text(lang.text(
                        "开启后，断句、导入字幕和打开工程都不会自动发起翻译。请在断句列表点击“翻译”，选择服务、模型和目标语言后确认执行。",
                        "Enabling this does not start translation after segmentation, subtitle import, or project restore. Click Translate in the sentence list, choose a service, model, and target language, then confirm."
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            Divider()

            HStack {
                settingsGroupTitle(
                    lang.text("翻译服务", "Translation Services"),
                    systemImage: "server.rack"
                )
                Spacer()
                Button {
                    showAddTranslationService = true
                } label: {
                    Label(lang.text("添加自定义模型", "Add Custom Model"), systemImage: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    serviceToDelete = translationSettings.selectedService
                    showDeleteConfirmation = serviceToDelete?.isBuiltIn == false
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .foregroundStyle(StudyMateMediaStyle.destructive)
                .disabled(translationSettings.selectedService?.isBuiltIn != false)
                .help(lang.text("删除当前自定义模型", "Delete the selected custom model"))
            }

            HStack(alignment: .top, spacing: 14) {
                List(selection: $translationSettings.selectedServiceID) {
                    ForEach(translationSettings.services) { service in
                        HStack(spacing: 8) {
                            Image(systemName: service.isBuiltIn ? "lock.fill" : "line.3.horizontal")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .lineLimit(1)
                                Text(service.provider.displayName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                            if translationSettings.hasAPIKey(for: service.id) {
                                Image(systemName: "key.fill")
                                    .font(.caption2)
                                    .foregroundStyle(StudyMateMediaStyle.success)
                            }
                        }
                        .tag(service.id)
                    }
                    .onMove(perform: translationSettings.moveServices)
                }
                .listStyle(.bordered)
                .frame(minWidth: 245, idealWidth: 275, minHeight: 210, maxHeight: 300)

                Divider()

                if let service = translationSettings.selectedService {
                    translationServiceEditor(service)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text(lang.text("还没有翻译服务", "No translation service"))
                            .font(.body.weight(.medium))
                        Text(lang.text("点击“添加”创建一个服务配置。", "Click Add to create a service configuration."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                }
            }

            settingsNote(lang.text(
                "DeepSeek 和 Gemini 是内置模型，只需填写 API Key 并点击“测试”。自定义模型可选择 OpenAI 或 Anthropic 协议，测试成功后从服务端返回的模型列表中选择。API Key 只保存在本机钥匙串。",
                "DeepSeek and Gemini are built in; enter an API key and click Test. Custom models use either OpenAI or Anthropic, and successful tests return a selectable model list. API keys stay in the local Keychain."
            ))

        }
        .sheet(isPresented: $showAddTranslationService) {
            TranslationServiceAddSheet(settings: translationSettings, lang: lang)
        }
        .confirmationDialog(
            lang.text("删除翻译服务？", "Delete translation service?"),
            isPresented: $showDeleteConfirmation
        ) {
            if let service = serviceToDelete {
                Button(lang.text("删除“\(service.name)”", "Delete “\(service.name)”"), role: .destructive) {
                    translationSettings.removeService(id: service.id)
                    translationAPIKey = translationSettings.apiKey()
                    serviceToDelete = nil
                }
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(lang.text(
                "删除后将同时移除该服务配置对应的钥匙串 API Key。",
                "The API key stored for this service will also be removed."
            ))
        }
    }

    private func translationServiceEditor(_ service: TranslationServiceProfile) -> some View {
        let currentProvider = translationSettings.selectedService?.provider ?? service.provider
        let isBuiltIn = service.isBuiltIn
        return VStack(alignment: .leading, spacing: 12) {
            Text(lang.text("服务字段", "Service Fields"))
                .font(.headline)

            HStack(spacing: 10) {
                Text(lang.text("模型名称", "Model Name"))
                    .font(.body.weight(.medium))
                    .frame(width: 78, alignment: .leading)
                if isBuiltIn {
                    Text(service.name)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(
                        lang.text("例如：我的翻译模型", "e.g. My Translation Model"),
                        text: Binding(
                            get: { translationSettings.selectedService?.name ?? service.name },
                            set: { translationSettings.updateService(id: service.id, name: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 10) {
                Text(lang.text("接口协议", "Protocol"))
                    .font(.body.weight(.medium))
                    .frame(width: 78, alignment: .leading)
                if isBuiltIn {
                    Text(currentProvider.displayName)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("", selection: Binding(
                        get: { translationSettings.selectedService?.provider ?? service.provider },
                        set: { translationSettings.updateService(id: service.id, provider: $0) }
                    )) {
                        ForEach(TranslationProviderID.customProtocolCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 10) {
                Text(lang.text("模型", "Model"))
                    .font(.body.weight(.medium))
                    .frame(width: 78, alignment: .leading)
                let currentModel = translationSettings.selectedService?.model ?? service.model
                if isBuiltIn {
                    Text(currentModel)
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(
                        currentProvider.defaultModel,
                        text: Binding(
                            get: { translationSettings.selectedService?.model ?? service.model },
                            set: { translationSettings.updateService(id: service.id, model: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                let models = translationSettings.availableModels(for: service.id)
                if !models.isEmpty {
                    Menu {
                        ForEach(models) { model in
                            Button {
                                translationSettings.updateService(id: service.id, model: model.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(model.displayName)
                                    if model.displayName != model.id {
                                        Text(model.id).font(.caption)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("\(models.count)", systemImage: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .help(lang.text("选择服务端返回的可用模型", "Choose a model returned by the server"))
                }
            }

            if !isBuiltIn {
                HStack(spacing: 10) {
                    Text(lang.text("Base URL", "Base URL"))
                        .font(.body.weight(.medium))
                        .frame(width: 78, alignment: .leading)
                    TextField(
                        currentProvider.defaultServerURL,
                        text: Binding(
                            get: { translationSettings.selectedService?.serverURL ?? service.serverURL },
                            set: { translationSettings.updateService(id: service.id, serverURL: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 10) {
                Text("API Key")
                    .font(.body.weight(.medium))
                    .frame(width: 78, alignment: .leading)
                SecureField(
                    lang.text("输入 API Key（存入钥匙串）", "Enter API Key (stored in Keychain)"),
                    text: $translationAPIKey
                )
                .textFieldStyle(.roundedBorder)

                if translationSettings.hasAPIKey(for: service.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StudyMateMediaStyle.success)
                        .help(lang.text("已保存到钥匙串", "Saved in Keychain"))

                    Button {
                        translationAPIKey = ""
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help(lang.text("清除 API Key", "Clear API Key"))
                }

                Button {
                    translationSettings.setAPIKey(translationAPIKey, for: service.id)
                    translationSettings.refreshModels(for: service.id)
                } label: {
                    Label(lang.text("测试", "Test"), systemImage: "checkmark.seal")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(
                    translationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || translationSettings.modelFetchState(for: service.id) == .loading
                )
                .help(lang.text("连接服务并读取可用模型", "Test the connection and load available models"))
            }

            modelFetchStatus(for: service.id)

            settingsNote(lang.text(
                isBuiltIn
                    ? "这是内置服务，只需填写 API Key，点击“测试”读取可用模型，然后在“模型”右侧的列表中选择。"
                    : "自定义模型只保存模型名称、协议、Base URL 和 API Key；点击“测试”读取可用模型，选择结果后会自动保存上次使用的模型。",
                isBuiltIn
                    ? "This built-in service only needs an API key. Click Test to load models, then choose one from the model list."
                    : "A custom model stores its name, protocol, Base URL, and API key. Click Test to load models; your last selected model is saved automatically."
            ))
        }
    }

    @ViewBuilder
    private func modelFetchStatus(for serviceID: UUID) -> some View {
        switch translationSettings.modelFetchState(for: serviceID) {
        case .idle:
            EmptyView()
        case .loading:
            Label(lang.text("正在连接并读取模型列表…", "Connecting and loading models…"), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundColor(.secondary)
        case let .loaded(count):
            Label(lang.text("已读取 \(count) 个可用模型", "Loaded \(count) available models"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                        .foregroundStyle(StudyMateMediaStyle.success)
        case let .failed(message):
            Label(lang.text("模型列表读取失败：\(message)", "Could not load models: \(message)"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(StudyMateMediaStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var decoderSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroupTitle(
                lang.text("音视频解码引擎", "Audio and Video Decoder"),
                systemImage: "cpu"
            )

            Picker("", selection: Binding(
                get: { engine.decoderMode },
                set: { engine.setDecoderMode($0) }
            )) {
                Text(lang.text("系统解码", "System")).tag(DecoderEngineMode.system)
                Text(lang.text("扩展解码", "Extended")).tag(DecoderEngineMode.mpv)
                Text(lang.text("智能混合（推荐）", "Hybrid (Recommended)")).tag(DecoderEngineMode.hybrid)
            }
            .pickerStyle(.segmented)

            Text(decoderDescription)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            settingsNote(lang.text(
                "智能混合会优先使用系统解码，遇到格式不兼容或定位失败时自动回退到扩展解码。",
                "Hybrid mode prefers native decoding and falls back to extended decoding when the format is unsupported or seeking fails."
            ))
        }
    }

    private func settingsGroupTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func settingsNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionTitle(_ section: SettingsSection) -> String {
        switch section {
        case .general:
            return lang.text("通用与界面", "General & Interface")
        case .playback:
            return lang.text("播放与练习", "Playback & Practice")
        case .segmentation:
            return lang.text("断句与字幕", "Segmentation & Subtitles")
        case .translation:
            return lang.text("翻译服务", "Translation Services")
        case .decoder:
            return lang.text("音视频解码", "Audio & Video Decoding")
        }
    }

    private func sectionSubtitle(_ section: SettingsSection) -> String {
        switch section {
        case .general:
            return lang.text("语言和显示", "Language and display")
        case .playback:
            return lang.text("复读练习", "Repeat practice")
        case .segmentation:
            return lang.text("时间轴、字幕和 AI 识别", "Timeline, subtitles, and AI recognition")
        case .translation:
            return lang.text("模型与 API Key", "Models and API keys")
        case .decoder:
            return lang.text("播放引擎", "Playback engine")
        }
    }

    private func sectionDescription(_ section: SettingsSection) -> String {
        switch section {
        case .general:
            return lang.text("配置应用语言和主窗口的基础显示方式。", "Configure the app language and basic main-window display options.")
        case .playback:
            return lang.text("配置精听练习时的默认筛选行为；播放过程中的即时控制仍在工具栏。", "Configure intensive-practice behavior; immediate playback controls remain in the toolbar.")
        case .segmentation:
            return lang.text("管理断句时间轴、字幕保存、Whisper 模型、识别语言和多人对话参数。", "Manage sentence timing, subtitle saving, the Whisper model, recognition language, and dialogue parameters.")
        case .translation:
            return lang.text("管理可复用的翻译服务配置，并在句子列表中手动确认后执行翻译。", "Manage reusable translation profiles and start translation manually after confirmation in the sentence list.")
        case .decoder:
            return lang.text("选择系统、扩展或智能混合音视频解码引擎。", "Choose the native, extended, or hybrid audio/video decoder.")
        }
    }

    private func sectionIcon(_ section: SettingsSection) -> String {
        switch section {
        case .general:
            return "gearshape"
        case .playback:
            return "play.circle"
        case .segmentation:
            return "waveform.path.ecg"
        case .translation:
            return "translate"
        case .decoder:
            return "cpu"
        }
    }

    private var decoderDescription: String {
        switch engine.decoderMode {
        case .system:
            return lang.text(
                "使用系统原生硬件解码，适合标准 MP4、MOV、MP3、M4A。",
                "Uses native system decoding for standard MP4, MOV, MP3, and M4A media."
            )
        case .mpv:
            return lang.text(
                "使用 libmpv 扩展格式解码，适合 MKV、WebM、AVI、TS、FLV、WMV。",
                "Uses libmpv for formats such as MKV, WebM, AVI, TS, FLV, and WMV."
            )
        case .hybrid:
            return lang.text(
                "优先使用系统解码；遇到不支持的格式时自动切换到 libmpv。",
                "Prefers native decoding and automatically falls back to libmpv for unsupported formats."
            )
        }
    }
}

private struct TranslationServiceAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var lang: LanguageManager

    @State private var modelName = ""
    @State private var protocolID: TranslationProviderID = .openAICompatible
    @State private var baseURL = TranslationProviderID.openAICompatible.defaultServerURL
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.text("添加翻译服务", "Add Translation Service"))
                .font(.title3.bold())

            Text(lang.text(
                "DeepSeek 和 Gemini 已内置。这里添加第三方模型时，只需填写模型名称、协议、Base URL 和 API Key；添加后可在编辑页点击“测试”读取模型列表。",
                "DeepSeek and Gemini are built in. To add a third-party model, enter its name, protocol, Base URL, and API key; then use Test in the editor to load its model list."
            ))
            .font(.caption)
            .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Text(lang.text("模型名称", "Model Name"))
                    .frame(width: 82, alignment: .leading)
                TextField(lang.text("例如：DeepSeek Chat", "e.g. DeepSeek Chat"), text: $modelName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Text(lang.text("接口协议", "Protocol"))
                    .frame(width: 82, alignment: .leading)
                Picker("", selection: $protocolID) {
                    ForEach(TranslationProviderID.customProtocolCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .onChange(of: protocolID) { _, value in
                    baseURL = value.defaultServerURL
                }
            }

            HStack(spacing: 10) {
                Text(lang.text("Base URL", "Base URL"))
                    .frame(width: 82, alignment: .leading)
                TextField(protocolID.defaultServerURL, text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Text("API Key")
                    .frame(width: 82, alignment: .leading)
                SecureField(lang.text("输入 API Key（存入钥匙串）", "Enter API Key (stored in Keychain)"), text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(lang.text("确认添加", "Confirm Add")) {
                    settings.addCustomModel(
                        modelName: modelName,
                        protocolID: protocolID,
                        baseURL: baseURL,
                        apiKey: apiKey
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 540, height: 350)
        .onAppear {
            baseURL = protocolID.defaultServerURL
        }
    }
}

#Preview("精听复读参数设置") {
    IntensiveSettingsPopover(engine: PlaybackEngine.shared)
        .padding()
}
