import AppKit
import SwiftUI

@MainActor @Observable
final class HopModel {
    private(set) var profiles: [Profile] = []
    private(set) var adoptOffered = false
    var errorMessage: String?
    var pendingSignIn: PendingSignIn?
    var signInTimeoutTask: Task<Void, Never>?
    private(set) var terminalApp: TerminalApp = .terminal
    var adoptName = "Personal"
    var newProfileName = ""
    private(set) var renamingID: String?
    var renameDraft = ""
    private(set) var removingID: String?
    private(set) var runningIDs: Set<String> = []
    private(set) var commandState: HopCommand.State = .notInstalled
    private(set) var commandOnPath = true
    private(set) var desktopInstalled = true
    private(set) var claudeCode: ClaudeEnvironment.Code?
    private var appObservers: [NSObjectProtocol] = []

    let store: ProfileStore

    init(store: ProfileStore = .standard) {
        self.store = store
        terminalApp = TerminalLauncher.savedApp()
        reload()
        observeDesktopLaunches()
    }

    /// Refreshes the running marks when Claude Desktop starts or quits, however it was started.
    private func observeDesktopLaunches() {
        let center = NSWorkspace.shared.notificationCenter
        let claudeID = ClaudeHandler.claudeBundleID
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == claudeID else { return }
                MainActor.assumeIsolated { self?.refreshRunning() }
            }
            appObservers.append(observer)
        }
    }

    func reload() {
        do {
            profiles = try store.load()
            adoptOffered = !profiles.contains { $0.isAdopted }
                && FileManager.default.fileExists(atPath: ClaudeDesktop.defaultDataDir.path)
        } catch {
            profiles = []
            adoptOffered = false
            errorMessage = error.localizedDescription
        }
    }

    func openDesktop(_ profile: Profile) {
        Task {
            do {
                _ = try await Launcher.launchDesktop(dataDir: URL(filePath: profile.desktopDataDir))
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshRunning()
        }
    }

    func quitDesktop(_ profile: Profile) {
        Task {
            do {
                _ = try await Launcher.quitDesktop(dataDir: URL(filePath: profile.desktopDataDir), name: profile.name)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshRunning()
        }
    }

    /// Marks each profile whose Desktop is running, from one fresh process list. Read-only.
    func refreshRunning() {
        do {
            let pids = try Launcher.runningDesktopPIDs(dataDirs: profiles.map { URL(filePath: $0.desktopDataDir) })
            runningIDs = Set(profiles.indices.compactMap { pids[$0] == nil ? nil : profiles[$0].id })
        } catch HopError.claudeDesktopNotFound {
            runningIDs = []
        } catch {
            runningIDs = []
            errorMessage = error.localizedDescription
        }
    }

    func openTerminal(_ profile: Profile) {
        do {
            try TerminalLauncher.requireClaudeCode()
            let script = try CLIProfile.prepare(profile, store: store)
            try TerminalLauncher.open(script, in: terminalApp)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var statusLines: [StatusLine] {
        ClaudeEnvironment.lines(desktopInstalled: desktopInstalled, code: claudeCode, error: errorMessage)
    }

    /// Checks for Claude Desktop and Claude Code (version included) off the main thread.
    func refreshEnvironment() async {
        let result = await Task.detached {
            Result { () throws(HopError) -> ClaudeEnvironment.Snapshot in try ClaudeEnvironment.check() }
        }.value
        switch result {
        case .success(let snapshot):
            desktopInstalled = snapshot.desktopInstalled
            claudeCode = snapshot.code
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the install state now and checks the login shell's PATH off the main thread.
    func refreshCommand() {
        commandState = HopCommand.state
        guard commandState != .notInstalled else {
            commandOnPath = true
            return
        }
        Task {
            let result = await Task.detached { Result { () throws(HopError) -> Bool in try HopCommand.isOnPath() } }.value
            switch result {
            case .success(let onPath):
                commandOnPath = onPath
            case .failure(let error):
                commandOnPath = true
                errorMessage = error.localizedDescription
            }
        }
    }

    func installCommand() {
        do {
            _ = try HopCommand.install()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshCommand()
    }

    func copyPathLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HopCommand.pathLine, forType: .string)
    }

    var startupFileName: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if shell.hasSuffix("zsh") { return "~/.zshrc" }
        if shell.hasSuffix("bash") { return "~/.bash_profile" }
        return "your shell's startup file"
    }

    func chooseTerminal(_ app: TerminalApp) {
        UserDefaults.standard.set(app.bundleID, forKey: TerminalApp.defaultsKey)
        terminalApp = app
    }

    func adopt() {
        do {
            var list = try store.load()
            let name = adoptName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !list.contains(where: \.isAdopted) else {
                errorMessage = "A profile already uses your current Claude login."
                return
            }
            let id = try ProfileEditing.newID(for: name, in: list)
            guard FileManager.default.fileExists(atPath: ClaudeDesktop.defaultDataDir.path) else {
                errorMessage = "No current Claude login was found to adopt."
                return
            }
            list.append(Profile(
                id: id,
                name: name,
                desktopDataDir: ClaudeDesktop.defaultDataDir.path,
                isAdopted: true
            ))
            try store.save(list)
            profiles = list
            adoptOffered = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addProfile() {
        do {
            var list = try store.load()
            let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = try ProfileEditing.newID(for: name, in: list)
            list.append(Profile(
                id: id,
                name: name,
                desktopDataDir: store.desktopDataDir(forID: id).path,
                isAdopted: false
            ))
            try store.save(list)
            profiles = list
            newProfileName = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func startRename(_ profile: Profile) {
        removingID = nil
        renameDraft = profile.name
        renamingID = profile.id
    }

    func cancelRename() {
        renamingID = nil
        renameDraft = ""
    }

    func commitRename() {
        guard let id = renamingID else { return }
        do {
            _ = try ProfileEditing.rename(id: id, to: renameDraft, store: store)
            renamingID = nil
            renameDraft = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func startRemove(_ profile: Profile) {
        renamingID = nil
        removingID = profile.id
    }

    func cancelRemove() {
        removingID = nil
    }

    func removeProfile(trashData: Bool) {
        guard let id = removingID else { return }
        do {
            _ = try ProfileEditing.remove(id: id, trashData: trashData, store: store)
            removingID = nil
            errorMessage = nil
        } catch {
            // The profile is already off the list when only the Trash step failed.
            if case .trashFailed = error { removingID = nil }
            errorMessage = error.localizedDescription
        }
        reload()
    }

    /// A folder path with the home folder shown as ~.
    func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    func profileFolder(for profile: Profile) -> URL {
        store.rootDir.appending(path: "profiles/\(profile.id)", directoryHint: .isDirectory)
    }
}

struct MenuView: View {
    @Bindable var model: HopModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.statusLines.enumerated()), id: \.offset) { _, line in
                switch line.kind {
                case .plain:
                    Text(line.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .yellow:
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text(line.text)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                case .red:
                    EmptyView()
                }
            }

            if model.adoptOffered {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use your current Claude login").font(.headline)
                    HStack {
                        TextField("Name", text: $model.adoptName)
                        Button("Adopt") { model.adopt() }
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Divider()
            }

            ForEach(model.profiles) { profile in
                profileRow(profile)
            }

            if let pending = model.pendingSignIn {
                VStack(alignment: .leading, spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Sign in inside \(pending.name)'s window. Waiting… \(elapsedText(pending, at: context.date))")
                            .font(.caption)
                    }
                    HStack {
                        Button("Signed in") { model.finishSignIn() }
                        Button("Cancel") { model.cancelSignIn() }
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            Picker("Terminal app", selection: Binding(
                get: { model.terminalApp },
                set: { model.chooseTerminal($0) }
            )) {
                ForEach(TerminalApp.installed) { app in
                    Text(terminalLabel(app)).tag(app)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 6) {
                Text("+ Add profile").font(.headline)
                HStack {
                    TextField("Name", text: $model.newProfileName)
                    Button("Add") { model.addProfile() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                switch model.commandState {
                case .notInstalled:
                    Button("Install hop command") { model.installCommand() }
                case .installedHere:
                    Text("Type hop <name> in any shell").font(.caption).foregroundStyle(.secondary)
                case .installedElsewhere:
                    Button("Update hop command") { model.installCommand() }
                }
                if model.commandState != .notInstalled, !model.commandOnPath {
                    Text("Add this line to \(model.startupFileName):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(HopCommand.pathLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy") { model.copyPathLine() }
                }
            }

            if let message = model.errorMessage {
                HStack(alignment: .top) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        model.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss error")
                }
            }

            Divider()
            Button("Quit Hop") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            model.refreshRunning()
            model.refreshCommand()
            Task { await model.refreshEnvironment() }
        }
    }

    private func terminalLabel(_ app: TerminalApp) -> String {
        [TerminalApp.terminal.bundleID, TerminalApp.ghostty.bundleID].contains(app.bundleID)
            ? app.name
            : "\(app.name) (untested)"
    }

    /// Time since the sign-in began, as m:ss.
    private func elapsedText(_ pending: PendingSignIn, at date: Date) -> String {
        let start = pending.deadline.addingTimeInterval(-Double(HopModel.signInSeconds))
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile) -> some View {
        if model.renamingID == profile.id {
            VStack(alignment: .leading, spacing: 6) {
                Text("hop: \(profile.id)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Name", text: $model.renameDraft)
                    Button("Save") { model.commitRename() }
                    Button("Cancel") { model.cancelRename() }
                }
            }
        } else if model.removingID == profile.id {
            VStack(alignment: .leading, spacing: 6) {
                Text("Remove \(profile.name)?").font(.headline)
                if profile.isAdopted {
                    Text("Claude's own data at \(model.displayPath(ClaudeDesktop.defaultDataDir)) is untouched.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.displayPath(model.profileFolder(for: profile)))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Its Claude Code login stays in the Keychain until you run /logout under it.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Remove from Hop") { model.removeProfile(trashData: false) }
                if !profile.isAdopted {
                    Button("Remove and move data to Trash", role: .destructive) {
                        model.removeProfile(trashData: true)
                    }
                }
                Button("Cancel") { model.cancelRemove() }
            }
        } else {
            HStack {
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        if model.runningIDs.contains(profile.id) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                                .accessibilityLabel("Running")
                        }
                        Text(profile.name)
                    }
                    Text("hop: \(profile.id)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if profile.needsSignIn {
                    Button("Sign in") { model.beginSignIn(profile) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.desktopInstalled)
                }
                Button("Desktop") { model.openDesktop(profile) }
                    .disabled(!model.desktopInstalled)
                Button("Terminal") { model.openTerminal(profile) }
                    .disabled(model.claudeCode == .missing)
                Menu {
                    if model.runningIDs.contains(profile.id) {
                        Button("Quit Claude Desktop") { model.quitDesktop(profile) }
                    }
                    if !profile.isAdopted {
                        Button("Sign in again") { model.beginSignIn(profile) }
                            .disabled(!model.desktopInstalled)
                    }
                    Button("Rename") { model.startRename(profile) }
                    Button("Remove", role: .destructive) { model.startRemove(profile) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More for \(profile.name)")
            }
        }
    }
}
