import Foundation
import CoreFoundation

public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt, lrc, vtt, txt
}

public struct ParsedSubtitleItem: Equatable, Sendable {
    public let index: Int
    public let startTime: Double
    public let endTime: Double
    public let text: String
    public let translation: String

    public init(index: Int, startTime: Double, endTime: Double, text: String, translation: String = "") {
        let safeStart = startTime.isFinite ? max(0, startTime) : 0
        let safeEnd = endTime.isFinite ? endTime : safeStart + 0.05
        self.index = max(1, index)
        self.startTime = safeStart
        self.endTime = max(safeStart + 0.05, safeEnd)
        self.text = text
        self.translation = translation
    }
}

public enum SubtitleParserError: LocalizedError {
    case fileTooLarge
    case unsupportedEncoding

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The subtitle file is too large."
        case .unsupportedEncoding:
            return "The subtitle text encoding could not be recognized."
        }
    }
}

/// SRT / LRC / WebVTT 容错解析器。严格校验时间码，同时保留真正的多行字幕。
public final class SubtitleParser: @unchecked Sendable {
    public static let shared = SubtitleParser()
    private static let maximumFileSize = 20 * 1024 * 1024

    public init() {}

    public func parse(from url: URL) throws -> [ParsedSubtitleItem] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumFileSize else { throw SubtitleParserError.fileTooLarge }
        guard let content = decodeText(data) else { throw SubtitleParserError.unsupportedEncoding }

        switch url.pathExtension.lowercased() {
        case "srt": return parseSRT(content: content)
        case "lrc": return parseLRC(content: content)
        case "vtt": return parseVTT(content: content)
        default:
            if content.range(of: #"(?m)^\s*WEBVTT"#, options: .regularExpression) != nil {
                return parseVTT(content: content)
            }
            if content.range(of: #"(?m)^\s*\[\d{1,3}:\d{1,2}"#, options: .regularExpression) != nil {
                return parseLRC(content: content)
            }
            return parseSRT(content: content)
        }
    }

    private func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        // CoreFoundation 扩展编码表中的稳定常量：GB 18030 = 0x0632，Big-5 = 0x0A03。
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0A03)))
        for encoding in [
            String.Encoding.utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            gb18030,
            big5,
            .windowsCP1252,
            .isoLatin1
        ] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return nil
    }

    // MARK: - SRT / WebVTT

    public func parseSRT(content: String) -> [ParsedSubtitleItem] {
        parseCueBlocks(content: content, isWebVTT: false)
    }

    public func parseVTT(content: String) -> [ParsedSubtitleItem] {
        parseCueBlocks(content: content, isWebVTT: true)
    }

    private func parseCueBlocks(content: String, isWebVTT: Bool) -> [ParsedSubtitleItem] {
        let normalized = normalizeNewlines(content)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let blocks: [String]
        if let separator = try? NSRegularExpression(pattern: #"\n[\t ]*\n+"#) {
            blocks = normalized.components(separatedBy: separator)
        } else {
            blocks = [normalized]
        }
        var result: [ParsedSubtitleItem] = []

        for rawBlock in blocks {
            let rawLines = rawBlock.components(separatedBy: "\n")
            let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
            guard !lines.isEmpty else { continue }
            let first = lines[0].uppercased()
            if first == "WEBVTT" || first.hasPrefix("WEBVTT ") || first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" {
                continue
            }
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let range = parseTimeRange(lines[timeLineIndex]) else { continue }

            let payload = lines.dropFirst(timeLineIndex + 1)
                .map { isWebVTT ? stripWebVTTMarkup($0) : $0 }
                .filter { !$0.isEmpty }
            guard !payload.isEmpty else { continue }
            let (text, translation) = splitTextAndTranslation(Array(payload))
            guard !text.isEmpty else { continue }
            result.append(ParsedSubtitleItem(
                index: result.count + 1,
                startTime: range.start,
                endTime: range.end,
                text: text,
                translation: translation
            ))
        }
        return result.sorted(by: cueOrdering).enumerated().map { offset, item in
            ParsedSubtitleItem(
                index: offset + 1,
                startTime: item.startTime,
                endTime: item.endTime,
                text: item.text,
                translation: item.translation
            )
        }
    }

    private func splitTextAndTranslation(_ lines: [String]) -> (String, String) {
        guard lines.count > 1 else { return (lines.first ?? "", "") }
        let firstHasCJK = containsCJK(lines[0])
        let remaining = lines.dropFirst().joined(separator: "\n")
        let remainingHasCJK = containsCJK(remaining)
        if firstHasCJK != remainingHasCJK {
            return (lines[0], remaining)
        }
        // 无法可靠判断双语时保留所有行，避免把同语种的第二行误当成译文。
        return (lines.joined(separator: "\n"), "")
    }

    private func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) ||
            (0x3040...0x30FF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private func stripWebVTTMarkup(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - LRC

    public func parseLRC(content: String) -> [ParsedSubtitleItem] {
        struct Entry {
            let time: Double
            let order: Int
            let text: String
        }

        let normalized = normalizeNewlines(content)
        let pattern = #"\[(\d{1,3}):(\d{1,2})(?:[\.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let offsetPattern = try? NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\]"#)
        var offsetSeconds = 0.0
        if let match = offsetPattern?.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let range = Range(match.range(at: 1), in: normalized),
           let milliseconds = Double(normalized[range]) {
            offsetSeconds = milliseconds / 1000
        }

        var entries: [Entry] = []
        for (lineNumber, line) in normalized.components(separatedBy: "\n").enumerated() {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }
            var text = line
            for match in matches.reversed() {
                text = (text as NSString).replacingCharacters(in: match.range, with: "")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let minutes = Int(line[minuteRange]),
                      let seconds = Int(line[secondRange]),
                      seconds < 60 else { continue }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = String(line[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                let time = max(0, Double(minutes * 60 + seconds) + fraction + offsetSeconds)
                entries.append(Entry(time: time, order: lineNumber, text: text))
            }
        }

        entries.sort {
            if $0.time == $1.time { return $0.order < $1.order }
            return $0.time < $1.time
        }
        return entries.enumerated().map { offset, entry in
            let nextTime = offset + 1 < entries.count ? entries[offset + 1].time : entry.time + 4
            return ParsedSubtitleItem(
                index: offset + 1,
                startTime: entry.time,
                endTime: max(entry.time + 0.05, nextTime),
                text: entry.text
            )
        }
    }

    // MARK: - Timecodes

    private func parseTimeRange(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let endToken = parts[1].trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        guard let start = parseTimestamp(parts[0]), let end = parseTimestamp(endToken), end > start else {
            return nil
        }
        return (start, end)
    }

    /// 支持 `hh:mm:ss.mmm`、`mm:ss.mmm` 与纯秒；拒绝负数、越界分秒和尾随垃圾字符。
    public func parseTimestamp(_ raw: String) -> Double? {
        let value = raw.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }

        func strictNumber(_ component: String) -> Double? {
            guard component.range(of: #"^\d+(?:\.\d{1,3})?$"#, options: .regularExpression) != nil else { return nil }
            return Double(component)
        }

        if parts.count == 1 {
            guard let seconds = strictNumber(parts[0]), seconds.isFinite else { return nil }
            return seconds
        }
        guard let seconds = strictNumber(parts.last!), seconds < 60,
              let minutes = Int(parts[parts.count - 2]), (0..<60).contains(minutes) || parts.count == 2 else {
            return nil
        }
        if parts.count == 2 {
            return Double(minutes) * 60 + seconds
        }
        guard (0..<60).contains(minutes), let hours = Int(parts[0]), hours >= 0 else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    private func cueOrdering(_ lhs: ParsedSubtitleItem, _ rhs: ParsedSubtitleItem) -> Bool {
        if lhs.startTime == rhs.startTime { return lhs.endTime < rhs.endTime }
        return lhs.startTime < rhs.startTime
    }

    private func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..., in: self)
        var result: [String] = []
        var cursor = startIndex
        for match in regex.matches(in: self, range: range) {
            guard let matchRange = Range(match.range, in: self) else { continue }
            result.append(String(self[cursor..<matchRange.lowerBound]))
            cursor = matchRange.upperBound
        }
        result.append(String(self[cursor...]))
        return result
    }
}
