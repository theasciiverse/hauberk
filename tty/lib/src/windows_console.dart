import 'dart:ffi';

/// Puts the Windows console into the modes the game needs, and back.
///
/// Dart's stdin reports whether the console takes escape codes but does not
/// switch them on. Without virtual terminal input the cursor keys never reach
/// the game, without virtual terminal processing older consoles print the
/// colour codes literally, and without the UTF-8 code page the box drawing
/// comes out garbled.
class WindowsConsole {
  static const _stdInputHandle = -10;
  static const _stdOutputHandle = -11;
  static const _enableVirtualTerminalInput = 0x0200;
  static const _enableVirtualTerminalProcessing = 0x0004;
  static const _utf8CodePage = 65001;

  final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  late final _getStdHandle = _kernel32
      .lookupFunction<IntPtr Function(Int32), int Function(int)>(
        'GetStdHandle',
      );
  late final _getConsoleMode = _kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetConsoleMode');
  late final _setConsoleMode = _kernel32
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
        'SetConsoleMode',
      );
  late final _getConsoleOutputCP = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetConsoleOutputCP');
  late final _setConsoleOutputCP = _kernel32
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'SetConsoleOutputCP',
      );

  int? _inputMode;
  int? _outputMode;
  int? _codePage;

  /// Turns on escape codes both ways and UTF-8 output, remembering the old
  /// settings.
  void enable() {
    _inputMode = _addMode(_stdInputHandle, _enableVirtualTerminalInput);
    _outputMode = _addMode(_stdOutputHandle, _enableVirtualTerminalProcessing);
    _codePage = _getConsoleOutputCP();
    _setConsoleOutputCP(_utf8CodePage);
  }

  /// Puts back what [enable] changed.
  void restore() {
    if (_inputMode case var mode?) {
      _setConsoleMode(_getStdHandle(_stdInputHandle), mode);
    }
    if (_outputMode case var mode?) {
      _setConsoleMode(_getStdHandle(_stdOutputHandle), mode);
    }
    if (_codePage case var codePage? when codePage != 0) {
      _setConsoleOutputCP(codePage);
    }
  }

  /// Adds [flag] to the console mode of [stdHandle] and returns the old mode,
  /// or null when it is not a console.
  int? _addMode(int stdHandle, int flag) {
    var handle = _getStdHandle(stdHandle);
    var mode = _malloc<Uint32>();
    try {
      if (_getConsoleMode(handle, mode) == 0) return null;
      var old = mode.value;
      _setConsoleMode(handle, old | flag);
      return old;
    } finally {
      _free(mode);
    }
  }

  late final _heapAlloc = _kernel32
      .lookupFunction<
        Pointer Function(IntPtr, Uint32, IntPtr),
        Pointer Function(int, int, int)
      >('HeapAlloc');
  late final _heapFree = _kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer),
        int Function(int, int, Pointer)
      >('HeapFree');
  late final _getProcessHeap = _kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');

  Pointer<T> _malloc<T extends NativeType>() =>
      _heapAlloc(_getProcessHeap(), 0, 8).cast<T>();

  void _free(Pointer pointer) => _heapFree(_getProcessHeap(), 0, pointer);
}
