import SwiftUI
import AppKit

/// 字幕编辑区视图（位于视频画面播放区域与播放控制栏之间，支持双行输入原文与译文，焦点离开时自动保存）
public struct SubtitleEditView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    
    enum FocusField: Hashable {
        case original
        case translation
    }
    
    @FocusState private var focusedField: FocusField?
    
    @State private var originalText: String = ""
    @State private var translationText: String = ""
    @State private var currentSegmentId: UUID? = nil
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    private var activeSegment: SentenceSegment? {
        guard let idx = engine.activeSegmentIndex, idx >= 0, idx < engine.segments.count else {
            return nil
        }
        return engine.segments[idx]
    }
    
    public var body: some View {
        VStack(spacing: 6) {
            if let seg = activeSegment {
                // 原文输入行
                HStack(spacing: 8) {
                    Text(lang.text("原文", "Original"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.blue)
                        .frame(width: 32, alignment: .trailing)
                    
                    TextField(lang.text("输入原文台词或字幕…", "Enter original text or subtitles…"), text: $originalText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .original)
                        .onSubmit {
                            saveCurrentSegment()
                            focusedField = .translation
                        }
                    
                    Text("#\(seg.index)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                
                // 译文输入行
                HStack(spacing: 8) {
                    Text(lang.text("译文", "Translation"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                        .frame(width: 32, alignment: .trailing)
                    
                    TextField(lang.text("输入译文…", "Enter a translation…"), text: $translationText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .translation)
                        .onSubmit {
                            saveCurrentSegment()
                            focusedField = nil
                        }
                    
                    Text(seg.formattedDuration)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            } else {
                HStack {
                    Image(systemName: "text.bubble")
                        .foregroundColor(.secondary)
                    Text(lang.text(
                        "未选中断句（请在波形图或右侧列表中选择断句）",
                        "No sentence selected. Choose one in a waveform or the list."
                    ))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(height: 52)
                .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onAppear {
            loadActiveSegment()
        }
        .onChange(of: activeSegment?.id) { _, _ in
            saveCurrentSegment()
            loadActiveSegment()
        }
        .onChange(of: activeSegment) { _, _ in
            if focusedField == nil { loadActiveSegment() }
        }
        .onDisappear { saveCurrentSegment() }
        .onChange(of: focusedField) { oldField, newField in
            if oldField != nil && newField == nil {
                // 焦点离开输入框时，自动保存并重新对齐当前最新活跃句
                saveCurrentSegment()
                loadActiveSegment()
            } else if oldField != nil && newField != oldField {
                // 焦点在原文与译文输入框之间切换时，也自动保存
                saveCurrentSegment()
            }
        }
    }
    
    private func loadActiveSegment() {
        if let seg = activeSegment {
            currentSegmentId = seg.id
            originalText = seg.text
            translationText = seg.translation
        } else {
            currentSegmentId = nil
            originalText = ""
            translationText = ""
        }
    }
    
    private func saveCurrentSegment() {
        guard let id = currentSegmentId else { return }
        engine.updateSegmentText(id: id, text: originalText, translation: translationText)
    }
}
