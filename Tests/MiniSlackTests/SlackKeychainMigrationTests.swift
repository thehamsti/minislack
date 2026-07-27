import Foundation
import Testing
@testable import MiniSlack

@Suite
struct SlackKeychainMigrationTests {
    @Test
    func currentItemWinsWithoutMigration() {
        let current = Data("current".utf8)
        let legacy = Data("legacy".utf8)

        let result = SlackKeychainMigration.resolve(current: current, legacy: legacy)

        #expect(result.data == current)
        #expect(result.needsMigration == false)
    }

    @Test
    func legacyItemIsSelectedForMigration() {
        let legacy = Data("legacy".utf8)

        let result = SlackKeychainMigration.resolve(current: nil, legacy: legacy)

        #expect(result.data == legacy)
        #expect(result.needsMigration)
    }

    @Test
    func missingItemsDoNotTriggerMigration() {
        let result = SlackKeychainMigration.resolve(current: nil, legacy: nil)

        #expect(result.data == nil)
        #expect(result.needsMigration == false)
    }

    @Test
    func migratedItemsUseADistinctServiceFromEveryLegacyNamespace() {
        #expect(!SlackKeychainNamespace.legacyServices.isEmpty)
        #expect(
            SlackKeychainNamespace.legacyServices.allSatisfy {
                $0 != SlackKeychainNamespace.currentService
            }
        )
    }
}
