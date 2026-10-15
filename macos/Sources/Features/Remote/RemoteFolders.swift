import Foundation

/// The Mac's folders as a device may browse them: only inside the home folder for
/// devices (Settings › Mobile), hidden ones left out.
enum RemoteFolders {
    /// The most entries one listing carries.
    static let limit = 500

    /// `path` as a folder inside `home` (or `home` itself), with links and `..`
    /// resolved first so neither can lead out of it; none otherwise.
    static func resolve(_ path: String, home: URL) -> URL? {
        let root = home.resolvingSymlinksInPath().standardizedFileURL
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// The folders directly inside `path` (or `home` for none), sorted by name.
    static func list(_ path: String?, home: URL) -> Result<FolderListing, RemoteError> {
        let root = home.resolvingSymlinksInPath().standardizedFileURL
        guard let url = resolve(path ?? root.path, home: home) else {
            return .failure(RemoteError(code: .notFound, message: "That folder isn't inside the Mac's home folder for devices."))
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        } catch {
            return .failure(RemoteError(code: .notFound, message: "The Mac couldn't read \(display(url)): \(error.localizedDescription)"))
        }
        let entries = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.pathExtension != "app" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { FolderListing.Entry(name: $0.lastPathComponent, path: $0.standardizedFileURL.path, isRepository: isRepository($0)) }
        let parent = url.path == root.path ? nil : url.deletingLastPathComponent().standardizedFileURL.path
        return .success(FolderListing(
            path: url.path,
            displayPath: display(url),
            parent: parent,
            isRepository: isRepository(url),
            entries: Array(entries)))
    }

    /// Holds a repository: a `.git` folder or file, as a worktree has.
    static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// `url` as the Mac would show it: `~` for the user's home.
    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
