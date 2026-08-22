import SwiftUI
import AppKit

/// 断句列表区视图（支持字幕导入导出、星标难句过滤、文本编辑与快捷切分）
public struct SegmentListView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    
    @State private var searchText: String = ""
    @State private var showImportSheet: Bool = false
    @State private var showSettingsPopover: Bool = false
    @State private var filterBookmarkedOnly: Bool = false
    @State private var exportErrorMessage: String?
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    private var displayedSegments: [SentenceSegment] {
        var list = engine.segments
        if filterBookmarkedOnly {
            list = list.filter { $0.isBookmarked }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list = list.filter {
                $0.text.localizedCaseInsensitiveContains(searchText) ||
                $0.translation.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // 列表头部工具栏
            HStack(spacing: 6) {
                Label(lang.localized(.segmentList), systemImage: "list.bullet.indent")
                    .font(.subheadline.bold())
                
                Text("(\(engine.segments.count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // 难句过滤筛选开关
                Button(action: { filterBookmarkedOnly.toggle() }) {
                    Image(systemName: filterBookmarkedOnly ? "star.fill" : "star")
                        .foregroundColor(filterBookmarkedOnly ? .yellow : .secondary)
                        .help(lang.text("只显示星标难句", "Show bookmarked sentences only"))
                }
                .buttonStyle(.plain)
                .focusable(false)
                
                // 导入字幕按钮
                Button(action: { showImportSheet = true }) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(.secondary)
                        .help(lang.text("导入字幕（SRT / LRC / VTT / TXT）", "Import subtitles (SRT / LRC / VTT / TXT)"))
                }
                .buttonStyle(.plain)
                .focusable(false)
                
                // 导出字幕菜单
                Menu {
                    Button(lang.text("导出为 SRT 字幕文件…", "Export as SRT…")) {
                        exportSubtitles(format: .srt)
                    }
                    Button(lang.text("导出为 LRC 歌词文件…", "Export as LRC…")) {
                        exportSubtitles(format: .lrc)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.secondary)
                        .help(lang.text("导出字幕", "Export subtitles"))
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                
                // 智能 VAD 断句菜单
                Menu {
                    Button(lang.text("标准断句（约 0.35 秒停顿）", "Standard (~0.35s pauses)")) {
                        engine.performSmartSegmentation(config: .normal)
                    }
                    Button(lang.text("精细短句（约 0.25 秒停顿）", "Short sentences (~0.25s pauses)")) {
                        engine.performSmartSegmentation(config: .sensitive)
                    }
                    Button(lang.text("长句断句（约 0.55 秒停顿）", "Long sentences (~0.55s pauses)")) {
                        engine.performSmartSegmentation(config: .relaxed)
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.secondary)
                        .help(lang.text("智能语音断句", "Smart voice segmentation"))
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                
                // 添加断句
                Button(action: {
                    let cur = engine.currentTime
                    engine.addSegment(startTime: cur, endTime: min(engine.duration > 0 ? engine.duration : 9999.0, cur + 3.0))
                }) {
                    Image(systemName: "plus")
                        .foregroundColor(.secondary)
                        .help(lang.localized(.addSegment))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            
            // 搜索过滤栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField(lang.text("搜索台词或字幕…", "Search text or subtitles…"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            Divider()
            
            // 断句列表 (采用高性能 ScrollView + LazyVStack，杜绝 NSTableView 代理重入警告)
            if displayedSegments.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: filterBookmarkedOnly ? "star.slash" : "text.badge.plus")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(filterBookmarkedOnly
                        ? lang.text("暂无星标难句", "No bookmarked sentences")
                        : lang.text("暂无断句数据", "No sentence data"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(displayedSegments) { seg in
                                let isActive: Bool = {
                                    guard let index = engine.activeSegmentIndex,
                                          index >= 0,
                                          index < engine.segments.count else { return false }
                                    return engine.segments[index].id == seg.id
                                }()
                                SegmentRowView(
                                    seg: seg,
                                    isActive: isActive,
                                    onSelect: {
                                        engine.jumpToSegment(id: seg.id)
                                    },
                                    onToggleBookmark: {
                                        engine.toggleBookmark(for: seg.id)
                                    },
                                    onSplit: {
                                        engine.splitSegment(id: seg.id, at: (seg.startTime + seg.endTime) / 2.0)
                                    },
                                    onMergeNext: {
                                        engine.mergeSegmentWithNext(id: seg.id)
                                    },
                                    onDelete: {
                                        engine.deleteSegment(id: seg.id)
                                    },
                                    onSaveText: { newText in
                                        engine.updateSegmentText(id: seg.id, text: newText)
                                    }
                                )
                                .id(seg.id)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: engine.activeSegmentIndex) { _, newIndex in
                        if let idx = newIndex, idx >= 0, idx < engine.segments.count {
                            let targetId = engine.segments[idx].id
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(targetId, anchor: nil)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showImportSheet) {
            SubtitleImportSheet(engine: engine)
        }
        .alert(lang.text("导出失败", "Export Failed"), isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button(lang.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }
    
    private func exportSubtitles(format: SubtitleFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (engine.currentMedia?.title ?? "Subtitles") + "." + format.rawValue
        
        if panel.runModal() == .OK, let url = panel.url {
            let content: String
            if format == .lrc {
                content = SubtitleExporter.shared.exportToLRC(segments: engine.segments, title: engine.currentMedia?.title ?? "")
            } else {
                content = SubtitleExporter.shared.exportToSRT(segments: engine.segments)
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }
}

/// 单行断句单元格
struct SegmentRowView: View {
    let seg: SentenceSegment
    let isActive: Bool
    let onSelect: () -> Void
    let onToggleBookmark: () -> Void
    let onSplit: () -> Void
    let onMergeNext: () -> Void
    let onDelete: () -> Void
    let onSaveText: (String) -> Void
    
    @State private var isHovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var tempText: String = ""
    @FocusState private var isFieldFocused: Bool
    @ObservedObject private var lang = LanguageManager.shared
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // 左侧活跃状态指示竖条
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? Color.blue : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        // 难句收藏星标按钮
                        Button(action: onToggleBookmark) {
                            Image(systemName: seg.isBookmarked ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundColor(seg.isBookmarked ? .yellow : .gray.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        
                        // 序号
                        Text("#\(seg.index)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isActive ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(isActive ? .white : .primary)
                            .cornerRadius(3)
                        
                        // 起止时间
                        Text("\(seg.formattedStartTime) - \(seg.formattedEndTime)")
                            .font(.system(size: 10, weight: isActive ? .bold : .regular).monospacedDigit())
                            .foregroundColor(isActive ? .primary : .secondary)
                        
                        Spacer()
                        
                        // 时长
                        Text(seg.formattedDuration)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary.opacity(0.8))
                        
                        // 悬停操作按钮
                        if isHovering {
                            HStack(spacing: 4) {
                                Button(action: {
                                    tempText = seg.text
                                    isEditing = true
                                    isFieldFocused = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.plain)
                                .help(lang.localized(.editSentenceText))
                                
                                Button(action: onSplit) {
                                    Image(systemName: "scissors")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.plain)
                                .help(lang.text("在中间拆分此句", "Split this sentence at its midpoint"))
                                
                                Button(action: onMergeNext) {
                                    Image(systemName: "arrow.down.to.line")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.plain)
                                .help(lang.localized(.mergeSegment))
                                
                                Button(action: onDelete) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9))
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help(lang.localized(.deleteSegment))
                            }
                        }
                    }
                    
                    // 第二行：分为两个区域，左边显示原文，右边显示译文
                    if isEditing {
                        HStack(spacing: 4) {
                            TextField(lang.text("原文…", "Original text…"), text: $tempText)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .focused($isFieldFocused)
                                .onSubmit {
                                    onSaveText(tempText)
                                    isEditing = false
                                }
                                .onChange(of: isFieldFocused) { _, focused in
                                    if !focused {
                                        onSaveText(tempText)
                                        isEditing = false
                                    }
                                }
                            
                            Button(lang.text("完成", "Done")) {
                                onSaveText(tempText)
                                isEditing = false
                            }
                            .controlSize(.mini)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            // 左边区域：原文（若无输入则显示默认占位 Sentence #）
                            let orig = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            Text(orig.isEmpty ? lang.localized(.sentenceIndex(seg.index)) : orig)
                                .font(.caption)
                                .foregroundColor(orig.isEmpty ? .secondary.opacity(0.6) : (isActive ? .primary : .primary.opacity(0.85)))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // 右边区域：译文
                            let trans = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trans.isEmpty {
                                Text(trans)
                                    .font(.caption)
                                    .foregroundColor(isActive ? .secondary : .secondary.opacity(0.8))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.blue.opacity(0.14) : (isHovering ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
        }
    }
}

#Preview("断句列表侧边栏") {
    SegmentListView(engine: PlaybackEngine.shared)
        .frame(width: 320, height: 600)
}
