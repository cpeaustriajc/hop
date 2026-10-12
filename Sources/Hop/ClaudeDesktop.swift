import Foundation

enum ClaudeDesktop {
    /// Claude Desktop's own data folder: where the existing login lives.
    static let defaultDataDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory)

    static func locateExecutable() throws(HopError) -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let apps: [URL]
        if let override = environment["HOP_CLAUDE_APP"], !override.isEmpty,
           let home = environment["HOP_HOME"], !home.isEmpty {
            apps = [URL(filePath: override)]
        } else {
            apps = [
                URL(filePath: "/Applications/Claude.app"),
                fileManager.homeDirectoryForCurrentUser.appending(path: "Applications/Claude.app"),
            ]
        }
        for app in apps where fileManager.fileExists(atPath: app.path) {
            let binary = app.appending(path: "Contents/MacOS/Claude")
            if fileManager.isExecutableFile(atPath: binary.path) {
                return binary
            }
        }
        throw HopError.claudeDesktopNotFound
    }
}
