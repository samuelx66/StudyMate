import Foundation

/// 字幕与断句导出引擎
public final class SubtitleExporter: Sendable {
    public static let shared = SubtitleExporter()
    
    public init() {}
    
    /// 导出为标准双语 LRC 歌词格式字符串。原文和译文使用相同时间戳，
    /// MacAboboo 再次导入时会自动组合成同一条双语字幕。
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
                do {
                    let subtitleLRC = SubtitleExporter.shared.exportToConcatenatedLRC(
                        segments: [segment],
                        title: fileBase
                    )
                    let subtitleSRT = SubtitleExporter.shared.exportToConcatenatedSRT(
                        segments: [segment]
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

        let lrcURL = normalizedOutputURL.deletingPathExtension().appendingPathExtension("lrc")
        let srtURL = normalizedOutputURL.deletingPathExtension().appendingPathExtension("srt")
        do {
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
                "-ss", preciseTime(segment.startTime),
                "-i", mediaURL.path,
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
        let ordered = entries.filter { mediaURLs[$0.id] != nil }
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        let exportDirectory = try createUniqueDirectory(
            in: destinationDirectory,
            preferredName: "\(sanitizedFileName(baseName))-句库逐句导出"
        )

        do {
            let total = ordered.count
            for (offset, entry) in ordered.enumerated() {
                try Task.checkCancellation()
                guard let sourceURL = mediaURLs[entry.id] else {
                    throw SegmentMediaExportError.ffmpegFailed("缺少句子音频：\(entry.id.uuidString)")
                }
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
                    duration: max(0.05, entry.endTime - entry.startTime),
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
                let singleSegment = librarySubtitleSegment(entry, index: offset + 1)
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
            audioFileCount: ordered.count,
            subtitleFileCount: ordered.count * 2
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
        let ordered = entries.filter { mediaURLs[$0.id] != nil }
        guard !ordered.isEmpty else { throw SegmentMediaExportError.noSelection }
        let outputURL = outputAudioURL.deletingPathExtension().appendingPathExtension("m4a")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let totalDuration = max(0.05, ordered.reduce(0) { $0 + max(0.05, $1.endTime - $1.startTime) })
        progress(SegmentMediaExportProgress(
            fraction: 0,
            completedItems: 0,
            totalItems: 1,
            currentItem: outputURL.lastPathComponent,
            phase: "合并句库音频"
        ))

        do {
            let firstSourcePath = ordered.first?.sourceMediaPath ?? ""
            let allFromSameSource = !firstSourcePath.isEmpty && ordered.allSatisfy { $0.sourceMediaPath == firstSourcePath }
            let sourceMediaURL = URL(fileURLWithPath: firstSourcePath)

            if allFromSameSource && FileManager.default.fileExists(atPath: firstSourcePath) {
                // 如果所有句子均来自同一源音视频文件，直接基于源文件在单次滤镜流中以采样级精度切片并拼接，
                // 杜绝多次有损重编码与 AAC 预卷帧累加（0ms 误差，完美对齐原声）。
                let sourceSegments = ordered.enumerated().map { (offset, entry) in
                    SentenceSegment(
                        id: entry.id,
                        index: offset + 1,
                        startTime: entry.startTime,
                        endTime: entry.endTime,
                        text: entry.originalText,
                        translation: entry.translation,
                        note: entry.note
                    )
                }
                try exportConcatenatedAudio(
                    mediaURL: sourceMediaURL,
                    segments: sourceSegments,
                    outputURL: outputURL,
                    album: album,
                    artist: artist,
                    progress: { fraction in
                        progress(SegmentMediaExportProgress(
                            fraction: fraction * 0.9,
                            completedItems: 0,
                            totalItems: 1,
                            currentItem: outputURL.lastPathComponent,
                            phase: "合并音频"
                        ))
                    }
                )
            } else if ordered.count == 1, let sourceURL = mediaURLs[ordered[0].id] {
                try exportTaggedCopy(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    album: album,
                    artist: artist,
                    duration: totalDuration,
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
                for index in ordered.indices {
                    filter += "[\(index):a:0]aresample=48000,asetpts=PTS-STARTPTS[a\(index)];\n"
                }
                let labels = ordered.indices.map { "[a\($0)]" }.joined()
                filter += "\(labels)concat=n=\(ordered.count):v=0:a=1[out]\n"
                try filter.write(to: filterURL, atomically: true, encoding: .utf8)
                var arguments: [String] = []
                for entry in ordered {
                    guard let sourceURL = mediaURLs[entry.id] else {
                        throw SegmentMediaExportError.ffmpegFailed("缺少句子音频：\(entry.id.uuidString)")
                    }
                    arguments += ["-i", sourceURL.path]
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

            let subtitleSegments = ordered.enumerated().map { librarySubtitleSegment($0.element, index: $0.offset + 1) }
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
                "-ss", preciseTime(segment.startTime),
                "-i", mediaURL.path,
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

    private func librarySubtitleSegment(_ entry: SentenceLibraryEntry, index: Int) -> SentenceSegment {
        SentenceSegment(
            id: entry.id,
            index: index,
            startTime: 0,
            endTime: max(0.05, entry.endTime - entry.startTime),
            text: entry.originalText,
            translation: entry.translation,
            note: entry.note
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
            "-vn",
            "-codec:a", "aac",
            "-b:a", "192k"
        ]
        if !album.isEmpty { arguments += ["-metadata", "album=\(album)"] }
        if !artist.isEmpty { arguments += ["-metadata", "artist=\(artist)"] }
        arguments += ["-movflags", "+faststart", outputURL.path]

        try runFFmpeg(
            arguments: arguments,
            duration: max(0.05, segments.reduce(0) { $0 + $1.duration }),
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
        var pending = ""
        var errorLines: [String] = []
        let safeDuration = max(0.05, duration.isFinite ? duration : 0.05)
        while true {
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
