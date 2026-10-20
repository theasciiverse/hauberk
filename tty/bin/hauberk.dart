import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hauberk/src/content.dart';
import 'package:hauberk/src/ui/input.dart';
import 'package:hauberk/src/ui/menu/main_menu_screen.dart';
import 'package:hauberk_tty/src/ansi_terminal.dart';
import 'package:hauberk_tty/src/keys.dart';
import 'package:malison/malison.dart';
import 'package:malison/malison_web.dart';

/// Where log lines go when `HAUBERK_LOG` names a file; nowhere otherwise, since
/// stdout and stderr are the game screen.
IOSink? _log;

late final UserInterface<Input> _ui;
AnsiTerminal? _terminal;
Timer? _timer;
bool _done = false;

void main(List<String> arguments) {
  if (arguments.contains('--version')) {
    stdout.writeln('hauberk (terminal build)');
    return;
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

  // Alternate screen, hidden cursor, application keypad, cleared screen.
  stdout.write('\x1b[?1049h\x1b[?25l\x1b=\x1b[0m\x1b[2J');

  var content = createContent();
  _ui = UserInterface<Input>(_makeTerminal());
  _bindKeys(_ui);

  _ui.push(MainMenuScreen(content));
  _ui.handlingInput = true;
  _ui.running = true;

  stdin.listen(_input, onDone: _quit);

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => _quit());
    ProcessSignal.sighup.watch().listen((_) => _quit());
  }

  _timer = Timer.periodic(
    Duration(microseconds: 1000000 ~/ _ui.framesPerSecond),
    (_) => _tick(),
  );
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

  var terminal = _terminal!;
  if (stdout.terminalColumns != terminal.width ||
      stdout.terminalLines != terminal.height) {
    stdout.write('\x1b[0m\x1b[2J');
    _ui.setTerminal(_makeTerminal());
  }

  _ui.refresh();
}

void _input(List<int> bytes) {
  for (var key in decodeKeys(bytes)) {
    if (_done) return;
    _log?.writeln('key $key');

    if (key.keyCode == ctrlC) {
      _quit();
      return;
    }

    // The browser game never quits; here q or Escape on the main menu does.
    if (_ui.topScreen is MainMenuScreen &&
        !key.shift &&
        !key.alt &&
        (key.keyCode == KeyCode.q || key.keyCode == KeyCode.escape)) {
      _quit();
      return;
    }

    // A terminal sends no key releases and cannot report Shift held on its
    // own. Hauberk's item screens inspect items while Shift is held, so press
    // and release it around every shifted key.
    if (key.shift) _ui.keyDown(KeyCode.shift, shift: true, alt: key.alt);
    _ui.keyDown(key.keyCode, shift: key.shift, alt: key.alt);
    _ui.keyUp(key.keyCode, shift: key.shift, alt: key.alt);
    if (key.shift) _ui.keyUp(KeyCode.shift, alt: key.alt);
  }

  // Draw the result now rather than on the next tick.
  _ui.refresh();
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
