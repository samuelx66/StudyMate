import Foundation

/// 应用中对用户可见的快捷键定义。快捷键集中维护，工具提示和帮助面板
/// 共用同一份数据，避免显示文字与实际绑定逐渐不一致。
public enum MacAbobooShortcutID: String, CaseIterable, Identifiable, Sendable {
    case openSentenceLibrary
    case openMedia
    case playbackModeContinuous
    case playbackModeSingleRepeat
    case playbackModePauseAfter
    case playbackModeLoopAll
    case playbackRateMenu
    case playbackRateUp
    case playbackRateDown
    case playbackRateReset
    case repeatCountMenu
    case shadowingPauseMenu
    case togglePlaylist
    case toggleWaveforms
    case toggleSubtitleEditor
    case toggleSegmentList
    case playPause
    case repeatCurrentSegment
    case previousSegment
    case nextSegment
    case mute
    case followActiveSentence
    case filterSentences
    case regenerateOriginalText
    case translateSentences
    case importSubtitles
    case exportMenu
    case exportSeparate
    case exportMerged
    case addToSentenceLibrary
    case segmentationMenu
    case fastSegmentation
    case intelligentSegmentation
    case clearSearch
    case selectSentence
    case toggleSentenceSelection
    case toggleDifficultyBookmark
    case editSentence
    case splitSentence
    case mergePreviousSentence
    case mergeNextSentence
    case toggleNavigationBookmark
    case deleteSentence
    case selectAllVisibleSentences
    case invertVisibleSentenceSelection

    public var id: String { rawValue }
}

public struct MacAbobooShortcutDescriptor: Identifiable, Equatable, Sendable {
    public let id: MacAbobooShortcutID
    public let chineseName: String
    public let englishName: String
    public let keyDisplay: String

    public init(
        id: MacAbobooShortcutID,
        chineseName: String,
        englishName: String,
        keyDisplay: String
    ) {
        self.id = id
        self.chineseName = chineseName
        self.englishName = englishName
        self.keyDisplay = keyDisplay
    }

    public func name(for language: AppLanguage) -> String {
        language == .zh ? chineseName : englishName
    }
}

public enum MacAbobooShortcutCatalog {
    public static let all: [MacAbobooShortcutDescriptor] = [
        .init(id: .openSentenceLibrary, chineseName: "打开句库", englishName: "Open Sentence Library", keyDisplay: "⌘L"),
        .init(id: .openMedia, chineseName: "打开音视频", englishName: "Open Audio or Video", keyDisplay: "⌘O"),
        .init(id: .playbackModeContinuous, chineseName: "播放模式：连续播放", englishName: "Playback Mode: Continuous Play", keyDisplay: "⌘1"),
        .init(id: .playbackModeSingleRepeat, chineseName: "播放模式：单句重复", englishName: "Playback Mode: Repeat Sentence", keyDisplay: "⌘2"),
        .init(id: .playbackModePauseAfter, chineseName: "播放模式：句后停顿", englishName: "Playback Mode: Pause After Sentence", keyDisplay: "⌘3"),
        .init(id: .playbackModeLoopAll, chineseName: "播放模式：全篇循环", englishName: "Playback Mode: Loop Entire File", keyDisplay: "⌘4"),
        .init(id: .playbackRateMenu, chineseName: "打开变速播放菜单", englishName: "Open Playback Rate Menu", keyDisplay: "⌘⇧R"),
        .init(id: .playbackRateUp, chineseName: "加速播放", englishName: "Increase Playback Rate", keyDisplay: "⌘↑"),
        .init(id: .playbackRateDown, chineseName: "减速播放", englishName: "Decrease Playback Rate", keyDisplay: "⌘↓"),
        .init(id: .playbackRateReset, chineseName: "恢复原速", englishName: "Reset Playback Rate", keyDisplay: "⌘0"),
        .init(id: .repeatCountMenu, chineseName: "设置单句复读次数", englishName: "Set Sentence Repeat Count", keyDisplay: "⌘⇧C"),
        .init(id: .shadowingPauseMenu, chineseName: "设置句末跟读停顿", englishName: "Set Shadowing Pause", keyDisplay: "⌘⇧P"),
        .init(id: .togglePlaylist, chineseName: "显示或隐藏播放列表", englishName: "Show or Hide Playlist", keyDisplay: "⌥P"),
        .init(id: .toggleWaveforms, chineseName: "显示或隐藏波形图", englishName: "Show or Hide Waveforms", keyDisplay: "⌥W"),
        .init(id: .toggleSubtitleEditor, chineseName: "显示或隐藏字幕编辑区", englishName: "Show or Hide Subtitle Editor", keyDisplay: "⌥S"),
        .init(id: .toggleSegmentList, chineseName: "显示或隐藏断句列表", englishName: "Show or Hide Sentence List", keyDisplay: "⌥L"),
        .init(id: .playPause, chineseName: "播放 / 暂停", englishName: "Play / Pause", keyDisplay: "空格"),
        .init(id: .repeatCurrentSegment, chineseName: "重播当前句", englishName: "Repeat Current Sentence", keyDisplay: "⌘R"),
        .init(id: .previousSegment, chineseName: "上一句", englishName: "Previous Sentence", keyDisplay: "⌘←"),
        .init(id: .nextSegment, chineseName: "下一句", englishName: "Next Sentence", keyDisplay: "⌘→"),
        .init(id: .mute, chineseName: "静音 / 取消静音", englishName: "Mute / Unmute", keyDisplay: "⌘⇧M"),
        .init(id: .followActiveSentence, chineseName: "播放时自动跟随当前句", englishName: "Follow Active Sentence During Playback", keyDisplay: "⌘⇧F"),
        .init(id: .filterSentences, chineseName: "筛选句子", englishName: "Filter Sentences", keyDisplay: "⌘⇧L"),
        .init(id: .regenerateOriginalText, chineseName: "重新生成原文", englishName: "Regenerate Original Text", keyDisplay: "⌘⇧T"),
        .init(id: .translateSentences, chineseName: "翻译句子", englishName: "Translate Sentences", keyDisplay: "⌘T"),
        .init(id: .importSubtitles, chineseName: "导入字幕", englishName: "Import Subtitles", keyDisplay: "⌘⇧I"),
        .init(id: .exportMenu, chineseName: "打开导出菜单", englishName: "Open Export Menu", keyDisplay: "⌘⌥E"),
        .init(id: .exportSeparate, chineseName: "逐句导出 M4A 与 LRC", englishName: "Export Separate M4A and LRC", keyDisplay: "⌘E"),
        .init(id: .exportMerged, chineseName: "合并导出 M4A 与 LRC", englishName: "Export Merged M4A and LRC", keyDisplay: "⌘⇧E"),
        .init(id: .addToSentenceLibrary, chineseName: "加入句库", englishName: "Add to Sentence Library", keyDisplay: "⌘⌥A"),
        .init(id: .segmentationMenu, chineseName: "打开断句菜单", englishName: "Open Segmentation Menu", keyDisplay: "⌘⇧G"),
        .init(id: .fastSegmentation, chineseName: "快速断句", englishName: "Fast Segmentation", keyDisplay: "⌃⌘1"),
        .init(id: .intelligentSegmentation, chineseName: "智能断句", englishName: "Intelligent Segmentation", keyDisplay: "⌃⌘2"),
        .init(id: .clearSearch, chineseName: "清除搜索", englishName: "Clear Search", keyDisplay: "Esc"),
        .init(id: .selectSentence, chineseName: "选中当前句并定位播放", englishName: "Select and Seek to Sentence", keyDisplay: "⌘↩"),
        .init(id: .toggleSentenceSelection, chineseName: "勾选 / 取消勾选当前句", englishName: "Select / Deselect Current Sentence", keyDisplay: "⌘⇧空格"),
        .init(id: .toggleDifficultyBookmark, chineseName: "切换难句星标", englishName: "Toggle Difficulty Star", keyDisplay: "⌘⇧B"),
        .init(id: .editSentence, chineseName: "编辑当前句原文和译文", englishName: "Edit Current Sentence", keyDisplay: "⌘⇧Y"),
        .init(id: .splitSentence, chineseName: "拆分当前句", englishName: "Split Current Sentence", keyDisplay: "⌘⇧S"),
        .init(id: .mergePreviousSentence, chineseName: "合并上一句", englishName: "Merge with Previous Sentence", keyDisplay: "⌘⌥←"),
        .init(id: .mergeNextSentence, chineseName: "合并下一句", englishName: "Merge with Next Sentence", keyDisplay: "⌘⌥→"),
        .init(id: .toggleNavigationBookmark, chineseName: "加入 / 移出当前句书签", englishName: "Toggle Current Sentence Bookmark", keyDisplay: "⌘B"),
        .init(id: .deleteSentence, chineseName: "删除当前句", englishName: "Delete Current Sentence", keyDisplay: "⌘⌫"),
        .init(id: .selectAllVisibleSentences, chineseName: "全选当前显示句子", englishName: "Select All Visible Sentences", keyDisplay: "⌘A"),
        .init(id: .invertVisibleSentenceSelection, chineseName: "反选当前显示句子", englishName: "Invert Visible Sentence Selection", keyDisplay: "⌘⌥I")
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func descriptor(_ id: MacAbobooShortcutID) -> MacAbobooShortcutDescriptor {
        byID[id]!
    }

    public static func help(
        _ text: String,
        shortcut id: MacAbobooShortcutID
    ) -> String {
        "\(text) (\(descriptor(id).keyDisplay))"
    }
}

public extension PlaybackLoopMode {
    /// 播放模式选择器中的四个选项与菜单命令共用同一快捷键目录。
    var shortcutID: MacAbobooShortcutID {
        switch self {
        case .normal: return .playbackModeContinuous
        case .singleSegment: return .playbackModeSingleRepeat
        case .pauseAfterSegment: return .playbackModePauseAfter
        case .all: return .playbackModeLoopAll
        }
    }
}
