import Foundation
import Combine

/// 主窗口状态栏使用的后台操作进度。状态栏之外的工作区不再各自绘制
/// 进度条，避免同一项任务在断句列表和波形区重复出现。
public struct MainStatusProgress: Equatable, Sendable {
    public let fraction: Double
    public let phase: String
    public let currentItem: String

    public init(fraction: Double, phase: String, currentItem: String = "") {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.phase = phase
        self.currentItem = currentItem
    }
}

/// 主窗口共享的短时任务状态。断句导出等不属于 PlaybackEngine 的任务
/// 也通过这里进入底部状态栏，避免把视图局部状态泄漏到主窗口布局。
@MainActor
public final class MainStatusCenter: ObservableObject {
    public static let shared = MainStatusCenter()

    @Published public private(set) var progress: MainStatusProgress?
    @Published public private(set) var errorMessage: String?

    private var progressGeneration = UUID()

    private init() {}

    @discardableResult
    public func begin(_ progress: MainStatusProgress) -> UUID {
        let generation = UUID()
        progressGeneration = generation
        self.progress = progress
        return generation
    }

    public func update(_ progress: MainStatusProgress, generation: UUID) {
        guard progressGeneration == generation else { return }
        self.progress = progress
    }

    public func finish(generation: UUID) {
        guard progressGeneration == generation else { return }
        progress = nil
    }

    public func showError(_ message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = normalized.isEmpty ? nil : normalized
    }

    public func clearError() {
        errorMessage = nil
    }
}
