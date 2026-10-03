import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudePluginTests {
    @Test func theBundledPluginIsTheOnlyDirectoryWhenNoneIsSet() {
        #expect(ClaudePlugin.pluginDirectories(nil, adding: "/App/ClaudePlugin") == "/App/ClaudePlugin")
        #expect(ClaudePlugin.pluginDirectories("", adding: "/App/ClaudePlugin") == "/App/ClaudePlugin")
    }

    @Test func directoriesAlreadySetAreKeptAhead() {
        #expect(ClaudePlugin.pluginDirectories("/mine:/theirs", adding: "/App/ClaudePlugin")
            == "/mine:/theirs:/App/ClaudePlugin")
    }

    @Test func theBundledPluginIsNotListedTwice() {
        #expect(ClaudePlugin.pluginDirectories("/App/ClaudePlugin:/mine", adding: "/App/ClaudePlugin")
            == "/App/ClaudePlugin:/mine")
    }

    @Test func theBundleShipsThePlugin() throws {
        let directory = try #require(ClaudePlugin.directory)
        let skill = directory.appendingPathComponent("skills/force-multiplier")
        for file in ["SKILL.md", "loc.sh", "loc-report.html"] {
            #expect(FileManager.default.fileExists(atPath: skill.appendingPathComponent(file).path), "\(file)")
        }
    }
}
