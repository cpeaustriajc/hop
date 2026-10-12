import Foundation

struct Profile: Codable, Identifiable, Equatable, Sendable {
    /// Lowercase ASCII slug fixed at creation; it becomes the `hop` name.
    let id: String
    var name: String
    var desktopDataDir: String
    var isAdopted: Bool
    /// Set until a sign-in made through Hop completes; profiles saved before this field existed default to `!isAdopted`.
    var needsSignIn: Bool

    init(id: String, name: String, desktopDataDir: String, isAdopted: Bool, needsSignIn: Bool? = nil) {
        self.id = id
        self.name = name
        self.desktopDataDir = desktopDataDir
        self.isAdopted = isAdopted
        self.needsSignIn = needsSignIn ?? !isAdopted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isAdopted = try container.decode(Bool.self, forKey: .isAdopted)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            desktopDataDir: try container.decode(String.self, forKey: .desktopDataDir),
            isAdopted: isAdopted,
            needsSignIn: try container.decodeIfPresent(Bool.self, forKey: .needsSignIn)
        )
    }

    /// Lowercase ASCII letters and digits joined by hyphens; empty when the name has none.
    static func slug(for name: String) -> String {
        name.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .joined(separator: "-")
    }
}

struct ProfileStore: Sendable {
    let rootDir: URL

    /// `HOP_HOME`, when set and non-empty, relocates the store for E2E runs; otherwise the real Hop folder.
    static let standard = ProfileStore(
        rootDir: {
            if let home = ProcessInfo.processInfo.environment["HOP_HOME"], !home.isEmpty {
                return URL(filePath: home, directoryHint: .isDirectory)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Hop", directoryHint: .isDirectory)
        }()
    )

    var fileURL: URL {
        rootDir.appending(path: "profiles.json")
    }

    func desktopDataDir(forID id: String) -> URL {
        rootDir.appending(path: "profiles/\(id)/desktop", directoryHint: .isDirectory)
    }

    /// A missing file is an empty list; an unreadable or corrupt file throws and is never overwritten.
    func load() throws(HopError) -> [Profile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            throw HopError.storeReadFailed(underlying: error)
        }
    }

    func save(_ profiles: [Profile]) throws(HopError) {
        do {
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            throw HopError.storeWriteFailed(underlying: error)
        }
    }
}
