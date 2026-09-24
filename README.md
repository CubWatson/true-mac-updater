# TrueMacUpdater

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple)](https://www.apple.com/macos/)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Version](https://img.shields.io/badge/version-2.2.0-blue)](TrueMacUpdater.sh)

Updates your Homebrew packages and Mac App Store apps, then checks for macOS updates.

Built for Apple Silicon (M-series, `arm64`).

```
./TrueMacUpdater.sh
```

The script runs three stages and prints a summary at the end.

## What it does

| Stage | Tool | Action |
|-------|------|--------|
| 1 · Homebrew | `brew` | Updates the catalog, then upgrades installed formulae and casks |
| 2 · App Store | `mas` | Updates installed Mac App Store apps (asks for your password, since mas 7 installs as root) |
| 3 · macOS | `softwareupdate` | Checks for system and security updates, then directs you to System Settings to install them |

If one stage fails, the others still run, and the summary shows what succeeded and what didn't. The exit code is non-zero if any stage failed.

## Highlights

- Asks once before the Homebrew stage, and again after listing App Store updates, before changing anything. Warns you if there's less than 10 GB of free disk space.
- Packages and apps upgrade one at a time with an `[n/N]` counter. A status area at the bottom of the terminal shows all three stages while their output scrolls above.
- `--dry-run` shows what would happen without changing anything. It skips the Homebrew catalog refresh, so its list of outdated packages can be slightly behind.
- Installs `mas` if it's missing, and offers to install Homebrew.
- Trusts packages you already have from third-party Homebrew taps, so `brew upgrade` doesn't skip them (Homebrew 6+). New packages you haven't installed still prompt you. Turn this off with `--no-trust`.
- When a formula's `brew link` step collides with files a cask already owns (for example the `docker` formula and the `docker-desktop` cask), it runs Homebrew's own `brew link --overwrite` fix instead of failing the whole Homebrew stage. Other upgrade failures still report as failed.
- You type your password once for App Store updates; sudo stays active for the rest of the run.
- `--notify` posts a macOS notification when the run finishes.
- The summary shows per-stage and per-item results, counts, elapsed time, and a notice when macOS updates are waiting in System Settings. App Store updates are checked against the app bundle's version on disk, not just `mas`'s exit code.
- Transcripts are saved to `~/Library/Logs/TrueMacUpdater/`. `--clear-logs` deletes them.
- Respects `NO_COLOR`, and turns off color when output isn't a terminal.

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

- An Apple Silicon Mac (M1/M2/M3/M4…) running macOS. On an Intel Mac the script warns you and asks before continuing.
- [Homebrew](https://brew.sh). The script offers to install it if it's missing.
- `mas`, installed automatically via Homebrew if needed.
- An App Store account you're signed in to (for App Store updates).

## First run

```bash
git clone https://github.com/CubWatson/true-mac-updater.git
cd true-mac-updater
./TrueMacUpdater.sh --dry-run     # preview first
```

To run it from anywhere, add an alias to your `~/.zshrc`:

```bash
alias update-mac="/path/to/TrueMacUpdater.sh"
```
