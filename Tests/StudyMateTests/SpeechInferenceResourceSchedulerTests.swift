import XCTest
@testable import StudyMateKit

final class SpeechInferenceResourceSchedulerTests: XCTestCase {
    func testCancelledWaiterDoesNotRunAndDoesNotConsumePermit() async throws {
        let scheduler = SpeechInferenceResourceScheduler()
        let gate = SchedulerTestGate()
        let execution = SchedulerTestFlag()

        let first = Task {
            try await scheduler.withExclusiveStage {
                await gate.markStartedAndWait()
            }
        }
        await gate.waitUntilStarted()

        let cancelled = Task {
            try await scheduler.withExclusiveStage {
                await execution.setTrue()
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        await gate.open()

        try await first.value
        do {
            try await cancelled.value
            XCTFail("A cancelled queued stage must not execute")
        } catch is CancellationError {
            // Expected.
        }
        let didExecute = await execution.value
        XCTAssertFalse(didExecute)

        // A cancelled waiter must not leak the single permit.
        let result = try await scheduler.withExclusiveStage { 42 }
        XCTAssertEqual(result, 42)
    }
}

private actor SchedulerTestGate {
    private var isStarted = false
    private var isOpen = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWait() async {
        isStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor SchedulerTestFlag {
    private(set) var value = false

    func setTrue() {
        value = true
    }
}
