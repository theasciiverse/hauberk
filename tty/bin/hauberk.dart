import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hauberk/src/content.dart';
import 'package:hauberk/src/engine.dart';
import 'package:hauberk/src/ui/game/game_screen.dart';
import 'package:hauberk/src/ui/input.dart';
import 'package:hauberk/src/ui/menu/main_menu_screen.dart';
import 'package:hauberk_tty/src/ansi_terminal.dart';
import 'package:hauberk_tty/src/autopilot.dart';
import 'package:hauberk_tty/src/keys.dart';
import 'package:hauberk_tty/src/windows_console.dart';
import 'package:malison/malison.dart';
import 'package:malison/malison_web.dart';
import 'package:piecemeal/piecemeal.dart';

/// Where log lines go when `HAUBERK_LOG` names a file; nowhere otherwise, since
/// stdout and stderr are the game screen.
IOSink? _log;

/// The smallest terminal Hauberk's screens are laid out for; its browser
/// build insists on the same.
const _minWidth = 80;
const _minHeight = 40;

late final Content _content;
UserInterface<Input>? _ui;
AnsiTerminal? _terminal;

/// Whether the terminal is below the minimum size and the "too small" message
/// is showing. The game waits until the terminal is big enough.
bool _tooSmall = false;

WindowsConsole? _windowsConsole;

/// `--hero NAME`: go straight into the town with this saved hero.
String? _heroName;

/// `--demo`: a new hero, played by the [Autopilot].
bool _demo = false;

/// `--quit-after SECONDS`: end the program by itself, for recordings.
Duration? _quitAfter;
Autopilot? _autopilot;

const _usage = '''Usage: hauberk [options]

  --hero NAME   start in the town with the saved hero NAME
  --demo        create a hero and watch the computer play
  --seed N      seed the random numbers, for a repeatable game
  --quit-after SECONDS
                quit by itself after this long, for recordings
  --version     print the version and exit

Heroes are saved in storage.json in \$HAUBERK_DATA_DIR, %APPDATA%\\hauberk
on Windows, or \$XDG_DATA_HOME/hauberk (~/.local/share/hauberk).
HAUBERK_LOG=FILE writes key presses and messages to FILE.''';
Timer? _timer;
bool _done = false;

void main(List<String> arguments) {
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--version':
        stdout.writeln('hauberk (terminal build)');
        return;
      case '--help' || '-h':
        stdout.writeln(_usage);
        return;
      case '--demo':
        _demo = true;
      case '--hero' when i + 1 < arguments.length:
        _heroName = arguments[++i];
      case '--quit-after' when i + 1 < arguments.length:
        var seconds = double.tryParse(arguments[++i]);
        if (seconds == null || seconds <= 0) {
          stderr.writeln('--quit-after needs a number of seconds.');
          exitCode = 2;
          return;
        }
        _quitAfter = Duration(milliseconds: (seconds * 1000).round());
      case '--seed' when i + 1 < arguments.length:
        var seed = int.tryParse(arguments[++i]);
        if (seed == null) {
          stderr.writeln('--seed needs a number.');
          exitCode = 2;
          return;
        }
        rng.setSeed(seed);
      default:
        stderr.writeln('Unknown option ${arguments[i]}.\n\n$_usage');
        exitCode = 2;
        return;
    }
  }

  if (!stdin.hasTerminal || !stdout.hasTerminal) {
    stderr.writeln('Hauberk needs to run in a terminal.');
    exitCode = 1;
    return;
  }

  var logPath = Platform.environment['HAUBERK_LOG'];
  if (logPath != null && logPath.isNotEmpty) {
    _log = File(logPath).openWrite(mode: FileMode.append);
  }

  // Hauberk prints notes such as "Saved." to the browser console; keep them
  // off the screen.
  runZonedGuarded(
    _run,
    (error, stack) {
      _restoreTerminal();
      stderr.writeln('Hauberk crashed: $error\n$stack');
      _log?.writeln('crash: $error\n$stack');
      _log?.flush().whenComplete(() => exit(70));
      if (_log == null) exit(70);
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => _log?.writeln(line),
    ),
  );
}

void _run() {
  stdout.encoding = utf8;
  stdin.echoMode = false;
  stdin.lineMode = false;
  if (Platform.isWindows) _windowsConsole = WindowsConsole()..enable();

  // Alternate screen, hidden cursor, application keypad, cleared screen.
  stdout.write('\x1b[?1049h\x1b[?25l\x1b=\x1b[0m\x1b[2J');

  _content = createContent();

  // A closed terminal ends the game like Ctrl+C.
  stdin.listen(_input, onDone: _quit, onError: (Object _) => _quit());

  // Ctrl+C arrives as a signal, since Dart leaves signals on in raw mode.
  ProcessSignal.sigint.watch().listen((_) => _quit());
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => _quit());
    ProcessSignal.sighup.watch().listen((_) => _quit());
  }

  if (_quitAfter case var after?) Timer(after, _quit);

  _timer = Timer.periodic(
    const Duration(microseconds: 1000000 ~/ 60),
    (_) => _tick(),
  );
  _tick();
}

/// Starts the user interface on the first terminal that is big enough.
void _start() {
  var ui = UserInterface<Input>(_makeTerminal());
  _ui = ui;
  _bindKeys(ui);

  var menu = MainMenuScreen(_content);
  ui.push(menu);
  ui.handlingInput = true;
  ui.running = true;

  if (_demo) {
    var save = _content.createHero(
      _demoName(menu.storage.heroes.map((hero) => hero.name).toSet()),
      race: _content.races.firstWhere((race) => race.name == 'Dwarf'),
      heroClass: _content.classes.firstWhere(
        (heroClass) => heroClass.name == 'Barbarian',
      ),
    );
    menu.storage.add(save);
    ui.push(GameScreen.town(menu.storage, _content, save, newHero: true));
    _autopilot = Autopilot(ui, (line) => _log?.writeln(line));
  } else if (_heroName case var name?) {
    for (var save in menu.storage.heroes) {
      if (save.name == name) {
        ui.push(GameScreen.town(menu.storage, _content, save));
        break;
      }
    }
  }
}

/// A name for the demo hero that no saved hero has.
String _demoName(Set<String> taken) {
  var name = 'Brannoc';
  for (var i = 2; taken.contains(name); i++) {
    name = 'Brannoc $i';
  }
  return name;
}

/// Shows how big the terminal needs to be, centred.
void _showTooSmall(int width, int height) {
  var lines = [
    'Hauberk needs a terminal of at least ${_minWidth}x$_minHeight.',
    'This one is ${width}x$height. Make the window bigger',
    'or the font smaller, or press Ctrl+C to quit.',
  ];

  var buffer = StringBuffer('\x1b[0m\x1b[2J');
  var top = (height - lines.length) ~/ 2;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.length > width) line = line.substring(0, width);
    var x = (width - line.length) ~/ 2;
    buffer.write('\x1b[${top + i + 1};${x + 1}H$line');
  }
  stdout.write(buffer.toString());
  _log?.writeln('too small: ${width}x$height');
}

AnsiTerminal _makeTerminal() {
  var terminal = AnsiTerminal(
    stdout.terminalColumns,
    stdout.terminalLines,
    stdout,
  );
  _terminal = terminal;
  _log?.writeln('terminal ${terminal.width}x${terminal.height}');
  return terminal;
}

void _tick() {
  if (_done) return;

  var width = stdout.terminalColumns;
  var height = stdout.terminalLines;

  // HAUBERK_ANY_SIZE=1 lifts the minimum, for recording the game screen,
  // which fits smaller terminals; the menus are then cut off.
  var anySize = Platform.environment['HAUBERK_ANY_SIZE'] == '1';
  if (!anySize && (width < _minWidth || height < _minHeight)) {
    if (!_tooSmall ||
        width != _terminal?.width ||
        height != _terminal?.height) {
      _tooSmall = true;
      // Remember the size so the message is redrawn only when it changes.
      _terminal = AnsiTerminal(width, height, stdout);
      _showTooSmall(width, height);
    }
    return;
  }

  var ui = _ui;
  if (ui == null) {
    stdout.write('\x1b[0m\x1b[2J');
    _tooSmall = false;
    _start();
    return;
  }

  if (_tooSmall || width != _terminal!.width || height != _terminal!.height) {
    _tooSmall = false;
    stdout.write('\x1b[0m\x1b[2J');
    ui.setTerminal(_makeTerminal());
  }

  _autopilot?.tick();
  ui.refresh();
}

void _input(List<int> bytes) {
  for (var key in decodeKeys(bytes)) {
    if (_done) return;
    _log?.writeln('key $key');

    if (key.keyCode == ctrlC) {
      _quit();
      return;
    }

    // Keys wait with the game while the terminal is too small.
    var ui = _ui;
    if (ui == null || _tooSmall) continue;

    // The browser game never quits; here q or Escape on the main menu does.
    if (ui.topScreen is MainMenuScreen &&
        !key.shift &&
        !key.alt &&
        (key.keyCode == KeyCode.q || key.keyCode == KeyCode.escape)) {
      _quit();
      return;
    }

    // A terminal sends no key releases and cannot report Shift held on its
    // own. Hauberk's item screens inspect items while Shift is held, so press
    // and release it around every shifted key.
    if (key.shift) ui.keyDown(KeyCode.shift, shift: true, alt: key.alt);
    ui.keyDown(key.keyCode, shift: key.shift, alt: key.alt);
    ui.keyUp(key.keyCode, shift: key.shift, alt: key.alt);
    if (key.shift) ui.keyUp(KeyCode.shift, alt: key.alt);
  }

  // Draw the result now rather than on the next tick.
  if (!_tooSmall) _ui?.refresh();
}

void _quit() {
  if (_done) return;
  _done = true;
  _timer?.cancel();
  _restoreTerminal();
  _log?.writeln('quit');
  var log = _log;
  if (log == null) exit(0);
  log.flush().whenComplete(() => exit(0));
}

void _restoreTerminal() {
  stdout.write('\x1b[0m\x1b>\x1b[?25h\x1b[?1049l');
  try {
    stdin.lineMode = true;
    stdin.echoMode = true;
    _windowsConsole?.restore();
  } on Object {
    // The terminal may already be gone.
  }
}

/// Hauberk's key bindings, as in its browser entry point `web/main.dart`, plus
/// the number keys as the keypad, since a keypad with Num Lock on sends them.
void _bindKeys(UserInterface<Input> ui) {
  ui.keyPress.bind(Input.ok, KeyCode.enter);
  ui.keyPress.bind(Input.cancel, KeyCode.escape);
  ui.keyPress.bind(Input.cancel, KeyCode.backtick);
  ui.keyPress.bind(Input.forfeit, KeyCode.f, shift: true);
  ui.keyPress.bind(Input.quit, KeyCode.q);

  ui.keyPress.bind(Input.operate, KeyCode.c); // TODO: Better key?
  ui.keyPress.bind(Input.drop, KeyCode.d);
  ui.keyPress.bind(Input.use, KeyCode.u);
  ui.keyPress.bind(Input.pickUp, KeyCode.g);
  ui.keyPress.bind(Input.swap, KeyCode.x);
  ui.keyPress.bind(Input.equip, KeyCode.e);
  ui.keyPress.bind(Input.toss, KeyCode.t);
  ui.keyPress.bind(Input.useAbility, KeyCode.a);
  ui.keyPress.bind(Input.castSpell, KeyCode.s);
  ui.keyPress.bind(Input.heroInfo, KeyCode.a, shift: true);
  // TODO: Better key.
  ui.keyPress.bind(Input.editSpells, KeyCode.s, shift: true);
  ui.keyPress.bind(Input.spendExperience, KeyCode.e, shift: true);
  ui.keyPress.bind(Input.help, KeyCode.h);

  // Laptop directions.
  ui.keyPress.bind(Input.nw, KeyCode.i);
  ui.keyPress.bind(Input.n, KeyCode.o);
  ui.keyPress.bind(Input.ne, KeyCode.p);
  ui.keyPress.bind(Input.w, KeyCode.k);
  ui.keyPress.bind(Input.e, KeyCode.semicolon);
  ui.keyPress.bind(Input.sw, KeyCode.comma);
  ui.keyPress.bind(Input.s, KeyCode.period);
  ui.keyPress.bind(Input.se, KeyCode.slash);
  ui.keyPress.bind(Input.runNW, KeyCode.i, shift: true);
  ui.keyPress.bind(Input.runN, KeyCode.o, shift: true);
  ui.keyPress.bind(Input.runNE, KeyCode.p, shift: true);
  ui.keyPress.bind(Input.runW, KeyCode.k, shift: true);
  ui.keyPress.bind(Input.runE, KeyCode.semicolon, shift: true);
  ui.keyPress.bind(Input.runSW, KeyCode.comma, shift: true);
  ui.keyPress.bind(Input.runS, KeyCode.period, shift: true);
  ui.keyPress.bind(Input.runSE, KeyCode.slash, shift: true);
  ui.keyPress.bind(Input.fireNW, KeyCode.i, alt: true);
  ui.keyPress.bind(Input.fireN, KeyCode.o, alt: true);
  ui.keyPress.bind(Input.fireNE, KeyCode.p, alt: true);
  ui.keyPress.bind(Input.fireW, KeyCode.k, alt: true);
  ui.keyPress.bind(Input.fireE, KeyCode.semicolon, alt: true);
  ui.keyPress.bind(Input.fireSW, KeyCode.comma, alt: true);
  ui.keyPress.bind(Input.fireS, KeyCode.period, alt: true);
  ui.keyPress.bind(Input.fireSE, KeyCode.slash, alt: true);

  ui.keyPress.bind(Input.ok, KeyCode.l);
  ui.keyPress.bind(Input.rest, KeyCode.l, shift: true);
  ui.keyPress.bind(Input.fire, KeyCode.l, alt: true);

  // Arrow keys.
  ui.keyPress.bind(Input.n, KeyCode.up);
  ui.keyPress.bind(Input.w, KeyCode.left);
  ui.keyPress.bind(Input.e, KeyCode.right);
  ui.keyPress.bind(Input.s, KeyCode.down);
  ui.keyPress.bind(Input.runN, KeyCode.up, shift: true);
  ui.keyPress.bind(Input.runW, KeyCode.left, shift: true);
  ui.keyPress.bind(Input.runE, KeyCode.right, shift: true);
  ui.keyPress.bind(Input.runS, KeyCode.down, shift: true);
  ui.keyPress.bind(Input.fireN, KeyCode.up, alt: true);
  ui.keyPress.bind(Input.fireW, KeyCode.left, alt: true);
  ui.keyPress.bind(Input.fireE, KeyCode.right, alt: true);
  ui.keyPress.bind(Input.fireS, KeyCode.down, alt: true);

  // Numeric keypad.
  ui.keyPress.bind(Input.nw, KeyCode.numpad7);
  ui.keyPress.bind(Input.n, KeyCode.numpad8);
  ui.keyPress.bind(Input.ne, KeyCode.numpad9);
  ui.keyPress.bind(Input.w, KeyCode.numpad4);
  ui.keyPress.bind(Input.e, KeyCode.numpad6);
  ui.keyPress.bind(Input.sw, KeyCode.numpad1);
  ui.keyPress.bind(Input.s, KeyCode.numpad2);
  ui.keyPress.bind(Input.se, KeyCode.numpad3);
  ui.keyPress.bind(Input.runNW, KeyCode.numpad7, shift: true);
  ui.keyPress.bind(Input.runN, KeyCode.numpad8, shift: true);
  ui.keyPress.bind(Input.runNE, KeyCode.numpad9, shift: true);
  ui.keyPress.bind(Input.runW, KeyCode.numpad4, shift: true);
  ui.keyPress.bind(Input.runE, KeyCode.numpad6, shift: true);
  ui.keyPress.bind(Input.runSW, KeyCode.numpad1, shift: true);
  ui.keyPress.bind(Input.runS, KeyCode.numpad2, shift: true);
  ui.keyPress.bind(Input.runSE, KeyCode.numpad3, shift: true);

  ui.keyPress.bind(Input.ok, KeyCode.numpad5);
  ui.keyPress.bind(Input.ok, KeyCode.numpadEnter);
  ui.keyPress.bind(Input.rest, KeyCode.numpad5, shift: true);
  ui.keyPress.bind(Input.rest, KeyCode.numpadEnter, shift: true);
  ui.keyPress.bind(Input.fire, KeyCode.numpad5, alt: true);

  ui.keyPress.bind(Input.wizard, KeyCode.w, shift: true, alt: true);

  // The keypad with Num Lock on types digits.
  ui.keyPress.bind(Input.nw, KeyCode.seven);
  ui.keyPress.bind(Input.n, KeyCode.eight);
  ui.keyPress.bind(Input.ne, KeyCode.nine);
  ui.keyPress.bind(Input.w, KeyCode.four);
  ui.keyPress.bind(Input.e, KeyCode.six);
  ui.keyPress.bind(Input.sw, KeyCode.one);
  ui.keyPress.bind(Input.s, KeyCode.two);
  ui.keyPress.bind(Input.se, KeyCode.three);
  ui.keyPress.bind(Input.ok, KeyCode.five);
}
