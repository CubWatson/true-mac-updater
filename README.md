# TrueMacUpdater

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple)](https://www.apple.com/macos/)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Version](https://img.shields.io/badge/version-2.2.0-blue)](TrueMacUpdater.sh)

A bash script that updates your Homebrew packages and Mac App Store apps, then
checks whether macOS has an update waiting. Written for Apple Silicon Macs.

```bash
./TrueMacUpdater.sh
```

## What it does

It runs three stages in order:

1. **Homebrew.** Refreshes the catalog, then upgrades each outdated formula and
   cask.
2. **App Store.** Updates your App Store apps with
   [`mas`](https://github.com/mas-cli/mas). You'll be asked for your password,
   since mas 7 installs apps as root.
3. **macOS.** Runs `softwareupdate --list`. If an update is available, it tells
   you to install it from System Settings. The script doesn't install macOS
   updates itself.

If one stage fails, the others still run. At the end you get a summary of what
was updated, what failed, and what's waiting in System Settings. The exit code
is non-zero if any stage failed.

## Details

- It asks before changing anything: once before the Homebrew stage, and again
  after listing App Store updates. `-y` answers yes to both.
- It warns you if there's less than 10 GB of free disk space.
- While it runs, the bottom of the terminal shows each stage's status and an
  `[n/N]` count of the current package or app.
- App Store updates are checked against the app's version on disk, because
  `mas` sometimes reports the wrong result.
- If `mas` is missing, it installs it. If Homebrew is missing, it offers to
  install it.
- Packages you already have from third-party taps are trusted automatically,
  so Homebrew 6 doesn't skip them. `--no-trust` turns this off.
- If an upgrade fails only because of a link conflict with a cask (for example
  the `docker` formula and the `docker-desktop` cask), it runs
  `brew link --overwrite` for that formula.
- Each run is logged to `~/Library/Logs/TrueMacUpdater/`. `--clear-logs`
  deletes the logs.
- `--dry-run` shows what would happen without changing anything. It skips the
  Homebrew catalog refresh, so its list of outdated packages can be slightly
  behind.

## Usage

```bash
./TrueMacUpdater.sh                 # interactive, does everything
./TrueMacUpdater.sh --dry-run       # preview only, change nothing
./TrueMacUpdater.sh -y              # update without confirmation prompts
./TrueMacUpdater.sh --skip-system   # skip the macOS update check
./TrueMacUpdater.sh --clear-logs    # delete every saved transcript and exit
```

### Options

| Flag | Description |
|------|-------------|
| `-y, --yes` | Don't ask for confirmation; assume yes |
| `-n, --dry-run` | Show what would happen, change nothing |
| `--skip-brew` | Skip the Homebrew stage |
| `--skip-appstore` | Skip the App Store stage |
| `--skip-system` | Skip the macOS system-update stage |
| `--no-trust` | Don't auto-trust installed packages from third-party taps |
| `--notify` | Post a macOS notification when the run finishes |
| `--no-color` | Disable colored output (`NO_COLOR` also works) |
| `--no-log` | Don't write a transcript |
| `--clear-logs` | Delete all saved transcripts and exit |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

## Requirements

- An Apple Silicon Mac. On an Intel Mac the script warns you and asks before
  continuing.
- [Homebrew](https://brew.sh). The script offers to install it if it's missing.
- An App Store account you're signed in to, for App Store updates.

## Install

```bash
git clone https://github.com/CubWatson/true-mac-updater.git
cd true-mac-updater
./TrueMacUpdater.sh --dry-run
```

To run it from anywhere, add an alias to your `~/.zshrc`:

```bash
alias update-mac="/path/to/true-mac-updater/TrueMacUpdater.sh"
```
