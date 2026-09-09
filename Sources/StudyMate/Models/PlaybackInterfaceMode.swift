import Foundation

/// 媒体播放界面显示模式
public enum PlaybackInterfaceMode: String, CaseIterable, Identifiable, Sendable {
    case video = "video"             // 视频模式
    case list = "list"               // 列表模式
    case fullText = "fullText"       // 全文模式
    case sentence = "sentence"       // 句子模式
    case fillInBlank = "fillInBlank" // 填空模式

    public var id: String { rawValue }

    public func localized(with lang: LanguageManager = .shared) -> String {
        switch self {
        case .video:
            return lang.text("视频模式", "Video Mode")
        case .list:
            return lang.text("列表模式", "List Mode")
        case .fullText:
            return lang.text("全文模式", "Full Text Mode")
        case .sentence:
            return lang.text("句子模式", "Sentence Mode")
        case .fillInBlank:
            return lang.text("填空模式", "Fill-in-the-Blank")
        }
    }

    public var iconName: String {
        switch self {
        case .video:
            return "video"
        case .list:
            return "list.bullet.rectangle"
        case .fullText:
            return "doc.text"
        case .sentence:
            return "text.quote"
        case .fillInBlank:
            return "character.textbox"
        }
    }
}

/// Each workspace remembers its own waveform visibility. The shared key remains
/// the active workspace value so menu commands and toolbar controls stay in sync.
public enum PlaybackWorkspacePreferences {
    public static func initializeWaveformPreferences(defaults: UserDefaults = .standard) {
        let legacy = defaults.object(forKey: "StudyMate.ShowWaveforms") as? Bool ?? true
        for mode in PlaybackInterfaceMode.allCases {
            let key = "StudyMate.ShowWaveforms." + mode.rawValue
            if defaults.object(forKey: key) == nil { defaults.set(legacy, forKey: key) }
        }
    }

    public static func waveformsVisible(for mode: PlaybackInterfaceMode, defaults: UserDefaults = .standard) -> Bool {
        let key = "StudyMate.ShowWaveforms." + mode.rawValue
        return defaults.object(forKey: key) as? Bool
            ?? defaults.object(forKey: "StudyMate.ShowWaveforms") as? Bool ?? true
    }

    public static func setWaveformsVisible(_ visible: Bool, for mode: PlaybackInterfaceMode, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: "StudyMate.ShowWaveforms." + mode.rawValue)
    }
}
