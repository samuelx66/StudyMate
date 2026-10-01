import SwiftUI

/// 适用于独立全屏或辅助窗口（如句库、生词本）的原生轻量级就近浮动状态胶囊 (HUD / Floating Toast)
/// 遵循 macOS 26 视觉规范：超薄/超厚材质毛玻璃质感、Capsule 胶囊形态、柔和微弹簧升起动画，
/// 解决全屏或独立窗口下操作反馈彻底隐形的问题。
public struct WindowFloatingStatusToast: View {
    @ObservedObject private var statusCenter = MainStatusCenter.shared
    private let bottomPadding: CGFloat

    public init(bottomPadding: CGFloat = 20) {
        self.bottomPadding = bottomPadding
    }

    public var body: some View {
        Group {
            if let errorMsg = statusCenter.errorMessage {
                toastView(
                    text: errorMsg,
                    systemImage: "exclamationmark.triangle.fill",
                    tintColor: Color.red
                )
            } else if let successMsg = statusCenter.successMessage {
                toastView(
                    text: successMsg,
                    systemImage: "checkmark.circle.fill",
                    tintColor: Color.green
                )
            }
        }
        .padding(.bottom, bottomPadding)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: statusCenter.successMessage)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: statusCenter.errorMessage)
    }

    @ViewBuilder
    private func toastView(text: String, systemImage: String, tintColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tintColor)

            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) {
                statusCenter.clearSuccess()
                statusCenter.clearError()
            }
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                removal: .opacity.combined(with: .scale(scale: 0.95))
            )
        )
        .help("点击关闭提示")
    }
}
