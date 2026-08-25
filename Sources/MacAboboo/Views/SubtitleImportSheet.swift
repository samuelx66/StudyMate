import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 字幕与文本导入弹窗面板
public struct SubtitleImportSheet: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    
    @State private var selectedTab: Int = 0 // 0: 文件导入 (SRT/LRC/VTT), 1: 纯文本粘贴对齐
    @State private var importedItems: [ParsedSubtitleItem] = []
    @State private var plainTextContent: String = ""
    @State private var splitSentencesPreview: [String] = []
    @State private var selectedFileName: String = ""
    @State private var subtitleImportTarget: SubtitleImportTarget = .automatic
    @State private var isFileTargeted: Bool = false
    @State private var isParsing: Bool = false
    @State private var importErrorMessage: String?
    @State private var showReplacementConfirmation = false
    @State private var pendingImportKind = 0
    @State private var targetMediaID: UUID?
    @State private var parsingTask: Task<Void, Never>?
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // 头部标题栏
            HStack {
                Label(lang.text("导入字幕或文章文本", "Import Subtitles or Text"), systemImage: "captions.bubble")
                    .font(.headline)
                
                Spacer()
                
                Picker("", selection: $selectedTab) {
                    Text(lang.text("字幕文件（SRT / LRC / VTT）", "Subtitle File (SRT / LRC / VTT)")).tag(0)
                    Text(lang.text("纯文本智能对齐（TXT / 粘贴）", "Align Plain Text (TXT / Paste)")).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // 主体内容区
            if selectedTab == 0 {
                fileImportView
            } else {
                plainTextImportView
            }
            
            Divider()
            
            // 底部操作栏
            HStack {
                Button(lang.text("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                if selectedTab == 0 {
                    Button(action: { requestApply(kind: 0) }) {
                        Text(lang.text("应用此字幕（\(importedItems.count) 句）", "Apply \(importedItems.count) Cues"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importedItems.isEmpty || engine.currentMedia == nil || isParsing)
                } else {
                    Button(action: { requestApply(kind: 1) }) {
                        Text(lang.text("对齐并应用（\(splitSentencesPreview.count) 句）", "Align and Apply \(splitSentencesPreview.count) Sentences"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(splitSentencesPreview.isEmpty || engine.currentMedia == nil)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 620, height: 480)
        .onAppear { targetMediaID = engine.currentMedia?.id }
        .onDisappear { parsingTask?.cancel() }
        .confirmationDialog(
            lang.text("当前断句将被替换", "Current Sentences Will Be Replaced"),
            isPresented: $showReplacementConfirmation,
            titleVisibility: .visible
        ) {
            Button(lang.text("替换（可撤销）", "Replace (Undo Available)"), role: .destructive) {
                performPendingImport()
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(lang.text(
                "导入会替换当前 \(engine.segments.count) 个断句；之后可以使用“撤销”。",
                "This import replaces \(engine.segments.count) sentences. You can undo it afterward."
            ))
        }
        .alert(lang.text("导入失败", "Import Failed"), isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button(lang.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
    }
    
    // MARK: - 字幕文件导入视图
    
    private var fileImportView: some View {
        VStack(spacing: 12) {
            if importedItems.isEmpty {
                // 拖拽与选择引导区
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                    
                    Text(lang.text("拖拽 SRT、LRC 或 VTT 字幕文件到此处", "Drop an SRT, LRC, or VTT file here"))
                        .font(.headline)
                    
                    Button(lang.text("选择字幕文件…", "Choose Subtitle File…")) {
                        selectSubtitleFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isParsing)

                    if isParsing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundColor(isFileTargeted ? .blue : .gray.opacity(0.4))
                        .padding(16)
                )
                .onDrop(of: [.fileURL], isTargeted: $isFileTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let validURL = url {
                            DispatchQueue.main.async {
                                parseSubtitleFile(at: validURL)
                            }
                        }
                    }
                    return true
                }
            } else {
                // 已解析字幕预览表格
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lang.text("文件：\(selectedFileName)", "File: \(selectedFileName)"))
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(lang.text("重新选择", "Choose Again")) {
                            importedItems = []
                            selectedFileName = ""
                            subtitleImportTarget = .automatic
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                    Picker(lang.text("导入到", "Import as"), selection: $subtitleImportTarget) {
                        Text(lang.text("自动检测", "Auto Detect")).tag(SubtitleImportTarget.automatic)
                        Text(lang.text("原文", "Original")).tag(SubtitleImportTarget.original)
                        Text(lang.text("译文", "Translation")).tag(SubtitleImportTarget.translation)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(previewSubtitleItems, id: \.index) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("#\(item.index)")
                                            .font(.caption2.bold())
                                            .foregroundColor(.blue)
                                        Text("\(SentenceSegment.formatTimecode(item.startTime)) - \(SentenceSegment.formatTimecode(item.endTime))")
                                            .font(.system(size: 9).monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                    Text(item.text)
                                        .font(.caption)
                                    if !item.translation.isEmpty {
                                        Text(item.translation)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(6)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                .cornerRadius(4)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
        }
    }
    
    // MARK: - 纯文本导入与智能对齐视图
    
    private var plainTextImportView: some View {
        VStack(spacing: 8) {
            Text(lang.text(
                "粘贴文章或课文，系统会自动分句并与音频语音段对齐：",
                "Paste an article or lesson. It will be split into sentences and aligned with detected speech:"
            ))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            
            TextEditor(text: $plainTextContent)
                .font(.system(.body, design: .monospaced))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .onChange(of: plainTextContent) { _, newText in
                    splitSentencesPreview = TextAlignmentEngine.shared.splitTextIntoSentences(newText)
                }
            
            if !splitSentencesPreview.isEmpty {
                HStack {
                    Text(lang.text(
                        "识别到 \(splitSentencesPreview.count) 个独立句子",
                        "Detected \(splitSentencesPreview.count) sentences"
                    ))
                        .font(.caption.bold())
                        .foregroundColor(.green)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
    }
    
    // MARK: - 动作逻辑

    private var previewSubtitleItems: [ParsedSubtitleItem] {
        subtitleImportTarget.apply(to: importedItems)
    }
    
    private func selectSubtitleFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .text,
            UTType(filenameExtension: "lrc") ?? .text,
            UTType(filenameExtension: "vtt") ?? .text,
            .text
        ]
        
        if panel.runModal() == .OK, let url = panel.url {
            parseSubtitleFile(at: url)
        }
    }
    
    private func parseSubtitleFile(at url: URL) {
        parsingTask?.cancel()
        isParsing = true
        importErrorMessage = nil
        parsingTask = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[ParsedSubtitleItem], Error> in
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    return .success(try SubtitleParser.shared.parse(from: url))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled else { return }
            isParsing = false
            switch result {
            case .success(let items) where !items.isEmpty:
                importedItems = items
                selectedFileName = url.lastPathComponent
                subtitleImportTarget = .automatic
            case .success:
                importErrorMessage = lang.currentLanguage == .zh
                    ? "没有找到有效的字幕时间码。"
                    : "No valid subtitle timecodes were found."
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
    }
    
    private func requestApply(kind: Int) {
        guard targetMediaID == engine.currentMedia?.id else {
            importErrorMessage = lang.currentLanguage == .zh
                ? "媒体文件已变化，请关闭此窗口后重新导入。"
                : "The media changed. Close this sheet and start the import again."
            return
        }
        pendingImportKind = kind
        if engine.segments.isEmpty {
            performPendingImport()
        } else {
            showReplacementConfirmation = true
        }
    }

    private func performPendingImport() {
        let previous = engine.segments
        undoManager?.registerUndo(withTarget: engine) { target in
            target.replaceSegmentsForUndo(previous)
        }
        undoManager?.setActionName(lang.currentLanguage == .zh ? "导入字幕" : "Import Subtitles")

        if pendingImportKind == 0 {
            engine.importSubtitleItems(importedItems, target: subtitleImportTarget)
        } else {
            engine.importPlainText(plainTextContent)
        }
        dismiss()
    }
}
