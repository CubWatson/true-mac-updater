#!/usr/bin/env bash
#
# ╭───────────────────────────────────────────────────────────────────────╮
# │  TrueMacUpdater — the one command that updates your whole Mac         │
# │                                                                       │
# │  • Homebrew     formulae, casks, and cleanup                          │
# │  • App Store    every app you bought, via mas                         │
# │  • macOS        system + security software updates                    │
# │                                                                       │
# │  Built for Apple Silicon (M-series, arm64).                           │
# ╰───────────────────────────────────────────────────────────────────────╯
#
# Usage:   ./TrueMacUpdater.sh [options]
# Help:    ./TrueMacUpdater.sh --help
#
# This script is intentionally resilient: if one component fails, the others
# still run, and you get an honest summary at the end.

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  Metadata
# ─────────────────────────────────────────────────────────────────────────────
readonly VERSION="2.0.0"
readonly SELF_NAME="TrueMacUpdater"

# ─────────────────────────────────────────────────────────────────────────────
#  Configuration (overridable by flags)
# ─────────────────────────────────────────────────────────────────────────────
DO_BREW=true
DO_APPSTORE=true
DO_SYSTEM=true
DO_CLEANUP=true
DRY_RUN=false
ASSUME_YES=false
USE_COLOR=true
USE_LOG=true
AUTO_RESTART=false

# Detect TTY *before* we possibly redirect stdout into a log pipe.
STDOUT_IS_TTY=false
[[ -t 1 ]] && STDOUT_IS_TTY=true

# ─────────────────────────────────────────────────────────────────────────────
#  Summary state (no associative arrays — keep macOS bash 3.2 happy)
# ─────────────────────────────────────────────────────────────────────────────
BREW_RESULT="skipped"
APPSTORE_RESULT="skipped"
SYSTEM_RESULT="skipped"
BREW_COUNT=0
APPSTORE_COUNT=0
SYSTEM_COUNT=0
RESTART_REQUIRED=false
FAILURES=0
START_TS=$(date +%s)
LOG_FILE=""

# ═════════════════════════════════════════════════════════════════════════════
#  Output helpers
# ═════════════════════════════════════════════════════════════════════════════

setup_colors() {
  if [[ "$USE_COLOR" == true && "$STDOUT_IS_TTY" == true && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'
    NC=$'\033[0m'
  else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""
    BLUE=""; CYAN=""; MAGENTA=""; NC=""
  fi
}

# A horizontal rule that adapts to terminal width (capped for readability).
rule() {
  local cols width line
  cols=$( { tput cols; } 2>/dev/null || echo 72 )
  width=$(( cols < 74 ? cols : 74 ))
  line=$(printf '─%.0s' $(seq 1 "$width"))
  printf '%s%s%s\n' "$DIM" "$line" "$NC"
}

section() {
  echo ""
  rule
  printf '%s%s  %s%s\n' "$BOLD" "$CYAN" "$1" "$NC"
  rule
}

info()  { printf '%s•%s %s\n'  "$BLUE"    "$NC" "$*"; }
step()  { printf '%s→%s %s\n'  "$MAGENTA" "$NC" "$*"; }
ok()    { printf '%s✓%s %s\n'  "$GREEN"   "$NC" "$*"; }
warn()  { printf '%s!%s %s\n'  "$YELLOW"  "$NC" "$*"; }
err()   { printf '%s✗%s %s\n'  "$RED"     "$NC" "$*" >&2; }
note()  { printf '  %s%s%s\n'  "$DIM"     "$*" "$NC"; }

die() {
  err "$*"
  exit 1
}

# Ask a yes/no question. Honors --yes. Default is the second arg (Y/n).
confirm() {
  local prompt="$1" default="${2:-Y}" reply hint="[Y/n]"
  [[ "$ASSUME_YES" == true ]] && return 0
  [[ "$STDOUT_IS_TTY" != true ]] && return 0  # non-interactive: don't block
  [[ "$default" == "N" ]] && hint="[y/N]"
  # Talk to the terminal directly so prompts aren't swallowed by the log tee.
  printf '%s?%s %s %s ' "$YELLOW" "$NC" "$prompt" "$hint" > /dev/tty
  read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ═════════════════════════════════════════════════════════════════════════════
#  Help / version
# ═════════════════════════════════════════════════════════════════════════════

print_help() {
  cat <<EOF
${BOLD}${SELF_NAME}${NC} v${VERSION} — update your entire Mac with one command.

${BOLD}USAGE${NC}
  ./TrueMacUpdater.sh [options]

${BOLD}WHAT IT DOES${NC}
  1. Homebrew   updates, upgrades formulae & casks, then cleans up
  2. App Store  upgrades every app you own (via mas)
  3. macOS      installs system & security updates (needs sudo)

${BOLD}OPTIONS${NC}
  -y, --yes            Don't ask for confirmation; assume yes
  -n, --dry-run        Show what would happen, change nothing
  -r, --restart        Reboot automatically if macOS updates require it

      --skip-brew      Skip the Homebrew stage
      --skip-appstore  Skip the App Store stage
      --skip-system    Skip the macOS system-update stage
      --no-cleanup     Don't run 'brew cleanup'

      --no-color       Disable colored output
      --no-log         Don't write a transcript to ~/Library/Logs
  -h, --help           Show this help and exit
  -v, --version        Show version and exit

${BOLD}EXAMPLES${NC}
  ./TrueMacUpdater.sh                 # interactive, does everything
  ./TrueMacUpdater.sh -y -r           # fully unattended, reboot if needed
  ./TrueMacUpdater.sh --skip-system   # just brew + App Store, no sudo
  ./TrueMacUpdater.sh --dry-run       # preview only
EOF
}

# ═════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ═════════════════════════════════════════════════════════════════════════════

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)         ASSUME_YES=true ;;
      -n|--dry-run)     DRY_RUN=true ;;
      -r|--restart)     AUTO_RESTART=true ;;
      --skip-brew)      DO_BREW=false ;;
      --skip-appstore)  DO_APPSTORE=false ;;
      --skip-system)    DO_SYSTEM=false ;;
      --no-cleanup)     DO_CLEANUP=false ;;
      --no-color)       USE_COLOR=false ;;
      --no-log)         USE_LOG=false ;;
      -h|--help)        setup_colors; print_help; exit 0 ;;
      -v|--version)     echo "${SELF_NAME} v${VERSION}"; exit 0 ;;
      *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
  done
}

# ═════════════════════════════════════════════════════════════════════════════
#  Logging — tee a full transcript while keeping the screen readable
# ═════════════════════════════════════════════════════════════════════════════

setup_logging() {
  [[ "$USE_LOG" != true || "$DRY_RUN" == true ]] && { USE_LOG=false; return 0; }
  local dir="${HOME}/Library/Logs/${SELF_NAME}"
  mkdir -p "$dir" 2>/dev/null || { USE_LOG=false; return 0; }
  LOG_FILE="${dir}/$(date +%Y-%m-%d_%H%M%S).log"
  # Send everything to both the screen and the log file.
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# ═════════════════════════════════════════════════════════════════════════════
#  Pre-flight checks
# ═════════════════════════════════════════════════════════════════════════════

preflight() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS."

  local arch macos
  arch=$(uname -m)
  macos=$(sw_vers -productVersion 2>/dev/null || echo "unknown")

  if [[ "$arch" != "arm64" ]]; then
    warn "This Mac reports architecture '${arch}', not Apple Silicon (arm64)."
    confirm "Continue anyway?" "N" || die "Aborted."
  fi

  info "Mac:    $(sw_vers -productName 2>/dev/null || echo macOS) ${macos} (${arch})"
  info "Host:   $(scutil --get ComputerName 2>/dev/null || hostname)"
  info "User:   ${USER}"
  [[ "$USE_LOG" == true && -n "$LOG_FILE" ]] && info "Log:    ${LOG_FILE}"
  [[ "$DRY_RUN" == true ]] && warn "DRY RUN — nothing will actually be changed."
}

# Keep sudo alive for the whole run so macOS updates don't stall on a prompt.
SUDO_KEEPALIVE_PID=""
ensure_sudo() {
  [[ "$DRY_RUN" == true ]] && return 0
  step "macOS updates need administrator access."
  sudo -v || return 1
  # Refresh the sudo timestamp in the background until this script exits.
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  return 0
}

cleanup_on_exit() {
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
}
trap cleanup_on_exit EXIT
trap 'echo; warn "Interrupted. Cleaning up…"; exit 130' INT TERM

# ═════════════════════════════════════════════════════════════════════════════
#  Stage 1 — Homebrew
# ═════════════════════════════════════════════════════════════════════════════

ensure_brew_on_path() {
  command -v brew >/dev/null 2>&1 && return 0
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  command -v brew >/dev/null 2>&1
}

install_homebrew() {
  confirm "Homebrew isn't installed. Install it now?" "Y" || return 1
  info "Installing Homebrew (runs Homebrew's official installer)…"
  /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || return 1
  ensure_brew_on_path
}

stage_homebrew() {
  section "1 · Homebrew"

  if ! ensure_brew_on_path; then
    warn "Homebrew not found."
    if [[ "$DRY_RUN" == true ]]; then
      note "Dry run: would offer to install Homebrew."
      BREW_RESULT="skipped"; return
    fi
    if install_homebrew; then
      ok "Homebrew installed."
    else
      err "Could not set up Homebrew. Skipping this stage."
      BREW_RESULT="failed"; FAILURES=$((FAILURES + 1)); return
    fi
  fi

  step "Refreshing Homebrew's catalog…"
  if [[ "$DRY_RUN" == true ]]; then
    note "Dry run: would run 'brew update'."
  elif ! brew update; then
    warn "'brew update' had trouble; continuing with what we have."
  fi

  # Grab the outdated list once; 'brew upgrade' also covers outdated casks.
  local outdated
  outdated=$(brew outdated 2>/dev/null || true)
  BREW_COUNT=$(printf '%s' "$outdated" | grep -c . || true)
  BREW_COUNT=${BREW_COUNT:-0}

  if [[ "$BREW_COUNT" -eq 0 ]]; then
    ok "All Homebrew packages are already up to date."
    BREW_RESULT="ok"
  else
    info "${BREW_COUNT} package(s) can be upgraded:"
    printf '%s\n' "$outdated" | sed 's/^/    /'
    echo ""
    if [[ "$DRY_RUN" == true ]]; then
      note "Dry run: would run 'brew upgrade' (formulae + casks)."
      BREW_RESULT="ok"
    elif confirm "Upgrade these now?" "Y"; then
      step "Upgrading formulae & casks (casks may ask for your password)…"
      if brew upgrade; then
        ok "Homebrew packages upgraded."
        BREW_RESULT="ok"
      else
        warn "Some Homebrew upgrades failed (see output above)."
        BREW_RESULT="failed"; FAILURES=$((FAILURES + 1))
      fi
    else
      note "Skipped by choice."
      BREW_RESULT="ok"
    fi
  fi

  if [[ "$DO_CLEANUP" == true && "$DRY_RUN" == false ]]; then
    step "Cleaning up old versions & caches…"
    if brew cleanup --prune=all >/dev/null 2>&1; then ok "Cleanup done."; else warn "Cleanup had issues."; fi
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Stage 2 — App Store (mas)
# ═════════════════════════════════════════════════════════════════════════════

stage_appstore() {
  section "2 · App Store"

  if ! command -v mas >/dev/null 2>&1; then
    if ensure_brew_on_path; then
      if [[ "$DRY_RUN" == true ]]; then
        note "Dry run: would install 'mas' via Homebrew."
        APPSTORE_RESULT="skipped"; return
      fi
      step "'mas' (Mac App Store CLI) isn't installed — adding it via Homebrew…"
      if ! brew install mas; then
        err "Couldn't install 'mas'. Skipping App Store."
        APPSTORE_RESULT="failed"; FAILURES=$((FAILURES + 1)); return
      fi
    else
      warn "'mas' and Homebrew are both missing — can't update App Store apps."
      APPSTORE_RESULT="skipped"; return
    fi
  fi

  step "Checking for App Store updates…"
  local outdated
  outdated=$(mas outdated 2>/dev/null || true)
  APPSTORE_COUNT=$(printf '%s' "$outdated" | grep -c . || true)
  APPSTORE_COUNT=${APPSTORE_COUNT:-0}

  if [[ "$APPSTORE_COUNT" -eq 0 ]]; then
    ok "All App Store apps are up to date."
    APPSTORE_RESULT="ok"; return
  fi

  info "${APPSTORE_COUNT} App Store app(s) can be updated:"
  printf '%s\n' "$outdated" | sed 's/^/    /'
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    note "Dry run: would run 'mas upgrade'."
    APPSTORE_RESULT="ok"; return
  fi

  if confirm "Update these App Store apps now?" "Y"; then
    step "Downloading & installing App Store updates…"
    if mas upgrade; then
      ok "App Store apps updated."
      APPSTORE_RESULT="ok"
    else
      warn "Some App Store updates failed (are you signed in to the App Store?)."
      APPSTORE_RESULT="failed"; FAILURES=$((FAILURES + 1))
    fi
  else
    note "Skipped by choice."
    APPSTORE_RESULT="ok"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Stage 3 — macOS system updates
# ═════════════════════════════════════════════════════════════════════════════

stage_system() {
  section "3 · macOS System Updates"

  step "Scanning for system & security updates…"
  local list
  list=$(softwareupdate --list 2>&1 || true)

  if printf '%s' "$list" | grep -qi "No new software available"; then
    ok "macOS is fully up to date."
    SYSTEM_RESULT="ok"; return
  fi

  # Each available update appears on a "* Label:" line in modern macOS.
  SYSTEM_COUNT=$(printf '%s' "$list" | grep -c '\* Label:' || true)
  SYSTEM_COUNT=${SYSTEM_COUNT:-0}

  # Note whether any update wants a restart.
  if printf '%s' "$list" | grep -qiE 'restart|shut down'; then
    RESTART_REQUIRED=true
  fi

  if [[ "$SYSTEM_COUNT" -gt 0 ]]; then
    info "${SYSTEM_COUNT} system update(s) available:"
    printf '%s\n' "$list" | grep -E 'Title:|\* Label:' | sed 's/^/  /'
  else
    info "Updates are available:"
    printf '%s\n' "$list" | sed 's/^/  /'
  fi
  echo ""
  [[ "$RESTART_REQUIRED" == true ]] && warn "At least one update will require a restart."

  if [[ "$DRY_RUN" == true ]]; then
    note "Dry run: would run 'sudo softwareupdate --install --all'."
    SYSTEM_RESULT="ok"; return
  fi

  if ! confirm "Install macOS system updates now?" "Y"; then
    note "Skipped by choice."
    SYSTEM_RESULT="ok"; return
  fi

  if ! ensure_sudo; then
    err "Administrator access denied — skipping system updates."
    SYSTEM_RESULT="failed"; FAILURES=$((FAILURES + 1)); return
  fi

  step "Installing system updates (this can take a while)…"
  local sw_args=(--install --all)
  if [[ "$RESTART_REQUIRED" == true && "$AUTO_RESTART" == true ]]; then
    warn "Updates will install and the Mac will RESTART automatically."
    sw_args+=(--restart)
  fi

  if sudo softwareupdate "${sw_args[@]}"; then
    ok "System updates installed."
    SYSTEM_RESULT="ok"
  else
    warn "softwareupdate reported a problem (see output above)."
    SYSTEM_RESULT="failed"; FAILURES=$((FAILURES + 1))
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Summary
# ═════════════════════════════════════════════════════════════════════════════

row() {
  # row <label> <result> <extra>
  local label="$1" result="$2" extra="${3:-}" icon color
  case "$result" in
    ok)      icon="✓"; color="$GREEN" ;;
    failed)  icon="✗"; color="$RED" ;;
    skipped) icon="–"; color="$DIM" ;;
    *)       icon="?"; color="$YELLOW" ;;
  esac
  printf '  %s%s%s  %-11s %s%s%s\n' "$color" "$icon" "$NC" "$label" "$DIM" "$extra" "$NC"
}

print_summary() {
  local end_ts elapsed mins secs
  end_ts=$(date +%s)
  elapsed=$(( end_ts - START_TS ))
  mins=$(( elapsed / 60 )); secs=$(( elapsed % 60 ))

  section "Summary"

  local brew_extra appstore_extra system_extra
  if [[ "$DO_BREW" == true ]]; then brew_extra="${BREW_COUNT} update(s)"; else BREW_RESULT="skipped"; brew_extra="disabled"; fi
  if [[ "$DO_APPSTORE" == true ]]; then appstore_extra="${APPSTORE_COUNT} update(s)"; else APPSTORE_RESULT="skipped"; appstore_extra="disabled"; fi
  if [[ "$DO_SYSTEM" == true ]]; then system_extra="${SYSTEM_COUNT} update(s)"; else SYSTEM_RESULT="skipped"; system_extra="disabled"; fi

  row "Homebrew"  "$BREW_RESULT"     "$brew_extra"
  row "App Store" "$APPSTORE_RESULT" "$appstore_extra"
  row "macOS"     "$SYSTEM_RESULT"   "$system_extra"
  echo ""
  printf '  %sTook %dm %02ds%s\n' "$DIM" "$mins" "$secs" "$NC"
  [[ "$USE_LOG" == true && -n "$LOG_FILE" ]] && printf '  %sTranscript: %s%s\n' "$DIM" "$LOG_FILE" "$NC"

  echo ""
  if [[ "$FAILURES" -gt 0 ]]; then
    warn "${FAILURES} stage(s) had problems — scroll up for details."
  elif [[ "$DRY_RUN" == true ]]; then
    ok "Dry run complete. Re-run without --dry-run to apply."
  else
    printf '%s%s🎉 Your Mac is fully up to date.%s\n' "$BOLD" "$GREEN" "$NC"
  fi

  if [[ "$RESTART_REQUIRED" == true && "$AUTO_RESTART" == false && "$DRY_RUN" == false ]]; then
    echo ""
    warn "A restart is required to finish installing macOS updates."
    if confirm "Restart now?" "N"; then
      info "Restarting…"
      sudo shutdown -r now
    else
      note "Remember to restart when you're ready."
    fi
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Banner
# ═════════════════════════════════════════════════════════════════════════════

banner() {
  printf '%s%s' "$BOLD" "$CYAN"
  cat <<'EOF'
  _____                __  __            _   _          _      _
 |_   _|_ _  _ ___    |  \/  |__ _ __   | | | |_ __  __| |__ _| |_ ___ _ _
   | || '_| || / -_)   | |\/| / _` / _|  | |_| | '_ \/ _` / _` |  _/ -_) '_|
   |_||_|  \_,_\___|   |_|  |_\__,_\__|   \___/| .__/\__,_\__,_|\__\___|_|
                                              |_|
EOF
  printf '%s' "$NC"
  printf '%s     one command to update Homebrew · App Store · macOS%s\n' "$DIM" "$NC"
}

# ═════════════════════════════════════════════════════════════════════════════
#  Main
# ═════════════════════════════════════════════════════════════════════════════

main() {
  parse_args "$@"
  setup_colors
  setup_logging

  banner
  section "Pre-flight"
  preflight

  [[ "$DO_BREW"     == true ]] && stage_homebrew
  [[ "$DO_APPSTORE" == true ]] && stage_appstore
  [[ "$DO_SYSTEM"   == true ]] && stage_system

  print_summary

  [[ "$FAILURES" -gt 0 ]] && exit 1
  exit 0
}

main "$@"
