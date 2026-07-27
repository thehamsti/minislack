import Foundation
import Testing
@testable import MiniSlack

struct SlackRequestCoordinatorTests {
    @Test
    func reservationsSpaceBurstsWithoutDelayingAnIdleRequest() {
        let clock = ContinuousClock()
        let start = clock.now
        var pacing = SlackRequestPacingState(minimumSpacing: .milliseconds(50))

        let first = pacing.reserve(at: start)
        let second = pacing.reserve(at: start)
        let third = pacing.reserve(at: start)
        let afterIdle = pacing.reserve(at: start.advanced(by: .seconds(1)))

        #expect(first.deadline == start)
        #expect(second.deadline == start.advanced(by: .milliseconds(50)))
        #expect(third.deadline == start.advanced(by: .milliseconds(100)))
        #expect(afterIdle.deadline == start.advanced(by: .seconds(1)))
    }

    @Test
    func retryAfterExtendsTheGlobalPauseWithoutShorteningIt() {
        let clock = ContinuousClock()
        let start = clock.now
        var pacing = SlackRequestPacingState(minimumSpacing: .milliseconds(50))

        pacing.pause(for: .seconds(4), at: start)
        pacing.pause(for: .seconds(1), at: start.advanced(by: .seconds(1)))
        let reservation = pacing.reserve(at: start)

        #expect(pacing.pausedUntil == start.advanced(by: .seconds(4)))
        #expect(reservation.deadline == start.advanced(by: .seconds(4)))
    }

    @Test
    func pauseInvalidatesOnlyReservationsThatWouldLeaveTooEarly() {
        let clock = ContinuousClock()
        let start = clock.now
        var pacing = SlackRequestPacingState(minimumSpacing: .seconds(1))
        let first = pacing.reserve(at: start)
        let second = pacing.reserve(at: start)
        let third = pacing.reserve(at: start)

        pacing.pause(for: .milliseconds(1_500), at: start)

        #expect(!pacing.isReady(first, at: start.advanced(by: .seconds(2))))
        #expect(!pacing.isReady(second, at: start.advanced(by: .seconds(2))))
        #expect(pacing.isReady(third, at: start.advanced(by: .seconds(2))))

        let replacement = pacing.reserve(at: start.advanced(by: .seconds(2)))
        #expect(replacement.deadline == start.advanced(by: .seconds(3)))
    }

    @Test
    func waitPropagatesSchedulerCancellation() async {
        let clock = ContinuousClock()
        let start = clock.now
        let coordinator = SlackRequestCoordinator(
            minimumSpacing: .milliseconds(50),
            now: { start },
            sleepUntil: { _ in throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            try await coordinator.waitIfNeeded()
        }
    }

    @Test
    func rateLimitPauseOnlyDelaysTheAffectedSlackMethod() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let recorder = PacingDeadlineRecorder()
        let coordinator = SlackRequestCoordinator(
            minimumSpacing: .milliseconds(50),
            now: { start },
            sleepUntil: { deadline in
                recorder.append(deadline)
            }
        )

        await coordinator.pause(for: 60, method: "conversations.members")
        try await coordinator.waitIfNeeded(method: "users.list")

        #expect(recorder.values == [start])
    }

    @Test
    func rateLimitPauseOnlyDelaysTheAffectedCredentialScope() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let recorder = PacingDeadlineRecorder()
        let coordinator = SlackRequestCoordinator(
            minimumSpacing: .milliseconds(50),
            now: { start },
            sleepUntil: { deadline in
                recorder.append(deadline)
            }
        )

        await coordinator.pause(
            for: 60,
            method: "conversations.list",
            credentialScope: 1
        )
        try await coordinator.waitIfNeeded(
            method: "conversations.list",
            credentialScope: 2
        )

        #expect(recorder.values == [start])
    }
}

private final class PacingDeadlineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [ContinuousClock.Instant] = []

    var values: [ContinuousClock.Instant] {
        lock.withLock { deadlines }
    }

    func append(_ deadline: ContinuousClock.Instant) {
        lock.withLock {
            deadlines.append(deadline)
        }
    }
}
