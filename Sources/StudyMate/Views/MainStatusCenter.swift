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

/// 第三层：重要报错与任务中心记录项
public struct StatusIssueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let message: String
    public let level: IssueLevel
    public let actionTitle: String?
    public let actionKind: IssueActionKind

    public enum IssueLevel: Sendable {
        case warning
        case error
    }

    public enum IssueActionKind: Sendable {
        case none
        case projectRecovery
        case retryAI
        case retryTranslation
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        message: String,
        level: IssueLevel = .warning,
        actionTitle: String? = nil,
        actionKind: IssueActionKind = .none
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.level = level
        self.actionTitle = actionTitle
        self.actionKind = actionKind
    }
}

/// 主窗口共享的短时任务状态与问题通知中心。
@MainActor
public final class MainStatusCenter: ObservableObject {
    public static let shared = MainStatusCenter()

    @Published public private(set) var progress: MainStatusProgress?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var successMessage: String?
    @Published public private(set) var issues: [StatusIssueItem] = []
    @Published public private(set) var lastIssueToken = UUID()

    private var progressGeneration = UUID()
    private var successGeneration = UUID()

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

    public func showSuccess(_ message: String, autoDismissAfter seconds: Double = 3.0) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let generation = UUID()
        successGeneration = generation
        successMessage = normalized
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.successGeneration == generation else { return }
            self.successMessage = nil
        }
    }

    public func clearSuccess() {
        successGeneration = UUID()
        successMessage = nil
    }

    public func showError(_ message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        progressGeneration = UUID()
        progress = nil
        errorMessage = normalized.isEmpty ? nil : normalized
        if !normalized.isEmpty {
            recordIssue(message: normalized, level: .error)
        }
    }

    @discardableResult
    public func recordIssue(
        message: String,
        level: StatusIssueItem.IssueLevel = .warning,
        actionTitle: String? = nil,
        actionKind: StatusIssueItem.IssueActionKind = .none
    ) -> UUID {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return UUID() }

        // 如果列表中已有完全相同的未解决问题，更新时间戳并置顶
        if let existingIndex = issues.firstIndex(where: { $0.message == normalized }) {
            let existing = issues[existingIndex]
            let updated = StatusIssueItem(
                id: existing.id,
                timestamp: Date(),
                message: normalized,
                level: level,
                actionTitle: actionTitle ?? existing.actionTitle,
                actionKind: actionKind != .none ? actionKind : existing.actionKind
            )
            issues.remove(at: existingIndex)
            issues.insert(updated, at: 0)
            lastIssueToken = UUID()
            return existing.id
        }

        let newIssue = StatusIssueItem(
            message: normalized,
            level: level,
            actionTitle: actionTitle,
            actionKind: actionKind
        )
        issues.insert(newIssue, at: 0)
        lastIssueToken = UUID()
        return newIssue.id
    }

    public func dismissIssue(id: UUID) {
        issues.removeAll { $0.id == id }
        if issues.isEmpty {
            errorMessage = nil
        }
    }

    public func clearAllIssues() {
        issues.removeAll()
        errorMessage = nil
    }

    public func clearError() {
        errorMessage = nil
        clearAllIssues()
    }
}
