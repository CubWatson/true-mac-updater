# TrueMacUpdater

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple)](https://www.apple.com/macos/)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Version](https://img.shields.io/badge/version-2.2.0-blue)](TrueMacUpdater.sh)

**One command to update your Mac's software** — Homebrew and App Store apps, plus a check for macOS updates.

Built for Apple Silicon (M-series, `arm64`).

```
./TrueMacUpdater.sh
```

That's it. The script walks through three stages and gives you a clean summary at the end.

<img width="1920" height="1105" alt="Screen Recording 2026-06-13 at 9 30 48 PM" src="https://github.com/user-attachments/assets/2d8b2a83-bad8-4be6-a6d3-27f4b94e440a" />

## What it does

| Stage | Tool | Action |
|-------|------|--------|
| 1 · Homebrew | `brew` | Updates the catalog, then upgrades installed formulae **and** casks |
| 2 · App Store | `mas` | Updates installed Mac App Store apps (asks for your password — mas 7 installs as root) |
| 3 · macOS | `softwareupdate` | Checks for system and security updates, then directs you to System Settings to install them |

It's **resilient**: if one stage hits a problem, the others still run, and the summary tells you honestly what succeeded and what didn't.

## Highlights

- **Safe by default** — shows you what's outdated (and whether you have the disk space for it) and asks before changing packages or apps.
- **Live progress** — packages and apps upgrade one at a time with an `[n/N]` counter, and a status area pinned to the bottom of the terminal keeps all three stages in view while their output scrolls above.
- **`--dry-run`** — preview everything without touching your system.
- **Self-healing** — installs `mas` (and offers to install Homebrew) if they're missing.
- **No more skipped taps** — auto-trusts packages you already have installed from third-party Homebrew taps, so `brew upgrade` stops silently skipping them (Homebrew 6+). New, not-yet-installed packages still prompt you; opt out with `--no-trust`.
- **Recovers from link conflicts** — when a formula's `brew link` step collides with files a cask already owns (classically the `docker` formula vs. the `docker-desktop` cask), it auto-runs Homebrew's own `brew link --overwrite` fix instead of failing the whole Homebrew stage. A genuine upgrade failure still reports as failed.
- **Sudo kept alive** — type your password once for App Store updates; no mid-run interruptions.
- **Done notification** — `--notify` posts a macOS notification when the run finishes, so you can tab away.
- **Honest summary** — per-stage *and* per-item results, counts, elapsed time, and a clear notice when macOS updates are waiting in System Settings. App Store updates are verified against the app bundle's version on disk, not just `mas`'s exit code.
- **Manageable logs** — transcripts are saved to `~/Library/Logs/TrueMacUpdater/`; delete them all with `--clear-logs`.
- **Color-aware** — respects `NO_COLOR` and non-interactive pipes.

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
| `--no-color` | Disable colored output |
| `--no-log` | Don't write a transcript |
| `--clear-logs` | Delete all saved transcripts and exit |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

## Requirements

- An Apple Silicon Mac (M1/M2/M3/M4…) running macOS.
- [Homebrew](https://brew.sh) — the script offers to install it if it's missing.
- `mas` — installed automatically via Homebrew if needed.
- An App Store account you're signed in to (for App Store updates).

## First run

```bash
git clone <this repo>
cd true-mac-updater
chmod +x TrueMacUpdater.sh
./TrueMacUpdater.sh --dry-run     # take it for a spin first
```

Want it even faster? Drop an alias in your `~/.zshrc`:

```bash
alias update-mac="/path/to/TrueMacUpdater.sh"
```
