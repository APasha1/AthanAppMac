#!/bin/bash
# Prayer Island installer: builds the app from source and puts it in /Applications.
#   curl -fsSL https://raw.githubusercontent.com/APasha1/PrayerIsland/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/APasha1/PrayerIsland/main/install.sh | bash -s -- --uninstall
set -euo pipefail

REPO="${PRAYER_ISLAND_REPO:-https://github.com/APasha1/PrayerIsland.git}"
SRC="${PRAYER_ISLAND_SRC:-$HOME/.prayer-island}"
APP_NAME="Prayer Island.app"

say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
    say "Removing Prayer Island"
    pkill -x PrayerIsland 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME" "$SRC"
    defaults delete com.abdullahpasha.prayerisland 2>/dev/null || true
    say "Done. (You can also remove it from System Settings → General → Login Items.)"
    exit 0
fi

[[ "$(uname)" == "Darwin" ]] || die "Prayer Island is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || die "Prayer Island needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."
if ! xcrun --find swift >/dev/null 2>&1; then
    say "Installing Apple's Command Line Tools (needed to build the app)…"
    xcode-select --install 2>/dev/null || true
    die "Finish the Command Line Tools install in the window that opened, then run this installer again."
fi
command -v git >/dev/null || die "git is missing. Install the Command Line Tools with: xcode-select --install"

if [[ -d "$SRC/.git" ]]; then
    say "Updating source in $SRC"
    git -C "$SRC" pull --ff-only --quiet
else
    say "Downloading source to $SRC"
    git clone --depth 1 --quiet "$REPO" "$SRC"
fi

say "Building (takes about a minute the first time)"
"$SRC/build.sh"

DEST="/Applications/$APP_NAME"
[[ -d "$DEST" ]] || DEST="$HOME/Applications/$APP_NAME"
say "Opening Prayer Island"
open "$DEST"
cat <<MSG

  Prayer Island is installed and running — look at your notch.
  • Allow Location (or set a city in Settings) so it can work out your prayer times.
  • Allow Calendar if you want it to stay quiet during meetings.
  • The moon icon in the menu bar has Settings, Pause and Quit.

  Update later by running the same command again.
MSG
