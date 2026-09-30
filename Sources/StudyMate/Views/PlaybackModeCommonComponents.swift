import SwiftUI
import AppKit

/// 播放模式通用工作区容器 (PlaybackWorkspaceContainer)
///
/// 统一管理顶部波形图工作区与底部双语字幕编辑区的展开、收起与动画过渡，
/// 消除 6 种界面模式工作区中大量重复的波形图与字幕编辑区布局代码。
public struct PlaybackWorkspaceContainer<Content: View>: View {
    let engine: PlaybackEngine
    let isWaveformsVisible: Bool
    let isSecondaryWaveformVisible: Bool
    let isSubtitleEditVisible: Bool
    let content: Content

    public init(
        engine: PlaybackEngine,
        isWaveformsVisible: Bool,
        isSecondaryWaveformVisible: Bool = true,
        isSubtitleEditVisible: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.engine = engine
        self.isWaveformsVisible = isWaveformsVisible
        self.isSecondaryWaveformVisible = isSecondaryWaveformVisible
        self.isSubtitleEditVisible = isSubtitleEditVisible
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isWaveformsVisible {
                VStack(spacing: 4) {
                    PrimaryWaveformView(
                        engine: engine,
                        isHeaderVisible: isSecondaryWaveformVisible
                    )
                    if isSecondaryWaveformVisible {
                        SecondaryWaveformView(engine: engine)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .studymateContentSurface(cornerRadius: 8)
                .clipped()
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isSubtitleEditVisible {
                SubtitleEditView(engine: engine)
                    .clipped()
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// 播放界面模式通用底部控制条 (PlaybackModeBottomBar)
///
/// 供列表模式、全文模式、句子模式、填空模式与反译模式统一复用，
/// 包含悬浮控制面板 FloatingVideoOSDView 与背景。
public struct PlaybackModeBottomBar: View {
    @ObservedObject var engine: PlaybackEngine
    @Binding var isScrubbing: Bool
    @Binding var isVolumeScrubbing: Bool

    public init(
        engine: PlaybackEngine,
        isScrubbing: Binding<Bool>,
        isVolumeScrubbing: Binding<Bool>
    ) {
        self.engine = engine
        self._isScrubbing = isScrubbing
        self._isVolumeScrubbing = isVolumeScrubbing
    }

    public var body: some View {
        HStack {
            Spacer()
            FloatingVideoOSDView(
                engine: engine,
                isScrubbing: $isScrubbing,
                isVolumeScrubbing: $isVolumeScrubbing
            )
            .padding(.vertical, 7)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(StudyMateMediaStyle.windowBackground)
    }
}

// MARK: - 说话人角色标签与改名弹窗组件（跨界面模式通用）

public enum SpeakerBadgeShape: Sendable, Equatable {
    case capsule
    case roundedRectangle(CGFloat)
}

/// 说话人重命名弹窗内容（支持选择仅修改此句 vs 修改所有相同角色、候选单一说话人快捷选择、输入框、智能排重合并说明、取消与保存按钮）
public struct SpeakerRenamePopoverContent: View {
    public let roleLabel: String
    @State private var renameText: String
    @State private var changeScope: SpeakerChangeScope
    public let sentenceIndex: Int?
    public let matchingCount: Int
    public let language: AppLanguage
    public var availableSpeakers: [String: String]
    @Binding public var isPresented: Bool
    public let onSave: (String, String, SpeakerChangeScope) -> Void

    public init(
        roleLabel: String,
        initialText: String,
        sentenceIndex: Int? = nil,
        matchingCount: Int = 1,
        language: AppLanguage,
        availableSpeakers: [String: String] = [:],
        isPresented: Binding<Bool>,
        onSave: @escaping (String, String, SpeakerChangeScope) -> Void
    ) {
        self.roleLabel = roleLabel
        self._renameText = State(initialValue: initialText)
        let isComp = SpeakerRoleManager.isCompositeRole(roleLabel)
        self._changeScope = State(initialValue: isComp ? .thisSentenceOnly : .allMatching)
        self.sentenceIndex = sentenceIndex
        self.matchingCount = max(1, matchingCount)
        self.language = language
        self.availableSpeakers = availableSpeakers
        self._isPresented = isPresented
        self.onSave = onSave
    }

    private var isComposite: Bool {
        SpeakerRoleManager.isCompositeRole(roleLabel)
    }

    private var candidates: [String] {
        SpeakerRoleManager.extractCandidateRoles(from: roleLabel)
    }

    private var quickOptions: [String] {
        if isComposite {
            return candidates
        } else {
            let normalizedSelf = SpeakerRoleManager.normalizeRoleKey(roleLabel)
            var others = [String]()
            for key in availableSpeakers.keys.sorted() {
                let norm = SpeakerRoleManager.normalizeRoleKey(key)
                if norm != normalizedSelf && !others.contains(norm) {
                    others.append(norm)
                }
            }
            return others
        }
    }

    private func candidateDisplayName(for cand: String) -> String {
        let normalized = SpeakerRoleManager.normalizeRoleKey(cand)
        if let name = availableSpeakers[normalized], !name.isEmpty, name.caseInsensitiveCompare(normalized) != .orderedSame {
            return "\(normalized) (\(name))"
        }
        return normalized
    }

    private var scopeAllTitle: String {
        if matchingCount > 1 {
            return language == .en ? "All Matching (\(matchingCount))" : "所有相同角色 (\(matchingCount)句)"
        } else {
            return language == .en ? "All Matching" : "所有相同角色"
        }
    }

    private var headerTitle: String {
        if changeScope == .thisSentenceOnly {
            return language == .en ? "Change Sentence Speaker" : "修改此句说话人"
        } else {
            if isComposite {
                return language == .en ? "Change All Matching Speakers" : "修改所有相同角色"
            } else {
                return language == .en ? "Rename Speaker" : "修改说话人姓名"
            }
        }
    }

    private var sentenceScopeDescription: String {
        let idxStr = sentenceIndex.map { "#\($0) " } ?? ""
        if language == .en {
            return "Only changes the speaker for sentence \(idxStr). Other sentences remain unchanged."
        } else {
            return "仅修改当前句（\(idxStr)）的角色，不影响其它任何句子。"
        }
    }

    private var allMatchingScopeDescription: String {
        if isComposite {
            if language == .en {
                return "Resolves all \(matchingCount) sentences marked as \(roleLabel) across the project."
            } else {
                return "将工程中所有标记为「\(roleLabel)」的句子（共 \(matchingCount) 句）全部修改为指定发言人。"
            }
        } else {
            if language == .en {
                return "Applies to all \(matchingCount) sentences marked as \(roleLabel). Existing speakers with same name will be merged."
            } else {
                return "将工程中所有标记为「\(roleLabel)」的句子（共 \(matchingCount) 句）全部统一修改。若与已有说话人重名将自动合并排重。"
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headerTitle)
                .font(.headline)

            // 范围选择分段控件
            Picker("", selection: $changeScope) {
                Text(language == .en ? "This Sentence Only" : "仅此句")
                    .tag(SpeakerChangeScope.thisSentenceOnly)
                Text(scopeAllTitle)
                    .tag(SpeakerChangeScope.allMatching)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)

            if !quickOptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isComposite
                         ? (language == .en ? "Quickly choose speaker:" : "快捷选择当前句发言人：")
                         : (language == .en ? "Quickly switch to existing speaker:" : "快捷切换为已有说话人："))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        ForEach(quickOptions, id: \.self) { opt in
                            Button {
                                handleSave(target: opt)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 9))
                                    Text(candidateDisplayName(for: opt))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(StudyMateMediaStyle.accent.opacity(0.12))
                                .foregroundColor(StudyMateMediaStyle.accent)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(language == .en ? "Set to \(opt)" : "设定为 \(opt)")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(language == .en ? "Or enter speaker name / ID (e.g. s2, Jim):" : "或输入角色代号/姓名（如 s2、Jim）：")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField(language == .en ? "Enter speaker name" : "输入说话人姓名", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit {
                        handleSave(target: renameText)
                    }
            }

            Group {
                if changeScope == .thisSentenceOnly {
                    Text(sentenceScopeDescription)
                } else {
                    Text(allMatchingScopeDescription)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 250)

            HStack {
                Button(language == .en ? "Cancel" : "取消") {
                    isPresented = false
                }
                Spacer()
                Button(language == .en ? "Save" : "保存") {
                    handleSave(target: renameText)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func handleSave(target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 若未做任何更改，直接关闭
        if trimmed.caseInsensitiveCompare(roleLabel) == .orderedSame {
            isPresented = false
            return
        }

        if changeScope == .allMatching {
            isPresented = false
            confirmBatchSpeakerChange(targetName: trimmed)
        } else {
            isPresented = false
            onSave(roleLabel, trimmed, changeScope)
        }
    }

    private func confirmBatchSpeakerChange(targetName: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = language == .en ? "Confirm Speaker Change" : "确认修改角色"
            alert.informativeText = language == .en
                ? "Are you sure you want to change '\(roleLabel)' to '\(targetName)', for all \(matchingCount) sentences?"
                : "你确定要修改 \(roleLabel) 为 \(targetName), 共 \(matchingCount) 句吗?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: language == .en ? "Confirm" : "确定")
            alert.addButton(withTitle: language == .en ? "Cancel" : "取消")

            let targetWindow = NSApp.windows.first(where: { $0.isKeyWindow && $0.isVisible && !($0 is NSPanel) })
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })

            if let targetWindow {
                alert.beginSheetModal(for: targetWindow) { response in
                    if response == .alertFirstButtonReturn {
                        onSave(roleLabel, targetName, changeScope)
                    }
                }
            } else {
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    onSave(roleLabel, targetName, changeScope)
                }
            }
        }
    }
}

/// 说话人角色胶囊按钮（点击唤出修改弹窗，支持样式自适应）
public struct SpeakerBadgeButton: View {
    public let speakerRoleLabel: String
    public let speakerRole: String?
    public let isOverlap: Bool
    public var font: Font
    public var tintColor: Color?
    public var shape: SpeakerBadgeShape
    public let language: AppLanguage
    public var availableSpeakers: [String: String]
    public var sentenceIndex: Int?
    public var matchingCount: Int
    public let onSave: (String, String, SpeakerChangeScope) -> Void

    @State private var isShowingRenamePopover: Bool = false

    public init(
        speakerRoleLabel: String,
        speakerRole: String? = nil,
        isOverlap: Bool = false,
        font: Font = .system(size: 10, weight: .semibold),
        tintColor: Color? = nil,
        shape: SpeakerBadgeShape = .capsule,
        language: AppLanguage,
        availableSpeakers: [String: String] = [:],
        sentenceIndex: Int? = nil,
        matchingCount: Int = 1,
        onSave: @escaping (String, String, SpeakerChangeScope) -> Void
    ) {
        self.speakerRoleLabel = speakerRoleLabel
        self.speakerRole = speakerRole
        self.isOverlap = isOverlap
        self.font = font
        self.tintColor = tintColor
        self.shape = shape
        self.language = language
        self.availableSpeakers = availableSpeakers
        self.sentenceIndex = sentenceIndex
        self.matchingCount = matchingCount
        self.onSave = onSave
    }

    private var effectiveColor: Color {
        if let tintColor { return tintColor }
        return isOverlap ? StudyMateMediaStyle.warning : StudyMateMediaStyle.accent
    }

    public var body: some View {
        Button {
            isShowingRenamePopover = true
        } label: {
            badgeLabel
        }
        .buttonStyle(.plain)
        .help(language == .en
              ? "Click to change speaker (this sentence or all matching)"
              : "点击修改说话人（可选择仅此句或所有相同角色）")
        .popover(isPresented: $isShowingRenamePopover, arrowEdge: .bottom) {
            SpeakerRenamePopoverContent(
                roleLabel: speakerRoleLabel,
                initialText: SpeakerRoleManager.isCompositeRole(speakerRoleLabel) ? "" : (speakerRole ?? speakerRoleLabel),
                sentenceIndex: sentenceIndex,
                matchingCount: matchingCount,
                language: language,
                availableSpeakers: availableSpeakers,
                isPresented: $isShowingRenamePopover,
                onSave: onSave
            )
        }
    }

    @ViewBuilder
    private var badgeLabel: some View {
        let text = Text(speakerRoleLabel)
            .font(font)
            .foregroundStyle(effectiveColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(effectiveColor.opacity(0.12))

        switch shape {
        case .capsule:
            text.clipShape(Capsule())
        case .roundedRectangle(let radius):
            text.clipShape(RoundedRectangle(cornerRadius: radius))
        }
    }
}
