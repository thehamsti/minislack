import Foundation
import Testing
@testable import MiniSlack

struct ReactionHoverSummaryTests {
    @Test
    func reactorDisplayNamesPreferResolvedNamesAndPreserveOrder() {
        let reaction = Reaction(
            name: "thumbsup",
            emoji: "👍",
            count: 3,
            userIDs: ["U1", "U2", "U3"]
        )
        let names = reaction.reactorDisplayNames { userID in
            switch userID {
            case "U1": "Ada"
            case "U3": "Grace"
            default: nil
            }
        }

        #expect(names == ["Ada", "U2", "Grace"])
    }

    @Test
    func hoverSummaryFormatsOneTwoAndManyReactors() {
        let one = Reaction(
            name: "eyes",
            emoji: "👀",
            count: 1,
            userIDs: ["U1"]
        )
        #expect(
            one.hoverSummary { _ in "Ada" } == "Ada reacted with 👀"
        )

        let two = Reaction(
            name: "heart",
            emoji: "❤️",
            count: 2,
            userIDs: ["U1", "U2"]
        )
        #expect(
            two.hoverSummary {
                $0 == "U1" ? "Ada" : "Linus"
            } == "Ada and Linus reacted with ❤️"
        )

        let many = Reaction(
            name: "tada",
            emoji: "🎉",
            count: 3,
            userIDs: ["U1", "U2", "U3"]
        )
        #expect(
            many.hoverSummary {
                switch $0 {
                case "U1": "Ada"
                case "U2": "Linus"
                default: "Grace"
                }
            } == "Ada, Linus, and Grace reacted with 🎉"
        )
    }

    @Test
    func hoverSummaryFallsBackToCountWhenUserIDsAreMissing() {
        let single = Reaction(name: "joy", emoji: "😂", count: 1)
        #expect(single.hoverSummary { _ in nil } == "1 person reacted with 😂")

        let plural = Reaction(name: "joy", emoji: "😂", count: 4)
        #expect(plural.hoverSummary { _ in nil } == "4 people reacted with 😂")
    }

    @Test
    func reactorDisplayNamesIgnoreBlankResolvedNames() {
        let reaction = Reaction(
            name: "white_check_mark",
            emoji: "✅",
            count: 1,
            userIDs: ["U1"]
        )
        #expect(
            reaction.reactorDisplayNames { _ in "   " } == ["U1"]
        )
    }
}
