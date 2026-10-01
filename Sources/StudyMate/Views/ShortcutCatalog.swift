import Foundation
import SwiftUI
import AppKit

/// 应用中对用户可见的快捷键定义。快捷键集中维护，工具提示和帮助面板
/// 共用同一份数据，避免显示文字与实际绑定逐渐不一致。
public enum StudyMateShortcutID: String, CaseIterable, Identifiable, Sendable {
    case openSentenceLibrary
    case openVocabulary
    case openDictionary
    case openMedia
    case toggleStatusBar
    case interfaceModeVideo
    case interfaceModeList
    case interfaceModeFullText
    case interfaceModeSentence
    case interfaceModeFillInBlank
    case interfaceModeReverseTranslation
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
    case toggleVideoOriginalSubtitle
    case toggleVideoTranslationSubtitle
    case togglePhonetics
    case videoSubtitleFontSettings
    case togglePlaylist
    case toggleWaveforms
    case toggleSecondaryWaveform
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
    case previewCurrentSegment
    case nudgeSentenceStartBackward
    case nudgeSentenceStartForward
    case nudgeSentenceEndBackward
    case nudgeSentenceEndForward
    case toggleFullScreen

    public var id: String { rawValue }
}

/// 快捷键逻辑分组类别
public enum StudyMateShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case general
    case interfaceMode
    case playbackMode
    case playbackControl
    case subtitleDisplay
    case sentenceOperations
    case segmentation
    case waveformNudge

    public var id: String { rawValue }

    public func localized(with lang: LanguageManager) -> String {
        switch self {
        case .general:
            return lang.text("常规与窗口", "General & Windows")
        case .interfaceMode:
            return lang.text("界面学习模式", "Interface Modes")
        case .playbackMode:
            return lang.text("播放循环模式", "Playback Modes")
        case .playbackControl:
            return lang.text("播放与控制", "Playback Control")
        case .subtitleDisplay:
            return lang.text("字幕与面板", "Subtitles & Panels")
        case .sentenceOperations:
            return lang.text("句子与编辑", "Sentences & Editing")
        case .segmentation:
            return lang.text("断句与识别", "Segmentation & AI")
        case .waveformNudge:
            return lang.text("波形与时间微调", "Waveform & Timing")
        }
    }

    public var iconName: String {
        switch self {
        case .general: return "macwindow"
        case .interfaceMode: return "rectangle.split.3x3"
        case .playbackMode: return "repeat"
        case .playbackControl: return "play.circle"
        case .subtitleDisplay: return "captions.bubble"
        case .sentenceOperations: return "text.quote"
        case .segmentation: return "scissors"
        case .waveformNudge: return "waveform.badge.magnifyingglass"
        }
    }
}

/// 快捷键按键组合定义模型，支持序列化与 SwiftUI/AppKit 转换
public struct ShortcutKeyBinding: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var isCommand: Bool
    public var isShift: Bool
    public var isOption: Bool
    public var isControl: Bool

    public init(
        key: String,
        isCommand: Bool = false,
        isShift: Bool = false,
        isOption: Bool = false,
        isControl: Bool = false
    ) {
        self.key = key
        self.isCommand = isCommand
        self.isShift = isShift
        self.isOption = isOption
        self.isControl = isControl
    }

    public var keyEquivalent: KeyEquivalent? {
        switch key.lowercased() {
        case "return", "enter": return .return
        case "space": return .space
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "delete", "backspace": return .delete
        case "deleteforward": return .deleteForward
        case "uparrow", "up": return .upArrow
        case "downarrow", "down": return .downArrow
        case "leftarrow", "left": return .leftArrow
        case "rightarrow", "right": return .rightArrow
        default:
            guard let first = key.first else { return nil }
            return KeyEquivalent(Character(extendedGraphemeClusterLiteral: first.lowercased().first ?? first))
        }
    }

    public var eventModifiers: EventModifiers {
        var mods: EventModifiers = []
        if isCommand { mods.insert(.command) }
        if isShift { mods.insert(.shift) }
        if isOption { mods.insert(.option) }
        if isControl { mods.insert(.control) }
        return mods
    }

    public var keyboardShortcut: KeyboardShortcut? {
        guard let ke = keyEquivalent else { return nil }
        return KeyboardShortcut(ke, modifiers: eventModifiers)
    }

    public var keyDisplay: String {
        var s = ""
        if isControl { s += "⌃" }
        if isOption { s += "⌥" }
        if isShift { s += "⇧" }
        if isCommand { s += "⌘" }
        switch key.lowercased() {
        case "return", "enter": s += "↩"
        case "space": s += "空格"
        case "tab": s += "⇥"
        case "escape", "esc": s += "Esc"
        case "delete", "backspace": s += "⌫"
        case "deleteforward": s += "⌦"
        case "uparrow", "up": s += "↑"
        case "downarrow", "down": s += "↓"
        case "leftarrow", "left": s += "←"
        case "rightarrow", "right": s += "→"
        default:
            s += key.uppercased()
        }
        return s
    }

    public static func from(event: NSEvent) -> ShortcutKeyBinding? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isCmd = flags.contains(.command)
        let isShift = flags.contains(.shift)
        let isOpt = flags.contains(.option)
        let isCtrl = flags.contains(.control)

        var keyName: String?
        switch event.keyCode {
        case 36, 76:
            keyName = "return"
        case 48:
            keyName = "tab"
        case 49:
            keyName = "space"
        case 51:
            keyName = "delete"
        case 53:
            keyName = "escape"
        case 117:
            keyName = "deleteForward"
        case 123:
            keyName = "leftArrow"
        case 124:
            keyName = "rightArrow"
        case 125:
            keyName = "downArrow"
        case 126:
            keyName = "upArrow"
        default:
            if let chars = event.charactersIgnoringModifiers, let first = chars.first {
                let s = String(first).lowercased()
                if let scalar = s.unicodeScalars.first, scalar.value >= 32 && scalar.value != 127 {
                    keyName = s
                }
            }
        }

        guard let keyName else { return nil }

        let isSpecialKey = ["space", "escape", "return", "tab", "delete", "deleteForward", "leftArrow", "rightArrow", "downArrow", "upArrow"].contains(keyName)
        if !isSpecialKey && !isCmd && !isOpt && !isCtrl {
            // 避免单字母/数字无修饰键被误绑定，影响正常文本输入
            return nil
        }

        return ShortcutKeyBinding(
            key: keyName,
            isCommand: isCmd,
            isShift: isShift,
            isOption: isOpt,
            isControl: isCtrl
        )
    }
}

public struct StudyMateShortcutDescriptor: Identifiable, Equatable, Sendable {
    public let id: StudyMateShortcutID
    public let category: StudyMateShortcutCategory
    public let chineseName: String
    public let englishName: String
    public let defaultBinding: ShortcutKeyBinding

    public init(
        id: StudyMateShortcutID,
        category: StudyMateShortcutCategory,
        chineseName: String,
        englishName: String,
        defaultBinding: ShortcutKeyBinding
    ) {
        self.id = id
        self.category = category
        self.chineseName = chineseName
        self.englishName = englishName
        self.defaultBinding = defaultBinding
    }

    public func name(for language: AppLanguage) -> String {
        language == .zh ? chineseName : englishName
    }

    @MainActor
    public var keyDisplay: String {
        StudyMateShortcutManager.shared.keyDisplay(for: id)
    }

    public var defaultKeyDisplay: String {
        defaultBinding.keyDisplay
    }

    @MainActor
    public var isCustomized: Bool {
        StudyMateShortcutManager.shared.isCustomized(id)
    }

    @MainActor
    public var currentBinding: ShortcutKeyBinding {
        StudyMateShortcutManager.shared.binding(for: id)
    }
}

public enum StudyMateShortcutCatalog {
    public static let all: [StudyMateShortcutDescriptor] = [
        // MARK: - 常规与窗口
        .init(id: .openMedia, category: .general, chineseName: "打开音视频", englishName: "Open Audio or Video", defaultBinding: .init(key: "o", isCommand: true)),
        .init(id: .openSentenceLibrary, category: .general, chineseName: "打开句库", englishName: "Open Sentence Library", defaultBinding: .init(key: "l", isCommand: true)),
        .init(id: .openVocabulary, category: .general, chineseName: "打开生词本", englishName: "Open Vocabulary", defaultBinding: .init(key: "v", isCommand: true, isShift: true)),
        .init(id: .openDictionary, category: .general, chineseName: "打开词典", englishName: "Open Dictionary", defaultBinding: .init(key: "d", isCommand: true, isControl: true)),
        .init(id: .toggleFullScreen, category: .general, chineseName: "进入或退出全屏幕", englishName: "Enter or Exit Full Screen", defaultBinding: .init(key: "f", isCommand: true, isControl: true)),
        .init(id: .toggleStatusBar, category: .general, chineseName: "显示或隐藏状态栏", englishName: "Show or Hide Status Bar", defaultBinding: .init(key: "/", isCommand: true)),

        // MARK: - 界面学习模式
        .init(id: .interfaceModeVideo, category: .interfaceMode, chineseName: "界面模式：视频模式", englishName: "Interface Mode: Video Mode", defaultBinding: .init(key: "1", isCommand: true, isOption: true)),
        .init(id: .interfaceModeList, category: .interfaceMode, chineseName: "界面模式：列表模式", englishName: "Interface Mode: List Mode", defaultBinding: .init(key: "2", isCommand: true, isOption: true)),
        .init(id: .interfaceModeFullText, category: .interfaceMode, chineseName: "界面模式：全文模式", englishName: "Interface Mode: Full Text Mode", defaultBinding: .init(key: "3", isCommand: true, isOption: true)),
        .init(id: .interfaceModeSentence, category: .interfaceMode, chineseName: "界面模式：句子模式", englishName: "Interface Mode: Sentence Mode", defaultBinding: .init(key: "4", isCommand: true, isOption: true)),
        .init(id: .interfaceModeFillInBlank, category: .interfaceMode, chineseName: "界面模式：填空模式", englishName: "Interface Mode: Fill-in-the-Blank Mode", defaultBinding: .init(key: "5", isCommand: true, isOption: true)),
        .init(id: .interfaceModeReverseTranslation, category: .interfaceMode, chineseName: "界面模式：反译模式", englishName: "Interface Mode: Reverse Translation Mode", defaultBinding: .init(key: "6", isCommand: true, isOption: true)),

        // MARK: - 播放循环模式
        .init(id: .playbackModeContinuous, category: .playbackMode, chineseName: "播放模式：连续播放", englishName: "Playback Mode: Continuous Play", defaultBinding: .init(key: "1", isCommand: true)),
        .init(id: .playbackModeSingleRepeat, category: .playbackMode, chineseName: "播放模式：单句重复", englishName: "Playback Mode: Repeat Sentence", defaultBinding: .init(key: "2", isCommand: true)),
        .init(id: .playbackModePauseAfter, category: .playbackMode, chineseName: "播放模式：句后停顿", englishName: "Playback Mode: Pause After Sentence", defaultBinding: .init(key: "3", isCommand: true)),
        .init(id: .playbackModeLoopAll, category: .playbackMode, chineseName: "播放模式：全篇循环", englishName: "Playback Mode: Loop Entire File", defaultBinding: .init(key: "4", isCommand: true)),

        // MARK: - 播放与控制
        .init(id: .playPause, category: .playbackControl, chineseName: "播放 / 暂停", englishName: "Play / Pause", defaultBinding: .init(key: "space")),
        .init(id: .repeatCurrentSegment, category: .playbackControl, chineseName: "重播当前句", englishName: "Repeat Current Sentence", defaultBinding: .init(key: "r", isCommand: true)),
        .init(id: .previousSegment, category: .playbackControl, chineseName: "上一句", englishName: "Previous Sentence", defaultBinding: .init(key: "leftArrow", isCommand: true)),
        .init(id: .nextSegment, category: .playbackControl, chineseName: "下一句", englishName: "Next Sentence", defaultBinding: .init(key: "rightArrow", isCommand: true)),
        .init(id: .mute, category: .playbackControl, chineseName: "静音 / 取消静音", englishName: "Mute / Unmute", defaultBinding: .init(key: "m", isCommand: true, isShift: true)),
        .init(id: .playbackRateUp, category: .playbackControl, chineseName: "加速播放", englishName: "Increase Playback Rate", defaultBinding: .init(key: "upArrow", isCommand: true)),
        .init(id: .playbackRateDown, category: .playbackControl, chineseName: "减速播放", englishName: "Decrease Playback Rate", defaultBinding: .init(key: "downArrow", isCommand: true)),
        .init(id: .playbackRateReset, category: .playbackControl, chineseName: "恢复原速", englishName: "Reset Playback Rate", defaultBinding: .init(key: "0", isCommand: true)),
        .init(id: .playbackRateMenu, category: .playbackControl, chineseName: "打开变速播放菜单", englishName: "Open Playback Rate Menu", defaultBinding: .init(key: "r", isCommand: true, isShift: true)),
        .init(id: .repeatCountMenu, category: .playbackControl, chineseName: "设置单句复读次数", englishName: "Set Sentence Repeat Count", defaultBinding: .init(key: "c", isCommand: true, isShift: true)),
        .init(id: .shadowingPauseMenu, category: .playbackControl, chineseName: "设置句末跟读停顿", englishName: "Set Shadowing Pause", defaultBinding: .init(key: "p", isCommand: true, isShift: true)),
        .init(id: .previewCurrentSegment, category: .playbackControl, chineseName: "试听当前句", englishName: "Preview Current Sentence", defaultBinding: .init(key: "v", isCommand: true, isOption: true)),

        // MARK: - 字幕与面板
        .init(id: .toggleVideoOriginalSubtitle, category: .subtitleDisplay, chineseName: "显示或隐藏画面原文字幕", englishName: "Show or Hide Original Subtitles", defaultBinding: .init(key: "o", isCommand: true, isOption: true)),
        .init(id: .toggleVideoTranslationSubtitle, category: .subtitleDisplay, chineseName: "显示或隐藏画面译文字幕", englishName: "Show or Hide Translation Subtitles", defaultBinding: .init(key: "t", isCommand: true, isOption: true)),
        .init(id: .togglePhonetics, category: .subtitleDisplay, chineseName: "显示或隐藏注音", englishName: "Show or Hide Phonetics", defaultBinding: .init(key: "p", isCommand: true, isOption: true)),
        .init(id: .videoSubtitleFontSettings, category: .subtitleDisplay, chineseName: "设置画面字幕字体", englishName: "Set Subtitle Fonts", defaultBinding: .init(key: "f", isCommand: true, isOption: true)),
        .init(id: .togglePlaylist, category: .subtitleDisplay, chineseName: "显示或隐藏播放列表", englishName: "Show or Hide Playlist", defaultBinding: .init(key: "p", isOption: true)),
        .init(id: .toggleWaveforms, category: .subtitleDisplay, chineseName: "显示或隐藏波形图", englishName: "Show or Hide Waveforms", defaultBinding: .init(key: "w", isOption: true)),
        .init(id: .toggleSecondaryWaveform, category: .subtitleDisplay, chineseName: "显示或隐藏次波形图", englishName: "Show or Hide Secondary Waveform", defaultBinding: .init(key: "w", isShift: true, isOption: true)),
        .init(id: .toggleSubtitleEditor, category: .subtitleDisplay, chineseName: "显示或隐藏字幕编辑区", englishName: "Show or Hide Subtitle Editor", defaultBinding: .init(key: "s", isOption: true)),
        .init(id: .toggleSegmentList, category: .subtitleDisplay, chineseName: "显示或隐藏断句列表", englishName: "Show or Hide Sentence List", defaultBinding: .init(key: "l", isOption: true)),

        // MARK: - 句子与编辑
        .init(id: .selectSentence, category: .sentenceOperations, chineseName: "选中当前句并定位播放", englishName: "Select and Seek to Sentence", defaultBinding: .init(key: "return", isCommand: true)),
        .init(id: .toggleSentenceSelection, category: .sentenceOperations, chineseName: "勾选 / 取消勾选当前句", englishName: "Select / Deselect Current Sentence", defaultBinding: .init(key: "space", isCommand: true, isShift: true)),
        .init(id: .selectAllVisibleSentences, category: .sentenceOperations, chineseName: "全选当前显示句子", englishName: "Select All Visible Sentences", defaultBinding: .init(key: "a", isCommand: true)),
        .init(id: .invertVisibleSentenceSelection, category: .sentenceOperations, chineseName: "反选当前显示句子", englishName: "Invert Visible Sentence Selection", defaultBinding: .init(key: "i", isCommand: true, isOption: true)),
        .init(id: .filterSentences, category: .sentenceOperations, chineseName: "筛选句子", englishName: "Filter Sentences", defaultBinding: .init(key: "l", isCommand: true, isShift: true)),
        .init(id: .clearSearch, category: .sentenceOperations, chineseName: "清除搜索", englishName: "Clear Search", defaultBinding: .init(key: "escape")),
        .init(id: .followActiveSentence, category: .sentenceOperations, chineseName: "播放时自动跟随当前句", englishName: "Follow Active Sentence During Playback", defaultBinding: .init(key: "f", isCommand: true, isShift: true)),
        .init(id: .editSentence, category: .sentenceOperations, chineseName: "编辑当前句原文和译文", englishName: "Edit Current Sentence", defaultBinding: .init(key: "y", isCommand: true, isShift: true)),
        .init(id: .splitSentence, category: .sentenceOperations, chineseName: "拆分当前句", englishName: "Split Current Sentence", defaultBinding: .init(key: "s", isCommand: true, isShift: true)),
        .init(id: .mergePreviousSentence, category: .sentenceOperations, chineseName: "合并上一句", englishName: "Merge with Previous Sentence", defaultBinding: .init(key: "leftArrow", isCommand: true, isOption: true)),
        .init(id: .mergeNextSentence, category: .sentenceOperations, chineseName: "合并下一句", englishName: "Merge with Next Sentence", defaultBinding: .init(key: "rightArrow", isCommand: true, isOption: true)),
        .init(id: .toggleNavigationBookmark, category: .sentenceOperations, chineseName: "加入 / 移出当前句书签", englishName: "Toggle Current Sentence Bookmark", defaultBinding: .init(key: "b", isCommand: true)),
        .init(id: .toggleDifficultyBookmark, category: .sentenceOperations, chineseName: "切换难句星标", englishName: "Toggle Difficulty Star", defaultBinding: .init(key: "b", isCommand: true, isShift: true)),
        .init(id: .deleteSentence, category: .sentenceOperations, chineseName: "删除当前句", englishName: "Delete Current Sentence", defaultBinding: .init(key: "delete", isCommand: true)),
        .init(id: .addToSentenceLibrary, category: .sentenceOperations, chineseName: "加入句库", englishName: "Add to Sentence Library", defaultBinding: .init(key: "a", isCommand: true, isOption: true)),
        .init(id: .translateSentences, category: .sentenceOperations, chineseName: "翻译句子", englishName: "Translate Sentences", defaultBinding: .init(key: "t", isCommand: true)),
        .init(id: .importSubtitles, category: .sentenceOperations, chineseName: "导入字幕", englishName: "Import Subtitles", defaultBinding: .init(key: "i", isCommand: true, isShift: true)),
        .init(id: .exportMenu, category: .sentenceOperations, chineseName: "打开导出菜单", englishName: "Open Export Menu", defaultBinding: .init(key: "e", isCommand: true, isOption: true)),
        .init(id: .exportSeparate, category: .sentenceOperations, chineseName: "逐句导出 M4A 与 LRC/SRT", englishName: "Export Separate M4A and LRC/SRT", defaultBinding: .init(key: "e", isCommand: true)),
        .init(id: .exportMerged, category: .sentenceOperations, chineseName: "合并导出 M4A 与 LRC/SRT", englishName: "Export Merged M4A and LRC/SRT", defaultBinding: .init(key: "e", isCommand: true, isShift: true)),

        // MARK: - 断句与识别
        .init(id: .segmentationMenu, category: .segmentation, chineseName: "打开断句菜单", englishName: "Open Segmentation Menu", defaultBinding: .init(key: "g", isCommand: true, isShift: true)),
        .init(id: .fastSegmentation, category: .segmentation, chineseName: "快速断句", englishName: "Fast Segmentation", defaultBinding: .init(key: "1", isCommand: true, isControl: true)),
        .init(id: .intelligentSegmentation, category: .segmentation, chineseName: "智能断句", englishName: "Intelligent Segmentation", defaultBinding: .init(key: "2", isCommand: true, isControl: true)),
        .init(id: .regenerateOriginalText, category: .segmentation, chineseName: "重新生成原文", englishName: "Regenerate Original Text", defaultBinding: .init(key: "t", isCommand: true, isShift: true)),

        // MARK: - 波形与时间微调
        .init(id: .nudgeSentenceStartBackward, category: .waveformNudge, chineseName: "句首提前 50 毫秒", englishName: "Move Sentence Start Earlier by 50 ms", defaultBinding: .init(key: "leftArrow", isOption: true, isControl: true)),
        .init(id: .nudgeSentenceStartForward, category: .waveformNudge, chineseName: "句首延后 50 毫秒", englishName: "Move Sentence Start Later by 50 ms", defaultBinding: .init(key: "rightArrow", isOption: true, isControl: true)),
        .init(id: .nudgeSentenceEndBackward, category: .waveformNudge, chineseName: "句尾提前 50 毫秒", englishName: "Move Sentence End Earlier by 50 ms", defaultBinding: .init(key: "downArrow", isOption: true, isControl: true)),
        .init(id: .nudgeSentenceEndForward, category: .waveformNudge, chineseName: "句尾延后 50 毫秒", englishName: "Move Sentence End Later by 50 ms", defaultBinding: .init(key: "upArrow", isOption: true, isControl: true))
    ]

    private static let byID: [StudyMateShortcutID: StudyMateShortcutDescriptor] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    public static func descriptor(_ id: StudyMateShortcutID) -> StudyMateShortcutDescriptor {
        byID[id]!
    }

    public static func defaultBinding(for id: StudyMateShortcutID) -> ShortcutKeyBinding {
        byID[id]!.defaultBinding
    }

    @MainActor
    public static func help(
        _ text: String,
        shortcut id: StudyMateShortcutID
    ) -> String {
        "\(text) (\(StudyMateShortcutManager.shared.keyDisplay(for: id)))"
    }
}

public extension PlaybackLoopMode {
    /// 播放模式选择器中的四个选项与菜单命令共用同一快捷键目录。
    var shortcutID: StudyMateShortcutID {
        switch self {
        case .normal: return .playbackModeContinuous
        case .singleSegment: return .playbackModeSingleRepeat
        case .pauseAfterSegment: return .playbackModePauseAfter
        case .all: return .playbackModeLoopAll
        }
    }
}

public extension PlaybackInterfaceMode {
    /// 界面模式选项与菜单命令共用同一快捷键目录。
    var shortcutID: StudyMateShortcutID {
        switch self {
        case .video: return .interfaceModeVideo
        case .list: return .interfaceModeList
        case .fullText: return .interfaceModeFullText
        case .sentence: return .interfaceModeSentence
        case .fillInBlank: return .interfaceModeFillInBlank
        case .reverseTranslation: return .interfaceModeReverseTranslation
        }
    }

    var shortcutKey: KeyEquivalent {
        switch self {
        case .video: return "1"
        case .list: return "2"
        case .fullText: return "3"
        case .sentence: return "4"
        case .fillInBlank: return "5"
        case .reverseTranslation: return "6"
        }
    }
}
