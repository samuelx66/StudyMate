import Foundation
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

/// 单个断句模型
public struct SentenceSegment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var index: Int
    public var startTime: Double // 秒 (精确到毫秒)
    public var endTime: Double   // 秒 (精确到毫秒)
    public var text: String
    public var translation: String
    public var note: String
    /// 独立于“难句收藏”星标的列表导航书签。
    /// 该标记只用于在“显示 > 书签”中快速定位句子。
    public var isNavigationBookmarked: Bool
    public var isBookmarked: Bool
    /// Speaker labels that participate in this sentence. The list may contain
    /// multiple speakers who took turns; `isSpeakerOverlap` is reserved for
    /// speakers that were active at the same time.
    public var speakerID: Int?
    public var speakerIDs: [Int]
    public var isSpeakerOverlap: Bool
    public var speakerRole: String?
    public var phoneticText: String?
    public var associatedWords: [StudyMatePackageVocabularyCard]?
    public var wordTokens: [StudyMatePackageWordToken]?
    public var originalIndex: Int?
    public var contextBefore: String?
    public var contextAfter: String?
    public var sourceMediaName: String?
    public var sourceStartTime: Double?
    
    public init(
        id: UUID = UUID(),
        index: Int,
        originalIndex: Int? = nil,
        startTime: Double,
        endTime: Double,
        text: String = "",
        translation: String = "",
        note: String = "",
        isNavigationBookmarked: Bool = false,
        isBookmarked: Bool = false,
        speakerID: Int? = nil,
        speakerIDs: [Int] = [],
        isSpeakerOverlap: Bool = false,
        speakerRole: String? = nil,
        phoneticText: String? = nil,
        associatedWords: [StudyMatePackageVocabularyCard]? = nil,
        wordTokens: [StudyMatePackageWordToken]? = nil,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        sourceMediaName: String? = nil,
        sourceStartTime: Double? = nil
    ) {
        let safeStart = startTime.isFinite ? max(0, startTime) : 0
        let safeEnd = endTime.isFinite ? endTime : safeStart + 0.05
        self.id = id
        self.index = index
        self.originalIndex = originalIndex
        self.startTime = safeStart
        self.endTime = max(safeStart + 0.05, safeEnd)
        self.text = text
        self.translation = translation
        self.note = note
        self.isNavigationBookmarked = isNavigationBookmarked
        self.isBookmarked = isBookmarked
        var normalizedSpeakerIDs = Set(speakerIDs)
        if let speakerID { normalizedSpeakerIDs.insert(speakerID) }
        self.speakerIDs = normalizedSpeakerIDs.sorted()
        self.speakerID = speakerID ?? (self.speakerIDs.count == 1 ? self.speakerIDs[0] : nil)
        self.isSpeakerOverlap = isSpeakerOverlap
        self.speakerRole = speakerRole
        self.phoneticText = phoneticText
        self.associatedWords = associatedWords
        self.wordTokens = wordTokens
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.sourceMediaName = sourceMediaName
        self.sourceStartTime = sourceStartTime
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, originalIndex, startTime, endTime, text, translation, note, isNavigationBookmarked, isBookmarked,
             speakerID, speakerIDs, isSpeakerOverlap, speakerRole, phoneticText, associatedWords,
             wordTokens, contextBefore, contextAfter, sourceMediaName, sourceStartTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedID: UUID
        if let directUUID = try? container.decodeIfPresent(UUID.self, forKey: .id) {
            resolvedID = directUUID
        } else if let stringID = try? container.decodeIfPresent(String.self, forKey: .id),
                  let parsed = UUID(uuidString: stringID) {
            resolvedID = parsed
        } else {
            resolvedID = UUID()
        }
        self.init(
            id: resolvedID,
            index: (try? container.decodeIfPresent(Int.self, forKey: .index)) ?? 0,
            originalIndex: try? container.decodeIfPresent(Int.self, forKey: .originalIndex),
            startTime: (try? container.decodeIfPresent(Double.self, forKey: .startTime)) ?? 0,
            endTime: (try? container.decodeIfPresent(Double.self, forKey: .endTime)) ?? 0.05,
            text: (try? container.decodeIfPresent(String.self, forKey: .text)) ?? "",
            translation: (try? container.decodeIfPresent(String.self, forKey: .translation)) ?? "",
            note: (try? container.decodeIfPresent(String.self, forKey: .note)) ?? "",
            isNavigationBookmarked: (try? container.decodeIfPresent(Bool.self, forKey: .isNavigationBookmarked)) ?? false,
            isBookmarked: (try? container.decodeIfPresent(Bool.self, forKey: .isBookmarked)) ?? false,
            speakerID: try? container.decodeIfPresent(Int.self, forKey: .speakerID),
            speakerIDs: (try? container.decodeIfPresent([Int].self, forKey: .speakerIDs)) ?? [],
            isSpeakerOverlap: (try? container.decodeIfPresent(Bool.self, forKey: .isSpeakerOverlap)) ?? false,
            speakerRole: try? container.decodeIfPresent(String.self, forKey: .speakerRole),
            phoneticText: try? container.decodeIfPresent(String.self, forKey: .phoneticText),
            associatedWords: try? container.decodeIfPresent([StudyMatePackageVocabularyCard].self, forKey: .associatedWords),
            wordTokens: try? container.decodeIfPresent([StudyMatePackageWordToken].self, forKey: .wordTokens),
            contextBefore: try? container.decodeIfPresent(String.self, forKey: .contextBefore),
            contextAfter: try? container.decodeIfPresent(String.self, forKey: .contextAfter),
            sourceMediaName: try? container.decodeIfPresent(String.self, forKey: .sourceMediaName),
            sourceStartTime: try? container.decodeIfPresent(Double.self, forKey: .sourceStartTime)
        )
    }
    
    public var duration: Double {
        max(0, endTime - startTime)
    }
    
    public func contains(time: Double) -> Bool {
        time >= startTime && time < endTime
    }
    
    public var formattedStartTime: String {
        SentenceSegment.formatTimecode(startTime)
    }
    
    public var formattedEndTime: String {
        SentenceSegment.formatTimecode(endTime)
    }
    
    public var formattedDuration: String {
        String(format: "%.2fs", duration)
    }

    /// 角色/说话人标签（优先使用自定义 speakerRole，如 "Jim"；若无则回退到 s1, s2 等；重叠时如 s1+s2，轮替时如 s1→s2；无角色时返回空字符串）
    public var speakerRoleLabel: String {
        if let role = speakerRole, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return role
        }
        guard !speakerIDs.isEmpty else { return "" }
        let labels = speakerIDs.map { "s\($0 + 1)" }
        if isSpeakerOverlap {
            return labels.joined(separator: "+")
        }
        if labels.count > 1 {
            return labels.joined(separator: "→")
        }
        return labels[0]
    }
    
    public static func formatTimecode(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite && seconds >= 0 else {
            return "00:00.000"
        }
        let roundedMilliseconds = Int((seconds * 1000).rounded())
        let totalMs = roundedMilliseconds % 1000
        let totalSecs = roundedMilliseconds / 1000
        let mins = (totalSecs / 60) % 60
        let hours = totalSecs / 3600
        let secs = totalSecs % 60

        let msStr: String
        if totalMs < 10 {
            msStr = "00\(totalMs)"
        } else if totalMs < 100 {
            msStr = "0\(totalMs)"
        } else {
            msStr = "\(totalMs)"
        }

        let secStr = secs < 10 ? "0\(secs)" : "\(secs)"
        let minStr = mins < 10 ? "0\(mins)" : "\(mins)"

        if hours > 0 {
            let hourStr = hours < 10 ? "0\(hours)" : "\(hours)"
            return "\(hourStr):\(minStr):\(secStr).\(msStr)"
        } else {
            return "\(minStr):\(secStr).\(msStr)"
        }
    }

    /// 将秒数格式化为原片坐标标准时间戳（HH:mm:ss，如 00:15:23）
    public static func formatCoordinateTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite && seconds >= 0 else {
            return "00:00:00"
        }
        let totalSecs = Int(seconds.rounded(.down))
        let hours = totalSecs / 3600
        let mins = (totalSecs / 60) % 60
        let secs = totalSecs % 60
        return String(format: "%02d:%02d:%02d", hours, mins, secs)
    }

    /// 原片坐标描述小字，形如：
    /// 来源：阿甘正传.mp4 · #88 (00:15:23)
    public func formattedCoordinate(language: AppLanguage = .zh) -> String? {
        let origIdx = (originalIndex != nil && originalIndex! > 0) ? originalIndex : nil
        let media = sourceMediaName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMedia = media != nil && !media!.isEmpty

        guard hasMedia || origIdx != nil else { return nil }

        let time = sourceStartTime ?? startTime
        let timeStr = SentenceSegment.formatCoordinateTime(time)

        if let media, !media.isEmpty {
            if let idx = origIdx {
                return language == .en
                    ? "Source: \(media) · #\(idx) (\(timeStr))"
                    : "来源：\(media) · 原#\(idx) (\(timeStr))"
            } else {
                return language == .en
                    ? "Source: \(media) (\(timeStr))"
                    : "来源：\(media) (\(timeStr))"
            }
        } else if let idx = origIdx {
            return language == .en
                ? "Orig #\(idx) (\(timeStr))"
                : "原片 #\(idx) (\(timeStr))"
        }
        return nil
    }
}

// MARK: - 词级时间戳调和与文本对齐（Reconciliation）

extension SentenceSegment {
    /// 对比目标原文与底层词级时间戳（Whisper wordTokens），在文本发生修改（如订正错别字 "buck" -> "book"、增删词语等）时
    /// 自动将词级时间戳对齐映射到新文本，保留词级起止时间、卡拉OK高亮与发音音标；
    /// 若文本发生大幅变更无法对齐，则优雅返回 nil 以回退至常规原文视图。
    public func reconciledWordTokens(for targetText: String? = nil) -> [StudyMatePackageWordToken]? {
        Self.reconcileWordTokens(for: targetText ?? text, baseTokens: wordTokens)
    }

    /// 静态调和方法，支持任意文本与 token 序列的对齐重构
    public static func reconcileWordTokens(
        for targetText: String,
        baseTokens: [StudyMatePackageWordToken]?
    ) -> [StudyMatePackageWordToken]? {
        guard let baseTokens, !baseTokens.isEmpty else { return nil }
        let resolved = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }

        // 1. 分词抽取
        let words = extractWords(from: resolved, baseTokenCount: baseTokens.count)
        guard !words.isEmpty else { return nil }

        // 2. 快速路径：分词数量与 token 数量一致
        if words.count == baseTokens.count {
            // 完全一致时直接复用原数组
            if zip(words, baseTokens).allSatisfy({ $0.0 == $0.1.text }) {
                return baseTokens
            }

            // 检查词形相似度（如错别字订正 "buck" -> "book"）
            let matchScores = zip(words, baseTokens).map { wordSimilarity($0.0, $0.1.text) }
            let positiveCount = matchScores.filter { $0 > 0 }.count
            // 只要有半数以上（或至少 1 个词）相似，即可直接 1:1 投影，完美保留起止时间
            if positiveCount >= max(1, words.count / 2) {
                return zip(words, baseTokens).map { word, token in
                    StudyMatePackageWordToken(
                        text: word,
                        startTime: token.startTime,
                        endTime: token.endTime,
                        confidence: token.confidence
                    )
                }
            }
        }

        // 3. 通用路径：动态规划序列对齐（Needleman-Wunsch）
        return alignWordsWithTokens(words: words, baseTokens: baseTokens)
    }

    private static func extractWords(from text: String, baseTokenCount: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains(where: \.isWhitespace) {
            return trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        if baseTokenCount <= 1 {
            return [trimmed]
        }
        // 无空格的多 token 语言（如中文、日文字符逐字对齐）
        return trimmed.map(String.init)
    }

    private static func wordSimilarity(_ w1: String, _ w2: String) -> Double {
        let punc = CharacterSet.punctuationCharacters.union(.symbols)
        let s1 = w1.trimmingCharacters(in: punc).lowercased()
        let s2 = w2.trimmingCharacters(in: punc).lowercased()
        if s1 == s2 {
            return 2.0
        }
        if s1.isEmpty || s2.isEmpty {
            return 0.0
        }
        let len = max(s1.count, s2.count)
        let dist = levenshteinDistance(s1, s2)
        if dist == 1 {
            return 1.4 // 极近（如单字母拼写订正）
        }
        if dist == 2 && len >= 4 {
            return 1.0 // 较近（如 4 字母以上词语修正 2 个字母）
        }
        let simRatio = 1.0 - (Double(dist) / Double(len))
        if simRatio >= 0.5 {
            return 0.8
        }
        return -1.0
    }

    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = curr
        }
        return prev[b.count]
    }

    private static func alignWordsWithTokens(
        words: [String],
        baseTokens: [StudyMatePackageWordToken]
    ) -> [StudyMatePackageWordToken]? {
        let n = words.count
        let m = baseTokens.count
        guard n > 0 && m > 0 else { return nil }

        let gapPenalty = -0.8
        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)

        for i in 0...n { dp[i][0] = Double(i) * gapPenalty }
        for j in 0...m { dp[0][j] = Double(j) * gapPenalty }

        for i in 1...n {
            for j in 1...m {
                let sim = wordSimilarity(words[i - 1], baseTokens[j - 1].text)
                let match = dp[i - 1][j - 1] + sim
                let insertWord = dp[i - 1][j] + gapPenalty
                let deleteToken = dp[i][j - 1] + gapPenalty
                dp[i][j] = max(match, insertWord, deleteToken)
            }
        }

        // 回溯找出对齐关系 (wordIndex -> tokenIndex)
        var i = n
        var j = m
        var alignedMap: [Int: Int] = [:]
        var positiveCount = 0

        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let sim = wordSimilarity(words[i - 1], baseTokens[j - 1].text)
                if abs(dp[i][j] - (dp[i - 1][j - 1] + sim)) < 1e-6 {
                    if sim > 0 {
                        alignedMap[i - 1] = j - 1
                        positiveCount += 1
                    }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0 && abs(dp[i][j] - (dp[i - 1][j] + gapPenalty)) < 1e-6 {
                i -= 1
            } else if j > 0 {
                j -= 1
            } else {
                break
            }
        }

        // 若正向匹配度极低（低于 25% 且不足 1 个匹配），说明原句被完全重写，返回 nil 优雅降级
        let maxLen = max(n, m)
        guard positiveCount > 0, (Double(positiveCount) / Double(maxLen)) >= 0.25 else {
            return nil
        }

        // 重建对齐 tokens，针对未对齐的插入词平滑插值时间戳
        var result: [StudyMatePackageWordToken] = []
        result.reserveCapacity(n)

        for wIdx in 0..<n {
            let wordText = words[wIdx]
            if let tIdx = alignedMap[wIdx] {
                let base = baseTokens[tIdx]
                result.append(StudyMatePackageWordToken(
                    text: wordText,
                    startTime: base.startTime,
                    endTime: base.endTime,
                    confidence: base.confidence
                ))
            } else {
                // 寻找前后最近的对齐时间点
                let prevTime: Double = {
                    for prevIdx in stride(from: wIdx - 1, through: 0, by: -1) {
                        if let prevT = alignedMap[prevIdx] {
                            return baseTokens[prevT].endTime
                        }
                    }
                    if let firstAligned = alignedMap.keys.sorted().first,
                       let tIdx = alignedMap[firstAligned] {
                        let distance = Double(firstAligned - wIdx)
                        return max(0, baseTokens[tIdx].startTime - 0.25 * distance)
                    }
                    return 0
                }()

                let nextTime: Double = {
                    for nextIdx in (wIdx + 1)..<n {
                        if let nextT = alignedMap[nextIdx] {
                            return baseTokens[nextT].startTime
                        }
                    }
                    if let lastAligned = alignedMap.keys.sorted().last,
                       let tIdx = alignedMap[lastAligned] {
                        let distance = Double(wIdx - lastAligned)
                        return baseTokens[tIdx].endTime + 0.25 * distance
                    }
                    return prevTime + 0.3
                }()

                let start = max(0, prevTime)
                let end = max(start + 0.05, nextTime)
                result.append(StudyMatePackageWordToken(
                    text: wordText,
                    startTime: start,
                    endTime: end,
                    confidence: 0.8
                ))
            }
        }

        // 保证时间戳单调递增
        var finalTokens: [StudyMatePackageWordToken] = []
        var lastEnd: Double = 0
        for token in result {
            let start = max(token.startTime, lastEnd)
            let end = max(start + 0.05, token.endTime)
            lastEnd = end
            finalTokens.append(StudyMatePackageWordToken(
                text: token.text,
                startTime: start,
                endTime: end,
                confidence: token.confidence
            ))
        }

        return finalTokens
    }
}

