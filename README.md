<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="Hop" width="330">
  </picture>
</p>

Hop is a menu-bar app that opens Claude Desktop and Claude Code as any of your Claude
accounts, side by side, without logging out. For example, you can keep a personal Max plan and
a Team plan open at the same time.

> [!NOTE]
> Hop is unofficial and not affiliated with Anthropic. It fills a gap until Claude supports
> several accounts itself, and will be retired when it does (see [Retirement](#retirement)).

## What it does

- **Desktop:** opens Claude Desktop signed into the profile you pick, next to any Claude
  windows already open. Clicking a profile that is already open brings its window forward.
- **Terminal:** opens Claude Code signed into that profile, in the terminal app you pick.
- **`hop <name>`:** starts Claude Code as that profile from any shell, passing on any further
  arguments (`hop team --resume`).
- **Shared config:** every profile's Claude Code uses your usual `CLAUDE.md`, settings,
  skills, agents, commands, hooks and plugins. Login, history, sessions and projects stay
  separate per profile.
- **Your current login:** on first run, Hop offers to adopt your existing Claude login as a
  profile (Personal), so it needs no new sign-in.
- **Running dot and Quit:** the panel shows which profiles are running and quits one without
  touching the others.

Hop never reads, copies or moves login tokens and makes no network requests. It starts the
official apps with a separate folder per profile: `--user-data-dir` for Claude Desktop and
`CLAUDE_CONFIG_DIR` for Claude Code.

## Install

Requires macOS 14 or later, and Claude Desktop in `/Applications` or `~/Applications`.

**Download:** get `Hop.zip` from Releases, unzip it, and move `Hop.app` to `/Applications` or
`~/Applications`. Hop must live in an Applications folder to sign profiles in.

The build is unsigned, so macOS blocks it on first open. Open it once, then choose
System Settings → Privacy & Security → **Open Anyway**. Alternatively, run:

```sh
xattr -dr com.apple.quarantine /Applications/Hop.app
```

**Build from source:** needs Swift 6 (Xcode 16 or the Command Line Tools).

```sh
./build.sh
```

This builds `build/Hop.app`, signs it ad hoc, and installs it to `~/Applications/Hop.app`.

## Use

1. Click the Hop icon in the menu bar. Accept **Use your current Claude login** to add it as
   Personal.
2. Under **+ Add profile**, type a name (for example `Team`) and click **Add**.
3. Click **Sign in** on the new profile. Its Claude Desktop opens; sign in inside that window,
   then click **Signed in** in Hop. Your other Claude windows stay open and signed in.
4. From then on, **Desktop** and **Terminal** open that profile directly. The first Terminal
   run of a new profile asks you to sign in to Claude Code once.
5. Click **Install hop command** to use `hop <name>` in new shells. It installs to
   `~/.local/bin/hop` without an admin password. If that folder is not on your PATH, the panel
   shows the line to add.

The `hop` name of a profile is shown under it (`hop: team`) and stays the same if you rename
the profile.

### How sign-in works

When Claude Desktop handles `claude://` links, a sign-in that finishes in your browser is sent
to whichever Claude opened first, which may be the wrong profile. While a profile signs in,
Hop briefly holds `claude://` links instead. Claude then signs in inside that profile:

- **Google:** in a separate "Sign in - Google Accounts" window.
- **Email:** with a verification code that you type into the app.

Hop gives `claude://` links back to Claude when you click **Signed in** or **Cancel**, after 5
minutes, and when Hop quits. A link that still reaches Hop during a sign-in is passed to that
profile's Claude in memory; it is never logged or stored. Outside a sign-in you started, Hop
never touches `claude://` links.

### Terminals

The panel's **Terminal app** menu lists the supported terminals installed on your Mac.

- **Tested:** Apple Terminal (the default) and Ghostty.
- **Untested:** WezTerm, Alacritty and kitty. Hop uses each one's documented way to open a
  new window running a command.
- **Not supported:** iTerm2 (scriptable only through AppleScript), Warp (its links open a
  folder, not a command) and Hyper (no documented way to run a command).

## Limits

- **MCP servers** added for all projects (`claude mcp add --scope user`) live in
  `~/.claude.json`, which also holds the login, so Hop can't share them. Add them again under
  each extra profile, for example `hop team mcp add --scope user …`.
- **Claude Code older than 2.1.296**, the newest version Hop was tested with, may let logins
  overwrite each other. The panel shows a yellow warning when it is older.
- Hop can't show which email or plan each profile is signed into, because that needs Claude's
  own data.

## Without Hop

Profiles are plain folders under `~/Library/Application Support/Hop/profiles/<name>/`, so you
can keep using them without Hop:

```sh
# Claude Desktop as the Team profile
/Applications/Claude.app/Contents/MacOS/Claude \
  --user-data-dir="$HOME/Library/Application Support/Hop/profiles/team/desktop"

# Claude Code as the Team profile
CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Hop/profiles/team/cli" claude
```

The adopted Personal profile uses Claude's default folders, so plain `claude` and the normal
Claude app open it. Never set `CLAUDE_CONFIG_DIR=~/.claude` for it: Claude Code would look for
a different login and ask you to sign in again.

## Uninstall

1. Quit Hop from its menu. This gives `claude://` links back to Claude.
2. Delete `Hop.app` and `~/.local/bin/hop`.
3. To drop the extra profiles, delete `~/Library/Application Support/Hop`. Each profile's
   Claude Code login stays in your Keychain until you run `/logout` under that profile first.

Your Personal login is untouched, since it lives in Claude's own folders.

## Retirement

When Claude Desktop or Claude Code supports several accounts natively, that half of Hop is
retired; when both do, Hop is. The README will then point to the built-in feature and the repo
will be archived. Nothing needs migrating: the commands in [Without Hop](#without-hop) keep your
profiles usable.

## License

[MIT](LICENSE)
