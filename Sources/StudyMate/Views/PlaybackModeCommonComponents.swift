import SwiftUI
import AppKit

/// 播放模式通用工作区容器 (PlaybackWorkspaceContainer)
///
/// 统一管理顶部波形图工作区与底部双语字幕编辑区的展开、收起与动画过渡，
/// 消除 5 种界面模式工作区中大量重复的波形图与字幕编辑区布局代码。
public struct PlaybackWorkspaceContainer<Content: View>: View {
    @ObservedObject var engine: PlaybackEngine
    let isWaveformsVisible: Bool
    let isSubtitleEditVisible: Bool
    let content: Content

    public init(
        engine: PlaybackEngine,
        isWaveformsVisible: Bool,
        isSubtitleEditVisible: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.engine = engine
        self.isWaveformsVisible = isWaveformsVisible
        self.isSubtitleEditVisible = isSubtitleEditVisible
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isWaveformsVisible {
                VStack(spacing: 4) {
                    PrimaryWaveformView(engine: engine)
                    SecondaryWaveformView(engine: engine)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .studymateContentSurface(cornerRadius: 8)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isSubtitleEditVisible {
                SubtitleEditView(engine: engine)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 播放界面模式通用底部控制条 (PlaybackModeBottomBar)
///
/// 供列表模式、全文模式、句子模式、填空模式统一复用，
/// 包含悬浮控制面板 FloatingVideoOSDView、背景及顶部分割线。
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
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(StudyMateMediaStyle.separator),
            alignment: .top
        )
    }
}
