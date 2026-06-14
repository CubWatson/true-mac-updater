# TrueMacUpdater

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M--series-black?logo=apple&logoColor=white)](https://www.apple.com/mac/m4/)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Version](https://img.shields.io/badge/version-2.0.0-blue)](TrueMacUpdater.sh)

**One command to update your entire Mac** — Homebrew, the App Store, and macOS itself.

Built for Apple Silicon (M-series, `arm64`).

```
./TrueMacUpdater.sh
```

That's it. The script walks through three stages and gives you a clean summary at the end.

---

## What it does

| Stage | Tool | Action |
|-------|------|--------|
| 1 · Homebrew | `brew` | Updates the catalog, upgrades formulae **and** casks, then cleans up old versions |
| 2 · App Store | `mas` | Upgrades every app you own from the Mac App Store |
| 3 · macOS | `softwareupdate` | Installs system & security updates (asks for your password) |

It's **resilient**: if one stage hits a problem, the others still run, and the summary tells you honestly what succeeded and what didn't.

## Highlights

- **Safe by default** — shows you what's outdated and asks before changing anything.
- **`--dry-run`** — preview everything without touching your system.
- **Self-healing** — installs `mas` (and offers to install Homebrew) if they're missing.
- **Sudo kept alive** — type your password once; no mid-run interruptions.
- **Honest summary** — per-stage status, counts, elapsed time, and restart detection.
- **Full transcript** saved to `~/Library/Logs/TrueMacUpdater/`.
- **Color-aware** — respects `NO_COLOR` and non-interactive pipes.

## Usage

```bash
./TrueMacUpdater.sh                 # interactive, does everything
./TrueMacUpdater.sh --dry-run       # preview only, change nothing
./TrueMacUpdater.sh -y -r           # fully unattended, reboot if macOS needs it
./TrueMacUpdater.sh --skip-system   # just Homebrew + App Store (no sudo needed)
```

### Options

| Flag | Description |
|------|-------------|
| `-y, --yes` | Don't ask for confirmation; assume yes |
| `-n, --dry-run` | Show what would happen, change nothing |
| `-r, --restart` | Reboot automatically if macOS updates require it |
| `--skip-brew` | Skip the Homebrew stage |
| `--skip-appstore` | Skip the App Store stage |
| `--skip-system` | Skip the macOS system-update stage |
| `--no-cleanup` | Don't run `brew cleanup` |
| `--no-color` | Disable colored output |
| `--no-log` | Don't write a transcript |
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
cd update-everything-on-my-mac
chmod +x TrueMacUpdater.sh
./TrueMacUpdater.sh --dry-run     # take it for a spin first
```

Want it even faster? Drop an alias in your `~/.zshrc`:

```bash
alias update-mac="/path/to/TrueMacUpdater.sh"
```
