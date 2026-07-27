import Foundation

struct SlackRequestPacingState: Sendable {
    struct Reservation: Equatable, Sendable {
        let deadline: ContinuousClock.Instant
    }

    let minimumSpacing: Duration
    private(set) var nextReservationAt: ContinuousClock.Instant?
    private(set) var pausedUntil: ContinuousClock.Instant?

    init(minimumSpacing: Duration) {
        self.minimumSpacing = max(.zero, minimumSpacing)
    }

    mutating func reserve(at now: ContinuousClock.Instant) -> Reservation {
        let deadline = max(now, nextReservationAt ?? now, pausedUntil ?? now)
        nextReservationAt = deadline.advanced(by: minimumSpacing)
        return Reservation(deadline: deadline)
    }

    mutating func pause(
        for duration: Duration,
        at now: ContinuousClock.Instant
    ) {
        let deadline = now.advanced(by: max(.zero, duration))
        pausedUntil = max(pausedUntil ?? deadline, deadline)
        nextReservationAt = max(nextReservationAt ?? deadline, deadline)
    }

    func isReady(
        _ reservation: Reservation,
        at now: ContinuousClock.Instant
    ) -> Bool {
        guard now >= reservation.deadline else {
            return false
        }
        guard let pausedUntil else {
            return true
        }
        return reservation.deadline >= pausedUntil
    }
}

actor SlackRequestCoordinator {
    private struct PacingKey: Hashable {
        let method: String
        let credentialScope: Int
    }

    typealias Now = @Sendable () -> ContinuousClock.Instant
    typealias SleepUntil = @Sendable (ContinuousClock.Instant) async throws -> Void

    private let minimumSpacing: Duration
    private var pacingByKey: [PacingKey: SlackRequestPacingState] = [:]
    private let now: Now
    private let sleepUntil: SleepUntil

    init(minimumSpacing: Duration = .milliseconds(50)) {
        let clock = ContinuousClock()
        self.minimumSpacing = minimumSpacing
        now = { clock.now }
        sleepUntil = { deadline in
            try await clock.sleep(until: deadline)
        }
    }

    init(
        minimumSpacing: Duration,
        now: @escaping Now,
        sleepUntil: @escaping SleepUntil
    ) {
        self.minimumSpacing = minimumSpacing
        self.now = now
        self.sleepUntil = sleepUntil
    }

    func waitIfNeeded(
        method: String = "default",
        credentialScope: Int = 0
    ) async throws {
        let key = PacingKey(method: method, credentialScope: credentialScope)
        var pacing = pacingByKey[key]
            ?? SlackRequestPacingState(minimumSpacing: minimumSpacing)
        var reservation = pacing.reserve(at: now())
        pacingByKey[key] = pacing
        while true {
            try Task.checkCancellation()
            try await sleepUntil(reservation.deadline)
            let currentTime = now()
            pacing = pacingByKey[key]
                ?? SlackRequestPacingState(minimumSpacing: minimumSpacing)
            guard !pacing.isReady(reservation, at: currentTime) else {
                return
            }
            reservation = pacing.reserve(at: currentTime)
            pacingByKey[key] = pacing
        }
    }

    func pause(
        for seconds: Int,
        method: String = "default",
        credentialScope: Int = 0
    ) {
        let key = PacingKey(method: method, credentialScope: credentialScope)
        var pacing = pacingByKey[key]
            ?? SlackRequestPacingState(minimumSpacing: minimumSpacing)
        pacing.pause(
            for: .seconds(max(0, seconds)),
            at: now()
        )
        pacingByKey[key] = pacing
    }
}
