import Foundation

/// 字幕与断句导出引擎
public final class SubtitleExporter {
    public static let shared = SubtitleExporter()
    
    public init() {}
    
    /// 导出为标准 SRT 格式字符串
    public func exportToSRT(segments: [SentenceSegment], includeTranslation: Bool = true) -> String {
        var srtContent = ""
        
        for (i, seg) in segments.enumerated() {
            let index = i + 1
            let startSRT = formatSRTTimestamp(seg.startTime)
            let endSRT = formatSRTTimestamp(seg.endTime)
            
            srtContent += "\(index)\n"
            srtContent += "\(startSRT) --> \(endSRT)\n"
            srtContent += "\(seg.text)\n"
            
            if includeTranslation && !seg.translation.isEmpty {
                srtContent += "\(seg.translation)\n"
            }
            srtContent += "\n"
        }
        
        return srtContent
    }
    
    /// 导出为标准 LRC 歌词格式字符串
    public func exportToLRC(segments: [SentenceSegment], title: String = "") -> String {
        var lrcContent = ""
        if !title.isEmpty {
            lrcContent += "[ti:\(title)]\n"
        }
        
        for seg in segments {
            let timeLRC = formatLRCTimestamp(seg.startTime)
            let text = seg.text.isEmpty ? "(music)" : seg.text
            lrcContent += "[\(timeLRC)]\(text)\n"
        }
        
        return lrcContent
    }
    
    /// 格式化为 00:01:23,456
    private func formatSRTTimestamp(_ seconds: Double) -> String {
        let safeSecs = seconds.isFinite ? max(0, seconds) : 0
        let rounded = Int((safeSecs * 1000).rounded())
        let totalMs = rounded % 1000
        let totalSecs = rounded / 1000
        let hours = totalSecs / 3600
        let mins = (totalSecs / 60) % 60
        let secs = totalSecs % 60
        
        return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, totalMs)
    }
    
    /// 格式化为 01:23.45
    private func formatLRCTimestamp(_ seconds: Double) -> String {
        let safeSecs = seconds.isFinite ? max(0, seconds) : 0
        let rounded = Int((safeSecs * 100).rounded())
        let totalCentiSecs = rounded % 100
        let totalSecs = rounded / 100
        let mins = totalSecs / 60
        let secs = totalSecs % 60
        
        return String(format: "%02d:%02d.%02d", mins, secs, totalCentiSecs)
    }
}
