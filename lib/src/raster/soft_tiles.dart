import 'dart:async';

import 'tile_priority.dart';

/// **The tiles drawn soft, waiting for the focus to come near.**
///
/// A tile out of `TileFocus.sharpRadius` is drawn at half the resolution
/// (see `VectorTileLayer.sharpTileRadius`). flutter_map does not ask for a
/// tile again while it is on screen, so on a trip the soft tiles ahead would
/// stay soft when the user reaches them. This keeps them, and twice a second
/// sends the ones the focus came near to be drawn sharp: the sharp image
/// replaces the soft one in the same image stream.
class SoftTiles {
  SoftTiles(this._focus, {this.every = const Duration(milliseconds: 500)});

  final TileFocus _focus;
  final Duration every;
  final _waiting = <(TileTicket, void Function())>[];
  Timer? _timer;

  int get length => _waiting.length;

  /// Keeps the tile of [ticket], drawn soft, until the focus comes near it:
  /// then [sharpen] runs, once. A cancelled tile is dropped.
  void add(TileTicket ticket, void Function() sharpen) {
    _waiting.add((ticket, sharpen));
    _timer ??= Timer.periodic(every, (_) => check());
  }

  /// Sends the tiles the focus is now near to be drawn sharp, and drops the
  /// cancelled ones.
  void check() {
    final near = <void Function()>[];
    _waiting.removeWhere((w) {
      final ticket = w.$1;
      if (ticket.cancelled()) {
        return true;
      }
      if (_focus.isSharp(ticket.x, ticket.y, ticket.z, ticket.tileSize)) {
        near.add(w.$2);
        return true;
      }
      return false;
    });
    if (_waiting.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
    for (final sharpen in near) {
      sharpen();
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _waiting.clear();
  }
}
