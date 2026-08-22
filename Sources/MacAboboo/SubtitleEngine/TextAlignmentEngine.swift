import Foundation

/// 纯文本句法拆分与音频 VAD 时间轴对齐引擎
public final class TextAlignmentEngine {
    public static let shared = TextAlignmentEngine()
    
    public init() {}
    
    /// 将大段纯文本根据中英文标点拆分成独立句子
    public func splitTextIntoSentences(_ rawText: String) -> [String] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        // 常见缩写保护（如 Mr., Dr., U.S., etc.）
        var processed = normalized
        let abbreviations = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "U.S.", "e.g.", "i.e.", "etc."]
        for abbr in abbreviations {
            let safeToken = abbr.replacingOccurrences(of: ".", with: "@@DOT@@")
            processed = processed.replacingOccurrences(of: abbr, with: safeToken)
        }
        
        // 标点断句分隔符：。！？! ? \n 或 句末英文句号后跟空格
        let pattern = "(?<=[。！？!?\\n])|(?<=\\.)\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return rawText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        
        let nsString = processed as NSString
        let matches = regex.matches(in: processed, range: NSRange(location: 0, length: nsString.length))
        
        var sentences = [String]()
        var lastLocation = 0
        
        for match in matches {
            let range = NSRange(location: lastLocation, length: match.range.location - lastLocation)
            if range.length > 0 {
                let sentence = nsString.substring(with: range)
                    .replacingOccurrences(of: "@@DOT@@", with: ".")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
            }
            lastLocation = match.range.location + match.range.length
        }
        
        if lastLocation < nsString.length {
            let sentence = nsString.substring(from: lastLocation)
                .replacingOccurrences(of: "@@DOT@@", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        
        return sentences
    }
    
    /// 将纯文本句子列表与已有音频 VAD 语音断句进行动态时间轴对齐
    /// - Parameters:
    ///   - sentences: 拆分后的文本句子列表
    ///   - baseSegments: 已由 VAD 生成的无字幕音频时间段列表
    ///   - totalDuration: 媒体总时长
    /// - Returns: 对齐后的断句列表
    public func alignSentences(
        _ sentences: [String],
        with baseSegments: [SentenceSegment],
        totalDuration: Double
    ) -> [SentenceSegment] {
        let cleanedSentences = sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedSentences.isEmpty else { return baseSegments }
        
        // 场景 1：如果已有 VAD 断句且数量与文本相近
        if !baseSegments.isEmpty {
            if cleanedSentences.count == baseSegments.count {
                var aligned = [SentenceSegment]()
                for i in 0..<cleanedSentences.count {
                    var seg = baseSegments[i]
                    seg.text = cleanedSentences[i]
                    aligned.append(seg)
                }
                return aligned
            } else if cleanedSentences.count < baseSegments.count {
                // 文本句子比 VAD 少：合并部分较短的相邻 VAD 语音片段
                let ratio = Double(baseSegments.count) / Double(cleanedSentences.count)
                var aligned = [SentenceSegment]()
                
                for (sIdx, text) in cleanedSentences.enumerated() {
                    let startVADIdx = Int(Double(sIdx) * ratio)
                    let endVADIdx = min(baseSegments.count - 1, Int(Double(sIdx + 1) * ratio) - 1)
                    
                    let start = baseSegments[startVADIdx].startTime
                    let end = baseSegments[max(startVADIdx, endVADIdx)].endTime
                    
                    aligned.append(SentenceSegment(
                        index: sIdx + 1,
                        startTime: start,
                        endTime: end,
                        text: text
                    ))
                }
                return aligned
            } else {
                // 文本句子比 VAD 多：按比例将句子精确分配到各 VAD 语音段，并在语音段内细分时间
                var aligned = [SentenceSegment]()
                let sentenceCount = cleanedSentences.count
                let vadCount = baseSegments.count
                
                for (vadIdx, vadSeg) in baseSegments.enumerated() {
                    let startSentenceIdx = Int(Double(vadIdx * sentenceCount) / Double(vadCount))
                    let endSentenceIdx = Int(Double((vadIdx + 1) * sentenceCount) / Double(vadCount))
                    let segSentences = Array(cleanedSentences[startSentenceIdx..<endSentenceIdx])
                    
                    if segSentences.isEmpty {
                        continue
                    } else if segSentences.count == 1 {
                        aligned.append(SentenceSegment(
                            index: aligned.count + 1,
                            startTime: vadSeg.startTime,
                            endTime: vadSeg.endTime,
                            text: segSentences[0]
                        ))
                    } else {
                        // 在当前 VAD 语音段内按字符长度分配子时间
                        let totalChars = max(1, segSentences.reduce(0) { $0 + max(1, $1.count) })
                        var subStart = vadSeg.startTime
                        let segDuration = vadSeg.duration
                        var consumedChars = 0
                        
                        for (subIdx, text) in segSentences.enumerated() {
                            consumedChars += max(1, text.count)
                            let subEnd = subIdx == segSentences.count - 1
                                ? vadSeg.endTime
                                : vadSeg.startTime + segDuration * Double(consumedChars) / Double(totalChars)
                            
                            aligned.append(SentenceSegment(
                                index: aligned.count + 1,
                                startTime: subStart,
                                endTime: subEnd,
                                text: text
                            ))
                            subStart = subEnd
                        }
                    }
                }
                
                return aligned
            }
        }
        
        // 场景 2：完全没有 VAD 数据时，按句子字符长度均匀比例估算时间轴
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        let totalChars = max(1, cleanedSentences.reduce(0) { $0 + max(1, $1.count) })
        var aligned = [SentenceSegment]()
        var curTime = 0.0
        var consumedChars = 0
        
        for (i, text) in cleanedSentences.enumerated() {
            consumedChars += max(1, text.count)
            let nextTime = i == cleanedSentences.count - 1
                ? totalDuration
                : totalDuration * Double(consumedChars) / Double(totalChars)
            
            aligned.append(SentenceSegment(
                index: i + 1,
                startTime: curTime,
                endTime: nextTime,
                text: text
            ))
            curTime = nextTime
        }
        
        return aligned
    }
}
