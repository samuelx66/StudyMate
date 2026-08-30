import Foundation
import SwiftUI
import Combine

/// 支持的应用语言
public enum AppLanguage: String, CaseIterable, Identifiable {
    case zh = "zh-Hans"
    case en = "en"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
}

/// 多语言管理器
public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()
    
    @AppStorage("AppLanguageSelection") public var currentLanguage: AppLanguage = .zh {
        didSet {
            objectWillChange.send()
        }
    }
    
    private init() {}
    
    public func localized(_ key: LocalizedKey) -> String {
        switch currentLanguage {
        case .zh:
            return key.zh
        case .en:
            return key.en
        }
    }

    /// 供短小、只在单个界面出现的文案使用，避免遗漏英文界面。
    public func text(_ chinese: String, _ english: String) -> String {
        currentLanguage == .zh ? chinese : english
    }
}

/// 本地化文案字典
public enum LocalizedKey {
    case appTitle
    case openFile
    case play
    case pause
    case previousSentence
    case nextSentence
    case repeatSentence
    case playSpeed
    case primaryWaveform
    case secondaryWaveform
    case segmentList
    case noFileLoaded
    case dragDropPrompt
    case sentenceIndex(Int)
    case duration(String)
    case startAnchor
    case endAnchor
    case zoomIn
    case zoomOut
    case resetZoom
    case loopModeSingle
    case loopModeAll
    case loopModePauseAfterSentence
    case loopModeNormal
    case timecodeFormat
    case addSegment
    case deleteSegment
    case splitSegment
    case mergeSegment
    case editSentenceText
    case language
    case videoTrack
    case audioTrack
    case extractingWaveform
    case volume
    case errorLoadingMedia
    case decoderEngine
    case decoderModeSystem
    case decoderModeMPV
    case decoderModeHybrid
    case hideWaveforms
    case showWaveforms
    
    var zh: String {
        switch self {
        case .appTitle: return "MacAboboo - 精听与口语复读"
        case .openFile: return "打开音视频文件"
        case .play: return "播放"
        case .pause: return "暂停"
        case .previousSentence: return "上一句"
        case .nextSentence: return "下一句"
        case .repeatSentence: return "重听当前句"
        case .playSpeed: return "播放倍速"
        case .primaryWaveform: return "主波形图"
        case .secondaryWaveform: return "次波形图"
        case .segmentList: return "断句列表"
        case .noFileLoaded: return "未加载媒体文件"
        case .dragDropPrompt: return "拖拽音视频文件到此处，或点击上方“打开”按钮"
        case .sentenceIndex(let i): return "第 \(i) 句"
        case .duration(let d): return "时长: \(d)"
        case .startAnchor: return "起始锚点"
        case .endAnchor: return "结束锚点"
        case .zoomIn: return "放大波形"
        case .zoomOut: return "缩小波形"
        case .resetZoom: return "重置缩放"
        case .loopModeSingle: return "单句重复"
        case .loopModeAll: return "全篇循环"
        case .loopModePauseAfterSentence: return "句后停顿"
        case .loopModeNormal: return "连续播放"
        case .timecodeFormat: return "时间码"
        case .addSegment: return "添加断句"
        case .deleteSegment: return "删除断句"
        case .splitSegment: return "拆分断句"
        case .mergeSegment: return "合并下一句"
        case .editSentenceText: return "编辑台词/字幕"
        case .language: return "语言 / Language"
        case .videoTrack: return "视频画面"
        case .audioTrack: return "音频模式"
        case .extractingWaveform: return "正在解析音频波形..."
        case .volume: return "音量"
        case .errorLoadingMedia: return "加载媒体文件失败"
        case .decoderEngine: return "解码引擎设置"
        case .decoderModeSystem: return "系统解码 (纯原生 AVPlayer)"
        case .decoderModeMPV: return "libmpv 解码 (全格式 libmpv)"
        case .decoderModeHybrid: return "混合解码 (系统自动优选)"
        case .hideWaveforms: return "折叠双波形图 (最大化视频画面)"
        case .showWaveforms: return "展开双波形图"
        }
    }
    
    var en: String {
        switch self {
        case .appTitle: return "MacAboboo - Intensive Listening & Shadowing"
        case .openFile: return "Open Media File"
        case .play: return "Play"
        case .pause: return "Pause"
        case .previousSentence: return "Previous Sentence"
        case .nextSentence: return "Next Sentence"
        case .repeatSentence: return "Repeat Sentence"
        case .playSpeed: return "Speed"
        case .primaryWaveform: return "Primary Waveform"
        case .secondaryWaveform: return "Secondary Waveform (Fine-tuning)"
        case .segmentList: return "Sentence List"
        case .noFileLoaded: return "No Media Loaded"
        case .dragDropPrompt: return "Drag & drop audio/video file here, or click Open"
        case .sentenceIndex(let i): return "Sentence #\(i)"
        case .duration(let d): return "Duration: \(d)"
        case .startAnchor: return "Start Anchor"
        case .endAnchor: return "End Anchor"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .resetZoom: return "Reset Zoom"
        case .loopModeSingle: return "Repeat Sentence"
        case .loopModeAll: return "Loop Entire File"
        case .loopModePauseAfterSentence: return "Pause After Sentence"
        case .loopModeNormal: return "Continuous Play"
        case .timecodeFormat: return "Timecode"
        case .addSegment: return "Add Sentence"
        case .deleteSegment: return "Delete Sentence"
        case .splitSegment: return "Split Sentence"
        case .mergeSegment: return "Merge with Next"
        case .editSentenceText: return "Edit Subtitle/Text"
        case .language: return "Language / 语言"
        case .videoTrack: return "Video View"
        case .audioTrack: return "Audio Mode"
        case .extractingWaveform: return "Extracting audio waveform..."
        case .volume: return "Volume"
        case .errorLoadingMedia: return "Failed to load media file"
        case .decoderEngine: return "Decoding Engine"
        case .decoderModeSystem: return "System Decoding (Native AVPlayer)"
        case .decoderModeMPV: return "libmpv Decoding (libmpv Engine)"
        case .decoderModeHybrid: return "Hybrid Decoding (Auto Recommended)"
        case .hideWaveforms: return "Hide Waveforms (Maximize Video)"
        case .showWaveforms: return "Show Waveforms"
        }
    }
}

// SwiftUI 辅助扩展
public extension View {
    func loc(_ key: LocalizedKey) -> String {
        LanguageManager.shared.localized(key)
    }
}
