import Foundation

/// The `hop <name>` shell command: a /bin/sh script in the install folder that asks Hop for the profile's config folder and starts Claude Code.
enum HopCommand {
    /// The marker must stay on a line of its own: install overwrites only a file that has that line.
    static let marker = "# Installed by Hop.app"
    static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    enum State: Equatable {
        case notInstalled
        case installedHere
        case installedElsewhere
    }

    /// `$HOP_HOME/bin` when HOP_HOME is set, so scratch runs never touch the real folder.
    static var binDir: URL {
        if let home = ProcessInfo.processInfo.environment["HOP_HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory).appending(path: "bin", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    static var file: URL {
        binDir.appending(path: "hop")
    }

    private static func hasMarker(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0 == Substring(marker) }
    }

    static var state: State {
        guard let text = try? String(contentsOf: file, encoding: .utf8), hasMarker(text) else {
            return .notInstalled
        }
        return text == script(hopPath: hopPath) ? .installedHere : .installedElsewhere
    }

    /// Writes the script to the install folder. A `hop` file without the marker line is refused and left untouched.
    static func install() throws(HopError) -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        } catch {
            throw HopError.commandFolderFailed(underlying: error)
        }
        if fileManager.fileExists(atPath: file.path), state == .notInstalled {
            throw HopError.commandFileForeign(path: (file.path as NSString).abbreviatingWithTildeInPath)
        }
        do {
            try Data(script(hopPath: hopPath).utf8).write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch {
            throw HopError.commandWriteFailed(underlying: error)
        }
        return file
    }

    /// The path of the running Hop executable, which the script calls with --cli-dir.
    static var hopPath: String {
        (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])).standardizedFileURL.path
    }

    static func script(hopPath: String) -> String {
        let hop = CLIProfile.shellQuote(hopPath)
        return [
            "#!/bin/sh",
            marker,
            "if [ ! -x \(hop) ]; then",
            "  echo \"hop: Hop.app moved or was deleted; reinstall the hop command from Hop's menu.\" >&2",
            "  exit 1",
            "fi",
            "if [ $# -eq 0 ]; then",
            "  echo \"usage: hop <name> [claude arguments]\" >&2",
            "  \(hop) --cli-dir \"\"",
            "  exit 1",
            "fi",
            "dir=$(\(hop) --cli-dir \"$1\") || exit 1",
            "if ! command -v claude >/dev/null 2>&1; then",
            "  echo \"hop: Claude Code is missing (no claude on your PATH).\" >&2",
            "  exit 127",
            "fi",
            "if [ -n \"$dir\" ]; then",
            "  export CLAUDE_CONFIG_DIR=\"$dir\"",
            "else",
            "  unset CLAUDE_CONFIG_DIR",
            "fi",
            "shift",
            "exec claude \"$@\"",
        ].joined(separator: "\n") + "\n"
    }

    /// The config folder for `hop <name>` (profile id, else name ignoring case), after refreshing its links. Nil for the adopted profile, which uses plain `claude`.
    static func cliDirectory(forName name: String) throws(HopError) -> URL? {
        let store = ProfileStore.standard
        let list = try store.load()
        let match = list.first(where: { $0.id == name })
            ?? list.first(where: { !name.isEmpty && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        guard let profile = match else {
            throw HopError.unknownProfile(id: name, known: list.map(\.id))
        }
        guard !profile.isAdopted else { return nil }
        _ = try CLIProfile.prepare(profile, store: store)
        return store.rootDir.appending(path: "profiles/\(profile.id)/cli", directoryHint: .isDirectory)
    }

    /// Whether the install folder is on the PATH of the user's login shell, which is what a new terminal gets. Blocks: call it off the main thread.
    static func isOnPath() throws(HopError) -> Bool {
        let result: LoginShell.Output
        do {
            result = try LoginShell.run("printf %s \"$PATH\"")
        } catch {
            throw HopError.commandPathCheckFailed(underlying: error)
        }
        guard result.status == 0 else {
            throw HopError.commandPathCheckFailed(underlying: NSError(
                domain: "Hop.pathCheck",
                code: Int(result.status)
            ))
        }
        let target = binDir.standardizedFileURL.path
        return result.text
            .split(separator: ":")
            .contains { URL(filePath: String($0)).standardizedFileURL.path == target }
    }
}
