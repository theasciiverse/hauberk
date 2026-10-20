/// Writes the licence of everything compiled into the binary to one file:
/// the Dart runtime and every package in `.dart_tool/package_config.json`.
///
/// Usage: dart run tool/licenses.dart <output file>
library;

import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  var buffer = StringBuffer(
    'Licences of the software compiled into this build of Hauberk.\n',
  );

  // The SDK's LICENSE covers the Dart runtime in the executable.
  var sdk = File(Platform.resolvedExecutable).parent.parent;
  _add(buffer, 'Dart runtime ${Platform.version.split(' ').first}', [
    File('${sdk.path}/LICENSE'),
  ]);

  var configFile = File('.dart_tool/package_config.json');
  var config = json.decode(configFile.readAsStringSync()) as Map;
  for (var package in config['packages'] as List) {
    var name = package['name'] as String;
    // Our own code, under Hauberk's licence.
    if (name == 'hauberk_tty' || name == 'web') continue;

    var root = configFile.parent.uri.resolve(package['rootUri'] as String);
    var directory = Directory.fromUri(root);
    _add(buffer, name, [
      for (var file in const ['LICENSE', 'COPYRIGHT'])
        File('${directory.path}/$file'),
    ]);
  }

  File(arguments.single).writeAsStringSync(buffer.toString());
}

void _add(StringBuffer buffer, String name, List<File> candidates) {
  for (var file in candidates) {
    if (!file.existsSync()) continue;
    buffer.write('\n${'=' * 72}\n$name\n${'=' * 72}\n\n');
    buffer.write(file.readAsStringSync().trimRight());
    buffer.write('\n');
    return;
  }
  throw StateError('No licence found for $name.');
}
