import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../extensions.dart';
import '../grid/constants.dart';
import '../grid/slippy_map_translator.dart';
import '../provider_exception.dart';
import '../raster/tile_loader.dart'
    show tileProbe, tileProbeCount, tileProbeLap;
import '../tile_identity.dart';
import '../tile_providers.dart';
import '../vector_tile_provider.dart';
import 'memory_cache.dart';
import 'storage_cache.dart';

class VectorTileLoadingCache {
  final Theme _theme;
  late final String _sourcesKey;
  final MemoryTileDataCache _tileDataCache;
  final MemoryCache _memoryCache;
  final StorageCache _delegate;
  final TileProviders _providers;
  final Map<String, Future<Uint8List?>> _byteFuturesByKey = {};
  final Map<String, Future<Uint8List?>> _cacheByteFuturesByKey = {};
  final Executor _executor;
  bool _ready = false;
  final _readyCompleter = Completer<bool>();
  late final int maximumZoom;
  final _probeDecoded = <String>{};

  VectorTileLoadingCache(this._delegate, this._memoryCache, this._tileDataCache,
      this._providers, this._executor, this._theme) {
    maximumZoom = _providers.tileProviderBySource.values
        .map((e) => e.maximumZoom)
        .reduce(max);
    _sourcesKey = _theme.tileSources.toList().sorted().join(',');
    _initialize();
  }

  Future<TileData?> retrieve(String source, TileIdentity tile,
      {required CancellationCallback cancelled,
      required bool cachedOnly}) async {
    if (!_ready) {
      await _readyCompleter.future;
    }
    return await _loadTile(source, tile, cancelled, cachedOnly);
  }

  void _initialize() async {
    final futures = _executor.submitAll(
        Job('setup theme', _setupTheme, _theme, deduplicationKey: null));
    for (final future in futures) {
      await future;
    }
    _ready = true;
    _readyCompleter.complete(true);
  }

  String _toKey(String source, TileIdentity id) =>
      '${id.z}_${id.x}_${id.y}_$source.pbf';

  Future<TileData?> _loadTile(String source, TileIdentity tile,
      CancellationCallback cancelled, bool cachedOnly) async {
    final tileKey = _toKey(source, tile);
    final cached = _tileDataCache.get(tileKey);
    if (cached != null) {
      tileProbeCount('m_en_memoria');
      return cached;
    }
    final watch = tileProbe ? (Stopwatch()..start()) : null;
    var future = cachedOnly
        ? _cacheByteFuturesByKey[tileKey]
        : _byteFuturesByKey[tileKey];
    var loaded = false;
    TileTranslation? translation;
    var dataKey = tileKey;
    if (future == null) {
      final provider = _providers.tileProviderBySource[source];
      if (provider == null || tile.z < provider.minimumZoom) {
        return _emptyTile();
      }
      final desiredZoom = min(
          max(tile.z + provider.tileOffset.zoomOffset, provider.minimumZoom),
          provider.maximumZoom);
      if (desiredZoom > tile.z) {
        return _emptyTile();
      }
      var tileToLoad = tile;
      if (tile.z != desiredZoom) {
        final translator = SlippyMapTranslator(desiredZoom);
        translation = translator.translate(tile);
        tileToLoad = translation.translated;
        dataKey = _toKey(source, tileToLoad);
      }
      loaded = true;
      future = _loadBytes(provider, dataKey, tileToLoad, cachedOnly);
      if (cachedOnly) {
        _cacheByteFuturesByKey[dataKey] = future;
      } else {
        _byteFuturesByKey[dataKey] = future;
      }
    }
    Uint8List? bytes;
    try {
      bytes = await future;
    } on ProviderException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 204) {
        return _emptyTile();
      }
      rethrow;
    } finally {
      if (loaded) {
        if (cachedOnly) {
          _cacheByteFuturesByKey.remove(dataKey);
        } else {
          _byteFuturesByKey.remove(dataKey);
        }
      }
    }
    tileProbeLap(watch, 'm_bytes');
    if (bytes == null) {
      return null;
    }
    if (tileProbe) {
      // Cuántas veces se decodifica una misma madre (la de z14 de una z17).
      tileProbeCount(
          _probeDecoded.add(dataKey) ? 'm_madre_nueva' : 'm_madre_otra_vez');
      if (_probeDecoded.length > 2000) _probeDecoded.clear();
    }
    final name = '$tileKey/${_theme.id}/$_sourcesKey';
    final tileData = await _executor.submit(Job(
        name,
        _createTile,
        _ThemeTile(
            source: source,
            themeId: _theme.id,
            dataKey: dataKey,
            bytes: bytes,
            translation: translation),
        cancelled: cancelled,
        deduplicationKey: name));
    tileProbeLap(watch, 'm_decodificar');
    _tileDataCache.put(tileKey, tileData);
    return tileData;
  }

  Future<Uint8List?> _loadBytes(VectorTileProvider provider, String key,
      TileIdentity tile, bool cachedOnly) async {
    var bytes = _memoryCache.get(key) ?? await _delegate.retrieve(key);
    if (bytes == null && !cachedOnly) {
      bytes = await provider.provide(tile);
      _memoryCache.put(key, bytes);
      await _delegate.put(key, bytes);
    }
    return bytes;
  }

  TileData _emptyTile() => TileFactory(_theme, const Logger.noop())
      .createTileData(VectorTile(layers: []));
}

class _ThemeTile {
  final String source;
  final String themeId;
  final String dataKey;
  final Uint8List bytes;
  final TileTranslation? translation;

  _ThemeTile(
      {required this.source,
      required this.themeId,
      required this.dataKey,
      required this.bytes,
      required this.translation});
}

final _themeById = <String, Theme>{};

Future<void> _setupTheme(Theme theme) async {
  _themeById[theme.id] = theme;
}

/// **The parents decoded last, in this isolate.** Past the source's top zoom
/// every tile is cut out of a parent —a z17 tile is one of 64 pieces of its
/// z14— and decoding the parent was half of a tile's data time on a low-end
/// phone (450–650 ms, 24-11), done again for each piece. Clipping and
/// translating build new objects and leave the parent as it was, so the
/// pieces can share it. Each isolate of the pool keeps its own few: a parent
/// is decoded at most once per isolate while it is in use. Measured on a
/// moto g06: a kept parent costs 0 ms, and cutting a piece out of it 0–3 ms.
final _parents = <String, TileData>{};
const _maxParents = 4;

TileData _decodeParent(_ThemeTile themeTile) {
  final key = '${themeTile.themeId}/${themeTile.dataKey}';
  final kept = _parents.remove(key);
  if (kept != null) {
    _parents[key] = kept;
    return kept;
  }
  final decoded = _decode(themeTile);
  _parents[key] = decoded;
  if (_parents.length > _maxParents) {
    _parents.remove(_parents.keys.first);
  }
  return decoded;
}

TileData _decode(_ThemeTile themeTile) =>
    TileFactory(_themeById[themeTile.themeId]!, const Logger.noop())
        .createTileData(VectorTileReader().read(themeTile.bytes));

TileData _createTile(_ThemeTile themeTile) {
  final translation = themeTile.translation;
  final watch = tileProbe ? (Stopwatch()..start()) : null;
  final hit = _parents.containsKey('${themeTile.themeId}/${themeTile.dataKey}');
  var tileData =
      translation == null ? _decode(themeTile) : _decodeParent(themeTile);
  final decodeMs = watch?.elapsedMilliseconds;
  if (translation != null && tileData.layers.isNotEmpty) {
    final clipSize = tileSize.width / translation.fraction;
    final dx = (translation.xOffset * clipSize);
    final dy = (translation.yOffset * clipSize);
    final clip = Rectangle(dx, dy, clipSize, clipSize);
    var transformed = TileClip(bounds: clip).clip(tileData);
    if (clip.left > 0.0 || clip.top > 0.0 || translation.fraction != 1.0) {
      transformed = TileTranslate(clip.topLeft * -1,
              scale: translation.fraction.toDouble())
          .translate(transformed);
    }
    tileData = transformed;
  }
  if (watch != null) {
    // Desde el isolate: lo que cuesta de verdad, sin la espera ni el viaje.
    debugPrint('[madre] ${hit ? 'guardada' : 'decodificada'} '
        'decodificar=$decodeMs recortar=${watch.elapsedMilliseconds - decodeMs!}');
  }
  return tileData;
}
