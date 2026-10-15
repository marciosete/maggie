import Foundation
import Testing
@testable import Ghostty

/// Devices browse only inside the home folder set for them.
struct RemoteFoldersTests {
    /// A home folder with `projects/orca` (a repository), `projects/notes`, a hidden
    /// folder, a file, and a link that points outside home.
    private func makeHome() throws -> (home: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-folders-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let home = base.appendingPathComponent("home")
        let outside = base.appendingPathComponent("outside")
        let manager = FileManager.default
        try manager.createDirectory(at: home.appendingPathComponent("projects/orca/.git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent("projects/notes"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: home.appendingPathComponent("readme.txt"))
        try manager.createSymbolicLink(at: home.appendingPathComponent("escape"), withDestinationURL: outside)
        return (home, outside)
    }

    @Test func listsFoldersInsideHomeByName() throws {
        let (home, _) = try makeHome()
        let top = try RemoteFolders.list(nil, home: home).get()
        #expect(top.path == home.path)
        #expect(top.parent == nil)
        // The link leads outside home, so it isn't offered; neither are files or hidden folders.
        #expect(top.entries.map(\.name) == ["projects"])

        let projects = try RemoteFolders.list(home.appendingPathComponent("projects").path, home: home).get()
        #expect(projects.entries.map(\.name) == ["notes", "orca"])
        #expect(projects.entries.map(\.isRepository) == [false, true])
        #expect(projects.parent == home.path)
    }

    @Test func nothingOutsideHomeIsReachable() throws {
        let (home, outside) = try makeHome()
        #expect(RemoteFolders.resolve(outside.path, home: home) == nil)
        #expect(RemoteFolders.resolve(home.appendingPathComponent("projects/../..").path, home: home) == nil)
        #expect(RemoteFolders.resolve(home.appendingPathComponent("escape").path, home: home) == nil)
        #expect(RemoteFolders.resolve(home.path + "-sibling", home: home) == nil)
        #expect(RemoteFolders.resolve(home.appendingPathComponent("readme.txt").path, home: home) == nil)
        #expect(RemoteFolders.resolve(home.appendingPathComponent("projects/orca").path, home: home) != nil)
        if case .success = RemoteFolders.list(outside.path, home: home) {
            Issue.record("listed a folder outside home")
        }
    }

    @Test @MainActor func theSmallestGridAskedForWins() {
        let sizes = [RemoteFit.Size(columns: 120, rows: 40), RemoteFit.Size(columns: 90, rows: 50)]
        #expect(RemoteFit.smallest(sizes) == RemoteFit.Size(columns: 90, rows: 40))
        #expect(RemoteFit.smallest([]) == nil)
    }
}
