import 'dart:collection';

import 'package:hauberk/src/content/tiles.dart';
import 'package:hauberk/src/engine.dart';
import 'package:hauberk/src/ui/game/game_screen.dart';
import 'package:hauberk/src/ui/input.dart';
import 'package:hauberk/src/ui/item/equip_dialog.dart';
import 'package:hauberk/src/ui/menu/main_menu_screen.dart';
import 'package:hauberk/src/ui/popup/select_depth_popup.dart';
import 'package:hauberk/src/ui/game/loading_dialog.dart';
import 'package:malison/malison.dart';
import 'package:malison/malison_web.dart';
import 'package:piecemeal/piecemeal.dart';

/// Plays the game for `--demo`, the way a player would at the keyboard: it
/// only hands the screens the same [Input]s the keys do.
///
/// In the town it equips what it carries (the starting weapon and a candle to
/// see by), then walks to the dungeon stairs and takes the deepest level
/// offered. In the dungeon it fights what it sees, rests when hurt, picks up
/// what lies in reach and otherwise explores the nearest unknown ground.
class Autopilot {
  final UserInterface<Input> _ui;

  /// Frames between decisions, so a viewer can follow.
  final int _framesPerMove;

  /// Where decisions are logged.
  final void Function(String) _log;

  int _frames = 0;

  /// The inventory slot to pick once the equip dialog is open.
  int? _equipIndex;

  /// The level whose ground [_visited] covers.
  Stage? _stage;

  /// Where the hero has stood on this level. A frontier tile already stood
  /// on borders darkness the light does not reach, so it is no goal again.
  final Set<Vec> _visited = {};

  Autopilot(this._ui, this._log, {int framesPerMove = 8})
    : _framesPerMove = framesPerMove;

  /// Called every frame.
  void tick() {
    if (++_frames < _framesPerMove) return;
    _frames = 0;

    var screen = _ui.topScreen;
    switch (screen) {
      case GameScreen():
        _play(screen);
      case SelectDepthPopup():
        _send(screen, Input.ok);
      case EquipDialog() when _equipIndex != null:
        // The dialog's letters are inventory slots, as a player types them.
        var index = _equipIndex!;
        _equipIndex = null;
        _log('autopilot EquipDialog ${String.fromCharCode(KeyCode.a + index)}');
        _ui.keyDown(KeyCode.a + index);
        _ui.dirty();
      case LoadingDialog() || MainMenuScreen():
        // Generating the level, which carries on by itself, or back on the
        // menu after the game.
        break;
      case null:
        break;
      default:
        // Anything else, an item list or a notice, is closed.
        _send(screen, Input.cancel);
    }
  }

  void _send(Screen<Input> screen, Input input) {
    _log('autopilot ${screen.runtimeType} $input');
    screen.handleInput(input);
    _ui.dirty();
  }

  void _play(GameScreen screen) {
    var game = screen.game;
    var hero = game.hero;
    if (!hero.needsInput(game)) {
      _log('autopilot busy at ${hero.pos}, depth ${game.depth}');
      return;
    }

    var stage = game.stage;
    if (!identical(stage, _stage)) {
      _stage = stage;
      _visited.clear();
    }
    _visited.add(hero.pos);

    // In the town, put on everything that can be worn or wielded.
    if (game.depth == 0) {
      for (var i = 0; i < hero.inventory.length; i++) {
        var item = hero.inventory[i];
        // A stack of candles stays equippable after one is taken from it.
        var worn = hero.equipment.any((other) => other.type == item.type);
        if (item.canEquip && !worn) {
          _equipIndex = i;
          _send(screen, Input.equip);
          return;
        }
      }
    }

    var monsters = [
      for (var actor in stage.actors)
        if (actor is Monster && actor.isAlive && stage.isVisibleToHero(actor))
          actor,
    ];

    // Next to a monster: hit it.
    for (var monster in monsters) {
      var offset = monster.pos - hero.pos;
      if (offset.kingLength == 1) {
        _send(screen, _walk(offset));
        return;
      }
    }

    // Hurt and nothing in sight: rest.
    if (monsters.isEmpty && hero.health < hero.maxHealth * 2 ~/ 3) {
      _send(screen, Input.rest);
      return;
    }

    // Standing on something: take it.
    if (game.depth > 0 && stage.isItemAt(hero.pos)) {
      _send(screen, Input.pickUp);
      return;
    }

    Vec? step;
    if (game.depth == 0) {
      step = _firstStep(
        stage,
        hero.pos,
        (pos) => stage[pos].portal == TilePortals.dungeon,
      );
    } else {
      // Go for a monster in sight; one that cannot be reached over known
      // ground yet is found by exploring.
      var targets = {for (var monster in monsters) monster.pos};
      if (targets.isNotEmpty) {
        step = _firstStep(stage, hero.pos, targets.contains);
      }

      step ??= _firstStep(
        stage,
        hero.pos,
        (pos) =>
            (stage.isItemAt(pos) && stage[pos].isVisible) ||
            (!_visited.contains(pos) && _isFrontier(stage, pos)),
      );
    }

    if (step != null) {
      _send(screen, _walk(step));
    } else {
      // Nothing left to do here; wait a turn.
      _send(screen, Input.ok);
    }
  }

  /// An explored, walkable tile next to one not explored yet.
  bool _isFrontier(Stage stage, Vec pos) {
    for (var dir in Direction.all) {
      var next = pos + dir;
      if (!stage.bounds.contains(next)) continue;
      if (!stage[next].isExplored) return true;
    }
    return false;
  }

  /// The first step on the shortest path over known ground from [start] to a
  /// tile that satisfies [goal], or null if none can be reached.
  Vec? _firstStep(Stage stage, Vec start, bool Function(Vec) goal) {
    var firstSteps = <Vec, Vec>{start: Vec.zero};
    var queue = Queue<Vec>()..add(start);

    while (queue.isNotEmpty) {
      var pos = queue.removeFirst();
      if (pos != start && goal(pos)) return firstSteps[pos];

      for (var dir in Direction.all) {
        var next = pos + dir;
        if (firstSteps.containsKey(next)) continue;
        if (!stage.bounds.contains(next)) continue;

        var tile = stage[next];
        if (!tile.isExplored || !tile.isTraversable) continue;

        // Go round other monsters' tiles unless one is what we are after.
        if (stage.actorAt(next) != null && !goal(next)) continue;

        firstSteps[next] = pos == start ? dir : firstSteps[pos]!;
        queue.add(next);
      }
    }

    return null;
  }

  Input _walk(Vec offset) => switch ((offset.x.sign, offset.y.sign)) {
    (-1, -1) => Input.nw,
    (0, -1) => Input.n,
    (1, -1) => Input.ne,
    (-1, 0) => Input.w,
    (1, 0) => Input.e,
    (-1, 1) => Input.sw,
    (0, 1) => Input.s,
    (1, 1) => Input.se,
    _ => Input.ok,
  };
}
