import Foundation

/// 媒体文件元信息模型
public struct MediaItem: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let duration: Double
    public let isVideo: Bool
    public let fileSize: Int64
    
    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        duration: Double = 0,
        isVideo: Bool = false,
        fileSize: Int64 = 0
    ) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.isVideo = isVideo
        self.fileSize = fileSize
    }
    
    public var formattedDuration: String {
        SentenceSegment.formatTimecode(duration)
    }
    
    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

/// 播放与复读循环模式
public enum PlaybackLoopMode: String, CaseIterable, Identifiable {
    case normal = "normal"               // 连续播放
    case singleSegment = "singleSegment" // 单句循环 (AB复读)
    case pauseAfterSegment = "pauseAfter" // 播放完当前句后自动暂停
    case all = "all"                     // 全曲循环
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .normal: return "arrow.forward"
        case .singleSegment: return "repeat.1"
        case .pauseAfterSegment: return "pause.circle"
        case .all: return "repeat"
        }
    }
    
    public func localized(with lang: LanguageManager = .shared) -> String {
        switch self {
        case .normal: return lang.localized(.loopModeNormal)
        case .singleSegment: return lang.localized(.loopModeSingle)
        case .pauseAfterSegment: return lang.localized(.loopModePauseAfterSentence)
        case .all: return lang.localized(.loopModeAll)
        }
    }
}
