import 'dart:async';
import 'dart:math';

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../extensions.dart';
import '../raster/tile_loader.dart' show tileProbe, tileProbeUi;

class TilesetUiPreprocessor {
  final TilesetPreprocessor _preprocessor;
  final Executor _executor;

  TilesetUiPreprocessor(this._preprocessor) : _executor = QueueExecutor();

  Future<Tileset> preprocess(TileIdentity identity, Tileset tileset,
      Rectangle<double>? clip, int zoom, CancellationCallback cancelled) async {
    final deduplicationKey =
        'preprocess ui: $identity clip=$clip zoom=$zoom sources=${tileset.tiles.keys.toList().sorted().join(',')}';
    return await _executor.submit(Job(
        deduplicationKey, _preprocessTile, _TilesetAndZoom(tileset, zoom),
        cancelled: cancelled, deduplicationKey: deduplicationKey));
  }

  Tileset _preprocessTile(_TilesetAndZoom job) {
    final watch = tileProbe ? (Stopwatch()..start()) : null;
    final out =
        _preprocessor.preprocess(job.tileset, zoom: job.zoom.toDouble());
    if (watch != null) {
      tileProbeUi(watch.elapsedMicroseconds);
    }
    return out;
  }
}

class _TilesetAndZoom {
  final Tileset tileset;
  final int zoom;

  _TilesetAndZoom(this.tileset, this.zoom);
}
