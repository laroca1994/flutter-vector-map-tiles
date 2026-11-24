import 'dart:async';

import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../cache/caches.dart';
import '../raster/tile_loader.dart' show tileProbe, tileProbeLap;
import 'tile_processor.dart';
import 'tile_supplier.dart';
import 'tileset_executor_preprocessor.dart';
import 'tileset_ui_preprocessor.dart';

class CachesTileProvider extends TileProvider {
  final Caches _caches;
  final TileProcessor _tileProcessor;
  final TilesetExecutorPreprocessor _preprocessor;
  final TilesetUiPreprocessor _uiPreprocessor;

  CachesTileProvider(this._caches, this._tileProcessor, this._preprocessor,
      this._uiPreprocessor);

  @override
  int get maximumZoom => _caches.vectorTileCache.maximumZoom;

  @override
  Future<TileResponse> provide(TileRequest request) =>
      _provide(request, localOnly: false);

  @override
  Future<TileResponse> provideLocalCopy(TileRequest request) =>
      _provide(request, localOnly: true);

  Future<TileResponse> _provide(TileRequest request,
      {required bool localOnly}) async {
    final watch = tileProbe ? (Stopwatch()..start()) : null;
    Map<String, TileData?> tileDataBySource =
        await _retrieve(request, localOnly: localOnly);
    tileProbeLap(watch, 'd_madre');
    if (tileDataBySource.values.any((t) => t == null)) {
      return TileResponse(identity: request.tileId, tileset: null);
    }
    Map<String, TileData> loadedDataBySource =
        tileDataBySource.map((key, value) => MapEntry(key, value!));
    Map<String, Tile> tileBySource =
        await _createTiles(request, loadedDataBySource);
    tileProbeLap(watch, 'd_recorte');
    var tileset = await _preprocessor.preprocess(
        request.tileId,
        Tileset(tileBySource),
        request.clip,
        request.zoom.truncate(),
        request.cancelled);
    tileProbeLap(watch, 'd_preparar');
    tileset = await _uiPreprocessor.preprocess(request.tileId, tileset,
        request.clip, request.zoom.truncate(), request.cancelled);
    tileProbeLap(watch, 'd_ui');
    return TileResponse(identity: request.tileId, tileset: tileset);
  }

  Future<Map<String, TileData?>> _retrieve(TileRequest request,
      {required bool localOnly}) async {
    Map<String, Future<TileData?>> futureBySource = {};
    for (final source in request.tileSources) {
      futureBySource[source] = _caches.vectorTileCache.retrieve(
          source, request.tileId,
          cachedOnly: localOnly, cancelled: request.cancelled);
    }
    Map<String, TileData?> tileBySource = {};
    for (final entry in futureBySource.entries) {
      request.testCancelled();
      tileBySource[entry.key] = await entry.value;
    }
    return tileBySource;
  }

  Future<Map<String, Tile>> _createTiles(
      TileRequest request, Map<String, TileData> tileDataBySource) async {
    final sourceToTileFuture = tileDataBySource.map((source, tileData) =>
        MapEntry(
            source,
            _tileProcessor.process(
                request, source, tileData, request.cancelled)));
    Map<String, Tile> tileBySource = {};
    for (final entry in sourceToTileFuture.entries) {
      request.testCancelled();
      tileBySource[entry.key] = await entry.value;
    }
    return tileBySource;
  }
}
