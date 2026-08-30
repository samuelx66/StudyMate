import Foundation

/// 多媒体解码引擎模式选项
public enum DecoderEngineMode: String, CaseIterable, Identifiable {
    case system = "system"
    case mpv = "mpv"
    case hybrid = "hybrid"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .system:
            return LanguageManager.shared.localized(.decoderModeSystem)
        case .mpv:
            return LanguageManager.shared.localized(.decoderModeMPV)
        case .hybrid:
            return LanguageManager.shared.localized(.decoderModeHybrid)
        }
    }
}
