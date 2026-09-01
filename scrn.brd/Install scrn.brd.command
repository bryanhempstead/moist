#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────
# scrn.brd — the screenshot board. Optional add-on to MOIST.
#
# A break-off window that collects every screenshot you take while it's open,
# each with a notes field beside it, and writes the whole lot to a folder plus
# one composite image when you're done.
#
# It runs inside Hammerspoon rather than inside MOIST, because it has to see
# screenshots system-wide. This copies it in and switches it on.
# ──────────────────────────────────────────────────────────────────────────
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
INIT="$HS_DIR/init.lua"
LINE='SHOTBOARD = require("shotboard")   -- scrn.brd'

say() { printf '  %s\n' "$1"; }
bye() { printf '\n  Press return to close.'; read -r _; exit "${1:-0}"; }

printf '\n  ┌────────────────────────────────┐\n'
printf '  │   scrn.brd — installing        │\n'
printf '  └────────────────────────────────┘\n\n'

if [ ! -d "/Applications/Hammerspoon.app" ]; then
  say "Hammerspoon isn't installed yet."
  say ""
  say "scrn.brd runs inside it — it's a free, open-source tool that lets"
  say "small scripts like this one watch for screenshots. Install it, then"
  say "run this again."
  say ""
  say "Opening the download page…"
  open "https://www.hammerspoon.org/" 2>/dev/null
  bye 1
fi

mkdir -p "$HS_DIR"

say "Copying scrn.brd in…"
if ! cp "$HERE/shotboard.lua" "$HS_DIR/shotboard.lua"; then
  say "Couldn't write to $HS_DIR."
  bye 1
fi

if [ -f "$INIT" ] && grep -q 'require("shotboard")' "$INIT"; then
  say "Already switched on in your Hammerspoon config."
else
  say "Switching it on…"
  # Appended, never overwritten — anything already in init.lua stays exactly as it is.
  printf '\n-- scrn.brd (screenshot board), added by the MOIST add-on installer\n%s\n' "$LINE" >> "$INIT"
fi

say "Reloading Hammerspoon…"
open -g "hammerspoon://reload" 2>/dev/null || osascript -e 'tell application "Hammerspoon" to reload config' >/dev/null 2>&1

printf '\n'
say "Done."
say ""
say "Press ⌘⇧B to open the board, or click the ▦ in your menu bar"
say "once it's up. Take screenshots as normal and they land in it."
say ""
say "If nothing happens, open Hammerspoon and grant it Screen"
say "Recording and Accessibility in System Settings → Privacy."
bye 0
