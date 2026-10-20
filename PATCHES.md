# Changes in this fork

Hauberk is Bob Nystrom's browser roguelike (github.com/munificent/hauberk,
MIT). This fork adds a build that runs in a text terminal, for the
Asciiverse catalog. It is based on upstream master and follows it: no file
of Hauberk's is changed, so upstream merges in cleanly.

Everything new is in `tty/`, a Dart package of its own:

- `tty/malison/`: malison 0.14.0 (Nystrom, MIT), imported unchanged, then
  adapted: the canvas terminals and their fonts are removed, and the
  screen stack takes key presses and frames from its host instead of the
  browser.
- `tty/web_stub/`: a stand-in for `package:web` with only what Hauberk's
  save code uses. `localStorage` is kept as `storage.json` in the
  player's data folder: `$HAUBERK_DATA_DIR` if set, `%APPDATA%\hauberk`
  on Windows, `$XDG_DATA_HOME/hauberk` (`~/.local/share/hauberk`)
  elsewhere.
- `tty/lib/`: a renderer that draws in 24-bit colour and sends only the
  cells that changed, a decoder from terminal key sequences to the
  browser's key codes, and on Windows, the console switched to escape
  codes and UTF-8.
- `tty/bin/hauberk.dart`: the program. Key bindings as in Hauberk's
  `web/main.dart`, plus the number keys as the keypad (a keypad with Num
  Lock on types them). A terminal reports no held Shift, so Shift is
  pressed and released around every shifted key; capitals inspect items
  as holding Shift does in the browser. q or Escape on the main menu, or
  Ctrl+C, quit. Below 80x40, the browser build's minimum, the game waits
  behind a message until the terminal is bigger. Hauberk's console prints
  go to the file named by `HAUBERK_LOG`, if any.
- Options: `--hero NAME` starts in the town with a saved hero; `--demo`
  creates a hero and lets an autopilot (`tty/lib/src/autopilot.dart`) play,
  handing the screens the same inputs the keys do; `--seed N` repeats a
  game; `--quit-after SECONDS` ends the program by itself, for recordings.
  `HAUBERK_ANY_SIZE=1` lifts the 80x40 minimum (for recording the game
  screen at 100x30; the menus are then cut off).
- On Windows the console is switched to escape codes in both directions
  and to UTF-8 output, and put back on exit. Dart reports these modes but
  does not set them.

Build: `cd tty && dart pub get && dart compile exe bin/hauberk.dart -o
build/hauberk`.

`.github/workflows/release.yml` builds the catalog archives, with
`tty/tool/licenses.dart` gathering the licences of everything compiled in
(the Dart runtime and each package) into THIRD-PARTY-LICENSES.txt.
`asciiverse/record-preview.sh` records `asciiverse/hauberk.cast`, the
catalog preview: `--demo` at 100x30, seed 1, 55 seconds.
