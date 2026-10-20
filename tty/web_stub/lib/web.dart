/// Stand-in for the parts of `package:web` that Hauberk's `Storage` uses, so
/// its save code compiles unchanged for a native terminal build.
library;

import 'dart:convert';
import 'dart:io';

final window = Window._();

class Window {
  final localStorage = Storage._();
  final location = Location._();

  Window._();
}

class Location {
  /// The browser build clears saved heroes when the URL query is "?clear".
  /// There is no URL here.
  String get search => '';

  Location._();
}

/// A `localStorage` kept as one JSON object in `storage.json` in the data
/// folder, written through a temporary file so a crash never leaves it half
/// written.
class Storage {
  Map<String, String>? _items;

  Storage._();

  /// Where `storage.json` lives: `$HAUBERK_DATA_DIR` if set, otherwise
  /// `%APPDATA%\hauberk` on Windows and `$XDG_DATA_HOME/hauberk` (by default
  /// `~/.local/share/hauberk`) elsewhere.
  static String get directory {
    var env = Platform.environment;
    var override = env['HAUBERK_DATA_DIR'];
    if (override != null && override.isNotEmpty) return override;

    var sep = Platform.pathSeparator;
    if (Platform.isWindows) {
      var appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) return '$appData${sep}hauberk';
      return 'hauberk';
    }

    var xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.startsWith('/')) return '$xdg${sep}hauberk';

    var home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home$sep.local${sep}share${sep}hauberk';
    }
    return 'hauberk';
  }

  static File get _file =>
      File('$directory${Platform.pathSeparator}storage.json');

  Map<String, String> get _all {
    if (_items case var items?) return items;

    var items = <String, String>{};
    try {
      var file = _file;
      if (file.existsSync()) {
        var data = json.decode(file.readAsStringSync());
        if (data is Map) {
          data.forEach((key, value) {
            if (key is String && value is String) items[key] = value;
          });
        }
      }
    } on Object catch (error) {
      stderr.writeln('Could not read ${_file.path}: $error');
    }
    return _items = items;
  }

  String? getItem(String key) => _all[key];

  void setItem(String key, String value) {
    _all[key] = value;

    var file = _file;
    file.parent.createSync(recursive: true);
    var temp = File('${file.path}.tmp');
    temp.writeAsStringSync(json.encode(_all), flush: true);
    temp.renameSync(file.path);
  }
}
