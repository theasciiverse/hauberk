#!/bin/sh
# Records hauberk.cast, the catalog preview (hub/RECORDING.md): the game's
# own --demo autopilot playing a fresh hero at 100x30, headless.
#
# Usage: asciiverse/record-preview.sh <hauberk binary> [seed] [out.cast]
#
# Hauberk wants 80x40 for its menus, but the game screen fits 100x30, and
# --demo goes straight into the game, so HAUBERK_ANY_SIZE=1 lifts the
# minimum. The program runs by name from a throwaway folder, with a
# throwaway home and data folder and a clean environment, so nothing of
# this machine ends up in the cast. Needs asciinema 3.
set -eu

binary=$1
seed=${2:-1}
out=${3:-hauberk.cast}

asciinema=$(command -v asciinema)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home"
cp "$binary" "$work/bin/hauberk"

env -i \
  HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" \
  TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 \
  USER=player LOGNAME=player \
  HAUBERK_DATA_DIR="$work/home/data" HAUBERK_ANY_SIZE=1 \
  "$asciinema" rec --headless --overwrite \
    --window-size 100x30 \
    --idle-time-limit 2 \
    --capture-env "TERM,COLORTERM,LANG" \
    --title "Hauberk" \
    --command "hauberk --demo --seed $seed --quit-after 55" \
    "$out"
