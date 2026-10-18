import Foundation
import Testing
import Sparkle
@testable import Ghostty

/// The hold for a mandatory update: what the feed's critical marker means for a build,
/// and what a launch does with it. On the main actor: the hold puts up a window.
@Suite
@MainActor
struct MandatoryUpdateTests {
    // MARK: Reading the feed

    @Test func theMarkersVersionIsTheMinimumBuild() {
        let properties: [AnyHashable: Any] = [
            "sparkle:version": "18500",
            "sparkle:criticalUpdate": ["sparkle:version": "18201"],
        ]
        #expect(MandatoryUpdate.minimumBuild(in: properties, fallback: "18500") == 18201)
    }

    @Test func aMarkerWithoutAVersionMeansTheUpdateItself() {
        // generate_appcast with an empty --critical-update-version: critical for every
        // older build, so the update's own build is the floor.
        let properties: [AnyHashable: Any] = ["sparkle:criticalUpdate": [:] as [AnyHashable: Any]]
        #expect(MandatoryUpdate.minimumBuild(in: properties, fallback: "18500") == 18500)
        #expect(MandatoryUpdate.minimumBuild(in: [:], fallback: "18500") == 18500)
    }

    @Test func aBuildThatIsntANumberIsNoMinimum() {
        let properties: [AnyHashable: Any] = ["sparkle:criticalUpdate": ["sparkle:version": "tip"]]
        #expect(MandatoryUpdate.minimumBuild(in: properties, fallback: "tip-abc1234") == nil)
    }

    // MARK: Deciding

    @Test func onlyBuildsBelowTheMinimumAreHeld() {
        #expect(MandatoryUpdate.isHeld(minimumBuild: 18201, build: 18200))
        #expect(!MandatoryUpdate.isHeld(minimumBuild: 18201, build: 18201))
        #expect(!MandatoryUpdate.isHeld(minimumBuild: 18201, build: 18500))
    }

    @Test func nothingToCompareMeansNotHeld() {
        #expect(!MandatoryUpdate.isHeld(minimumBuild: nil, build: 18200))
        #expect(!MandatoryUpdate.isHeld(minimumBuild: 18201, build: nil))
    }

    // MARK: Remembering

    @Test func theFeedsAnswerIsRememberedAndForgotten() throws {
        let defaults = try isolatedDefaults()
        let update = MandatoryUpdate(controller: UpdateController(), defaults: defaults, build: "18200")
        #expect(update.rememberedMinimumBuild == nil)

        // A critical update: its marker's build is kept, and Maggie holds.
        update.found(try criticalItem(build: "18500", minimum: "18201"))
        #expect(update.rememberedMinimumBuild == 18201)
        #expect(update.isHolding)
        #expect(update.required?.versionString == "18500")

        // The feed later says nothing newer: the floor is gone, and so is the hold.
        var lifted = false
        update.onLift = { lifted = true }
        update.notFound()
        #expect(update.rememberedMinimumBuild == nil)
        #expect(!update.isHolding)
        #expect(lifted)
    }

    @Test func anUpdateThatIsntCriticalLiftsTheHold() throws {
        let defaults = try isolatedDefaults()
        defaults.set(18201, forKey: MandatoryUpdate.defaultsKey)
        let update = MandatoryUpdate(controller: UpdateController(), defaults: defaults, build: "18200")
        update.hold()
        #expect(update.isHolding)

        update.found(try item(build: "18500"))
        #expect(!update.isHolding)
        #expect(update.rememberedMinimumBuild == nil)
    }

    @Test func aBuildRememberedAsTooOldIsHeldBeforeTheFeedAnswers() throws {
        let defaults = try isolatedDefaults()
        defaults.set(18201, forKey: MandatoryUpdate.defaultsKey)

        let held = MandatoryUpdate(controller: UpdateController(), defaults: defaults, build: "18200")
        held.checkAtLaunch()
        #expect(held.isHolding)
        held.lift()

        let current = MandatoryUpdate(controller: UpdateController(), defaults: defaults, build: "18201")
        current.checkAtLaunch()
        #expect(!current.isHolding)
    }

    // MARK: Helpers

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "MandatoryUpdateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func item(build: String) throws -> SUAppcastItem {
        try #require(SUAppcastItem(dictionary: [
            "sparkle:version": build,
            "enclosure": ["url": "https://example.com/Maggie.zip"],
        ]))
    }

    private func criticalItem(build: String, minimum: String) throws -> SUAppcastItem {
        try #require(SUAppcastItem(dictionary: [
            "sparkle:version": build,
            "sparkle:criticalUpdate": ["sparkle:version": minimum],
            "enclosure": ["url": "https://example.com/Maggie.zip"],
        ]))
    }
}
