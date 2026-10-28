import AppKit
import Foundation

enum Launcher {
    // Without createsNewApplicationInstance, LaunchServices focuses the running Claude; spawning with Process bills Claude's energy to Hop.
    /// Brings the Desktop already running on `dataDir` forward, or starts one and brings its window forward. Returns its PID.
    @MainActor
    static func launchDesktop(dataDir: URL) async throws(HopError) -> Int32 {
        let (pid, spawned) = try await start(dataDir: dataDir)
        _ = try await focus(pid: pid, spawned: spawned)
        return pid
    }

    /// CLI form: a focus failure is returned as `focusError` and does not fail the launch. Only a failed start throws.
    @MainActor
    static func launchDesktopForCLI(dataDir: URL) async throws(HopError) -> (pid: Int32, isActive: Bool?, focusError: HopError?) {
        let (pid, spawned) = try await start(dataDir: dataDir)
        do {
            let isActive = try await focus(pid: pid, spawned: spawned)
            return (pid, isActive, nil)
        } catch {
            return (pid, nil, error)
        }
    }

    @MainActor
    private static func start(dataDir: URL) async throws(HopError) -> (pid: Int32, spawned: Bool) {
        let binary = try ClaudeDesktop.locateExecutable()
        if let pid = try runningPID(dataDir: dataDir, binary: binary) {
            return (pid, false)
        }
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--user-data-dir=\(dataDir.path)"]
            let appURL = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return (app.processIdentifier, true)
        } catch {
            throw HopError.launchFailed(underlying: error)
        }
    }

    /// Returns whether the app reports itself active after activation.
    @MainActor
    private static func focus(pid: Int32, spawned: Bool) async throws(HopError) -> Bool? {
        if spawned {
            return try await comeForward(pid: pid)
        }
        return try bringForward(pid: pid)
    }

    /// PID of the main Desktop process running on `dataDir`, or nil when none is running. Read-only.
    static func runningDesktopPID(dataDir: URL) throws(HopError) -> Int32? {
        try runningPID(dataDir: dataDir, binary: ClaudeDesktop.locateExecutable())
    }

    /// Running main Desktop PID for each dir, index-matched to `dataDirs`, from one fresh ps read. Read-only.
    static func runningDesktopPIDs(dataDirs: [URL]) throws(HopError) -> [Int32?] {
        let processes = try mainProcesses(binary: ClaudeDesktop.locateExecutable())
        return dataDirs.map { owner(of: $0, in: processes) }
    }

    /// Asks the main Desktop process on `dataDir` to quit with a normal terminate request, then waits up to 5 s for it to exit.
    /// Returns the PID asked to quit, or nil when none was running. Matches by data dir only, never by bundle ID.
    @MainActor
    static func quitDesktop(dataDir: URL, name: String) async throws(HopError) -> Int32? {
        guard let pid = try runningDesktopPID(dataDir: dataDir),
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard app.terminate() else {
            throw HopError.quitFailed(name: name, underlying: nil)
        }
        for _ in 0..<50 {
            guard try runningDesktopPID(dataDir: dataDir) == pid else { return pid }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                throw HopError.quitFailed(name: name, underlying: error)
            }
        }
        return pid
    }

    private static func runningPID(dataDir: URL, binary: URL) throws(HopError) -> Int32? {
        owner(of: dataDir, in: try mainProcesses(binary: binary))
    }

    /// Main Desktop processes (helpers excluded) as PID and command, from one ps read.
    private static func mainProcesses(binary: URL) throws(HopError) -> [(pid: Int32, command: String)] {
        var processes: [(pid: Int32, command: String)] = []
        for line in try psOutput().split(separator: "\n") {
            let row = line.drop(while: \.isWhitespace)
            guard let gap = row.firstIndex(where: \.isWhitespace),
                  let pid = Int32(row[..<gap]) else { continue }
            let command = row[gap...].drop(while: \.isWhitespace)
            guard isMainProcess(command, binary: binary) else { continue }
            processes.append((pid, String(command)))
        }
        return processes
    }

    /// The first of `processes` that owns `dataDir`. The default dir owns a process with no --user-data-dir.
    private static func owner(of dataDir: URL, in processes: [(pid: Int32, command: String)]) -> Int32? {
        let target = canonicalPath(dataDir)
        let targetIsDefault = target == canonicalPath(ClaudeDesktop.defaultDataDir)
        return processes.first { process in
            let command = process.command[...]
            return command.contains("--user-data-dir")
                ? usesDataDir(command, target)
                : targetIsDefault
        }?.pid
    }

    private static func isMainProcess(_ command: Substring, binary: URL) -> Bool {
        let path = binary.path
        guard command.hasPrefix(path) else { return false }
        let rest = command.dropFirst(path.count)
        return (rest.isEmpty || rest.first == " ") && !command.contains("--type=")
    }

    private static func usesDataDir(_ command: Substring, _ target: String) -> Bool {
        var rest = command[...]
        while let found = rest.range(of: "--user-data-dir=") {
            let after = rest[found.upperBound...]
            let end = after.range(of: " --")?.lowerBound ?? after.endIndex
            if canonicalPath(URL(filePath: String(after[..<end]))) == target {
                return true
            }
            rest = after
        }
        return false
    }

    private static func psOutput() throws(HopError) -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        // -ww: without it ps may cut long command lines, hiding the --user-data-dir match.
        process.arguments = ["-axww", "-o", "pid=,command="]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let data: Data
        do {
            try process.run()
            data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            throw HopError.processListFailed(underlying: error)
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        guard status == 0 else {
            throw HopError.processListFailed(underlying: NSError(
                domain: "Hop.ps",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "ps exited with status \(status)"]
            ))
        }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private static func bringForward(pid: Int32) throws(HopError) -> Bool {
        guard let isActive = activate(pid: pid) else {
            throw HopError.launchFailed(underlying: NSError(
                domain: "Hop",
                code: Int(pid),
                userInfo: [NSLocalizedDescriptionKey: "macOS does not list process \(pid) as an app"]
            ))
        }
        return isActive
    }

    /// Polls off the main thread for up to 5 s, then activates the new process on the main actor.
    private static func comeForward(pid: Int32) async throws(HopError) -> Bool? {
        for _ in 0..<50 {
            if NSRunningApplication(processIdentifier: pid) != nil,
               let isActive = await MainActor.run(body: { activate(pid: pid) }) {
                return isActive
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                throw HopError.launchFailed(underlying: error)
            }
        }
        throw HopError.launchFailed(underlying: NSError(
            domain: "Hop",
            code: Int(pid),
            userInfo: [NSLocalizedDescriptionKey: "Claude started but didn't come forward; it may be behind other windows"]
        ))
    }

    // NSApp can be nil before the app starts, so use NSApplication.shared.
    @MainActor
    private static func activate(pid: Int32) -> Bool? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        app.unhide()
        NSApplication.shared.yieldActivation(to: app)
        if !app.activate(from: NSRunningApplication.current, options: []) {
            app.activate()
        }
        return app.isActive
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
