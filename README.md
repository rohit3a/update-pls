# Update pls

A macOS menu bar app that keeps every AI coding tool up to date, on this Mac and on every machine in your `~/.ssh/config`.

Claude Desktop and the Codex app don't have an update button. Update pls gives you one for each tool, plus **Update all**.

## What it tracks

**CLIs:** Claude Code, Codex, OpenCode, T3 Code, Cursor Agent, Gemini CLI, GitHub Copilot CLI, Amp, Factory Droid, Qwen Code, Crush, Kilo Code, Cline, Auggie, Goose, Aider, Antigravity CLI

**Desktop apps:** Claude, Codex / ChatGPT, Cursor, Antigravity, T3 Code (incl. Nightly), Grok Bot, Kiro, Zed

The menu lists everything installed on each machine with its version and the latest one, grouped by brand (Claude Code and Claude Desktop under **Claude**, and so on).

It finds them by itself: the CLIs on your `PATH` (including nvm, bun, brew, pipx and uv installs) and the apps in `/Applications`. On Windows hosts it uses `winget`, and on Linux it reads `dpkg`.

## How it updates

Each tool is updated the same way it was installed:

| Installed with | Update |
| --- | --- |
| npm | `npm install -g --prefix <its prefix> <pkg>@<version>` (the right nvm or custom prefix) |
| Homebrew | `brew upgrade` / `brew upgrade --cask` |
| Native installer | the tool's own updater (`claude update`, `codex update`, `t3 update`, ...) |
| pipx / uv / bun | `pipx upgrade` / `uv tool upgrade` / `bun add -g` |
| Mac app download | the publisher's build, checked before it replaces the app (see below) |
| winget (Windows) | `winget upgrade --id ...` |
| apt (Linux) | needs sudo, so it shows a **Copy sudo command** button instead |

Before a Mac app download replaces the installed app, Update pls checks:

1. The SHA-256 or SHA-512 matches what the publisher (or Homebrew) lists.
2. `codesign --verify` and `spctl` (Gatekeeper/notarization) pass.
3. The bundle ID and the **signing team** are the same as the installed app's.

If an app is open, it asks first, then quits it, updates it and reopens it.

Nothing is installed on your other machines. Checks and updates run over your existing SSH config with `BatchMode`, so password prompts are never answered.

## Install

Requires macOS 14+ and Xcode / Swift 5.9+.

```bash
git clone https://github.com/rohit3a/update-pls
cd update-pls
./scripts/build-app.sh --install
open "/Applications/Update pls.app"
```

## Command line

The app binary doubles as a CLI:

```bash
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" check            # every machine
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" check my-server  # one host
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" update all
"/Applications/Update pls.app/Contents/MacOS/UpdatePls" update local/cursor
```

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
