import 'dart:io';

import 'package:malison/malison.dart';
import 'package:piecemeal/piecemeal.dart';

/// A [RenderableTerminal] that draws to a text terminal with 24-bit colour
/// escape codes.
///
/// It keeps what was last sent to the screen and writes only the cells that
/// changed, in a single write per frame.
class AnsiTerminal extends RenderableTerminal {
  @override
  final int width;

  @override
  final int height;

  /// The glyphs drawn since the last render.
  final List<Glyph> _glyphs;

  /// What the screen shows, or null where it is unknown (so it gets drawn).
  final List<Glyph?> _shown;

  final IOSink _out;

  AnsiTerminal(this.width, this.height, this._out)
    : _glyphs = List.filled(width * height, Glyph.clear),
      _shown = List.filled(width * height, null);

  @override
  Vec get size => Vec(width, height);

  @override
  void drawGlyph(int x, int y, Glyph glyph) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    _glyphs[y * width + x] = glyph;
  }

  /// Forgets what the screen shows, so the next render draws every cell.
  void invalidate() {
    _shown.fillRange(0, _shown.length, null);
  }

  @override
  void render() {
    var buffer = StringBuffer();
    Color? fore;
    Color? back;
    var cursorX = -1;
    var cursorY = -1;

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var i = y * width + x;
        var glyph = _glyphs[i];
        if (_shown[i] == glyph) continue;
        _shown[i] = glyph;

        if (x != cursorX || y != cursorY) buffer.write('\x1b[${y + 1};${x + 1}H');

        if (glyph.fore != fore) {
          fore = glyph.fore;
          buffer.write('\x1b[38;2;${fore.r};${fore.g};${fore.b}m');
        }
        if (glyph.back != back) {
          back = glyph.back;
          buffer.write('\x1b[48;2;${back.r};${back.g};${back.b}m');
        }

        var char = glyph.char;
        // Control characters and lone surrogates would upset the terminal.
        if (char < 32 || (char >= 0x7f && char < 0xa0) ||
            (char >= 0xd800 && char < 0xe000)) {
          char = 32;
        }
        buffer.writeCharCode(char);

        cursorX = x + 1;
        cursorY = y;
      }
    }

    if (buffer.isEmpty) return;
    buffer.write('\x1b[0m');
    _out.write(buffer.toString());
  }

  /// There is no mouse here.
  @override
  Vec pixelToChar(Vec pixel) => pixel;
}
