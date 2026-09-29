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

/// 说话人重命名弹窗内容（包含输入框、智能排重合并说明、取消与保存按钮）
public struct SpeakerRenamePopoverContent: View {
    public let roleLabel: String
    @State private var renameText: String
    public let language: AppLanguage
    @Binding public var isPresented: Bool
    public let onSave: (String, String) -> Void

    public init(
        roleLabel: String,
        initialText: String,
        language: AppLanguage,
        isPresented: Binding<Bool>,
        onSave: @escaping (String, String) -> Void
    ) {
        self.roleLabel = roleLabel
        self._renameText = State(initialValue: initialText)
        self.language = language
        self._isPresented = isPresented
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language == .en ? "Rename Speaker" : "修改说话人姓名")
                .font(.headline)

            TextField(language == .en ? "Enter speaker name" : "输入说话人姓名", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Text(language == .en
                 ? "If changed to an existing speaker name (e.g. s1 or Jim), all sentences will be automatically merged and deduplicated."
                 : "若修改为已存在的说话人（如 s1 或 Jim），其所属全部句子将自动合并排重。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220)

            HStack {
                Button(language == .en ? "Cancel" : "取消") {
                    isPresented = false
                }
                Spacer()
                Button(language == .en ? "Save" : "保存") {
                    isPresented = false
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(roleLabel, trimmed)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
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
    public let onSave: (String, String) -> Void

    @State private var isShowingRenamePopover: Bool = false

    public init(
        speakerRoleLabel: String,
        speakerRole: String? = nil,
        isOverlap: Bool = false,
        font: Font = .system(size: 10, weight: .semibold),
        tintColor: Color? = nil,
        shape: SpeakerBadgeShape = .capsule,
        language: AppLanguage,
        onSave: @escaping (String, String) -> Void
    ) {
        self.speakerRoleLabel = speakerRoleLabel
        self.speakerRole = speakerRole
        self.isOverlap = isOverlap
        self.font = font
        self.tintColor = tintColor
        self.shape = shape
        self.language = language
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
        .help(language == .en ? "Click to rename speaker (auto-merge duplicate)" : "点击修改说话人（重名自动合并）")
        .popover(isPresented: $isShowingRenamePopover, arrowEdge: .bottom) {
            SpeakerRenamePopoverContent(
                roleLabel: speakerRoleLabel,
                initialText: speakerRole ?? speakerRoleLabel,
                language: language,
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
