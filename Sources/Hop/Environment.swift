import Foundation

enum LoginShell {
    struct Output: Sendable {
        let status: Int32
        let text: String
    }

    /// Runs `command` in the user's login shell and returns its stdout. Blocks: call it off the main thread.
    static func run(_ command: String) throws -> Output {
        let process = Process()
        process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
}

struct StatusLine: Equatable, Sendable {
    enum Kind: String, Sendable {
        case plain
        case yellow
        case red
    }

    let kind: Kind
    let text: String
}

enum ClaudeEnvironment {
    static let newestTestedVersion = "2.1.296"

    enum Code: Equatable, Sendable {
        case missing
        case version(String)
        case unreadable
    }

    struct Snapshot: Sendable {
        let desktopInstalled: Bool
        let code: Code
    }

    /// Blocks on the login shell: call it off the main thread.
    static func check() throws(HopError) -> Snapshot {
        let desktopInstalled: Bool
        do {
            _ = try ClaudeDesktop.locateExecutable()
            desktopInstalled = true
        } catch HopError.claudeDesktopNotFound {
            desktopInstalled = false
        }
        return Snapshot(desktopInstalled: desktopInstalled, code: try codeStatus())
    }

    static func codeStatus() throws(HopError) -> Code {
        let result: LoginShell.Output
        do {
            result = try LoginShell.run("command -v claude >/dev/null 2>&1 || exit 127; claude --version")
        } catch {
            throw HopError.cliCheckFailed(underlying: error)
        }
        if result.status == 127 { return .missing }
        guard result.status == 0, let version = parseVersion(result.text) else { return .unreadable }
        return .version(version)
    }

    /// The first dotted number in `text`, such as 2.1.296 from "2.1.296 (Claude Code)".
    static func parseVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    static func isOlder(_ version: String, than other: String) -> Bool {
        let left = version.split(separator: ".").map { Int($0) ?? 0 }
        let right = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    static func lines(desktopInstalled: Bool, code: Code?, error: String?) -> [StatusLine] {
        var lines: [StatusLine] = []
        if !desktopInstalled {
            lines.append(StatusLine(kind: .plain, text: "Claude Desktop isn't installed in /Applications or ~/Applications."))
        }
        let newest = newestTestedVersion
        switch code {
        case .missing:
            lines.append(StatusLine(kind: .plain, text: "Claude Code isn't on your PATH."))
        case .version(let version) where isOlder(version, than: newest):
            lines.append(StatusLine(
                kind: .yellow,
                text: "Claude Code \(version) is older than \(newest), the newest version Hop was tested with. Logins may overwrite each other."
            ))
        case .unreadable:
            lines.append(StatusLine(
                kind: .yellow,
                text: "Hop couldn't read Claude Code's version. Versions older than \(newest) may let logins overwrite each other."
            ))
        case .version, nil:
            break
        }
        if let error {
            lines.append(StatusLine(kind: .red, text: error))
        }
        return lines
    }
}
