import Foundation
import AVFoundation

/// 字幕与断句导出引擎
public final class SubtitleExporter: Sendable {
    public static let shared = SubtitleExporter()
    
    public init() {}
    
    /// 导出为标准双语 LRC 歌词格式字符串。原文和译文使用相同时间戳，
    /// StudyMate 再次导入时会自动组合成同一条双语字幕。
    public func exportToLRC(
        segments: [SentenceSegment],
        title: String = "",
        includeTranslation: Bool = true
    ) -> String {
        exportToLRC(
            segments: segments,
            startTimes: segments.map(\.startTime),
            title: title,
            includeTranslation: includeTranslation
        )
    }

    /// 将不连续的断句按合并后 M4A 的连续时间轴生成 LRC。
    public func exportToConcatenatedLRC(
        segments: [SentenceSegment],
        title: String = "",
        includeTranslation: Bool = true
    ) -> String {
        var cursor = 0.0
        let startTimes = segments.map { segment -> Double in
            defer { cursor += segment.duration }
            return cursor
        }
        return exportToLRC(
            segments: segments,
            startTimes: startTimes,
            title: title,
            includeTranslation: includeTranslation
        )
    }

    private func exportToLRC(
        segments: [SentenceSegment],
        startTimes: [Double],
        title: String,
        includeTranslation: Bool
    ) -> String {
        var lrcContent = ""
        if !title.isEmpty {
            lrcContent += "[ti:\(title)]\n"
        }
        
        for (segment, startTime) in zip(segments, startTimes) {
            let safeStartTime = max(0.0, startTime.isFinite ? startTime : 0.0)
            let timeLRC = formatLRCTimestamp(safeStartTime)
            let originalLines = normalizedLRCLines(segment.text)
            let translationLines = includeTranslation ? normalizedLRCLines(segment.translation) : []
            if originalLines.isEmpty, translationLines.isEmpty {
                lrcContent += "[\(timeLRC)](music)\n"
                continue
            }
            for line in originalLines {
                lrcContent += "[\(timeLRC)]\(line)\n"
            }
            for line in translationLines {
                lrcContent += "[\(timeLRC)]\(line)\n"
            }
        }
        
        return lrcContent
    }

    private func normalizedLRCLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    /// 导出为标准双语 SRT 字幕格式字符串。
    public func exportToSRT(
        segments: [SentenceSegment],
        includeTranslation: Bool = true
    ) -> String {
        exportToSRT(
            segments: segments,
            startTimes: segments.map(\.startTime),
            endTimes: segments.map(\.endTime),
            includeTranslation: includeTranslation
        )
    }

    /// 将不连续的断句按合并后 M4A 的连续时间轴生成 SRT。
    public func exportToConcatenatedSRT(
        segments: [SentenceSegment],
        includeTranslation: Bool = true
    ) -> String {
        var cursor = 0.0
        var startTimes: [Double] = []
        var endTimes: [Double] = []
        for segment in segments {
            startTimes.append(cursor)
            cursor += max(0.05, segment.duration)
            endTimes.append(cursor)
        }
        return exportToSRT(
            segments: segments,
            startTimes: startTimes,
            endTimes: endTimes,
            includeTranslation: includeTranslation
        )
    }

    private func exportToSRT(
        segments: [SentenceSegment],
        startTimes: [Double],
        endTimes: [Double],
        includeTranslation: Bool
    ) -> String {
        var blocks: [String] = []
        for (index, (segment, (startTime, endTime))) in zip(segments, zip(startTimes, endTimes)).enumerated() {
            let safeStart = max(0, startTime.isFinite ? startTime : 0)
            let safeEnd = max(safeStart + 0.05, endTime.isFinite ? endTime : safeStart + 0.05)
            let timeCode = "\(formatSRTTimestamp(safeStart)) --> \(formatSRTTimestamp(safeEnd))"
            var lines: [String] = []
            let original = normalizedLRCLines(segment.text).joined(separator: "\n")
            let translation = includeTranslation ? normalizedLRCLines(segment.translation).joined(separator: "\n") : ""
            if !original.isEmpty { lines.append(original) }
            if !translation.isEmpty { lines.append(translation) }
            if lines.isEmpty { lines.append("(music)") }

            blocks.append("\(index + 1)\n\(timeCode)\n\(lines.joined(separator: "\n"))")
        }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    private func formatSRTTimestamp(_ seconds: Double) -> String {
        let safeSecs = seconds.isFinite ? max(0, seconds) : 0
        let totalMillis = Int((safeSecs * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let secs = totalSeconds % 60
        let mins = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, millis)
    }
}

public struct SegmentMediaExportResult: Sendable {
    public let location: URL
    public let audioFileCount: Int
    public let subtitleFileCount: Int
}

/// 媒体导出进度。回调始终在导出后台线程触发，调用方应切回主线程更新界面。
public struct SegmentMediaExportProgress: Sendable, Equatable {
    public let fraction: Double
    public let completedItems: Int
    public let totalItems: Int
    public let currentItem: String
    public let phase: String

    public init(
        fraction: Double,
        completedItems: Int,
        totalItems: Int,
        currentItem: String = "",
        phase: String = ""
    ) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.completedItems = max(0, completedItems)
        self.totalItems = max(0, totalItems)
        self.currentItem = currentItem
        self.phase = phase
    }
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

/// 将已选断句导出为 AAC 编码的 M4A 与时间轴同步的双语 LRC。
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
        baseName: String,
        progress: @escaping @Sendable (SegmentMediaExportProgress) -> Void = { _ in }
    ) throws -> SegmentMediaExportResult {
        let ordered = normalizedSelection(segments)
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        let exportDirectory = try createUniqueDirectory(
            in: destinationDirectory,
            preferredName: "\(sanitizedFileName(baseName))-逐句导出"
        )

        do {
            let total = ordered.count
            progress(SegmentMediaExportProgress(
                fraction: 0,
                completedItems: 0,
                totalItems: total,
                phase: "准备导出"
            ))
            for (offset, segment) in ordered.enumerated() {
                let suffix = String(format: "%04d", max(1, segment.index))
                let fileBase = "\(sanitizedFileName(baseName))-\(suffix)"
                let audioURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("m4a")
                let lrcURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("lrc")
                let srtURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("srt")
                let itemProgress: @Sendable (Double) -> Void = { fraction in
                    progress(SegmentMediaExportProgress(
                        fraction: (Double(offset) + fraction) / Double(total),
                        completedItems: offset,
                        totalItems: total,
                        currentItem: fileBase,
                        phase: "导出音频"
                    ))
                }
                try exportAudioRange(
                    mediaURL: mediaURL,
                    segment: segment,
                    outputURL: audioURL,
                    progress: itemProgress
                )
                let playableDuration = try verifyEncodedAudio(
                    at: audioURL,
                    expectedDuration: max(0.05, segment.duration),
                    context: "逐句导出音频"
                )
                let subtitleSegment = segmentWithDuration(segment, duration: playableDuration)
                do {
                    let subtitleLRC = SubtitleExporter.shared.exportToConcatenatedLRC(
                        segments: [subtitleSegment],
                        title: fileBase
                    )
                    let subtitleSRT = SubtitleExporter.shared.exportToConcatenatedSRT(
                        segments: [subtitleSegment]
                    )
                    try subtitleLRC.write(to: lrcURL, atomically: true, encoding: .utf8)
                    try subtitleSRT.write(to: srtURL, atomically: true, encoding: .utf8)
                } catch {
                    try? FileManager.default.removeItem(at: audioURL)
                    throw error
                }
                progress(SegmentMediaExportProgress(
                    fraction: Double(offset + 1) / Double(total),
                    completedItems: offset + 1,
                    totalItems: total,
                    currentItem: fileBase,
                    phase: "写入字幕"
                ))
            }
        } catch {
            // 该目录由本次操作新建；失败时不留下不完整的半成品。
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }

        return SegmentMediaExportResult(
            location: exportDirectory,
            audioFileCount: ordered.count,
            subtitleFileCount: ordered.count * 2
        )
    }

    public func exportMerged(
        mediaURL: URL,
        segments: [SentenceSegment],
        outputAudioURL: URL,
        progress: @escaping @Sendable (SegmentMediaExportProgress) -> Void = { _ in }
    ) throws -> SegmentMediaExportResult {
        let ordered = normalizedSelection(segments)
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        // 无论调用方传入什么后缀，合并导出始终落为 AAC 编码的 M4A，
        // 避免用户在保存面板中手动输入 .mp3 后得到错误的容器/编码组合。
        let normalizedOutputURL = outputAudioURL
            .deletingPathExtension()
            .appendingPathExtension("m4a")
        try FileManager.default.createDirectory(
            at: normalizedOutputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        progress(SegmentMediaExportProgress(
            fraction: 0,
            completedItems: 0,
            totalItems: 1,
            currentItem: normalizedOutputURL.lastPathComponent,
            phase: "导出音频"
        ))

        let lrcURL = normalizedOutputURL.deletingPathExtension().appendingPathExtension("lrc")
        let srtURL = normalizedOutputURL.deletingPathExtension().appendingPathExtension("srt")
        do {
            if ordered.count == 1, let segment = ordered.first {
                try exportAudioRange(
                    mediaURL: mediaURL,
                    segment: segment,
                    outputURL: normalizedOutputURL,
                    progress: { fraction in
                        progress(SegmentMediaExportProgress(
                            fraction: fraction * 0.9,
                            completedItems: 0,
                            totalItems: 1,
                            currentItem: normalizedOutputURL.lastPathComponent,
                            phase: "导出音频"
                        ))
                    }
                )
            } else {
                try exportConcatenatedAudio(
                    mediaURL: mediaURL,
                    segments: ordered,
                    outputURL: normalizedOutputURL,
                    progress: { fraction in
                        progress(SegmentMediaExportProgress(
                            fraction: fraction * 0.9,
                            completedItems: 0,
                            totalItems: 1,
                            currentItem: normalizedOutputURL.lastPathComponent,
                            phase: "合并音频"
                        ))
                    }
                )
            }

            _ = try verifyEncodedAudio(
                at: normalizedOutputURL,
                expectedDuration: max(0.05, ordered.reduce(0) { $0 + max(0.05, $1.duration) }),
                context: "合并导出音频"
            )
            let subtitleLRC = SubtitleExporter.shared.exportToConcatenatedLRC(
                segments: ordered,
                title: normalizedOutputURL.deletingPathExtension().lastPathComponent
            )
            let subtitleSRT = SubtitleExporter.shared.exportToConcatenatedSRT(
                segments: ordered
            )
            try subtitleLRC.write(to: lrcURL, atomically: true, encoding: .utf8)
            try subtitleSRT.write(to: srtURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: normalizedOutputURL)
            try? FileManager.default.removeItem(at: lrcURL)
            try? FileManager.default.removeItem(at: srtURL)
            throw error
        }

        progress(SegmentMediaExportProgress(
            fraction: 1,
            completedItems: 1,
            totalItems: 1,
            currentItem: normalizedOutputURL.lastPathComponent,
            phase: "写入字幕"
        ))

        return SegmentMediaExportResult(
            location: normalizedOutputURL,
            audioFileCount: 1,
            subtitleFileCount: 2
        )
    }

    /// 导出一个句库独立 AAC M4A 片段。输出时间轴从 0 开始，之后播放不再依赖原媒体。
    public func exportAudioClip(
        mediaURL: URL,
        segment: SentenceSegment,
        outputURL: URL,
        progress: @escaping @Sendable (SegmentMediaExportProgress) -> Void = { _ in }
    ) throws {
        guard segment.duration > 0 else { throw SegmentMediaExportError.noSelection }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        progress(SegmentMediaExportProgress(
            fraction: 0,
            completedItems: 0,
            totalItems: 1,
            currentItem: outputURL.lastPathComponent,
            phase: "导出句库音频"
        ))
        try runFFmpeg(
            arguments: [
                "-i", mediaURL.path,
                // 将 -ss 放在输入之后，使用准确寻址而不是输入侧的快速
                // keyframe seek，避免压缩音频片段从前一个关键帧开始。
                "-ss", preciseTime(segment.startTime),
                "-t", preciseTime(segment.duration),
                "-map", "0:a:0",
                "-vn",
                "-codec:a", "aac",
                "-b:a", "192k",
                "-af", "aresample=48000,asetpts=PTS-STARTPTS",
                "-movflags", "+faststart",
                outputURL.path
            ],
            duration: max(0.05, segment.duration),
            progress: { fraction in
                progress(SegmentMediaExportProgress(
                    fraction: fraction * 0.95,
                    completedItems: 0,
                    totalItems: 1,
                    currentItem: outputURL.lastPathComponent,
                    phase: "导出句库音频"
                ))
            }
        )
        // 完整解码验证，避免损坏或被提前截断的 AAC 文件进入句库。
        do {
            _ = try verifyEncodedAudio(
                at: outputURL,
                expectedDuration: max(0.05, segment.duration),
                context: "句库音频"
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        progress(SegmentMediaExportProgress(
            fraction: 1,
            completedItems: 1,
            totalItems: 1,
            currentItem: outputURL.lastPathComponent,
            phase: "句库音频完成"
        ))
    }

    /// 导出句库中已经独立保存的 M4A 片段。这里不再读取原始音视频，
    /// 仅对句库内的 AAC 文件做一次封装并写入来源标签，同时生成对应 LRC 与 SRT。
    public func exportLibraryEntriesIndividually(
        entries: [SentenceLibraryEntry],
        mediaURLs: [UUID: URL],
        destinationDirectory: URL,
        baseName: String,
        album: String,
        artist: String,
        progress: @escaping @Sendable (SegmentMediaExportProgress) -> Void = { _ in }
    ) throws -> SegmentMediaExportResult {
        let ordered = entries
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        // 句库音频必须是可独立播放的完整文件。这里先逐个打开并从头读到尾，
        // 同时取得 AAC 解码后的真实时长，后续字幕不再依赖原媒体的时间戳。
        let verifiedEntries = try ordered.map {
            entry -> (entry: SentenceLibraryEntry, sourceURL: URL, duration: Double) in
            guard let sourceURL = mediaURLs[entry.id] else {
                throw SegmentMediaExportError.ffmpegFailed("缺少句子音频：\(entry.id.uuidString)")
            }
            let duration = try verifyEncodedAudio(
                at: sourceURL,
                expectedDuration: max(0.05, entry.endTime - entry.startTime),
                context: "句库音频"
            )
            return (entry, sourceURL, duration)
        }
        let exportDirectory = try createUniqueDirectory(
            in: destinationDirectory,
            preferredName: "\(sanitizedFileName(baseName))-句库逐句导出"
        )

        do {
            let total = ordered.count
            for (offset, verified) in verifiedEntries.enumerated() {
                try Task.checkCancellation()
                let entry = verified.entry
                let sourceURL = verified.sourceURL
                let fileBase = "\(sanitizedFileName(baseName))-\(String(format: "%04d", offset + 1))"
                let audioURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("m4a")
                let lrcURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("lrc")
                let srtURL = exportDirectory.appendingPathComponent(fileBase).appendingPathExtension("srt")
                progress(SegmentMediaExportProgress(
                    fraction: Double(offset) / Double(total),
                    completedItems: offset,
                    totalItems: total,
                    currentItem: fileBase,
                    phase: "导出句库音频"
                ))
                try exportTaggedCopy(
                    sourceURL: sourceURL,
                    outputURL: audioURL,
                    album: album,
                    artist: artist,
                    duration: verified.duration,
                    progress: { fraction in
                        progress(SegmentMediaExportProgress(
                            fraction: (Double(offset) + fraction) / Double(total),
                            completedItems: offset,
                            totalItems: total,
                            currentItem: fileBase,
                            phase: "导出句库音频"
                        ))
                    }
                )
                let copiedDuration = try verifyEncodedAudio(
                    at: audioURL,
                    expectedDuration: verified.duration,
                    context: "句库导出音频"
                )
                let singleSegment = librarySubtitleSegment(
                    entry,
                    index: offset + 1,
                    duration: copiedDuration
                )
                let subtitleLRC = SubtitleExporter.shared.exportToConcatenatedLRC(
                    segments: [singleSegment],
                    title: fileBase
                )
                let subtitleSRT = SubtitleExporter.shared.exportToConcatenatedSRT(
                    segments: [singleSegment]
                )
                try subtitleLRC.write(to: lrcURL, atomically: true, encoding: .utf8)
                try subtitleSRT.write(to: srtURL, atomically: true, encoding: .utf8)
                progress(SegmentMediaExportProgress(
                    fraction: Double(offset + 1) / Double(total),
                    completedItems: offset + 1,
                    totalItems: total,
                    currentItem: fileBase,
                    phase: "写入字幕"
                ))
            }
        } catch {
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }

        return SegmentMediaExportResult(
            location: exportDirectory,
            audioFileCount: verifiedEntries.count,
            subtitleFileCount: verifiedEntries.count * 2
        )
    }

    /// 将句库中的多个独立片段无间隙合并为一个带 AAC 编码和来源标签的 M4A，
    /// 再按同一顺序生成连续时间轴 LRC 与 SRT。
    public func exportLibraryEntriesMerged(
        entries: [SentenceLibraryEntry],
        mediaURLs: [UUID: URL],
        outputAudioURL: URL,
        album: String,
        artist: String,
        progress: @escaping @Sendable (SegmentMediaExportProgress) -> Void = { _ in }
    ) throws -> SegmentMediaExportResult {
        let ordered = entries
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        // 句库条目的 start/end 属于原始媒体，只能作为完整性校验的期望值。
        // 合并时使用每个独立 M4A 实际可解码的采样长度，避免 AAC 编码延迟
        // 或容器舍入在多句累加后造成字幕越来越靠前/靠后。
        let verifiedEntries = try ordered.map {
            entry -> (entry: SentenceLibraryEntry, sourceURL: URL, duration: Double) in
            guard let sourceURL = mediaURLs[entry.id] else {
                throw SegmentMediaExportError.ffmpegFailed("缺少句子音频：\(entry.id.uuidString)")
            }
            let duration = try verifyEncodedAudio(
                at: sourceURL,
                expectedDuration: max(0.05, entry.endTime - entry.startTime),
                context: "句库音频"
            )
            return (entry, sourceURL, duration)
        }
        let outputURL = outputAudioURL.deletingPathExtension().appendingPathExtension("m4a")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let totalDuration = max(0.05, verifiedEntries.reduce(0) { $0 + $1.duration })
        progress(SegmentMediaExportProgress(
            fraction: 0,
            completedItems: 0,
            totalItems: 1,
            currentItem: outputURL.lastPathComponent,
            phase: "合并句库音频"
        ))

        do {
            if verifiedEntries.count == 1, let verified = verifiedEntries.first {
                try exportTaggedCopy(
                    sourceURL: verified.sourceURL,
                    outputURL: outputURL,
                    album: album,
                    artist: artist,
                    duration: verified.duration,
                    progress: { fraction in
                        progress(SegmentMediaExportProgress(
                            fraction: fraction * 0.9,
                            completedItems: 0,
                            totalItems: 1,
                            currentItem: outputURL.lastPathComponent,
                            phase: "导出句库音频"
                        ))
                    }
                )
            } else {
                let temporaryDirectory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                let filterURL = temporaryDirectory.appendingPathComponent("library-concat.filter")
                var filter = ""
                for index in verifiedEntries.indices {
                    filter += "[\(index):a:0]aresample=48000,asetpts=PTS-STARTPTS[a\(index)];\n"
                }
                let labels = verifiedEntries.indices.map { "[a\($0)]" }.joined()
                filter += "\(labels)concat=n=\(verifiedEntries.count):v=0:a=1[out]\n"
                try filter.write(to: filterURL, atomically: true, encoding: .utf8)
                var arguments: [String] = []
                for verified in verifiedEntries {
                    arguments += ["-i", verified.sourceURL.path]
                }
                arguments += [
                    "-/filter_complex", filterURL.path,
                    "-map", "[out]",
                    "-vn",
                    "-codec:a", "aac",
                    "-b:a", "192k",
                    "-metadata", "album=\(album)",
                    "-metadata", "artist=\(artist)",
                    "-movflags", "+faststart",
                    outputURL.path
                ]
                try runFFmpeg(
                    arguments: arguments,
                    duration: totalDuration,
                    progress: { fraction in
                        progress(SegmentMediaExportProgress(
                            fraction: fraction * 0.9,
                            completedItems: 0,
                            totalItems: 1,
                            currentItem: outputURL.lastPathComponent,
                            phase: "合并句库音频"
                        ))
                    }
                )
            }

            _ = try verifyEncodedAudio(
                at: outputURL,
                expectedDuration: totalDuration,
                context: "合并句库音频"
            )
            let subtitleSegments = verifiedEntries.enumerated().map {
                librarySubtitleSegment(
                    $0.element.entry,
                    index: $0.offset + 1,
                    duration: $0.element.duration
                )
            }
            let subtitleLRC = SubtitleExporter.shared.exportToConcatenatedLRC(
                segments: subtitleSegments,
                title: outputURL.deletingPathExtension().lastPathComponent
            )
            let subtitleSRT = SubtitleExporter.shared.exportToConcatenatedSRT(
                segments: subtitleSegments
            )
            let lrcURL = outputURL.deletingPathExtension().appendingPathExtension("lrc")
            let srtURL = outputURL.deletingPathExtension().appendingPathExtension("srt")
            try subtitleLRC.write(to: lrcURL, atomically: true, encoding: .utf8)
            try subtitleSRT.write(to: srtURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: outputURL.deletingPathExtension().appendingPathExtension("lrc"))
            try? FileManager.default.removeItem(at: outputURL.deletingPathExtension().appendingPathExtension("srt"))
            throw error
        }

        progress(SegmentMediaExportProgress(
            fraction: 1,
            completedItems: 1,
            totalItems: 1,
            currentItem: outputURL.lastPathComponent,
            phase: "写入字幕"
        ))
        return SegmentMediaExportResult(location: outputURL, audioFileCount: 1, subtitleFileCount: 2)
    }

    private func exportAudioRange(
        mediaURL: URL,
        segment: SentenceSegment,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws {
        try runFFmpeg(
            arguments: [
                "-i", mediaURL.path,
                // 精确寻址，避免独立句库片段带入前一个关键帧的音频。
                "-ss", preciseTime(segment.startTime),
                "-t", preciseTime(segment.duration),
                "-map", "0:a:0",
                "-vn",
                "-codec:a", "aac",
                "-b:a", "192k",
                "-af", "aresample=48000,asetpts=PTS-STARTPTS",
                "-movflags", "+faststart",
                outputURL.path
            ],
            duration: max(0.05, segment.duration),
            progress: progress
        )
    }

    private func librarySubtitleSegment(
        _ entry: SentenceLibraryEntry,
        index: Int,
        duration: Double? = nil
    ) -> SentenceSegment {
        SentenceSegment(
            id: entry.id,
            index: index,
            startTime: 0,
            endTime: max(0.05, duration ?? (entry.endTime - entry.startTime)),
            text: entry.originalText,
            translation: entry.translation,
            note: entry.note
        )
    }

    private func segmentWithDuration(_ segment: SentenceSegment, duration: Double) -> SentenceSegment {
        SentenceSegment(
            id: segment.id,
            index: segment.index,
            startTime: 0,
            endTime: max(0.05, duration),
            text: segment.text,
            translation: segment.translation,
            note: segment.note
        )
    }

    private func exportTaggedCopy(
        sourceURL: URL,
        outputURL: URL,
        album: String,
        artist: String,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        try runFFmpeg(
            arguments: [
                "-i", sourceURL.path,
                "-map", "0:a:0",
                "-vn",
                "-codec:a", "copy",
                "-metadata", "album=\(album)",
                "-metadata", "artist=\(artist)",
                "-movflags", "+faststart",
                outputURL.path
            ],
            duration: duration,
            progress: progress
        )
    }

    private func exportConcatenatedAudio(
        mediaURL: URL,
        segments: [SentenceSegment],
        outputURL: URL,
        album: String = "",
        artist: String = "",
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws {
        let totalDuration = max(0.05, segments.reduce(0) { $0 + $1.duration })
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

        var arguments = [
            "-i", mediaURL.path,
            "-/filter_complex", filterURL.path,
            "-map", "[out]",
            "-t", preciseTime(totalDuration),
            "-vn",
            "-codec:a", "aac",
            "-b:a", "192k"
        ]
        if !album.isEmpty { arguments += ["-metadata", "album=\(album)"] }
        if !artist.isEmpty { arguments += ["-metadata", "artist=\(artist)"] }
        arguments += ["-movflags", "+faststart", outputURL.path]

        try runFFmpeg(
            arguments: arguments,
            duration: totalDuration,
            progress: progress
        )
    }

    private func runFFmpeg(
        arguments: [String],
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        guard let executable = AudioPCMExtractor.ffmpegExecutableURL() else {
            throw SegmentMediaExportError.ffmpegUnavailable
        }
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-nostats", "-progress", "pipe:2"
        ] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        var pending = ""
        var errorLines: [String] = []
        let safeDuration = max(0.05, duration.isFinite ? duration : 0.05)
        while true {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            let data = errorPipe.fileHandleForReading.readData(ofLength: 4096)
            if data.isEmpty { break }
            pending += String(data: data, encoding: .utf8) ?? ""
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeSubrange(...newline)
                if line.hasPrefix("out_time_ms="),
                   let value = Double(line.dropFirst("out_time_ms=".count)) {
                    progress(min(1, max(0, value / 1_000_000 / safeDuration)))
                } else if line == "progress=end" {
                    progress(1)
                } else if !line.isEmpty, !line.contains("=") {
                    errorLines.append(line)
                }
            }
        }
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorLines.append(pending.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = errorLines.joined(separator: "\n")
            throw SegmentMediaExportError.ffmpegFailed(details)
        }
    }

    /// 打开并完整读取一个已编码的音频文件，返回解码后的真实时长。
    ///
    /// 句库中的每条音频都是独立 AAC 文件。仅检查文件存在或读取容器时长，
    /// 无法发现尾部截断、空音频帧或损坏的索引；按固定大小缓冲区读到 EOF
    /// 可以在不把整个文件载入内存的前提下验证它确实能够被播放器完整消费。
    private func verifyEncodedAudio(
        at url: URL,
        expectedDuration: Double? = nil,
        context: String
    ) throws -> Double {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SegmentMediaExportError.ffmpegFailed("\(context)文件不存在：\(url.lastPathComponent)")
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SegmentMediaExportError.ffmpegFailed(
                "\(context)无法读取：\(url.lastPathComponent)"
            )
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        guard sampleRate.isFinite, sampleRate > 0, totalFrames > 0 else {
            throw SegmentMediaExportError.ffmpegFailed(
                "\(context)没有可播放的音频帧：\(url.lastPathComponent)"
            )
        }

        let duration = Double(totalFrames) / sampleRate
        let frameCapacity = AVAudioFrameCount(min(Int64(65_536), totalFrames))
        guard frameCapacity > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: frameCapacity
              ) else {
            throw SegmentMediaExportError.ffmpegFailed(
                "\(context)无法创建解码缓冲区：\(url.lastPathComponent)"
            )
        }

        do {
            while audioFile.framePosition < totalFrames {
                let remaining = totalFrames - audioFile.framePosition
                let request = AVAudioFrameCount(min(Int64(frameCapacity), remaining))
                try audioFile.read(into: buffer, frameCount: request)
                guard buffer.frameLength > 0 else {
                    throw SegmentMediaExportError.ffmpegFailed(
                        "\(context)在文件尾部前停止：\(url.lastPathComponent)"
                    )
                }
            }
        } catch let error as SegmentMediaExportError {
            throw error
        } catch {
            throw SegmentMediaExportError.ffmpegFailed(
                "\(context)解码失败：\(url.lastPathComponent)"
            )
        }

        if let expectedDuration, expectedDuration.isFinite, expectedDuration > 0 {
            // AAC 的 priming/容器取整通常只有几毫秒；给很短的句子一个固定
            // 最小容差，同时拒绝明显提前结束的片段。
            let tolerance = max(0.03, min(0.12, expectedDuration * 0.08))
            guard duration + tolerance >= expectedDuration else {
                throw SegmentMediaExportError.ffmpegFailed(
                    "\(context)长度不足（应为约 \(String(format: "%.3f", expectedDuration)) 秒，实际 \(String(format: "%.3f", duration)) 秒）：\(url.lastPathComponent)"
                )
            }
        }
        return duration
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
                .appendingPathComponent("StudyMate", isDirectory: true)
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
        return sanitized.isEmpty ? "StudyMate-Export" : String(sanitized.prefix(96))
    }

    private func preciseTime(_ value: Double) -> String {
        String(format: "%.6f", max(0, value.isFinite ? value : 0))
    }
}
