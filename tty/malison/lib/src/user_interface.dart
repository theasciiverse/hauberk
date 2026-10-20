import 'package:piecemeal/piecemeal.dart';

import 'key_bindings.dart';
import 'terminal.dart';

/// A simple modal user interface layer.
///
/// It maintains a stack of screens. All screens in the stack update. Screens
/// may indicate if they are opaque or transparent. Transparent screens allow
/// the screen under them to render.
///
/// In addition, the interface can define a number of global [KeyBindings]
/// which screens can use to map raw keypresses to something higher-level.
class UserInterface<T> {
  /// Keyboard bindings for key press events.
  final keyPress = KeyBindings<T>();

  final List<Screen<T>> _screens = [];
  RenderableTerminal? _terminal;
  bool _dirty = true;

  /// Whether or not the host forwards keyboard events to [keyDown] and
  /// [keyUp].
  ///
  /// Initially off.
  bool handlingInput = false;

  /// Whether or not the host is calling [refresh()] every frame.
  ///
  /// Initially off.
  bool running = false;

  /// The rate that [refresh()] should ideally be called at when [running] is
  /// `true`.
  int framesPerSecond = 60;

  UserInterface([this._terminal]);

  /// The screen on top of the stack, which gets the input, if any.
  Screen<T>? get topScreen => _screens.isEmpty ? null : _screens.last;

  void setTerminal(RenderableTerminal terminal) {
    var resized =
        _terminal == null ||
        _terminal!.width != terminal.width ||
        _terminal!.height != terminal.height;

    _terminal = terminal;
    dirty();

    // If the terminal size changed, let the screens known.
    if (resized) {
      for (var screen in _screens) {
        screen.resize(terminal.size);
      }
    }
  }

  /// Pushes [screen] onto the top of the stack.
  void push(Screen<T> screen) {
    screen._bind(this);
    _screens.add(screen);
    _render();
  }

  /// Pops the top screen off the top of the stack.
  ///
  /// The next screen down is activated. If [result] is given, it is passed to
  /// the new active screen's [activate] method.
  void pop([Object? result]) {
    var screen = _screens.removeLast();
    screen._unbind();
    _screens[_screens.length - 1].activate(screen, result);
    _render();
  }

  /// Switches the current top screen to [screen].
  ///
  /// This is equivalent to a [pop] followed by a [push].
  void goTo(Screen<T> screen) {
    var old = _screens.removeLast();
    old._unbind();

    screen._bind(this);
    _screens.add(screen);
    _render();
  }

  void dirty() {
    _dirty = true;
  }

  void refresh() {
    // Don't use a for-in loop here so that we don't run into concurrent
    // modification exceptions if a screen is added or removed during a call to
    // update().
    for (var i = 0; i < _screens.length; i++) {
      _screens[i].update();
    }
    if (_dirty) _render();
  }

  /// Handles a key press from the host.
  void keyDown(int keyCode, {bool shift = false, bool alt = false}) {
    if (!handlingInput || _screens.isEmpty) return;

    var input = keyPress.find(keyCode, shift: shift, alt: alt);

    var screen = _screens.last;
    if (input != null) {
      if (screen.handleInput(input)) return;
    }

    screen.keyDown(keyCode, shift: shift, alt: alt);
  }

  /// Handles a key release from the host.
  void keyUp(int keyCode, {bool shift = false, bool alt = false}) {
    if (!handlingInput || _screens.isEmpty) return;

    _screens.last.keyUp(keyCode, shift: shift, alt: alt);
  }

  void _render() {
    // If the UI isn't currently bound to a terminal, there's nothing to render.
    var terminal = _terminal;
    if (terminal == null) return;

    terminal.clear();

    // Skip past all of the covered screens.
    int i;
    for (i = _screens.length - 1; i >= 0; i--) {
      if (!_screens[i].isTransparent) break;
    }

    if (i < 0) i = 0;

    // Render the top opaque screen and any transparent ones above it.
    for (; i < _screens.length; i++) {
      _screens[i].render(terminal);
    }

    _dirty = false;
    terminal.render();
  }
}

class Screen<T> {
  UserInterface<T>? _ui;

  /// The [UserInterface] this screen is bound to.
  ///
  /// Throws an exception if the screen is not currently bound to an interface.
  UserInterface<T> get ui => _ui!;

  /// Whether this screen is bound to a [UserInterface].
  ///
  /// If this is `false`, then [ui] cannot be accessed.
  bool get isBound => _ui != null;

  /// Whether this screen allows any screens under it to be visible.
  ///
  /// Subclasses can override this. Defaults to `false`.
  bool get isTransparent => false;

  /// Binds this screen to [ui].
  void _bind(UserInterface<T> ui) {
    assert(_ui == null);
    _ui = ui;

    resize(ui._terminal!.size);
  }

  /// Unbinds this screen from the [ui] that owns it.
  void _unbind() {
    assert(_ui != null);
    _ui = null;
  }

  /// Marks the user interface as needing to be rendered.
  ///
  /// Call this during [update] to indicate that a subsequent call to [render]
  /// is needed.
  void dirty() {
    // If we aren't bound (yet), just do nothing. The screen will be dirtied
    // when it gets bound.
    if (_ui == null) return;

    _ui!.dirty();
  }

  /// If a keypress has a binding defined for it and is pressed, this will be
  /// called with the bound input when this screen is active.
  ///
  /// If this returns `false` (the default), then the lower-level [keyDown]
  /// method will be called.
  bool handleInput(T input) => false;

  bool keyDown(int keyCode, {required bool shift, required bool alt}) => false;

  bool keyUp(int keyCode, {required bool shift, required bool alt}) => false;

  /// Called when the screen above this one ([popped]) has been popped and this
  /// screen is now the top-most screen. If a value was passed to [pop()], it
  /// will be passed to this as [result].
  void activate(Screen<T> popped, Object? result) {}

  void update() {}

  void render(Terminal terminal) {}

  /// Called when the [UserInterface] has been bound to a new terminal with a
  /// different size while this [Screen] is present.
  void resize(Vec size) {}
}
