import Foundation

enum HopError: LocalizedError {
    case claudeDesktopNotFound
    case launchFailed(underlying: Error)
    case processListFailed(underlying: Error)
    case storeReadFailed(underlying: Error)
    case storeWriteFailed(underlying: Error)
    case cliLinkBlocked(path: String)
    case cliSetupFailed(underlying: Error)
    case launcherWriteFailed(underlying: Error)
    case claudeCodeNotFound
    case cliCheckFailed(underlying: Error)
    case terminalLaunchFailed(underlying: Error)
    case nameEmpty
    case nameHasNoSlug(name: String)
    case nameTaken(name: String)
    case profileNotFound(id: String)
    case adoptedDataProtected(name: String)
    case desktopRunning(name: String)
    case dataOutsideProfiles(path: String)
    case trashFailed(underlying: Error)
    case signInNeedsApplications
    case handlerNotCaught(name: String)
    case handlerSetFailed(underlying: Error)
    case handlerRestoreFailed(underlying: Error?)
    case linkForwardFailed(status: Int32)
    case linkOpenFailed(underlying: Error)
    case claudeClosedBeforeLink(name: String)
    case signInTimedOut(name: String)
    case desktopNotReady(name: String, underlying: Error?)
    case quitFailed(name: String, underlying: Error?)
    case unknownProfile(id: String, known: [String])
    case commandFolderFailed(underlying: Error)
    case commandFileForeign(path: String)
    case commandWriteFailed(underlying: Error)
    case commandPathCheckFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .claudeDesktopNotFound:
            return "Claude Desktop is not installed in /Applications or ~/Applications."
        case .launchFailed(let underlying):
            return "Could not open Claude Desktop: \(underlying.localizedDescription)"
        case .processListFailed(let underlying):
            return "Could not check whether Claude Desktop is already running: \(underlying.localizedDescription)"
        case .storeReadFailed(let underlying):
            return "Could not read the profile list, so it was left unchanged: \(underlying.localizedDescription)"
        case .storeWriteFailed(let underlying):
            return "Could not save the profile list: \(underlying.localizedDescription)"
        case .cliLinkBlocked(let path):
            return "\(path) is a real file or folder, not a link, so Hop left it alone. Move it aside to share Claude Code's config."
        case .cliSetupFailed(let underlying):
            return "Could not set up the Claude Code config folder: \(underlying.localizedDescription)"
        case .launcherWriteFailed(let underlying):
            return "Could not write the Claude Code launcher script: \(underlying.localizedDescription)"
        case .claudeCodeNotFound:
            return "Claude Code not found on your PATH"
        case .cliCheckFailed(let underlying):
            return "Could not check for Claude Code on your PATH: \(underlying.localizedDescription)"
        case .terminalLaunchFailed(let underlying):
            return "Could not open the terminal: \(underlying.localizedDescription)"
        case .nameEmpty:
            return "Enter a name for the profile."
        case .nameHasNoSlug(let name):
            return "\"\(name)\" needs at least one letter or number."
        case .nameTaken(let name):
            return "Another profile already uses the name \"\(name)\"."
        case .profileNotFound(let id):
            return "No profile with id \(id)."
        case .adoptedDataProtected(let name):
            return "\(name) uses your current Claude login, so its data is never moved to Trash."
        case .desktopRunning(let name):
            return "Quit \(name)'s Claude first"
        case .dataOutsideProfiles(let path):
            return "Hop only moves a profile folder that sits directly inside profiles/, so it left \(path) alone."
        case .trashFailed(let underlying):
            return "Removed from Hop, but could not move its data to Trash: \(underlying.localizedDescription)"
        case .signInNeedsApplications:
            return "Move Hop to Applications to sign in profiles"
        case .handlerNotCaught(let name):
            return "macOS didn't let Hop catch the sign-in. Quit your other Claude windows, then sign in from \(name)'s window."
        case .handlerSetFailed(let underlying):
            return "Could not make Hop the claude:// link handler: \(underlying.localizedDescription)"
        case .handlerRestoreFailed:
            return "Could not give claude:// links back to Claude. Quit and reopen Hop to retry; if links still open in Hop, remove Hop from Applications."
        case .linkForwardFailed(let status):
            return "Could not pass the claude:// link to Claude Desktop (status \(status))."
        case .linkOpenFailed(let underlying):
            // System error text can quote the URL, which holds a one-time sign-in code; show only domain and code.
            let error = underlying as NSError
            return "Could not open the claude:// link in Claude (\(error.domain) \(error.code))."
        case .claudeClosedBeforeLink(let name):
            return "\(name)'s Claude closed before the sign-in arrived"
        case .signInTimedOut(let name):
            return "Sign-in for \(name) timed out after 5 minutes."
        case .desktopNotReady(let name, _):
            return "\(name)'s Claude did not finish starting. Click Sign in again."
        case .quitFailed(let name, let underlying):
            if let underlying {
                return "Could not wait for \(name)'s Claude to quit: \(underlying.localizedDescription)"
            }
            return "\(name)'s Claude did not accept the quit request."
        case .unknownProfile(let id, let known):
            if known.isEmpty {
                return "hop: no profile named \"\(id)\". Hop has no profiles yet."
            }
            return "hop: no profile named \"\(id)\". Known: \(known.joined(separator: ", "))"
        case .commandFolderFailed(let underlying):
            return "Could not create the folder for the hop command: \(underlying.localizedDescription)"
        case .commandFileForeign(let path):
            return "\(path) already exists and isn't Hop's, so Hop left it alone."
        case .commandWriteFailed(let underlying):
            return "Could not write the hop command: \(underlying.localizedDescription)"
        case .commandPathCheckFailed(let underlying):
            return "Could not check whether the hop folder is on your PATH: \(underlying.localizedDescription)"
        }
    }
}
