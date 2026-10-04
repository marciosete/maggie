import Foundation
import Testing
@testable import Ghostty

@Suite
struct MaggieTests {
    @Test func maggiesReleaseNotesAreItsGitHubRelease() {
        #expect(Maggie.releaseNotesURL(version: "0.7.0", maggie: true)?.absoluteString
            == "https://github.com/marciosete/maggie/releases/tag/v0.7.0")
    }

    @Test func ghosttysReleaseNotesStayOnItsSite() {
        #expect(Maggie.releaseNotesURL(version: "1.2.3", maggie: false)?.absoluteString
            == "https://ghostty.org/docs/install/release-notes/1-2-3")
    }

    @Test func commitsAndComparisonsAreInTheAppsOwnRepository() {
        #expect(Maggie.commitURL("abc1234", maggie: true)?.absoluteString
            == "https://github.com/marciosete/maggie/commit/abc1234")
        #expect(Maggie.compareURL(from: "abc1234", to: "def5678", maggie: true)?.absoluteString
            == "https://github.com/marciosete/maggie/compare/abc1234...def5678")
        #expect(Maggie.commitURL("abc1234", maggie: false)?.absoluteString
            == "https://github.com/ghostty-org/ghostty/commit/abc1234")
    }

    @Test func anUpdateLinksToTheBuildsOwnReleaseNotes() {
        // A test host isn't Maggie, so the update points at Ghostty's notes here; the
        // Maggie case is the helper above.
        let notes = UpdateState.ReleaseNotes(displayVersionString: "1.2.3", currentCommit: nil)
        #expect(notes?.url == Maggie.releaseNotesURL(version: "1.2.3"))
        #expect(notes?.label == "View Release Notes")
    }
}
