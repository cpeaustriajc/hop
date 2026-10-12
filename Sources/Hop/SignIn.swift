import AppKit
import Foundation

struct PendingSignIn: Equatable {
    let profileID: String
    let name: String
    let dataDir: URL
    let pid: Int32
    let deadline: Date
}

/// Owns the `claude://` handler: Hop holds it for one sign-in, then Claude.app gets it back.
@MainActor
enum ClaudeHandler {
    static let hopBundleID = "com.cj.hop"
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let claudeAppPath = "/Applications/Claude.app"
    static let maxAttempts = 3
    static let settleSeconds = 3
    static let tookBackMessage = "Claude took back claude:// links before the sign-in started. Click Sign in again."
    private static let probeURL = URL(string: "claude://x")!

    static func holdsScheme() -> Bool {
        liveHandlerBundleID() == hopBundleID
    }

    static func isInApplications(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    static func liveHandlerBundleID() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func setHandler(appURL: URL) async throws(HopError) {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "claude") { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            throw HopError.handlerSetFailed(underlying: error)
        }
    }

    /// Retries only the named condition "lookup is not Claude.app yet", up to `maxAttempts`; other failures throw at once.
    static func restoreClaude() async throws(HopError) {
        let claudeApp = URL(filePath: claudeAppPath)
        for attempt in 1...maxAttempts {
            try await setHandler(appURL: claudeApp)
            if liveHandlerBundleID() == claudeBundleID { return }
            if attempt < maxAttempts {
                do {
                    try await Task.sleep(for: .milliseconds(backoffMilliseconds(attempt)))
                } catch {
                    throw HopError.handlerRestoreFailed(underlying: error)
                }
            }
        }
        throw HopError.handlerRestoreFailed(underlying: nil)
    }

    /// Exponential backoff from 200 ms, capped at 1 s, with 0-100 ms of jitter.
    static func backoffMilliseconds(_ attempt: Int) -> Int {
        min(1000, 200 * (1 << (attempt - 1))) + Int.random(in: 0...100)
    }

    /// Sends kAEGetURL to one PID; callers must first check that PID is the pending profile's Desktop.
    nonisolated static func sendGetURL(pid: Int32, url: String) throws(HopError) {
        let eventClass = AEEventClass(0x4755_524C)
        let eventID = AEEventID(0x4755_524C)
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyDirectObject))
        var reply = AEDesc()
        let status = AESendMessage(event.aeDesc, &reply, AESendMode(kAEWaitReply), kAEDefaultTimeout)
        AEDisposeDesc(&reply)
        guard status == noErr else {
            throw HopError.linkForwardFailed(status: status)
        }
    }
}

extension HopModel {
    static let signInSeconds = 300

    func beginSignIn(_ profile: Profile) {
        guard ClaudeHandler.isInApplications(Bundle.main.bundleURL) else {
            errorMessage = HopError.signInNeedsApplications.localizedDescription
            return
        }
        Task {
            do {
                _ = try await startDesktop(profile, report: { _ in })
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            do {
                try await takeOverClaudeHandler(for: profile)
                let forwardedPID = try await Launcher.launchDesktop(dataDir: URL(filePath: profile.desktopDataDir))
                arm(profile, pid: forwardedPID)
            } catch {
                let message = error.localizedDescription
                if await restoreAfterSignIn() { errorMessage = message }
            }
        }
    }

    /// Starts or raises the profile's Desktop before Hop takes the scheme, so its own sign-in window can open.
    /// A freshly started Desktop gets a settle delay; an already-running one does not.
    func startDesktop(_ profile: Profile, report: (String) -> Void) async throws(HopError) -> Int32 {
        let dataDir = URL(filePath: profile.desktopDataDir)
        let wasRunning = try Launcher.runningDesktopPID(dataDir: dataDir) != nil
        let pid = try await Launcher.launchDesktop(dataDir: dataDir)
        guard !wasRunning else { return pid }
        report("waiting for \(profile.name)'s Claude to start (pid \(pid))")
        try await waitForDesktop(pid, dataDir: dataDir, name: profile.name)
        report("settling \(ClaudeHandler.settleSeconds) s before takeover")
        do {
            try await Task.sleep(for: .seconds(ClaudeHandler.settleSeconds))
        } catch {
            throw HopError.desktopNotReady(name: profile.name, underlying: error)
        }
        return pid
    }

    private func waitForDesktop(_ pid: Int32, dataDir: URL, name: String) async throws(HopError) {
        for _ in 0..<50 {
            if try Launcher.runningDesktopPID(dataDir: dataDir) == pid { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                throw HopError.desktopNotReady(name: name, underlying: error)
            }
        }
        throw HopError.desktopNotReady(name: name, underlying: nil)
    }

    func finishSignIn() {
        guard let pending = pendingSignIn else { return }
        clearPending()
        errorMessage = nil
        Task {
            await restoreAfterSignIn()
            markSignedIn(id: pending.profileID)
        }
    }

    func cancelSignIn() {
        guard pendingSignIn != nil else { return }
        clearPending()
        errorMessage = nil
        Task { await restoreAfterSignIn() }
    }

    func receiveSignInLink(_ url: URL) {
        let pending = pendingSignIn
        clearPending()
        Task { await deliverLink(url, pending: pending) }
    }

    func healClaudeHandlerAtLaunch() async {
        guard pendingSignIn == nil, ClaudeHandler.liveHandlerBundleID() == ClaudeHandler.hopBundleID else { return }
        await restoreAfterSignIn()
    }

    func restoreBeforeQuit() async {
        clearPending()
        await restoreAfterSignIn()
    }

    @discardableResult
    func restoreAfterSignIn() async -> Bool {
        do {
            try await ClaudeHandler.restoreClaude()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func clearPending() {
        pendingSignIn = nil
        signInTimeoutTask?.cancel()
        signInTimeoutTask = nil
    }

    private func takeOverClaudeHandler(for profile: Profile) async throws(HopError) {
        NSApp.activate()
        try await ClaudeHandler.setHandler(appURL: Bundle.main.bundleURL)
        guard ClaudeHandler.liveHandlerBundleID() == ClaudeHandler.hopBundleID else {
            throw HopError.handlerNotCaught(name: profile.name)
        }
    }

    private func arm(_ profile: Profile, pid: Int32, watchesHandler: Bool = true) {
        signInTimeoutTask?.cancel()
        let deadline = Date.now.addingTimeInterval(TimeInterval(Self.signInSeconds))
        pendingSignIn = PendingSignIn(
            profileID: profile.id,
            name: profile.name,
            dataDir: URL(filePath: profile.desktopDataDir),
            pid: pid,
            deadline: deadline
        )
        errorMessage = nil
        signInTimeoutTask = Task {
            while true {
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                guard pendingSignIn?.deadline == deadline else { return }
                if Date.now >= deadline {
                    await expireSignIn(deadline: deadline)
                    return
                }
                if watchesHandler, !ClaudeHandler.holdsScheme() {
                    endWatch(deadline: deadline)
                    return
                }
            }
        }
    }

    /// Ends the wait without restoring: Claude already holds the scheme, so Hop must not grab it back silently.
    private func endWatch(deadline: Date) {
        guard pendingSignIn?.deadline == deadline else { return }
        pendingSignIn = nil
        signInTimeoutTask = nil
        errorMessage = ClaudeHandler.tookBackMessage
    }

    /// Hidden `--signin-dry` check: runs the real start and watch steps against a scratch profile, skipping takeover.
    func runSignInDry(_ profile: Profile, bypassWatch: Bool, report: (String) -> Void) async throws(HopError) -> Int32 {
        let pid = try await startDesktop(profile, report: report)
        report("takeover skipped (dry run)")
        arm(profile, pid: pid, watchesHandler: !bypassWatch)
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            throw HopError.desktopNotReady(name: profile.name, underlying: error)
        }
        if errorMessage == ClaudeHandler.tookBackMessage {
            report("watch tripped: \(ClaudeHandler.tookBackMessage)")
        } else if pendingSignIn != nil {
            report("watch did not trip after 5 s\(bypassWatch ? " (bypassed)" : "")")
        }
        clearPending()
        return pid
    }

    /// Clears the pending state without cancelling the timer, since this method runs inside that timer's task.
    private func expireSignIn(deadline: Date) async {
        guard let pending = pendingSignIn, pending.deadline == deadline else { return }
        pendingSignIn = nil
        signInTimeoutTask = nil
        errorMessage = HopError.signInTimedOut(name: pending.name).localizedDescription
        await restoreAfterSignIn()
    }

    private func deliverLink(_ url: URL, pending: PendingSignIn?) async {
        guard let pending else {
            await openWithClaude(url, notice: nil)
            return
        }
        // Checks the PID against this profile's Desktop data dir, so a reused PID never receives the link.
        let alive: Bool
        do {
            alive = try Launcher.runningDesktopPID(dataDir: pending.dataDir) == pending.pid
        } catch {
            errorMessage = error.localizedDescription
            await restoreAfterSignIn()
            return
        }
        if alive {
            await forward(url, to: pending)
        } else {
            await openWithClaude(
                url,
                notice: HopError.claudeClosedBeforeLink(name: pending.name).localizedDescription
            )
        }
    }

    private func forward(_ url: URL, to pending: PendingSignIn) async {
        do {
            try ClaudeHandler.sendGetURL(pid: pending.pid, url: url.absoluteString)
        } catch {
            errorMessage = error.localizedDescription
            await restoreAfterSignIn()
            return
        }
        await restoreAfterSignIn()
        markSignedIn(id: pending.profileID)
        do {
            _ = try await Launcher.launchDesktop(dataDir: pending.dataDir)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openWithClaude(_ url: URL, notice: String?) async {
        do {
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(filePath: ClaudeHandler.claudeAppPath),
                configuration: NSWorkspace.OpenConfiguration()
            )
            errorMessage = notice
        } catch {
            errorMessage = HopError.linkOpenFailed(underlying: error).localizedDescription
        }
        await restoreAfterSignIn()
    }

    private func markSignedIn(id: String) {
        do {
            var list = try store.load()
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].needsSignIn = false
            try store.save(list)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
