# Update pls

A macOS menu bar app that keeps every AI coding tool up to date, on this Mac and on every machine in your `~/.ssh/config`.

Claude Desktop and the Codex app don't have an update button. Update pls gives you one for each tool, plus **Update all**.

- Updates each tool the way it was installed: npm, Homebrew, its own updater, pipx, uv, bun, the publisher's download, apt or winget.
- Checks every desktop app download (hash, signature, Gatekeeper, signing team) before it replaces anything, and quits and reopens open apps for you.
- Shows live progress for every tool, says exactly why something failed, and only says "Updated" once the new version is really there.
- Rolls any tool back to an older version.
- Works on all your SSH machines, with nothing installed on them.

## What it tracks

**CLIs:** Claude Code, Codex, OpenCode, T3 Code, Cursor Agent, Gemini CLI, GitHub Copilot CLI, Amp, Factory Droid, Qwen Code, Crush, Kilo Code, Cline, Auggie, Goose, Aider, Antigravity CLI

**Desktop apps:** Claude, Codex / ChatGPT, Cursor, Antigravity, T3 Code (incl. Nightly), Grok Bot, Kiro, Zed

The menu lists everything installed on each machine with its version and the latest one, grouped by brand (Claude Code and Claude Desktop under **Claude**, and so on).

It checks again every 3 hours (change it in Settings), through macOS's background activity scheduler, which picks an energy-friendly moment. The menu bar icon shows how many updates are waiting.

It finds them by itself: the CLIs on your `PATH` (including nvm, bun, brew, pipx and uv installs) and the apps in `/Applications`. On Windows hosts it uses `winget`, and on Linux it reads `dpkg`.

## How it updates

Each tool is updated the same way it was installed:

| Installed with | Update |
| --- | --- |
| npm | `npm install -g --prefix <its prefix> <pkg>@<version>` (the right nvm or custom prefix) |
| Homebrew | `brew upgrade` / `brew upgrade --cask` |
| Native installer | the tool's own updater (`claude update`, `codex update`, `droid update`, `agy update`, ...) |
| pipx / uv / bun | `pipx upgrade` / `uv tool upgrade` / `bun add -g` |
| Mac app download | the publisher's build, checked before it replaces the app (see below) |
| winget (Windows) | `winget upgrade --id ...` |
| apt (Linux) | `apt-get install --only-upgrade` when sudo works without a password there (its package lists are refreshed first if they are over 12 hours old); otherwise a **Copy sudo command** button. An app that is open there is downloaded first, then quit (after asking), updated and opened again there |

Before a Mac app download replaces the installed app, Update pls checks:

1. The SHA-256 or SHA-512 matches what the publisher (or Homebrew) lists.
2. `codesign --verify` and `spctl` (Gatekeeper/notarization) pass.
3. The bundle ID and the **signing team** are the same as the installed app's.
4. The download really is the version listed, or at least newer than the installed one: a feed pointing at an older build never downgrades the app.

The download is checked while the app keeps running, so it is closed only for the few seconds the swap takes. If an app is open, Update pls asks once (you can turn that off), quits it like ⌘Q, swaps the new version in and reopens it in the background. Apps that weren't open are updated in place and stay closed. If the app doesn't quit, usually because it is asking you something, it is brought to the front and the update stops with that reason instead of hanging.

Many apps also update themselves (Squirrel's ShipIt, Sparkle, electron-updater). If an app has already downloaded the new version in the background, Update pls uses that copy instead of downloading it again, after the same signature, Gatekeeper and team checks (and the published hash, for electron-updater's zip). Update pls checks the installed version before it downloads, again after the download, and after the app quits, and waits for the app's own updater to finish if quitting sets it off. If the app is already on the new version, it isn't replaced or restarted a second time. The version its own updater replaced is still kept for rollback: the app is cloned just before it quits (instant and free on APFS), and if that copy can't be made, the app isn't quit or updated. If its own updater is still running after 5 minutes, the update stops there rather than replacing the app under it. If anything fails after the app was quit, the old version stays in place and the app is reopened.

Nothing is installed on your other machines. Checks and updates run over your existing SSH config with `BatchMode`, so password prompts are never answered.

## Install

Requires macOS 14+ and Xcode / Swift 5.9+.

```bash
git clone https://github.com/rohit3a/update-pls
cd update-pls
./scripts/build-app.sh --install
open "/Applications/Update pls.app"
```

## Progress, errors and logs

Each tool shows what its update is doing right now: waiting in the queue, downloading (with a percentage), checking the signature, quitting, installing, reopening. Updates run one at a time per machine and machines in parallel; pressing Update or Update all again never starts a second install. When an update ends, the row says so: **Updated to 3.27.12**, or the reason it failed in red with **Retry** (which repeats that exact job, a rollback included) and a button that opens that update's full output. A notification sums up each batch. After updating, the version is read again before the row turns green, so "Updated" means the new version is really there; only then is the old version recorded for rollback. The command line confirms its updates the same way.

While updates run, the Mac doesn't idle-sleep. A desktop app's update first checks there is room for it, and fails before downloading if there isn't. One tool is never updated twice at once, even from the menu and the command line together, and updates on a machine wait for a check of it to finish. If an app's swap is ever cut off (Update pls killed, power lost), the app is put back the next time Update pls starts, or for another Mac at its next check; a copy left incomplete is replaced by the complete one. GitHub lookups use your `gh` login (or `GH_TOKEN`) when there is one, are only fetched again when they changed, and fall back to the last answer if GitHub refuses.

Everything is logged locally:

- `~/Library/Logs/Update pls/update-pls.log`: every check (per machine, with each tool's versions), every failed version lookup (HTTP status, GitHub rate limits), every update and rollback with its steps, result and timing. Also in Console.app under `com.rohit3a.updatepls`. Click **Log** in the menu to open it.
- `~/Library/Logs/Update pls/runs/`: one file per update with its complete output, written as it runs (the last 60 are kept). **Show last update output** in a tool's **⋯** menu opens it.

## Command line

The app binary doubles as a CLI:

```bash
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" check            # every machine
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" check my-server  # one host
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" update all
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" update local/cursor
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" update all --dry-run  # Mac apps: download and check only; others: show the command
```

## Skip and roll back

Hover a tool and click **⋯** (or right-click it):

- **Skip in Update all** leaves that tool alone when you press Update all, and leaves it out of the count on the icon. You can still update it on its own. A ⏸ marks skipped tools; click it to include the tool again.
- **Hide from list** removes a tool you don't care about from the menu (and from Update all). Settings → **Hidden tools** brings it back.
- **Roll back to …** puts back the version Update pls replaced:
  - Mac apps come back from the copies kept when they were updated (the last 3 versions by default, set in Settings; in `~/Library/Application Support/Update pls/Backups`), or from the publisher's download of that version. A copy is checked first: same bundle ID and a valid signature. If the swap fails, the current version stays.
  - npm, bun, pipx and uv tools reinstall that exact version, as do Claude Code and Factory Droid through their own updaters.
  - Once rolled back, the version is read again, and the tool is skipped in Update all so it stays put.

## Updating Update pls

The app checks GitHub for a newer version of itself. If it was built from a git clone, **Update** pulls the clone, rebuilds it and reopens the new version.

## Add your own tools

Settings → **Add your own tools…** opens `~/.config/update-pls/harnesses.json`. Entries use the same format as [`catalog.json`](Sources/UpdatePls/Resources/catalog.json), and an entry with the same `id` replaces the built-in one.

```json
{
  "clis": [
    { "id": "my-tool", "name": "My Tool", "binaries": ["mytool"], "npm": ["my-tool"],
      "brand": "My Company", "selfUpdate": "update", "latest": { "npm": "my-tool" } }
  ]
}
```

`latest` can be `npm`, `pypi`, `github` (`owner/repo`), `cask`, `electronGithub` (`{ repo, channel }`), `squirrel` (a Squirrel.Mac update URL, with `{platform}` for darwin-arm64 or darwin-x64), or `scrape` (`{ url, regex }`). Tools with the same `brand` are grouped together. Pull requests that add popular tools to the catalog are welcome.

## Status

Tested on macOS and Ubuntu over SSH. Windows hosts (PowerShell + winget) are implemented but not yet tested on a real machine.

## License

MIT
