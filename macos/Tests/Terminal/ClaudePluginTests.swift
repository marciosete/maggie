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

    @Test func frontmatterIsReadUpToItsClosingLine() {
        let text = "---\nname: force-multiplier\ndescription: Measure it: lines per day\n---\nname: body\n"
        #expect(ClaudePlugin.frontmatter(text) == ["name": "force-multiplier", "description": "Measure it: lines per day"])
        #expect(ClaudePlugin.frontmatter("# no frontmatter\nname: x\n").isEmpty)
    }

    @Test func aCommandIsTypedWithThePluginNameAndTitledInWords() {
        let command = ClaudePlugin.Command(name: "force-multiplier", description: "")
        #expect(command.slashCommand == "/maggie:force-multiplier")
        #expect(command.title == "Force Multiplier")
    }

    @Test func theBundledCommandsAreItsSkills() throws {
        let directory = try #require(ClaudePlugin.directory)
        #expect(ClaudePlugin.commands(in: directory).map(\.name) == ["force-multiplier"])
        #expect(ClaudePlugin.commands.first?.description.isEmpty == false)

        // The menu types /maggie:<skill>, which only works while the plugin is named so.
        let manifest = try Data(contentsOf: directory.appendingPathComponent(".claude-plugin/plugin.json"))
        let plugin = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        #expect(plugin["name"] as? String == ClaudePlugin.name)
    }

    @MainActor
    @Test func aTerminalWithoutClaudeCodeCannotRunThem() {
        #expect(!ClaudePlugin.canRun(in: nil))
    }

    @Test func theBundleShipsThePlugin() throws {
        let directory = try #require(ClaudePlugin.directory)
        let skill = directory.appendingPathComponent("skills/force-multiplier")
        for file in ["SKILL.md", "loc.sh", "loc-report.html"] {
            #expect(FileManager.default.fileExists(atPath: skill.appendingPathComponent(file).path), "\(file)")
        }
    }
}
