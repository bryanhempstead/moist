#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────
# MOIST installer.
#
# One double-click: copies MOIST into your Applications folder, clears the
# macOS download flag that would otherwise refuse to open it, and launches it.
#
# The flag is the only reason this file exists. macOS quarantines anything
# downloaded that isn't signed with a paid Apple developer certificate and then
# claims the app is "damaged". It isn't. This clears that, and nothing else on
# your Mac is touched.
# ──────────────────────────────────────────────────────────────────────────
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/MOIST.app"
DEST="/Applications/MOIST.app"

say() { printf '  %s\n' "$1"; }
bye() { printf '\n  Press return to close.'; read -r _; exit "${1:-0}"; }

printf '\n  ┌────────────────────────────────┐\n'
printf '  │   MOIST — installing           │\n'
printf '  └────────────────────────────────┘\n\n'

if [ ! -d "$SRC" ]; then
  say "Couldn't find MOIST.app next to this installer."
  say ""
  say "Open the MOIST disk image and run this file from inside it,"
  say "rather than copying the installer somewhere on its own."
  bye 1
fi

if [ -d "$DEST" ]; then
  say "Replacing the copy already in Applications…"
  osascript -e 'quit app "MOIST"' >/dev/null 2>&1
  sleep 1
  rm -rf "$DEST" 2>/dev/null
  if [ -d "$DEST" ]; then
    say "Couldn't replace it — it may be running, or need your password."
    say "Quit MOIST and try again."
    bye 1
  fi
fi

say "Copying into Applications…"
if ! ditto "$SRC" "$DEST"; then
  say "The copy failed. If your Applications folder is locked down,"
  say "drag MOIST across by hand and run this again."
  bye 1
fi

say "Clearing the download flag…"
xattr -cr "$DEST" 2>/dev/null

say "Opening MOIST…"
open "$DEST" 2>/dev/null

printf '\n'
say "Done — MOIST is in your Applications folder and starting up."
say ""
say "It will ask you two things (your name, and where your photos"
say "live) and then walk you through anything you want to connect."
say "Nothing is filled in for you: it runs on your machine, with"
say "your folders and your accounts."
say ""
say "You never need to run this installer again. Updates install"
say "themselves."
bye 0
