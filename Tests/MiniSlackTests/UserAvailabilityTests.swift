import Foundation
import Testing
@testable import MiniSlack

struct UserAvailabilityTests {
    private let now = Date(timeIntervalSince1970: 2_000)

    @Test
    func customStatusExpiresAtItsBoundary() {
        let status = UserCustomStatus(
            text: "In focus time",
            emoji: ":spiral_calendar_pad:",
            expiresAt: now
        )

        #expect(status.isActive(at: now.addingTimeInterval(-0.001)))
        #expect(!status.isActive(at: now))
        #expect(!status.isActive(at: now.addingTimeInterval(1)))
    }

    @Test
    func customStatusWithoutExpirationRemainsActive() {
        let status = UserCustomStatus(
            text: "Working remotely",
            emoji: ":house_with_garden:",
            expiresAt: nil
        )

        #expect(status.isActive(at: .distantPast))
        #expect(status.isActive(at: .distantFuture))
    }

    @Test
    func doNotDisturbExpiresAtItsBoundary() {
        let doNotDisturb = UserDoNotDisturb(isEnabled: true, endsAt: now)

        #expect(doNotDisturb.isActive(at: now.addingTimeInterval(-0.001)))
        #expect(!doNotDisturb.isActive(at: now))
        #expect(!UserDoNotDisturb(isEnabled: false, endsAt: nil).isActive(at: now))
    }

    @Test
    func scheduledDoNotDisturbIsInactiveBeforeTheWindowStarts() {
        // Slack often returns dnd_enabled + the *next* overnight window while
        // the user is free during the workday. Without a start bound, every
        // scheduled user looks like they are currently in DND.
        let doNotDisturb = UserDoNotDisturb(
            isEnabled: true,
            endsAt: now.addingTimeInterval(36_000),
            startsAt: now.addingTimeInterval(28_800)
        )

        #expect(!doNotDisturb.isActive(at: now))
        #expect(doNotDisturb.isActive(at: now.addingTimeInterval(28_800)))
        #expect(doNotDisturb.isActive(at: now.addingTimeInterval(30_000)))
        #expect(!doNotDisturb.isActive(at: now.addingTimeInterval(36_000)))
    }

    @Test
    func snoozeDoNotDisturbWithoutStartRemainsActiveUntilEnd() {
        let doNotDisturb = UserDoNotDisturb(
            isEnabled: true,
            endsAt: now.addingTimeInterval(3_600),
            startsAt: nil
        )

        #expect(doNotDisturb.isActive(at: now))
        #expect(!doNotDisturb.isActive(at: now.addingTimeInterval(3_600)))
    }

    @Test
    func displayAndAccessibilityPreserveIndependentAvailabilitySignals() {
        let availability = UserAvailability(
            presence: .active,
            customStatus: UserCustomStatus(
                text: "In focus time",
                emoji: ":spiral_calendar_pad:",
                expiresAt: now.addingTimeInterval(600)
            ),
            doNotDisturb: UserDoNotDisturb(
                isEnabled: true,
                endsAt: now.addingTimeInterval(300)
            ),
            fetchedAt: now.addingTimeInterval(-5)
        )

        #expect(availability.displayText(at: now) == ":spiral_calendar_pad: In focus time")
        #expect(
            availability.accessibilityLabel(at: now)
                == "Active, Do not disturb, Status: In focus time"
        )
        #expect(availability.presence == .active)
        #expect(availability.isDoNotDisturbActive(at: now))
        #expect(availability.activeCustomStatus(at: now)?.text == "In focus time")
    }

    @Test
    func expiredCustomStatusFallsBackWithoutHidingDoNotDisturb() {
        let availability = UserAvailability(
            presence: .away,
            customStatus: UserCustomStatus(
                text: "Back soon",
                emoji: ":wave:",
                expiresAt: now
            ),
            doNotDisturb: UserDoNotDisturb(isEnabled: true, endsAt: nil)
        )

        #expect(availability.displayText(at: now) == "Do not disturb")
        #expect(availability.accessibilityLabel(at: now) == "Away, Do not disturb")
    }

    @Test(
        arguments: [
            (UserPresence.active, "Active"),
            (UserPresence.away, "Away"),
            (UserPresence.offline, "Offline"),
            (UserPresence.unknown, "Status unavailable"),
            (UserPresence.notApplicable, "Presence not applicable"),
        ]
    )
    func presenceUsesTruthfulLabels(presence: UserPresence, expected: String) {
        let availability = UserAvailability(presence: presence)

        #expect(availability.displayText(at: now) == expected)
        #expect(availability.accessibilityLabel(at: now) == expected)
    }

    @Test
    func legacyWorkspaceUserInitializerPreservesExistingSemantics() {
        let avatarURL = URL(string: "https://avatars.slack-edge.com/maya.png")
        let active = WorkspaceUser(
            id: "U1",
            displayName: "Maya Chen",
            status: "Product",
            isActive: true,
            avatarURL: avatarURL
        )
        let away = WorkspaceUser(
            id: "U2",
            displayName: "Alex Morgan",
            status: "",
            isActive: false
        )

        #expect(active.profileTitle == "Product")
        #expect(active.availability.presence == .active)
        #expect(active.status == "Product")
        #expect(active.isActive)
        #expect(active.avatarURL == avatarURL)
        #expect(away.profileTitle == nil)
        #expect(away.availability.presence == .away)
        #expect(away.status == "Away")
        #expect(!away.isActive)
    }
}
