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
# ─────────────────────────────────────────────────────────────────────────────
#  How this script is organized (a map for contributors)
# ─────────────────────────────────────────────────────────────────────────────
#
#   main()                  entry point; wires everything together in order
#    ├─ parse_args()        turn CLI flags into the DO_* / *_RUN globals
#    ├─ setup_colors()      decide whether to emit ANSI color
#    ├─ setup_logging()     tee the whole run to ~/Library/Logs (unless --no-log)
#    ├─ preflight()         sanity-check the machine, print the header
#    ├─ stage_homebrew()    Stage 1 — brew update / upgrade / cleanup
#    ├─ stage_appstore()    Stage 2 — Mac App Store apps, via `mas`
#    ├─ stage_system()      Stage 3 — macOS system & security updates
#    └─ print_summary()     the final pass/fail table + exit code
#
#  Design principles, so changes stay consistent:
#
#   • Resilient, not fail-fast. A stage NEVER aborts the script. Instead each
#     stage records its outcome in a <STAGE>_RESULT global ("ok"/"failed"/
#     "skipped"/"staged") and bumps FAILURES on trouble. main() exits non-zero
#     at the end iff FAILURES > 0. This is why we deliberately do NOT use `set -e`.
#
#   • Honest reporting. We only claim success when the thing actually happened.
#     The summary reflects reality even when individual steps go sideways.
#
#   • --dry-run changes nothing. Every code path that would mutate the system is
#     guarded by a DRY_RUN check that prints "would do X" instead.
#
#   • bash 3.2 compatible. macOS still ships bash 3.2, so: no associative arrays,
#     no `${var^^}`, no `mapfile`. Keep it portable.
#
#   • Talk to the user through the helpers (info/step/ok/warn/err/note), not raw
#     `echo`, so coloring and formatting stay uniform.

# Shell safety options:
#   -u            error on use of an unset variable (catches typos early)
#   -o pipefail   a pipeline fails if ANY stage fails, not just the last one
# Note: `-e` is intentionally omitted — see "Resilient, not fail-fast" above.
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  Metadata
# ─────────────────────────────────────────────────────────────────────────────
readonly VERSION="2.0.0"
readonly SELF_NAME="TrueMacUpdater"
# Below this much free disk, preflight warns and asks before continuing. Blunt
# on purpose: a macOS update alone can want this much, and an update that dies
# halfway through a download is the worst failure mode this script has.
readonly MIN_FREE_DISK_GB=10

# ─────────────────────────────────────────────────────────────────────────────
#  Configuration — these are the defaults; parse_args() flips them from flags
# ─────────────────────────────────────────────────────────────────────────────
DO_BREW=true          # run the Homebrew stage          (--skip-brew)
DO_APPSTORE=true      # run the App Store stage          (--skip-appstore)
DO_SYSTEM=true        # run the macOS system-update stage (--skip-system)
DO_CLEANUP=true       # run `brew cleanup` after upgrades (--no-cleanup)
DO_TRUST=true         # auto-trust third-party-tap packages (--no-trust)
DO_NOTIFY=false       # post a notification when the run ends (--notify)
DRY_RUN=false         # preview only, mutate nothing      (-n / --dry-run)
ASSUME_YES=false      # answer "yes" to every prompt      (-y / --yes)
USE_COLOR=true        # emit ANSI color                   (--no-color)
USE_LOG=true          # write a transcript to ~/Library/Logs (--no-log)
AUTO_RESTART=false    # reboot automatically if macOS asks (-r / --restart)

# Whether stdout is a real terminal. We capture this *before* setup_logging()
# may redirect stdout into a `tee` pipe — past that point `[[ -t 1 ]]` would
# wrongly report "not a TTY" and we'd lose color and interactive prompts.
STDOUT_IS_TTY=false
[[ -t 1 ]] && STDOUT_IS_TTY=true

# ─────────────────────────────────────────────────────────────────────────────
#  Summary state — each stage writes here; print_summary() reads it at the end.
#  Plain scalars only (no associative arrays) to stay bash 3.2 compatible.
# ─────────────────────────────────────────────────────────────────────────────
BREW_RESULT="skipped"      # "ok" | "failed" | "skipped" — outcome of each stage;
APPSTORE_RESULT="skipped"  # the macOS stage can also be "staged": downloaded,
SYSTEM_RESULT="skipped"    # but only truly installed after a restart
BREW_COUNT=0               # how many updates each stage found (for the summary)
APPSTORE_COUNT=0
SYSTEM_COUNT=0
BREW_ITEMS=""              # per-item outcomes from the upgrade loops, one
APPSTORE_ITEMS=""          # "<ok|failed>\t<name>" line each, for the summary
RESTART_REQUIRED=false     # set true if a macOS update needs a reboot to finish
FAILURES=0                 # number of stages that hit trouble; drives exit code
START_TS=$(date +%s)       # wall-clock start, so the summary can show duration
LOG_FILE=""                # path to the transcript, filled in by setup_logging()

# ═════════════════════════════════════════════════════════════════════════════
#  Output helpers
#
#  All user-facing text goes through these so the look stays consistent. Pick by
#  intent, not by color:
#    info  •  a neutral fact            step  →  an action we're about to take
#    ok    ✓  something succeeded        warn  !  a non-fatal problem
#    err   ✗  a fatal/important error    note     dimmed secondary detail
#  The color variables are filled in by setup_colors() (empty when color is off).
# ═════════════════════════════════════════════════════════════════════════════

# Populate the color globals — but only when output is a real terminal, color
# wasn't disabled (--no-color), and the user hasn't set NO_COLOR (a cross-tool
# convention; see no-color.org). Otherwise every color var becomes empty, so the
# same printf calls emit clean, plain text into pipes and log files.
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

# Print a horizontal rule that spans the terminal width, capped at 74 columns so
# it stays readable on very wide windows. Falls back to 72 if `tput` can't tell
# us the width (e.g. when piped).
rule() {
  local cols width line
  cols=$( { tput cols; } 2>/dev/null || echo 72 )
  width=$(( cols < 74 ? cols : 74 ))
  line=$(printf '─%.0s' $(seq 1 "$width"))   # repeat "─" `width` times
  printf '%s%s%s\n' "$DIM" "$line" "$NC"
}

# Print a titled section header (blank line + rule + bold title + rule). Used to
# visually separate the stages in the output.
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

# Print an error and abort the whole script. Reserved for unrecoverable setup
# problems (wrong OS, etc.) — individual stages report failure instead of dying.
die() {
  err "$*"
  exit 1
}

# Ask a yes/no question and return 0 for yes, 1 for no.
#   $1  prompt text
#   $2  default taken on empty input — "Y" (default) or "N"
# Auto-answers in two cases so the script never hangs: --yes forces yes, and a
# non-interactive run (no TTY, e.g. piped or cron) also returns yes so unattended
# use isn't blocked waiting on a prompt.
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
#  Status area — a live stage list pinned to the bottom of the terminal
#
#  While a stage's raw output (brew's compile scroll, mas's download chatter)
#  flows past above, a small pinned area keeps every stage's state and counter
#  in view. Mechanics: the bottom STATUS_ROWS rows are fenced off with a scroll
#  region (DECSTBM), and each redraw saves the cursor (ESC 7), repaints those
#  rows, and restores it (ESC 8). Everything is written to /dev/tty, never
#  stdout, so the escape codes stay out of the transcript and the log tee.
#
#  When stdout isn't a TTY (cron, pipes, CI), STATUS_ENABLED stays false, every
#  function here is a no-op, and the plain line-per-event output stands alone.
# ═════════════════════════════════════════════════════════════════════════════

STATUS_ENABLED=false
STATUS_ROWS=4          # 1 separator rule + one line per stage
STATUS_TERM_LINES=0    # terminal height captured at init (resizes aren't tracked)
STATUS_BREW="waiting"
STATUS_APPSTORE="waiting"
STATUS_SYSTEM="waiting"

# Fence off the bottom rows and turn the pinned area on. Quietly does nothing
# without a TTY, or on terminals too short to give up four rows. The newlines
# scroll existing output up first so nothing gets painted over.
status_init() {
  [[ "$STDOUT_IS_TTY" == true ]] || return 0
  STATUS_TERM_LINES=$( { tput lines; } 2>/dev/null || echo 0 )
  [[ "$STATUS_TERM_LINES" -ge 15 ]] || return 0
  STATUS_ENABLED=true
  {
    printf '\n%.0s' $(seq 1 "$STATUS_ROWS")
    printf '\033[%dA' "$STATUS_ROWS"
    printf '\0337'
    printf '\033[1;%dr' $(( STATUS_TERM_LINES - STATUS_ROWS ))
    printf '\0338'
  } > /dev/tty
  status_draw
}

# Repaint the pinned rows from the STATUS_* globals. Lines are truncated to the
# terminal width so a long package name can't wrap and shove the layout apart.
status_draw() {
  [[ "$STATUS_ENABLED" == true ]] || return 0
  local top cols row text
  top=$(( STATUS_TERM_LINES - STATUS_ROWS + 1 ))
  cols=$( { tput cols; } 2>/dev/null || echo 80 )
  {
    printf '\0337'
    printf '\033[%d;1H\033[2K%s' "$top" "$DIM"
    printf '─%.0s' $(seq 1 $(( cols < 74 ? cols : 74 )))
    printf '%s' "$NC"
    row=$(( top + 1 ))
    for text in "1 Homebrew   ${STATUS_BREW}" \
                "2 App Store  ${STATUS_APPSTORE}" \
                "3 macOS      ${STATUS_SYSTEM}"; do
      printf '\033[%d;1H\033[2K %s' "$row" "${text:0:$(( cols - 2 ))}"
      row=$(( row + 1 ))
    done
    printf '\0338'
  } > /dev/tty
}

# Update one stage's line and repaint.
#   $1  stage key: brew | appstore | system     $2  new state text
status_set() {
  case "$1" in
    brew)     STATUS_BREW="$2" ;;
    appstore) STATUS_APPSTORE="$2" ;;
    system)   STATUS_SYSTEM="$2" ;;
  esac
  status_draw
}

# Translate a finished stage's *_RESULT into its final status-area text.
#   $1  stage key   $2  result ("ok"/"failed"/…)   $3  update count
status_finish() {
  local text
  case "$2" in
    ok)     text="✓ done · $3 update(s)" ;;
    failed) text="✗ problems (see above)" ;;
    staged) text="» staged · finishes on restart" ;;
    *)      text="– $2" ;;
  esac
  status_set "$1" "$text"
}

# Erase the pinned rows and give the whole screen back to normal scrolling.
# Called before the summary, and from cleanup_on_exit so an interrupt can't
# leave the terminal stuck with a shrunken scroll region.
status_close() {
  [[ "$STATUS_ENABLED" == true ]] || return 0
  STATUS_ENABLED=false
  local top row
  top=$(( STATUS_TERM_LINES - STATUS_ROWS + 1 ))
  {
    printf '\0337'
    for (( row = top; row < top + STATUS_ROWS; row++ )); do
      printf '\033[%d;1H\033[2K' "$row"
    done
    printf '\033[r'
    printf '\0338'
  } > /dev/tty
}

# ═════════════════════════════════════════════════════════════════════════════
#  Help / version
# ═════════════════════════════════════════════════════════════════════════════

# Print the --help text. Uses an *unquoted* heredoc so the ${BOLD}/${NC} color
# variables are expanded. If you add or rename a flag, update both this text and
# the case statement in parse_args() so they stay in sync.
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
      --no-trust       Don't auto-trust installed third-party-tap packages
      --notify         Post a macOS notification when the run finishes

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

# Translate command-line flags into the configuration globals defined up top.
# Unknown flags exit with code 2. -h/-v are handled here because they short-
# circuit the whole run. To add an option: add a case branch here, a default
# global above, and a line in print_help().
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
      --no-trust)       DO_TRUST=false ;;
      --notify)         DO_NOTIFY=true ;;
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

# Start mirroring all output to a timestamped transcript under ~/Library/Logs.
# Skipped for --no-log and --dry-run (a preview isn't worth a log file). If the
# log directory can't be created we silently fall back to screen-only output
# rather than failing the run.
setup_logging() {
  [[ "$USE_LOG" != true || "$DRY_RUN" == true ]] && { USE_LOG=false; return 0; }
  local dir="${HOME}/Library/Logs/${SELF_NAME}"
  mkdir -p "$dir" 2>/dev/null || { USE_LOG=false; return 0; }
  LOG_FILE="${dir}/$(date +%Y-%m-%d_%H%M%S).log"
  # Redirect this shell's stdout through `tee` so every subsequent line is both
  # printed to the screen and appended to the log; `2>&1` folds stderr in too.
  # `> >(...)` is process substitution — `tee` runs as a parallel process whose
  # input is our stdout. Done once here, it covers the entire rest of the run.
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# ═════════════════════════════════════════════════════════════════════════════
#  Pre-flight checks
# ═════════════════════════════════════════════════════════════════════════════

# Verify we're on a supported machine and print the run header (OS, host, user,
# disk, log path). Hard-stops on non-macOS; only warns (and asks) on non-arm64,
# since the tool can still mostly work on Intel even though it's tuned for Apple
# Silicon, and on low disk, since the user may know their updates are small.
preflight() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS."

  local arch macos free_gb
  arch=$(uname -m)
  macos=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  # Free space on the boot volume, in whole GB ($4 = "Available"). If df's
  # output isn't understood, free_gb ends up non-numeric and the check below
  # is skipped rather than blocking the run on a parsing quirk.
  free_gb=$(df -g / 2>/dev/null | awk 'NR == 2 { print $4 }')

  if [[ "$arch" != "arm64" ]]; then
    warn "This Mac reports architecture '${arch}', not Apple Silicon (arm64)."
    confirm "Continue anyway?" "N" || die "Aborted."
  fi

  info "Mac:    $(sw_vers -productName 2>/dev/null || echo macOS) ${macos} (${arch})"
  info "Host:   $(scutil --get ComputerName 2>/dev/null || hostname)"
  info "User:   ${USER}"
  case "$free_gb" in
    *[!0-9]*|'') ;;  # unparseable — skip the disk check
    *)
      info "Disk:   ${free_gb} GB free"
      if [[ "$free_gb" -lt "$MIN_FREE_DISK_GB" ]]; then
        warn "Low disk space (under ${MIN_FREE_DISK_GB} GB) — updates that fail mid-download can leave a real mess."
        confirm "Continue anyway?" "N" || die "Aborted."
      fi
      ;;
  esac
  [[ "$USE_LOG" == true && -n "$LOG_FILE" ]] && info "Log:    ${LOG_FILE}"
  [[ "$DRY_RUN" == true ]] && warn "DRY RUN — nothing will actually be changed."
}

# Acquire admin rights once and keep them warm for the rest of the run, so a long
# install doesn't suddenly block on a password prompt halfway through. Both the
# App Store stage (mas 7 runs updates as root) and the macOS stage need this;
# calling it again is a cheap no-op once the keepalive is running. PID of the
# background refresher is stored so cleanup_on_exit() can stop it. Returns 1 if
# the user fails/declines the initial sudo prompt.
#   $1  the reason to show the user before the password prompt
SUDO_KEEPALIVE_PID=""
ensure_sudo() {
  [[ "$DRY_RUN" == true ]] && return 0
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && return 0  # already acquired earlier this run
  step "${1:-Administrator access is required.}"
  sudo -v || return 1
  # Re-validate the sudo timestamp every 50s (under the default 5-min timeout) in
  # the background. `kill -0 "$$"` checks our own PID is still alive and exits the
  # loop once the main script is gone, so this never becomes an orphan.
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  return 0
}

# Restore the terminal and stop the sudo-keepalive background loop. Registered
# on EXIT so it runs no matter how the script ends (normal finish, error, or
# Ctrl-C).
cleanup_on_exit() {
  status_close
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
}
trap cleanup_on_exit EXIT
# On Ctrl-C / kill, print a tidy message and exit 130 (the conventional
# "terminated by SIGINT" code); the EXIT trap above still fires for cleanup.
trap 'echo; warn "Interrupted. Cleaning up…"; exit 130' INT TERM

# ═════════════════════════════════════════════════════════════════════════════
#  Stage 1 — Homebrew
# ═════════════════════════════════════════════════════════════════════════════

# Make sure `brew` is callable, returning 0 if it is and 1 if it can't be found.
# A non-login shell (the usual case for a script) often hasn't sourced Homebrew's
# environment, so if brew isn't on PATH we try the standard Apple Silicon install
# location and load its shellenv before giving up.
ensure_brew_on_path() {
  command -v brew >/dev/null 2>&1 && return 0
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  command -v brew >/dev/null 2>&1
}

# Offer to install Homebrew via its official installer. Returns 1 if the user
# declines or the install fails. Only reached when brew is genuinely missing.
install_homebrew() {
  confirm "Homebrew isn't installed. Install it now?" "Y" || return 1
  info "Installing Homebrew (runs Homebrew's official installer)…"
  /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || return 1
  ensure_brew_on_path
}

# Homebrew 6 refuses to *load* formulae/casks from non-official ("untrusted")
# taps, which makes 'brew upgrade' quietly skip them with a one-line warning.
# Anything you already have installed from a third-party tap is code you've
# already chosen to run, so we trust those up front — but nothing more, so a
# brand-new install from an untrusted tap still asks you first.
#
# We read the on-disk install receipts rather than 'brew info', because brew
# won't even load the metadata of an untrusted package — the exact ones we need
# to find. Each receipt records its origin under "source": { "tap": ... }, and
# every receipt has precisely one "tap" key, so a plain sed pulls it out with no
# dependency on jq (which isn't present on macOS before 15).
trust_installed_packages() {
  local prefix
  prefix=$(brew --prefix 2>/dev/null) || return 0

  # Build a newline list of "<flag>\t<full-name>" for installed packages whose
  # tap isn't an official homebrew/* one. Formulae and casks store receipts in
  # different places, so handle each.
  local entries="" receipt tap name
  for receipt in "$prefix"/Cellar/*/*/INSTALL_RECEIPT.json; do
    [[ -f "$receipt" ]] || continue            # unmatched glob stays literal
    tap=$(sed -n 's/.*"tap"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt" | head -1)
    case "$tap" in homebrew/*|"") continue ;; esac
    name=$(basename "$(dirname "$(dirname "$receipt")")")
    entries+="--formula	${tap}/${name}"$'\n'
  done
  for receipt in "$prefix"/Caskroom/*/.metadata/INSTALL_RECEIPT.json; do
    [[ -f "$receipt" ]] || continue
    tap=$(sed -n 's/.*"tap"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt" | head -1)
    case "$tap" in homebrew/*|"") continue ;; esac
    name=$(basename "$(dirname "$(dirname "$receipt")")")
    entries+="--cask	${tap}/${name}"$'\n'
  done

  entries=$(printf '%s' "$entries" | sed '/^$/d' | sort -u)
  [[ -z "$entries" ]] && return 0

  local count flag fullname
  count=$(printf '%s\n' "$entries" | grep -c .)
  step "Trusting ${count} installed package(s) from third-party taps so upgrades don't skip them…"

  while IFS=$'\t' read -r flag fullname; do
    [[ -z "$fullname" ]] && continue
    if [[ "$DRY_RUN" == true ]]; then
      note "Dry run: would run 'brew trust ${flag} ${fullname}'."
    elif brew trust "$flag" "$fullname" >/dev/null 2>&1; then
      note "trusted ${fullname}"
    else
      warn "Couldn't trust ${fullname} (continuing)."
    fi
  done <<EOF
$entries
EOF
}

# After a failed 'brew upgrade', some "failures" are not failures at all: a
# formula's final `brew link` step can collide with files a cask already owns
# (classically the `docker` formula vs the `docker-desktop` cask — both ship
# docker shell completions). The package itself upgrades fine; only the symlink
# step loses the race. Homebrew prints the exact remedy — 'brew link --overwrite
# <formula>' — so we parse it back out of the captured output and run it for each
# affected formula.
#
# Returns success only when *every* error in this upgrade was such a link
# conflict and we resolved them all, so a genuine upgrade failure (a download
# error, a build error, …) still fails the stage honestly.
brew_recover_link_conflicts() {
  local log="$1" formulae f resolved=true total_errors link_errors

  formulae=$(grep -oE 'brew link --overwrite [A-Za-z0-9@._+-]+' "$log" 2>/dev/null \
               | awk '{print $NF}' | sort -u)
  [[ -z "$formulae" ]] && return 1

  # Bail out (report failure) if brew also failed for any reason that isn't a
  # link-step conflict, so we never paper over a real problem.
  total_errors=$(grep -c '^Error:' "$log" 2>/dev/null); total_errors=${total_errors:-0}
  link_errors=$(grep -c 'step did not complete' "$log" 2>/dev/null); link_errors=${link_errors:-0}
  [[ "$total_errors" -le "$link_errors" ]] || return 1

  step "A formula's link step conflicted with a cask's files; relinking with --overwrite…"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if brew link --overwrite "$f" >/dev/null 2>&1; then
      note "relinked ${f}"
    else
      resolved=false
      warn "Couldn't relink ${f} (try 'brew link --overwrite ${f}' manually)."
    fi
  done <<EOF
$formulae
EOF

  [[ "$resolved" == true ]]
}

# Turn `brew outdated --json=v2` output into "<--formula|--cask>\t<name>" lines,
# so the upgrade loop knows which flag each package needs. The JSON form is more
# robust than counting text lines, and it's the only output that distinguishes
# formulae from casks. Parsed with grep/sed rather than jq (not present on macOS
# before 15): everything before the "casks" key is the formulae half, everything
# after it is the casks half, and each entry has exactly one "name" key.
brew_outdated_entries() {
  local json="$1" formulae_half casks_half
  formulae_half=${json%%'"casks"'*}
  casks_half=${json#*'"casks"'}
  # No "casks" key at all (unexpected shape): don't let both halves fall back to
  # the whole string, or every formula would also be listed as a cask.
  case "$json" in *'"casks"'*) ;; *) casks_half="" ;; esac

  printf '%s' "$formulae_half" \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"/\1/' \
    | awk '{ print "--formula\t" $0 }'
  printf '%s' "$casks_half" \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"/\1/' \
    | awk '{ print "--cask\t" $0 }'
}

# Upgrade packages one at a time (entries: "<flag>\t<name>" lines) instead of one
# monolithic 'brew upgrade'. That buys a real [n/N] counter, per-package pass/
# fail instead of an all-or-nothing stage result, and link-conflict recovery that
# only ever deals with one formula at a time. Slightly slower than brew's
# internal batching — the visibility is worth it. Sets BREW_RESULT / FAILURES.
brew_upgrade_each() {
  local entries="$1" flag name idx=0 failed=0 upgrade_log
  upgrade_log=$(mktemp -t "${SELF_NAME}" 2>/dev/null) || upgrade_log="/dev/null"

  # The list is fed on fd 3 so brew keeps its own stdin. HOMEBREW_NO_AUTO_UPDATE
  # stops every single call from re-running the catalog auto-update — we already
  # ran 'brew update' once up front.
  while IFS=$'\t' read -r -u 3 flag name; do
    [[ -z "$name" ]] && continue
    idx=$((idx + 1))
    step "[${idx}/${BREW_COUNT}] Upgrading ${name}…"
    status_set brew "[${idx}/${BREW_COUNT}] upgrading ${name}…"
    # Keep a copy of the output (still shown on screen and in the log via the
    # global tee) so we can recognize — and recover from — a benign 'brew link'
    # conflict without re-running the upgrade.
    if HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade "$flag" "$name" 2>&1 | tee "$upgrade_log"; then
      BREW_ITEMS+="ok	${name}"$'\n'
    elif brew_recover_link_conflicts "$upgrade_log"; then
      ok "${name} upgraded (resolved a link conflict)."
      BREW_ITEMS+="ok	${name}"$'\n'
    else
      warn "Upgrade of ${name} failed (see output above)."
      BREW_ITEMS+="failed	${name}"$'\n'
      failed=$((failed + 1))
    fi
  done 3<<EOF
$entries
EOF

  [[ "$upgrade_log" != "/dev/null" ]] && rm -f "$upgrade_log"

  if [[ "$failed" -eq 0 ]]; then
    ok "All ${BREW_COUNT} Homebrew package(s) upgraded."
    BREW_RESULT="ok"
  else
    warn "${failed} of ${BREW_COUNT} Homebrew upgrade(s) failed."
    BREW_RESULT="failed"; FAILURES=$((FAILURES + 1))
  fi
}

# Stage 1 — Homebrew. Flow:
#   1. ensure brew exists (offer to install it if not)
#   2. `brew update`            refresh the catalog
#   3. trust third-party taps   so step 4 doesn't skip them (unless --no-trust)
#   4. `brew outdated`          list what needs upgrading (text + JSON forms)
#   5. `brew upgrade <pkg>`     one package at a time, with an [n/N] counter
#   6. `brew cleanup`           prune old versions (unless --no-cleanup)
# Records the outcome in BREW_RESULT / BREW_COUNT for the summary.
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

  # Trust already-installed third-party-tap packages before anything tries to
  # load them, so 'brew outdated'/'brew upgrade' don't silently skip them.
  [[ "$DO_TRUST" == true ]] && trust_installed_packages

  # Grab the outdated list in both forms: the plain text for the human-readable
  # listing (it shows versions), and --json=v2 to drive the upgrade loop.
  local outdated entries
  outdated=$(brew outdated 2>/dev/null || true)
  entries=$(brew_outdated_entries "$(brew outdated --json=v2 2>/dev/null || true)")
  # `grep -c .` counts non-empty lines = number of outdated packages. The `|| true`
  # keeps a zero count (grep exits 1 when nothing matches) from tripping pipefail.
  BREW_COUNT=$(printf '%s' "$entries" | grep -c . || true)
  BREW_COUNT=${BREW_COUNT:-0}

  if [[ "$BREW_COUNT" -eq 0 ]]; then
    ok "All Homebrew packages are already up to date."
    BREW_RESULT="ok"
  else
    info "${BREW_COUNT} package(s) can be upgraded:"
    printf '%s\n' "$outdated" | sed 's/^/    /'
    echo ""
    if [[ "$DRY_RUN" == true ]]; then
      note "Dry run: would upgrade these one at a time with 'brew upgrade <package>'."
      BREW_RESULT="ok"
    elif confirm "Upgrade these now?" "Y"; then
      step "Upgrading formulae & casks (casks may ask for your password)…"
      brew_upgrade_each "$entries"
    else
      note "Skipped by choice."
      BREW_RESULT="ok"
    fi
  fi

  # Reclaim disk space by removing outdated downloads and old keg versions.
  # `--prune=all` drops every cached download regardless of age. Output is hidden
  # (it's noisy and purely informational) unless something goes wrong.
  if [[ "$DO_CLEANUP" == true && "$DRY_RUN" == false ]]; then
    step "Cleaning up old versions & caches…"
    if brew cleanup --prune=all >/dev/null 2>&1; then ok "Cleanup done."; else warn "Cleanup had issues."; fi
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Stage 2 — App Store (mas)
# ═════════════════════════════════════════════════════════════════════════════

# Pull one string field out of a single-line JSON object ('"key":"value"').
# The [,{] anchor before the key keeps e.g. "displayName" from matching "name".
# Values containing escaped quotes get cut short — fine for the app names and
# paths we read in practice, and it keeps us free of a jq dependency.
#   $1  the JSON line   $2  the key
json_str_field() {
  printf '%s' "$1" | sed -n 's/.*[,{]"'"$2"'":"\([^"]*\)".*/\1/p'
}

# Turn `mas outdated --json` output (one JSON object per line, mas 7) into
# "<id>\t<name>\t<installed>\t<new>\t<path>" records for the update loop.
# Reads stdin; lines without an adamID (e.g. blank) are skipped.
mas_outdated_entries() {
  local line id name installed new path
  while IFS= read -r line; do
    case "$line" in *'"adamID"'*) ;; *) continue ;; esac
    id=$(printf '%s' "$line" | sed -n 's/.*[,{]"adamID":\([0-9][0-9]*\).*/\1/p')
    [[ -z "$id" ]] && continue
    name=$(json_str_field "$line" "name")
    installed=$(json_str_field "$line" "version")
    new=$(json_str_field "$line" "newVersion")
    path=$(json_str_field "$line" "path")
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "${name:-app-$id}" "$installed" "$new" "$path"
  done
}

# Read an app bundle's version straight from disk. This is the ground truth for
# "did this update actually land" — mas's exit code can be wrong in both
# directions, so we check the Info.plist instead of trusting it.
app_bundle_version() {
  defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null
}

# Update apps one at a time (entries: records from mas_outdated_entries) instead
# of one opaque 'mas upgrade': a real [n/N] counter plus per-app verification.
# After each update we poll the app bundle on disk until it reports the expected
# version (installs can take a moment to settle after mas returns).
# Sets APPSTORE_RESULT / FAILURES.
mas_update_each() {
  local entries="$1" id name installed new path idx=0 failed=0
  local mas_ok actual tries

  # The list is fed on fd 3 so mas keeps its own stdin.
  while IFS=$'\t' read -r -u 3 id name installed new path; do
    [[ -z "$id" ]] && continue
    idx=$((idx + 1))
    step "[${idx}/${APPSTORE_COUNT}] Updating ${name} (${installed} → ${new})…"
    status_set appstore "[${idx}/${APPSTORE_COUNT}] updating ${name}…"
    mas_ok=true
    sudo mas update "$id" || mas_ok=false

    # Verify on disk. When mas claims success, give the install up to ~15s to
    # settle; when it claims failure, one quick re-check is enough.
    actual=""
    if [[ -n "$path" ]]; then
      tries=5
      [[ "$mas_ok" == false ]] && tries=2
      while [[ "$tries" -gt 0 ]]; do
        actual=$(app_bundle_version "$path")
        [[ "$actual" == "$new" ]] && break
        tries=$((tries - 1))
        [[ "$tries" -gt 0 ]] && sleep 3
      done
    fi

    if [[ -n "$actual" && "$actual" == "$new" ]]; then
      [[ "$mas_ok" == false ]] && note "mas reported an error, but the bundle is at ${new} — counting it as updated."
      ok "${name} is now ${new}."
      APPSTORE_ITEMS+="ok	${name}"$'\n'
    elif [[ -z "$actual" && "$mas_ok" == true ]]; then
      # Bundle unreadable (moved? renamed?) — fall back to mas's own verdict.
      note "Couldn't verify ${name} on disk; trusting mas's success report."
      ok "${name} updated."
      APPSTORE_ITEMS+="ok	${name}"$'\n'
    else
      warn "${name} still reports version ${actual:-unknown} (expected ${new})."
      APPSTORE_ITEMS+="failed	${name}"$'\n'
      failed=$((failed + 1))
    fi
  done 3<<EOF
$entries
EOF

  if [[ "$failed" -eq 0 ]]; then
    ok "All ${APPSTORE_COUNT} App Store app(s) updated."
    APPSTORE_RESULT="ok"
  else
    warn "${failed} of ${APPSTORE_COUNT} App Store update(s) failed (are you signed in to the App Store?)."
    APPSTORE_RESULT="failed"; FAILURES=$((FAILURES + 1))
  fi
}

# Stage 2 — Mac App Store, driven by the `mas` CLI (https://github.com/mas-cli/mas).
# If `mas` isn't installed we try to add it via Homebrew first. Note: `mas` can
# only upgrade apps tied to the currently signed-in Apple ID, so a failure here
# is often just "not signed in to the App Store" rather than a real error, and
# mas 7 runs updates as root, so this stage acquires sudo before its loop.
# Records the outcome in APPSTORE_RESULT / APPSTORE_COUNT.
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
  local entries
  entries=$(mas outdated --json 2>/dev/null | mas_outdated_entries)
  APPSTORE_COUNT=$(printf '%s' "$entries" | grep -c . || true)
  APPSTORE_COUNT=${APPSTORE_COUNT:-0}

  if [[ "$APPSTORE_COUNT" -eq 0 ]]; then
    ok "All App Store apps are up to date."
    APPSTORE_RESULT="ok"; return
  fi

  info "${APPSTORE_COUNT} App Store app(s) can be updated:"
  printf '%s\n' "$entries" | awk -F'\t' '{ printf "    %s  %s → %s\n", $2, $3, $4 }'
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    note "Dry run: would update these one at a time with 'sudo mas update <app-id>'."
    APPSTORE_RESULT="ok"; return
  fi

  if confirm "Update these App Store apps now?" "Y"; then
    if ! ensure_sudo "App Store updates need administrator access (mas 7 installs as root)."; then
      err "Administrator access denied — skipping App Store updates."
      APPSTORE_RESULT="failed"; FAILURES=$((FAILURES + 1)); return
    fi
    mas_update_each "$entries"
  else
    note "Skipped by choice."
    APPSTORE_RESULT="ok"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Stage 3 — macOS system updates
# ═════════════════════════════════════════════════════════════════════════════

# Stage 3 — macOS system & security updates, via Apple's `softwareupdate` tool.
# This is the only stage that can trigger a reboot, so it's deliberately handled
# last (it shares sudo with stage 2). We parse `softwareupdate --list`
# both to count updates and to detect whether any of them require a restart.
# Records the outcome in SYSTEM_RESULT / SYSTEM_COUNT (and may set RESTART_REQUIRED).
stage_system() {
  section "3 · macOS System Updates"

  step "Scanning for system & security updates…"
  # `softwareupdate --list` prints to stderr on some macOS versions, so fold
  # stderr in (2>&1) to capture the listing reliably; `|| true` ignores its exit.
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

  if ! ensure_sudo "macOS updates need administrator access."; then
    err "Administrator access denied — skipping system updates."
    SYSTEM_RESULT="failed"; FAILURES=$((FAILURES + 1)); return
  fi

  step "Installing system updates (this can take a while)…"
  status_set system "installing ${SYSTEM_COUNT} update(s)…"
  local sw_args=(--install --all)
  if [[ "$RESTART_REQUIRED" == true && "$AUTO_RESTART" == true ]]; then
    warn "Updates will install and the Mac will RESTART automatically."
    sw_args+=(--restart)
  fi

  if sudo softwareupdate "${sw_args[@]}"; then
    if [[ "$RESTART_REQUIRED" == true && "$AUTO_RESTART" == false ]]; then
      # Restart-class updates aren't truly installed until the reboot happens
      # (on Apple Silicon, plain sudo can only download and stage them), so
      # don't claim more than what actually took place.
      warn "Updates are downloaded & staged — they finish installing on restart."
      SYSTEM_RESULT="staged"
    else
      ok "System updates installed."
      SYSTEM_RESULT="ok"
    fi
  else
    warn "softwareupdate reported a problem (see output above)."
    SYSTEM_RESULT="failed"; FAILURES=$((FAILURES + 1))
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Summary
# ═════════════════════════════════════════════════════════════════════════════

# Print one line of the summary table, mapping a result string to an icon+color.
#   $1  label   (e.g. "Homebrew")
#   $2  result  ("ok" | "failed" | "skipped" | "staged"; anything else renders as "?")
#   $3  extra   trailing dimmed detail (e.g. "3 update(s)")
row() {
  local label="$1" result="$2" extra="${3:-}" icon color
  case "$result" in
    ok)      icon="✓"; color="$GREEN" ;;
    failed)  icon="✗"; color="$RED" ;;
    skipped) icon="–"; color="$DIM" ;;
    staged)  icon="»"; color="$YELLOW" ;;
    *)       icon="?"; color="$YELLOW" ;;
  esac
  printf '  %s%s%s  %-11s %s%s%s\n' "$color" "$icon" "$NC" "$label" "$DIM" "$extra" "$NC"
}

# Print the per-item detail lines under a stage's summary row: one dimmed line
# per attempted upgrade, ✓ or ✗ by outcome. Takes the stage's *_ITEMS lines;
# prints nothing when no upgrades were attempted (skipped, dry run, up to date).
row_items() {
  local state name icon color
  [[ -z "$1" ]] && return 0
  while IFS=$'\t' read -r state name; do
    [[ -z "$name" ]] && continue
    if [[ "$state" == "ok" ]]; then icon="✓"; color="$GREEN"; else icon="✗"; color="$RED"; fi
    printf '       %s%s%s %s%s%s\n' "$color" "$icon" "$NC" "$DIM" "$name" "$NC"
  done <<EOF
$1
EOF
}

# Print the final report: per-stage pass/fail table, elapsed time, transcript
# path, an overall verdict, and (if needed) the reboot prompt. Reads all the
# *_RESULT / *_COUNT / FAILURES / RESTART_REQUIRED globals the stages filled in.
print_summary() {
  local end_ts elapsed mins secs
  end_ts=$(date +%s)
  elapsed=$(( end_ts - START_TS ))
  mins=$(( elapsed / 60 )); secs=$(( elapsed % 60 ))

  section "Summary"

  # A stage that was turned off via a --skip flag shows as "disabled" rather than
  # its (never-updated) default result, so the report matches what actually ran.
  local brew_extra appstore_extra system_extra
  if [[ "$DO_BREW" == true ]]; then brew_extra="${BREW_COUNT} update(s)"; else BREW_RESULT="skipped"; brew_extra="disabled"; fi
  if [[ "$DO_APPSTORE" == true ]]; then appstore_extra="${APPSTORE_COUNT} update(s)"; else APPSTORE_RESULT="skipped"; appstore_extra="disabled"; fi
  if [[ "$DO_SYSTEM" == true ]]; then system_extra="${SYSTEM_COUNT} update(s)"; else SYSTEM_RESULT="skipped"; system_extra="disabled"; fi

  row "Homebrew"  "$BREW_RESULT"     "$brew_extra"
  row_items "$BREW_ITEMS"
  row "App Store" "$APPSTORE_RESULT" "$appstore_extra"
  row_items "$APPSTORE_ITEMS"
  row "macOS"     "$SYSTEM_RESULT"   "$system_extra"
  echo ""
  printf '  %sTook %dm %02ds%s\n' "$DIM" "$mins" "$secs" "$NC"
  [[ "$USE_LOG" == true && -n "$LOG_FILE" ]] && printf '  %sTranscript: %s%s\n' "$DIM" "$LOG_FILE" "$NC"

  echo ""
  if [[ "$FAILURES" -gt 0 ]]; then
    warn "${FAILURES} stage(s) had problems — scroll up for details."
  elif [[ "$DRY_RUN" == true ]]; then
    ok "Dry run complete. Re-run without --dry-run to apply."
  elif [[ "$SYSTEM_RESULT" == "staged" ]]; then
    ok "Almost there — macOS updates are staged and finish installing on restart."
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

# Post a macOS notification (with a sound) so a run you tabbed away from can
# call you back — a full update easily takes ten minutes. Only with --notify.
# osascript gets its text via argv rather than spliced into the AppleScript
# source, so nothing in the message can break (or inject into) the script.
notify_done() {
  [[ "$DO_NOTIFY" == true ]] || return 0
  if [[ "$DRY_RUN" == true ]]; then
    note "Dry run: would post a completion notification."
    return 0
  fi

  local msg
  if [[ "$FAILURES" -gt 0 ]]; then
    msg="Finished with ${FAILURES} problem(s) — check the terminal."
  elif [[ "$SYSTEM_RESULT" == "staged" ]]; then
    msg="Finished — macOS updates are staged; restart to complete them."
  else
    msg="All done — your Mac is up to date."
  fi

  osascript -e 'on run argv' \
            -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
            -e 'end run' \
            "$SELF_NAME" "$msg" >/dev/null 2>&1 \
    || warn "Couldn't post the completion notification."
}

# ═════════════════════════════════════════════════════════════════════════════
#  Banner
# ═════════════════════════════════════════════════════════════════════════════

# Print the ASCII-art splash. The heredoc is single-quoted ('EOF') so the
# backslashes in the art aren't treated as escapes; color is applied around it.
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

# Entry point. Order matters: parse flags first (they configure everything),
# set up color/logging before any output, run pre-flight, then the three stages
# (each gated by its DO_* flag), and finally the summary. Exit non-zero if any
# stage reported a failure, so callers and CI can detect trouble.
main() {
  parse_args "$@"
  setup_colors
  setup_logging

  banner
  section "Pre-flight"
  preflight

  # Pin the live status area (TTY only) now that the header is out; stages that
  # were switched off by a --skip flag show as disabled from the start.
  [[ "$DO_BREW"     == true ]] || STATUS_BREW="– disabled"
  [[ "$DO_APPSTORE" == true ]] || STATUS_APPSTORE="– disabled"
  [[ "$DO_SYSTEM"   == true ]] || STATUS_SYSTEM="– disabled"
  status_init

  if [[ "$DO_BREW" == true ]]; then
    status_set brew "running…"
    stage_homebrew
    status_finish brew "$BREW_RESULT" "$BREW_COUNT"
  fi
  if [[ "$DO_APPSTORE" == true ]]; then
    status_set appstore "running…"
    stage_appstore
    status_finish appstore "$APPSTORE_RESULT" "$APPSTORE_COUNT"
  fi
  if [[ "$DO_SYSTEM" == true ]]; then
    status_set system "running…"
    stage_system
    status_finish system "$SYSTEM_RESULT" "$SYSTEM_COUNT"
  fi

  status_close
  # Notify before the summary: print_summary can end waiting on the restart
  # prompt, and the whole point of --notify is to call back a user who tabbed
  # away — they should get pinged, not silently waited for.
  notify_done
  print_summary

  [[ "$FAILURES" -gt 0 ]] && exit 1
  exit 0
}

# Pass the script's arguments straight through to main().
main "$@"
