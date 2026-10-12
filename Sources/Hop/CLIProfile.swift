import Foundation

/// Per-profile Claude Code setup: shared config links back to ~/.claude, and a launcher script that starts Claude Code as the profile.
enum CLIProfile {
    static let sharedNames = ["CLAUDE.md", "settings.json", "skills", "agents", "commands", "hooks", "plugins"]

    /// Refreshes the profile's links and writes its launcher script; returns the script's URL.
    /// Personal (adopted) runs plain `claude`. Setting CLAUDE_CONFIG_DIR to ~/.claude would select another Keychain entry and log the user out.
    static func prepare(_ profile: Profile, store: ProfileStore) throws(HopError) -> URL {
        let dir = store.rootDir.appending(path: "profiles/\(profile.id)", directoryHint: .isDirectory)
        var export: String?
        if !profile.isAdopted {
            let cliDir = dir.appending(path: "cli", directoryHint: .isDirectory)
            try linkSharedConfig(into: cliDir)
            export = "export CLAUDE_CONFIG_DIR=\(shellQuote(cliDir.path))"
        }
        let commands = [export, "exec claude"].compactMap { $0 }.joined(separator: "; ")
        let text = "#!/bin/zsh\nexec \"$SHELL\" -l -c \(shellQuote(commands))\n"
        return try writeScript(text, in: dir)
    }

    /// Creates or refreshes a symlink to each shared item that exists in ~/.claude. A real file or folder at a link path is never replaced.
    private static func linkSharedConfig(into cliDir: URL) throws(HopError) {
        let fileManager = FileManager.default
        let sourceRoot = fileManager.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: cliDir, withIntermediateDirectories: true)
        } catch {
            throw HopError.cliSetupFailed(underlying: error)
        }
        for name in sharedNames {
            let link = cliDir.appending(path: name)
            let source = sourceRoot.appending(path: name)
            let existingType = (try? fileManager.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType
            if let existingType, existingType != .typeSymbolicLink {
                throw HopError.cliLinkBlocked(path: link.path)
            }
            do {
                if existingType != nil {
                    try fileManager.removeItem(at: link)
                }
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
                }
            } catch {
                throw HopError.cliSetupFailed(underlying: error)
            }
        }
    }

    private static func writeScript(_ text: String, in dir: URL) throws(HopError) -> URL {
        let script = dir.appending(path: "claude.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            throw HopError.launcherWriteFailed(underlying: error)
        }
        return script
    }

    /// Wraps `text` in single quotes for `sh`, escaping any single quote in it.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }
}
