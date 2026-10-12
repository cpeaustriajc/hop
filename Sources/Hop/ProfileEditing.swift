import Foundation

/// Name, rename and remove rules shared by the panel and the hidden CLI entries.
enum ProfileEditing {
    /// The id a new profile named `name` gets; throws when the name is refused.
    static func newID(for name: String, in list: [Profile]) throws(HopError) -> String {
        let trimmed = trimmedName(name)
        guard !trimmed.isEmpty else { throw .nameEmpty }
        let id = Profile.slug(for: trimmed)
        guard !id.isEmpty else { throw .nameHasNoSlug(name: trimmed) }
        guard !list.contains(where: { $0.id == id }) else { throw .nameTaken(name: trimmed) }
        return id
    }

    /// Changes the display name only; the id (the hop name) never changes.
    static func rename(id: String, to name: String, store: ProfileStore) throws(HopError) -> Profile {
        var list = try store.load()
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw .profileNotFound(id: id) }
        let trimmed = trimmedName(name)
        guard !trimmed.isEmpty else { throw .nameEmpty }
        list[index].name = trimmed
        try store.save(list)
        return list[index]
    }

    /// Drops the profile from Hop's list. With `trashData`, moves its folder to the Trash and returns where it went.
    static func remove(id: String, trashData: Bool, store: ProfileStore) throws(HopError) -> URL? {
        var list = try store.load()
        guard let profile = list.first(where: { $0.id == id }) else { throw .profileNotFound(id: id) }
        var folder: URL?
        if trashData {
            guard !profile.isAdopted else { throw .adoptedDataProtected(name: profile.name) }
            folder = try trashTarget(id: id, store: store)
            if try Launcher.runningDesktopPID(dataDir: URL(filePath: profile.desktopDataDir)) != nil {
                throw .desktopRunning(name: profile.name)
            }
        }
        list.removeAll { $0.id == id }
        try store.save(list)
        guard let folder else { return nil }
        return try moveToTrash(folder)
    }

    /// The real folder to trash, or nil when nothing is on disk. Symlinks resolve first, so a link out of profiles/ is refused.
    private static func trashTarget(id: String, store: ProfileStore) throws(HopError) -> URL? {
        let folder = store.rootDir.appending(path: "profiles/\(id)", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let profilesDir = directoryPath(
            store.rootDir.appending(path: "profiles", directoryHint: .isDirectory).resolvingSymlinksInPath()
        )
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        guard directoryPath(resolved.deletingLastPathComponent()) == profilesDir else {
            throw .dataOutsideProfiles(path: folder.path)
        }
        return resolved
    }

    private static func moveToTrash(_ folder: URL) throws(HopError) -> URL? {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: &resulting)
        } catch {
            throw .trashFailed(underlying: error)
        }
        return resulting as URL?
    }

    private static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func directoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
