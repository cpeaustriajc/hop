import Foundation
import SwiftUI

@main
struct HopApp: App {
    @NSApplicationDelegateAdaptor(HopAppDelegate.self) private var appDelegate

    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--launch-desktop") && !arguments.contains("--find-desktop") {
            Task { @MainActor in exit(await HopCLI.launch(arguments: arguments)) }
        } else if arguments.contains("--signin-dry") {
            Task { @MainActor in exit(await HopCLI.signInDry(arguments: arguments)) }
        } else if arguments.contains("--status") {
            Task { @MainActor in exit(await HopCLI.status()) }
        } else if arguments.contains("--add") {
            Task { @MainActor in exit(HopCLI.add(arguments: arguments)) }
        } else if arguments.contains("--quit-desktop") {
            Task { @MainActor in exit(await HopCLI.quitScratchDesktop(arguments: arguments)) }
        } else if let status = HopCLI.run(arguments: arguments) {
            exit(status)
        }
    }

    var body: some Scene {
        MenuBarExtra("Hop", systemImage: "person.2.circle") {
            MenuView(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class HopAppDelegate: NSObject, NSApplicationDelegate {
    let model = HopModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.refreshEnvironment() }
        Task { await model.healClaudeHandlerAtLaunch() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "claude" {
            model.receiveSignInLink(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.restoreBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Hidden E2E entry: `Hop --launch-desktop <dataDir>` starts Desktop through the same Launcher and exits.
enum HopCLI {
    static func run(arguments: [String]) -> Int32? {
        if let flag = arguments.firstIndex(of: "--prepare-cli") {
            guard arguments.indices.contains(flag + 1) else {
                writeStderr("usage: Hop --prepare-cli <id>\n")
                return 1
            }
            let id = arguments[flag + 1]
            do {
                let store = ProfileStore.standard
                guard let profile = try store.load().first(where: { $0.id == id }) else {
                    writeStderr("no profile with id \(id)\n")
                    return 1
                }
                let script = try CLIProfile.prepare(profile, store: store)
                let text = try String(contentsOf: script, encoding: .utf8)
                print(script.path)
                print(text, terminator: "")
                return 0
            } catch {
                writeStderr("\(error.localizedDescription)\n")
                return 1
            }
        }
        if let flag = arguments.firstIndex(of: "--cli-dir") {
            guard arguments.indices.contains(flag + 1) else {
                writeStderr("usage: Hop --cli-dir <name>\n")
                return 1
            }
            do {
                print(try HopCommand.cliDirectory(forName: arguments[flag + 1])?.path ?? "")
                return 0
            } catch {
                writeStderr("\(error.localizedDescription)\n")
                return 1
            }
        }
        if arguments.contains("--install-command") {
            do {
                let file = try HopCommand.install()
                print(file.path)
                print("on PATH: \(try HopCommand.isOnPath() ? "yes" : "no")")
                return 0
            } catch {
                writeStderr("\(error.localizedDescription)\n")
                return 1
            }
        }
        if let flag = arguments.firstIndex(of: "--find-desktop") {
            guard arguments.indices.contains(flag + 1) else {
                writeStderr("usage: Hop --find-desktop <dataDir>\n")
                return 1
            }
            do {
                let pid = try Launcher.runningDesktopPID(dataDir: URL(filePath: arguments[flag + 1]))
                print(pid.map { String($0) } ?? "none")
                return 0
            } catch {
                writeStderr("\(error.localizedDescription)\n")
                return 1
            }
        }
        if let flag = arguments.firstIndex(of: "--remove") {
            guard arguments.indices.contains(flag + 1) else {
                writeStderr("usage: Hop --remove <id> [--trash-data]\n")
                return 1
            }
            let id = arguments[flag + 1]
            do {
                let trashed = try ProfileEditing.remove(
                    id: id,
                    trashData: arguments.contains("--trash-data"),
                    store: .standard
                )
                print("removed \(id)")
                if let trashed {
                    print("trashed \(trashed.path)")
                }
                return 0
            } catch {
                writeStderr("\(error.localizedDescription)\n")
                return 1
            }
        }
        if let flag = arguments.firstIndex(of: "--rename") {
            guard arguments.indices.contains(flag + 2) else {
                writeStderr("usage: Hop --rename <id> <name>\n")
                return 1
            }
            do {
                let profile = try ProfileEditing.rename(
                    id: arguments[flag + 1],
                    to: arguments[flag + 2],
                    store: .standard
                )
                print("renamed \(profile.id) to \(profile.name)")
                return 0
            } catch {
                writeStderr("\(error.localizedDescription)\n")
                return 1
            }
        }
        if let flag = arguments.firstIndex(of: "--list-terminals") {
            guard arguments.indices.contains(flag + 1) else {
                writeStderr("usage: Hop --list-terminals <script>\n")
                return 1
            }
            let script = arguments[flag + 1]
            for app in TerminalApp.all {
                guard let appURL = app.installedURL else {
                    print("\(app.bundleID)\t\(app.name)\tnot installed")
                    continue
                }
                let open = app.openArguments(appPath: appURL.path, script: script).joined(separator: " ")
                print("\(app.bundleID)\t\(app.name)\t/usr/bin/open \(open)")
            }
            return 0
        }
        if let flag = arguments.firstIndex(of: "--forward-url") {
            guard arguments.indices.contains(flag + 2), let pid = Int32(arguments[flag + 1]) else {
                writeStderr("usage: Hop --forward-url <pid> <url>\n")
                return 1
            }
            do {
                try ClaudeHandler.sendGetURL(pid: pid, url: arguments[flag + 2])
                print("forwarded to pid \(pid)")
                return 0
            } catch {
                writeStderr("\(error.localizedDescription)\n")
                return 1
            }
        }
        return nil
    }

    /// Starts Desktop and waits for the launch. Activation is best-effort: its failure is reported on stderr and exit stays 0.
    static func launch(arguments: [String]) async -> Int32 {
        guard let flag = arguments.firstIndex(of: "--launch-desktop"),
              arguments.indices.contains(flag + 1) else {
            writeStderr("usage: Hop --launch-desktop <dataDir>\n")
            return 1
        }
        let dataDir = URL(filePath: arguments[flag + 1])
        do {
            let result = try await Launcher.launchDesktopForCLI(dataDir: dataDir)
            print(result.pid)
            if let isActive = result.isActive {
                writeStderr("activation: isActive=\(isActive) (best-effort from the CLI)\n")
            }
            if let focusError = result.focusError {
                writeStderr("activation: not confirmed: \(focusError.localizedDescription)\n")
            }
            return 0
        } catch {
            writeStderr("\(error.localizedDescription)\n")
            return 1
        }
    }

    /// Hidden `--signin-dry <id> [--bypass-watch]`: runs the sign-in order on a scratch profile in HOP_HOME, skipping takeover.
    @MainActor
    static func signInDry(arguments: [String]) async -> Int32 {
        guard let flag = arguments.firstIndex(of: "--signin-dry"),
              arguments.indices.contains(flag + 1) else {
            writeStderr("usage: HOP_HOME=<scratch folder> Hop --signin-dry <id> [--bypass-watch]\n")
            return 1
        }
        let id = arguments[flag + 1]
        guard let home = ProcessInfo.processInfo.environment["HOP_HOME"], !home.isEmpty else {
            writeStderr("--signin-dry needs HOP_HOME set to a scratch folder\n")
            return 1
        }
        let scratchPrefix = URL(filePath: home).standardizedFileURL.path + "/"
        let model = HopModel()
        var dataDir: URL?
        do {
            guard let profile = try model.store.load().first(where: { $0.id == id }) else {
                writeStderr("no profile with id \(id)\n")
                return 1
            }
            let profileDir = URL(filePath: profile.desktopDataDir)
            guard profileDir.standardizedFileURL.path.hasPrefix(scratchPrefix) else {
                writeStderr("--signin-dry refuses a profile whose Desktop folder is outside HOP_HOME\n")
                return 1
            }
            dataDir = profileDir
            let pid = try await model.runSignInDry(profile, bypassWatch: arguments.contains("--bypass-watch")) {
                print($0)
                fflush(stdout)
            }
            try await stopScratchDesktop(profileDir, startedPID: pid)
            return 0
        } catch {
            writeStderr("\(error.localizedDescription)\n")
            if let dataDir {
                do {
                    try await stopScratchDesktop(dataDir, startedPID: nil)
                } catch {
                    writeStderr("cleanup failed, a scratch Claude may still run on \(dataDir.path): \(error.localizedDescription)\n")
                    return 2
                }
            }
            return 1
        }
    }

    /// Hidden `--status`: prints the lines the panel would show, each prefixed plain:, yellow: or red:.
    @MainActor
    static func status() async -> Int32 {
        let model = HopModel()
        await model.refreshEnvironment()
        for line in model.statusLines {
            print("\(line.kind.rawValue): \(line.text)")
        }
        return 0
    }

    /// Hidden `--add <name>`: runs the panel's Add with that name; prints `added <id>` or `red: <message>`.
    @MainActor
    static func add(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--add"), arguments.indices.contains(flag + 1) else {
            writeStderr("usage: HOP_HOME=<scratch folder> Hop --add <name>\n")
            return 1
        }
        guard let home = ProcessInfo.processInfo.environment["HOP_HOME"], !home.isEmpty else {
            writeStderr("--add needs HOP_HOME set to a scratch folder\n")
            return 1
        }
        let model = HopModel()
        model.newProfileName = arguments[flag + 1]
        model.addProfile()
        if let message = model.errorMessage {
            print("red: \(message)")
            return 1
        }
        print("added \(model.profiles.last?.id ?? "")")
        return 0
    }

    /// Hidden `--quit-desktop <dataDir>`: terminate request to the Desktop on a scratch dir in HOP_HOME, through the same Launcher as the panel.
    @MainActor
    static func quitScratchDesktop(arguments: [String]) async -> Int32 {
        guard let flag = arguments.firstIndex(of: "--quit-desktop"),
              arguments.indices.contains(flag + 1) else {
            writeStderr("usage: HOP_HOME=<scratch folder> Hop --quit-desktop <dataDir>\n")
            return 1
        }
        guard let home = ProcessInfo.processInfo.environment["HOP_HOME"], !home.isEmpty else {
            writeStderr("--quit-desktop needs HOP_HOME set to a scratch folder\n")
            return 1
        }
        let scratchPrefix = URL(filePath: home).standardizedFileURL.path + "/"
        let dataDir = URL(filePath: arguments[flag + 1])
        guard dataDir.standardizedFileURL.path.hasPrefix(scratchPrefix) else {
            writeStderr("--quit-desktop refuses a folder outside HOP_HOME\n")
            return 1
        }
        do {
            guard let pid = try await Launcher.quitDesktop(dataDir: dataDir, name: "scratch") else {
                print("no scratch Desktop running on \(dataDir.path)")
                return 0
            }
            let stillRunning = try Launcher.runningDesktopPID(dataDir: dataDir) == pid
            print(stillRunning ? "pid \(pid) still running after 5 s" : "pid \(pid) exited")
            return 0
        } catch {
            writeStderr("\(error.localizedDescription)\n")
            return 1
        }
    }

    /// Sends SIGTERM to the scratch Desktop in `dataDir` and waits until it is gone. Only ever called with a HOP_HOME folder.
    private static func stopScratchDesktop(_ dataDir: URL, startedPID: Int32?) async throws(HopError) {
        guard let pid = try Launcher.runningDesktopPID(dataDir: dataDir) else {
            print("scratch Desktop already gone")
            fflush(stdout)
            return
        }
        kill(pid, SIGTERM)
        for _ in 0..<40 {
            if try Launcher.runningDesktopPID(dataDir: dataDir) != pid {
                print("killed scratch pid \(pid)\(startedPID == pid ? "" : " (found after an error)")")
                fflush(stdout)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                throw HopError.desktopNotReady(name: "scratch", underlying: error)
            }
        }
        print("scratch pid \(pid) still running after 4 s")
        fflush(stdout)
    }

    private static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
