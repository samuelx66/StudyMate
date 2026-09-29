import Foundation
import CoreFoundation
import CoreServices
import NaturalLanguage
import SwiftUI

public final class PhoneticEngineManager: ObservableObject, @unchecked Sendable {
    public static let shared = PhoneticEngineManager()
    
    private let userDefaultsKey = "StudyMate.ShowPhonetics"
    @Published public var showPhonetics: Bool = false

    private init() {
        self.showPhonetics = UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    public func togglePhonetics() {
        showPhonetics.toggle()
        UserDefaults.standard.set(showPhonetics, forKey: userDefaultsKey)
        let isEn = LanguageManager.shared.currentLanguage == .en
        let msg = showPhonetics
            ? (isEn ? "Phonetics display enabled" : "已开启注音显示")
            : (isEn ? "Phonetics display hidden" : "已隐藏注音显示")
        Task { @MainActor in
            MainStatusCenter.shared.showInfo(msg)
        }
    }

    public func setPhoneticsVisible(_ visible: Bool) {
        guard showPhonetics != visible else { return }
        showPhonetics = visible
        UserDefaults.standard.set(visible, forKey: userDefaultsKey)
        let isEn = LanguageManager.shared.currentLanguage == .en
        let msg = showPhonetics
            ? (isEn ? "Phonetics display enabled" : "已开启注音显示")
            : (isEn ? "Phonetics display hidden" : "已隐藏注音显示")
        Task { @MainActor in
            MainStatusCenter.shared.showInfo(msg)
        }
    }

    public func phoneticText(for text: String, language: String? = nil) -> String? {
        let p = PhoneticEngine.generatePhonetics(for: text, language: language)
        return p.isEmpty ? nil : p
    }
}

/// 原生自动注音引擎：基于 CoreFoundation、CoreServices 与 NaturalLanguage 提供零外部依赖、
/// 高性能的英文音标（IPA）、中文拼音（Pinyin）与日文假名（Furigana）解析能力。
public enum PhoneticEngine {
    public static var shared: PhoneticEngineManager { PhoneticEngineManager.shared }

    public static func phoneticText(for text: String, language: String? = nil) -> String? {
        shared.phoneticText(for: text, language: language)
    }

    /// 注音文本片段模型，用于 UI 呈现 Ruby 效果
    public struct Segment: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let text: String
        public let phonetic: String?

        public init(id: UUID = UUID(), text: String, phonetic: String? = nil) {
            self.id = id
            self.text = text
            self.phonetic = phonetic
        }
    }

    // MARK: - 英文 IPA 词典高速缓存

    private static let dcsPhoneticCache = NSCache<NSString, NSString>()

    /// 提取英文单词的国际音标 (IPA)
    public static func lookupEnglishIPA(for word: String) -> String? {
        let cleaned = word.trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()
        let cacheKey = lower as NSString

        if let cached = dcsPhoneticCache.object(forKey: cacheKey) {
            let str = cached as String
            return str.isEmpty ? nil : str
        }

        func queryDCS(_ term: String) -> String? {
            let cfTerm = term as CFString
            guard let defRef = DCSCopyTextDefinition(nil, cfTerm, CFRangeMake(0, CFStringGetLength(cfTerm))) else {
                return nil
            }
            let def = defRef.takeRetainedValue() as String
            // 匹配字典中的标准国际音标：/.../ 或 //...// 或 |...|
            if let match = def.range(of: #"(?:/|//|\|)([^/|\n\r]{1,40})(?:/|//|\|)"#, options: .regularExpression) {
                let raw = String(def[match]).trimmingCharacters(in: CharacterSet(charactersIn: "/| "))
                if !raw.isEmpty {
                    return "/\(raw)/"
                }
            }
            return nil
        }

        if let res = queryDCS(cleaned) ?? queryDCS(lower) {
            dcsPhoneticCache.setObject(res as NSString, forKey: cacheKey)
            return res
        }

        // 尝试词形还原（例如 running -> run, cats -> cat）后再次查词
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = lower
        tagger.setLanguage(.english, range: lower.startIndex..<lower.endIndex)
        let (tag, _) = tagger.tag(at: lower.startIndex, unit: .word, scheme: .lemma)
        if let lemma = tag?.rawValue, lemma != lower, let res = queryDCS(lemma) {
            dcsPhoneticCache.setObject(res as NSString, forKey: cacheKey)
            return res
        }

        dcsPhoneticCache.setObject("" as NSString, forKey: cacheKey)
        return nil
    }

    /// 根据语种和文本自动生成完整注音文本行
    public static func generatePhonetics(for text: String, language: String? = nil) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let detectedLang = language ?? detectLanguage(for: trimmed)
        if detectedLang.hasPrefix("zh") || containsChinese(trimmed) {
            return generateChinesePinyin(for: trimmed)
        } else if detectedLang.hasPrefix("ja") || containsJapanese(trimmed) {
            return generateJapaneseFurigana(for: trimmed)
        } else {
            return generateLatinPhonetics(for: trimmed)
        }
    }

    /// 将整段句子拆解为带对应注音的片段列表，便于在 5 大模式下进行紧凑双行吸附排版
    public static func buildSegments(for text: String, language: String? = nil) -> [Segment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let detectedLang = language ?? detectLanguage(for: trimmed)
        if detectedLang.hasPrefix("zh") || containsChinese(trimmed) {
            return buildChineseSegments(for: trimmed)
        } else if detectedLang.hasPrefix("ja") || containsJapanese(trimmed) {
            return buildJapaneseSegments(for: trimmed)
        } else {
            return buildLatinSegments(for: trimmed)
        }
    }

    // MARK: - 中文拼音 (Mandarin Pinyin)

    public static func generateChinesePinyin(for text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        return mutable as String
    }

    private static func buildChineseSegments(for text: String) -> [Segment] {
        var segments: [Segment] = []
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, CFStringGetLength(text as CFString)),
            kCFStringTokenizerUnitWord,
            Locale(identifier: "zh_CN") as CFLocale
        )

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        var lastLocation = 0

        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > lastLocation {
                let leadRange = NSRange(location: lastLocation, length: range.location - lastLocation)
                let punctuation = (text as NSString).substring(with: leadRange)
                segments.append(Segment(text: punctuation, phonetic: nil))
            }

            let word = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if containsChinese(word) {
                let fullPinyin = generateChinesePinyin(for: word)
                let pinyinTokens = fullPinyin.components(separatedBy: " ").filter { !$0.isEmpty }
                let chars = Array(word).map { String($0) }
                if pinyinTokens.count == chars.count {
                    for (ch, py) in zip(chars, pinyinTokens) {
                        segments.append(Segment(text: ch, phonetic: py))
                    }
                } else {
                    for ch in chars {
                        if containsChinese(ch) {
                            segments.append(Segment(text: ch, phonetic: generateChinesePinyin(for: ch)))
                        } else {
                            segments.append(Segment(text: ch, phonetic: nil))
                        }
                    }
                }
            } else {
                let isWordLike = word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                let ipa = isWordLike ? lookupEnglishIPA(for: word) : nil
                segments.append(Segment(text: word, phonetic: ipa))
            }

            lastLocation = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        if lastLocation < (text as NSString).length {
            let tail = (text as NSString).substring(from: lastLocation)
            segments.append(Segment(text: tail, phonetic: nil))
        }

        return segments.isEmpty ? [Segment(text: text, phonetic: generateChinesePinyin(for: text))] : segments
    }

    // MARK: - 日文振假名 (Japanese Furigana)

    public static func generateJapaneseFurigana(for text: String) -> String {
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, CFStringGetLength(text as CFString)),
            kCFStringTokenizerUnitWord,
            Locale(identifier: "ja_JP") as CFLocale
        )

        var result: [String] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)

        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let word = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if containsKanji(word),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let mut = NSMutableString(string: latin)
                CFStringTransform(mut, nil, kCFStringTransformLatinHiragana, false)
                result.append(mut as String)
            } else {
                result.append(word)
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return result.joined()
    }

    private static func buildJapaneseSegments(for text: String) -> [Segment] {
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, CFStringGetLength(text as CFString)),
            kCFStringTokenizerUnitWord,
            Locale(identifier: "ja_JP") as CFLocale
        )

        var segments: [Segment] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        var lastLocation = 0

        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > lastLocation {
                let leadRange = NSRange(location: lastLocation, length: range.location - lastLocation)
                let sep = (text as NSString).substring(with: leadRange)
                segments.append(Segment(text: sep, phonetic: nil))
            }

            let word = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if containsKanji(word),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let mut = NSMutableString(string: latin)
                CFStringTransform(mut, nil, kCFStringTransformLatinHiragana, false)
                segments.append(Segment(text: word, phonetic: mut as String))
            } else {
                segments.append(Segment(text: word, phonetic: nil))
            }

            lastLocation = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        if lastLocation < (text as NSString).length {
            let tail = (text as NSString).substring(from: lastLocation)
            segments.append(Segment(text: tail, phonetic: nil))
        }

        return segments.isEmpty ? [Segment(text: text, phonetic: nil)] : segments
    }

    // MARK: - 英文 / 拉丁语系国际音标 (IPA)

    private static func generateLatinPhonetics(for text: String) -> String {
        let segments = buildLatinSegments(for: text)
        let phonetics = segments.compactMap { $0.phonetic }
        return phonetics.joined(separator: " ")
    }

    private static func buildLatinSegments(for text: String) -> [Segment] {
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, CFStringGetLength(text as CFString)),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "en_US") as CFLocale
        )

        var segments: [Segment] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        var lastLocation = 0

        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > lastLocation {
                let sepRange = NSRange(location: lastLocation, length: range.location - lastLocation)
                let sep = (text as NSString).substring(with: sepRange)
                segments.append(Segment(text: sep, phonetic: nil))
            }

            let word = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            let isWordLike = word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            let ipa = isWordLike ? lookupEnglishIPA(for: word) : nil
            segments.append(Segment(text: word, phonetic: ipa))

            lastLocation = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        if lastLocation < (text as NSString).length {
            let tail = (text as NSString).substring(from: lastLocation)
            segments.append(Segment(text: tail, phonetic: nil))
        }

        return segments.isEmpty ? [Segment(text: text, phonetic: nil)] : segments
    }

    // MARK: - 辅助检测函数

    public static func detectLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    public static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    public static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    public static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}

// MARK: - SwiftUI Ruby 动态排版组件

public struct RubyTextView: View {
    public let text: String
    public let fontSize: CGFloat
    public let textColor: Color
    public let phoneticColor: Color
    public let isPhoneticsVisible: Bool

    public init(
        text: String,
        fontSize: CGFloat = 16,
        textColor: Color = .primary,
        phoneticColor: Color? = nil,
        isPhoneticsVisible: Bool = true
    ) {
        self.text = text
        self.fontSize = fontSize
        self.textColor = textColor
        self.phoneticColor = phoneticColor ?? StudyMateMediaStyle.accent
        self.isPhoneticsVisible = isPhoneticsVisible
    }

    public var body: some View {
        if !isPhoneticsVisible {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(textColor)
        } else {
            let segments = PhoneticEngine.buildSegments(for: text)
            let hasAnyPhonetic = segments.contains { $0.phonetic != nil }
            if !hasAnyPhonetic {
                Text(text)
                    .font(.system(size: fontSize))
                    .foregroundColor(textColor)
            } else {
                RubyFlowLayout(horizontalSpacing: 2, verticalSpacing: 4) {
                    ForEach(segments) { seg in
                        if seg.text == " " {
                            Text(" ")
                                .font(.system(size: fontSize))
                                .frame(width: max(4, fontSize * 0.28))
                        } else {
                            VStack(alignment: .center, spacing: 1) {
                                if let phonetic = seg.phonetic, !phonetic.isEmpty {
                                    Text(phonetic)
                                        .font(.system(size: max(10, fontSize * 0.52), weight: .medium, design: .rounded))
                                        .foregroundColor(phoneticColor)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                } else {
                                    Text(" ")
                                        .font(.system(size: max(10, fontSize * 0.52)))
                                        .opacity(0)
                                }
                                Text(seg.text)
                                    .font(.system(size: fontSize))
                                    .foregroundColor(textColor)
                            }
                        }
                    }
                }
            }
        }
    }
}

public struct RubyFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 2
    var verticalSpacing: CGFloat = 4

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 800
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            maxLineWidth = max(maxLineWidth, currentX)
        }
        return CGSize(width: min(maxWidth, max(maxLineWidth, 10)), height: currentY + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.minX + maxWidth && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
