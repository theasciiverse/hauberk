import 'package:malison/malison.dart';

/// A key press read from the terminal, as the browser's key code and
/// modifiers that Hauberk's screens expect.
class KeyPress {
  final int keyCode;
  final bool shift;
  final bool alt;

  const KeyPress(this.keyCode, {this.shift = false, this.alt = false});

  KeyPress withAlt() => KeyPress(keyCode, shift: shift, alt: true);

  @override
  String toString() =>
      'KeyPress($keyCode${shift ? ' shift' : ''}${alt ? ' alt' : ''})';
}

/// Ctrl+C, which the terminal sends as a byte because the terminal is raw.
const ctrlC = -1;

/// Turns bytes from a raw terminal into [KeyPress]es.
///
/// Escape sequences are expected to arrive whole in one read, which is how
/// terminals send them; an escape byte at the end of a read is the Escape key.
List<KeyPress> decodeKeys(List<int> bytes) {
  var keys = <KeyPress>[];
  var i = 0;

  while (i < bytes.length) {
    var byte = bytes[i];

    if (byte != 0x1b) {
      var key = _byteKey(byte);
      if (key != null) keys.add(key);
      i++;
      // Skip the rest of a UTF-8 character; Hauberk only takes ASCII.
      if (byte >= 0xc0) {
        while (i < bytes.length && bytes[i] & 0xc0 == 0x80) {
          i++;
        }
      }
      continue;
    }

    // Escape on its own.
    if (i + 1 >= bytes.length) {
      keys.add(const KeyPress(KeyCode.escape));
      i++;
      continue;
    }

    var next = bytes[i + 1];
    if (next == 0x5b /* [ */ ) {
      // CSI: parameters, then a final byte from 0x40 to 0x7e.
      var end = i + 2;
      while (end < bytes.length && (bytes[end] < 0x40 || bytes[end] > 0x7e)) {
        end++;
      }
      if (end >= bytes.length) break;

      var params = String.fromCharCodes(bytes.sublist(i + 2, end));
      var key = _csiKey(params, bytes[end]);
      if (key != null) keys.add(key);
      i = end + 1;
    } else if (next == 0x4f /* O */ && i + 2 < bytes.length) {
      var key = _ss3Key(bytes[i + 2]);
      if (key != null) keys.add(key);
      i += 3;
    } else if (next == 0x1b) {
      keys.add(const KeyPress(KeyCode.escape));
      i++;
    } else {
      // Escape followed by a key is that key with Alt.
      var key = _byteKey(next);
      if (key != null) keys.add(key.withAlt());
      i += 2;
    }
  }

  return keys;
}

KeyPress? _byteKey(int byte) {
  switch (byte) {
    case 3:
      return const KeyPress(ctrlC);
    case 8 || 0x7f:
      return const KeyPress(KeyCode.delete);
    case 9:
      return const KeyPress(KeyCode.tab);
    case 10 || 13:
      return const KeyPress(KeyCode.enter);
    case 0x20:
      return const KeyPress(KeyCode.space);
  }

  // Letters: the browser reports the upper case code, with Shift for capitals.
  if (byte >= 0x61 && byte <= 0x7a) return KeyPress(byte - 0x20);
  if (byte >= 0x41 && byte <= 0x5a) return KeyPress(byte, shift: true);
  if (byte >= 0x30 && byte <= 0x39) return KeyPress(byte);

  // Punctuation on a US layout, which is what the browser's key codes assume.
  return switch (String.fromCharCode(byte)) {
    ';' => const KeyPress(KeyCode.semicolon),
    ':' => const KeyPress(KeyCode.semicolon, shift: true),
    '=' => const KeyPress(KeyCode.equals),
    '+' => const KeyPress(KeyCode.equals, shift: true),
    ',' => const KeyPress(KeyCode.comma),
    '<' => const KeyPress(KeyCode.comma, shift: true),
    '-' => const KeyPress(KeyCode.hyphen),
    '_' => const KeyPress(KeyCode.hyphen, shift: true),
    '.' => const KeyPress(KeyCode.period),
    '>' => const KeyPress(KeyCode.period, shift: true),
    '/' => const KeyPress(KeyCode.slash),
    '?' => const KeyPress(KeyCode.slash, shift: true),
    '`' => const KeyPress(KeyCode.backtick),
    '~' => const KeyPress(KeyCode.backtick, shift: true),
    '[' => const KeyPress(KeyCode.leftBracket),
    '{' => const KeyPress(KeyCode.leftBracket, shift: true),
    '\\' => const KeyPress(KeyCode.backslash),
    '|' => const KeyPress(KeyCode.backslash, shift: true),
    ']' => const KeyPress(KeyCode.rightBracket),
    '}' => const KeyPress(KeyCode.rightBracket, shift: true),
    "'" => const KeyPress(KeyCode.apostrophe),
    '"' => const KeyPress(KeyCode.apostrophe, shift: true),
    '!' => const KeyPress(KeyCode.one, shift: true),
    '@' => const KeyPress(KeyCode.two, shift: true),
    '#' => const KeyPress(KeyCode.three, shift: true),
    r'$' => const KeyPress(KeyCode.four, shift: true),
    '%' => const KeyPress(KeyCode.five, shift: true),
    '^' => const KeyPress(KeyCode.six, shift: true),
    '&' => const KeyPress(KeyCode.seven, shift: true),
    '*' => const KeyPress(KeyCode.eight, shift: true),
    '(' => const KeyPress(KeyCode.nine, shift: true),
    ')' => const KeyPress(KeyCode.zero, shift: true),
    _ => null,
  };
}

/// Cursor and editing keys: `ESC [ ... final`.
KeyPress? _csiKey(String params, int finalByte) {
  var parts = params.split(';');

  // xterm modifiers: the last parameter is 1 + (shift 1, alt 2, ctrl 4).
  var modifiers = 0;
  if (parts.length >= 2) modifiers = (int.tryParse(parts[1]) ?? 1) - 1;
  var shift = modifiers & 1 != 0;
  var alt = modifiers & 2 != 0;

  int? keyCode = switch (String.fromCharCode(finalByte)) {
    'A' => KeyCode.up,
    'B' => KeyCode.down,
    'C' => KeyCode.right,
    'D' => KeyCode.left,
    // The keypad with Num Lock off: Home, End and the centre key.
    'H' => KeyCode.numpad7,
    'F' => KeyCode.numpad1,
    'E' || 'G' => KeyCode.numpad5,
    'Z' => KeyCode.tab,
    '~' => switch (parts[0]) {
      '1' || '7' => KeyCode.numpad7,
      '4' || '8' => KeyCode.numpad1,
      '5' => KeyCode.numpad9,
      '6' => KeyCode.numpad3,
      '3' => KeyCode.delete,
      _ => null,
    },
    _ => null,
  };

  if (keyCode == null) return null;
  // Shift+Tab.
  if (finalByte == 0x5a) shift = true;
  return KeyPress(keyCode, shift: shift, alt: alt);
}

/// `ESC O x`: cursor keys in application mode, F1 to F4 and the keypad in
/// application keypad mode.
KeyPress? _ss3Key(int byte) {
  if (byte >= 0x70 && byte <= 0x79)
    return KeyPress(KeyCode.numpad0 + byte - 0x70);

  return switch (String.fromCharCode(byte)) {
    'A' => const KeyPress(KeyCode.up),
    'B' => const KeyPress(KeyCode.down),
    'C' => const KeyPress(KeyCode.right),
    'D' => const KeyPress(KeyCode.left),
    'H' => const KeyPress(KeyCode.numpad7),
    'F' => const KeyPress(KeyCode.numpad1),
    'E' => const KeyPress(KeyCode.numpad5),
    'M' => const KeyPress(KeyCode.numpadEnter),
    _ => null,
  };
}
