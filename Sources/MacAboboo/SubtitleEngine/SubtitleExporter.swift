import Foundation

/// 字幕与断句导出引擎
public final class SubtitleExporter {
    public static let shared = SubtitleExporter()
    
    public init() {}
    
    /// 导出为标准 SRT 格式字符串
    public func exportToSRT(segments: [SentenceSegment], includeTranslation: Bool = true) -> String {
        exportToSRT(
            segments: segments,
            timings: segments.map { ($0.startTime, $0.endTime) },
            includeTranslation: includeTranslation
        )
    }

    /// 将若干不连续的断句按导出后的连续音频重新排列时间轴。
    public func exportToConcatenatedSRT(
        segments: [SentenceSegment],
        includeTranslation: Bool = true
    ) -> String {
        var cursor = 0.0
        let timings = segments.map { segment -> (Double, Double) in
            let start = cursor
            cursor += segment.duration
            return (start, cursor)
        }
        return exportToSRT(
            segments: segments,
            timings: timings,
            includeTranslation: includeTranslation
        )
    }

    private func exportToSRT(
        segments: [SentenceSegment],
        timings: [(Double, Double)],
        includeTranslation: Bool
    ) -> String {
        var srtContent = ""
        
        for (i, pair) in zip(segments, timings).enumerated() {
            let seg = pair.0
            let index = i + 1
            let startSRT = formatSRTTimestamp(pair.1.0)
            let endSRT = formatSRTTimestamp(pair.1.1)
            
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

public struct SegmentMediaExportResult: Sendable {
    public let location: URL
    public let audioFileCount: Int
    public let subtitleFileCount: Int
}

public enum SegmentMediaExportError: LocalizedError {
    case noSelection
    case ffmpegUnavailable
    case cannotCreateTemporaryDirectory
    case ffmpegFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSelection:
            return "请先选择至少一个句子。"
        case .ffmpegUnavailable:
            return "没有找到应用内置的音频导出组件。"
        case .cannotCreateTemporaryDirectory:
            return "无法创建音频导出临时目录。"
        case let .ffmpegFailed(details):
            return details.isEmpty ? "音频导出失败。" : "音频导出失败：\(details)"
        }
    }
}

/// 将已选断句导出为 MP3 与时间轴同步的双语 SRT。
public final class SegmentMediaExporter: @unchecked Sendable {
    public static let shared = SegmentMediaExporter()

    private let temporaryRootURL: URL?

    public init(temporaryRootURL: URL? = nil) {
        self.temporaryRootURL = temporaryRootURL
    }

    public func exportIndividually(
        mediaURL: URL,
        segments: [SentenceSegment],
        destinationDirectory: URL,
        baseName: String
    ) throws -> SegmentMediaExportResult {
        let ordered = normalizedSelection(segments)
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        let exportDirectory = try createUniqueDirectory(
            in: destinationDirectory,
            preferredName: "\(sanitizedFileName(baseName))-逐句导出"
        )

        do {
            for segment in ordered {
                let suffix = String(format: "%04d", max(1, segment.index))
                let fileBase = "\(sanitizedFileName(baseName))-\(suffix)"
                let audioURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("mp3")
                let subtitleURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("srt")
                try exportAudioRange(mediaURL: mediaURL, segment: segment, outputURL: audioURL)
                do {
                    let subtitle = SubtitleExporter.shared.exportToConcatenatedSRT(segments: [segment])
                    try subtitle.write(to: subtitleURL, atomically: true, encoding: .utf8)
                } catch {
                    try? FileManager.default.removeItem(at: audioURL)
                    throw error
                }
            }
        } catch {
            // 该目录由本次操作新建；失败时不留下不完整的半成品。
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }

        return SegmentMediaExportResult(
            location: exportDirectory,
            audioFileCount: ordered.count,
            subtitleFileCount: ordered.count
        )
    }

    public func exportMerged(
        mediaURL: URL,
        segments: [SentenceSegment],
        outputAudioURL: URL
    ) throws -> SegmentMediaExportResult {
        let ordered = normalizedSelection(segments)
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        try FileManager.default.createDirectory(
            at: outputAudioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if ordered.count == 1, let segment = ordered.first {
            try exportAudioRange(mediaURL: mediaURL, segment: segment, outputURL: outputAudioURL)
        } else {
            try exportConcatenatedAudio(mediaURL: mediaURL, segments: ordered, outputURL: outputAudioURL)
        }

        let subtitleURL = outputAudioURL.deletingPathExtension().appendingPathExtension("srt")
        do {
            let subtitle = SubtitleExporter.shared.exportToConcatenatedSRT(segments: ordered)
            try subtitle.write(to: subtitleURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: outputAudioURL)
            throw error
        }

        return SegmentMediaExportResult(
            location: outputAudioURL,
            audioFileCount: 1,
            subtitleFileCount: 1
        )
    }

    private func exportAudioRange(
        mediaURL: URL,
        segment: SentenceSegment,
        outputURL: URL
    ) throws {
        try runFFmpeg(arguments: [
            "-i", mediaURL.path,
            "-ss", preciseTime(segment.startTime),
            "-t", preciseTime(segment.duration),
            "-map", "0:a:0",
            "-vn",
            "-codec:a", "libmp3lame",
            "-q:a", "2",
            outputURL.path
        ])
    }

    private func exportConcatenatedAudio(
        mediaURL: URL,
        segments: [SentenceSegment],
        outputURL: URL
    ) throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let filterURL = temporaryDirectory.appendingPathComponent("concat.filter")
        let sourceLabels = segments.indices.map { "[source\($0)]" }.joined()
        var filter = "[0:a:0]asplit=\(segments.count)\(sourceLabels);\n"
        for (index, segment) in segments.enumerated() {
            filter += "[source\(index)]atrim=start=\(preciseTime(segment.startTime)):end=\(preciseTime(segment.endTime)),asetpts=PTS-STARTPTS[a\(index)];\n"
        }
        let audioLabels = segments.indices.map { "[a\($0)]" }.joined()
        filter += "\(audioLabels)concat=n=\(segments.count):v=0:a=1[out]\n"
        try filter.write(to: filterURL, atomically: true, encoding: .utf8)

        try runFFmpeg(arguments: [
            "-i", mediaURL.path,
            "-/filter_complex", filterURL.path,
            "-map", "[out]",
            "-vn",
            "-codec:a", "libmp3lame",
            "-q:a", "2",
            outputURL.path
        ])
    }

    private func runFFmpeg(arguments: [String]) throws {
        guard let executable = AudioPCMExtractor.ffmpegExecutableURL() else {
            throw SegmentMediaExportError.ffmpegUnavailable
        }
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-y", "-nostdin", "-hide_banner", "-loglevel", "error"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SegmentMediaExportError.ffmpegFailed(details)
        }
    }

    private func normalizedSelection(_ segments: [SentenceSegment]) -> [SentenceSegment] {
        segments
            .filter { $0.duration > 0 }
            .sorted {
                if abs($0.startTime - $1.startTime) > 0.000_001 {
                    return $0.startTime < $1.startTime
                }
                return $0.index < $1.index
            }
    }

    private func createUniqueDirectory(in parent: URL, preferredName: String) throws -> URL {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var candidate = parent.appendingPathComponent(preferredName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(preferredName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    private func makeTemporaryDirectory() throws -> URL {
        let parent: URL
        if let temporaryRootURL {
            parent = temporaryRootURL
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw SegmentMediaExportError.cannotCreateTemporaryDirectory
            }
            parent = appSupport
                .appendingPathComponent("MacAboboo", isDirectory: true)
                .appendingPathComponent("ExportTemp", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func sanitizedFileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return sanitized.isEmpty ? "MacAboboo-Export" : String(sanitized.prefix(96))
    }

    private func preciseTime(_ value: Double) -> String {
        String(format: "%.6f", max(0, value.isFinite ? value : 0))
    }
}
