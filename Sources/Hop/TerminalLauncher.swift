import AppKit
import Foundation

/// How `open` hands a launcher script to a terminal app. Each form is from that app's documented command line.
enum TerminalLaunchStyle: Sendable, Hashable {
    /// Apple Terminal opens the script file itself.
    case openFile
    /// Ghostty and Alacritty: `-e <command>` runs the script.
    case execFlag
    /// WezTerm: `start -- <prog>` runs the script.
    case weztermStart
    /// kitty: the script is the program-to-run argument.
    case positional
}

/// A terminal app Hop can open a launcher script in, keyed by bundle ID.
struct TerminalApp: Sendable, Hashable, Identifiable {
    let bundleID: String
    let name: String
    let style: TerminalLaunchStyle

    var id: String { bundleID }

    static let defaultsKey = "terminalApp"

    static let terminal = TerminalApp(bundleID: "com.apple.Terminal", name: "Apple Terminal", style: .openFile)
    static let ghostty = TerminalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty", style: .execFlag)
    static let wezterm = TerminalApp(bundleID: "com.github.wez.wezterm", name: "WezTerm", style: .weztermStart)
    static let alacritty = TerminalApp(bundleID: "org.alacritty", name: "Alacritty", style: .execFlag)
    static let kitty = TerminalApp(bundleID: "net.kovidgoyal.kitty", name: "kitty", style: .positional)

    /// Every terminal with a documented way to run a program in a new window. iTerm2, Warp and Hyper have none.
    static let all: [TerminalApp] = [terminal, ghostty, wezterm, alacritty, kitty]

    /// Where macOS finds this app, or nil when it is not installed.
    var installedURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Terminals installed on this Mac, in table order.
    static var installed: [TerminalApp] {
        all.filter { $0.installedURL != nil }
    }

    /// The `/usr/bin/open` arguments that run `script` in a new window of this app at `appPath`.
    func openArguments(appPath: String, script: String) -> [String] {
        switch style {
        case .openFile:
            ["-a", appPath, script]
        case .execFlag:
            ["-na", appPath, "--args", "-e", script]
        case .weztermStart:
            ["-na", appPath, "--args", "start", "--", script]
        case .positional:
            ["-na", appPath, "--args", script]
        }
    }

    /// Maps the values older Hop versions stored ("terminal", "ghostty") to bundle IDs.
    static func bundleID(forStored value: String) -> String {
        switch value {
        case "terminal": terminal.bundleID
        case "ghostty": ghostty.bundleID
        default: value
        }
    }
}

/// Opens a launcher script in a new terminal window.
enum TerminalLauncher {
    /// The remembered choice, or Apple Terminal when the saved app is unknown or no longer installed.
    static func savedApp() -> TerminalApp {
        let stored = UserDefaults.standard.string(forKey: TerminalApp.defaultsKey) ?? TerminalApp.terminal.bundleID
        let bundleID = TerminalApp.bundleID(forStored: stored)
        guard let app = TerminalApp.all.first(where: { $0.bundleID == bundleID }), app.installedURL != nil else {
            return .terminal
        }
        return app
    }

    /// Throws claudeCodeNotFound when the user's login shell cannot find `claude`.
    static func requireClaudeCode() throws(HopError) {
        let result: LoginShell.Output
        do {
            result = try LoginShell.run("command -v claude")
        } catch {
            throw HopError.cliCheckFailed(underlying: error)
        }
        guard result.status == 0 else {
            throw HopError.claudeCodeNotFound
        }
    }

    static func open(_ script: URL, in app: TerminalApp) throws(HopError) {
        guard let appURL = app.installedURL else {
            throw HopError.terminalLaunchFailed(underlying: NSError(
                domain: "Hop.open",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "\(app.name) is not installed"]
            ))
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = app.openArguments(appPath: appURL.path, script: script.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw HopError.terminalLaunchFailed(underlying: error)
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        guard status == 0 else {
            throw HopError.terminalLaunchFailed(underlying: NSError(
                domain: "Hop.open",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "open exited with status \(status)"]
            ))
        }
    }
}
