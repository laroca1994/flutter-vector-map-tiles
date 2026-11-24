import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'extensions.dart';
import 'grid/grid_layer.dart';
import 'io/io.dart';
import 'options.dart';
import 'style/style.dart';
import 'tile_offset.dart';
import 'tile_providers.dart';
import 'vector_tile_controller.dart';
import 'vector_tile_layer_mode.dart';
import 'vector_tile_provider.dart';

/// A widget for a vector tile layer, to be used as a child
/// of a [FlutterMap].
/// See readme for details.
class VectorTileLayer extends StatelessWidget {
  /// An optional controller for programmatic access to cache operations.
  ///
  /// Use [VectorTileController.clearMemoryCaches] to clear all in-memory
  /// caches on demand.
  final VectorTileController? controller;

  /// provides vector tiles, by source ID where the source ID corresponds to
  /// a source in the theme
  final TileProviders tileProviders;

  /// the theme used to render tiles
  final Theme theme;

  /// the sprites to be used when rendering tiles
  final SpriteStyle? sprites;

  /// the time to live of items in the file cache
  /// consider the terms of your tile provider service
  /// and the desired freshness of map data when setting this value
  final Duration fileCacheTtl;

  /// the default [fileCacheTtl]
  static const defaultCacheTtl = Duration(days: 30);

  /// the maximum size of the file-based cache in bytes.
  /// the cache does a good-enough effort to keep the cache size
  /// within the specified limit, however the size can exceed the
  /// specified limit from time to time.
  final int fileCacheMaximumSizeInBytes;

  /// the default [fileCacheMaximumSizeInBytes]
  static const defaultCacheMaxSize = 50 * 1024 * 1024;

  /// The maximum size in bytes of the memory vector tile cache.
  final int memoryTileCacheMaxSize;

  /// the default [memoryTileCacheMaxSize]
  static const defaultTileCacheMaxSize = 1024 * 1024 * 10;

  /// The maximum size in tiles of the memory vector tile cache.
  /// Differs from [memoryTileCacheMaxSize] in that this is the cache
  /// of parsed vector tiles, whereas [memoryTileCacheMaxSize] is the raw
  /// tile data.
  final int memoryTileDataCacheMaxSize;

  /// the default [memoryTileDataCacheMaxSize]
  static const defaultTileDataCacheMaxSize = 20;

  /// The maximum size of the text cache.
  final int textCacheMaxSize;

  /// the default [textCacheMaxSize]
  static const defaultTextCacheMaxSize = 100;

  /// Indicates whether debug information should be shown for tiles
  /// For vector [layerMode] only, ignored otherwise.
  final bool showTileDebugInfo;

  /// Indicates whether to log cache stats
  final bool logCacheStats;

  /// Draws background from a vector tile source when available
  /// For vector [layerMode] only, ignored otherwise.
  final Theme? backgroundTheme;

  /// The delay that should be applied to tile loading, useful for
  /// slowing down the map to observe how it behaves as tiles are loading
  final Duration tileDelay;

  /// The level of concurrency to use, must be >= 0.
  /// When set to 1 or higher, [isolates](https://dart.dev/guides/language/concurrency)
  /// are used for computations to offload expensive operations from the UI thread.
  /// This setting has no effect in debug mode.
  final int concurrency;

  /// The maximum zoom difference when substituting tiles while overlapping tiles
  /// are loading. A higher zoom difference results in lower chance of a blank map
  /// while loading tiles to display. A larger zoom difference requires more
  /// memory and can result in an application exceeding available memory, resulting
  /// in a crash. To avoid substituting tiles, use a value of 0.
  /// For vector [layerMode] only, ignored otherwise.
  final int maximumTileSubstitutionDifference;

  /// the default [maximumTileSubstitutionDifference]
  static const defaultMaxTileSubstitutionDifference = 2;

  /// The default [concurrency]
  static const defaultConcurrency = 4;

  /// The tile offset, defaults to [TileOffset.DEFAULT].
  /// See [TileOffset.mapbox].
  final TileOffset tileOffset;

  /// The mode of rendering. See [VectorTileLayerMode] for more details.
  final VectorTileLayerMode layerMode;

  /// The maximum zoom of the tile layer, for raster [layerMode] only.
  final double? maximumZoom;

  /// A function that resolves a folder for filesystem caching.
  /// If unspecified, defaults to a subfolder of the temporary directory.
  /// Applications that wish to delete persistent cache data should specify
  /// this function.
  final Future<Directory> Function()? cacheFolder;

  /// Decides when the map asks for tiles as it moves, for raster [layerMode]
  /// only. Passed as is to flutter_map's `TileLayer.tileUpdateTransformer`;
  /// when null, flutter_map's default applies.
  ///
  /// Raster tiles are painted on the UI thread, so asking for them on every
  /// frame of a zoom gesture competes with the gesture itself. A transformer
  /// can hold those requests until the zoom settles.
  final TileUpdateTransformer? tileUpdateTransformer;

  /// Where on the layer the tiles that matter most are, for raster
  /// [layerMode] only: within each batch, the nearest to this point load
  /// first. Defaults to the centre.
  ///
  /// flutter_map orders a batch from the centre of the tile range outwards.
  /// A layer that is laid out larger than what is seen —a map drawn tilted,
  /// with the camera's point near the bottom of a tall, flat rectangle— wants
  /// that point instead: the centre of the range is far away, near the
  /// horizon, and the tiles under the camera would load last.
  final Alignment tileFocus;

  /// **Where the tiles that matter most are, on the map**: the user's
  /// location, for example. Takes the place of [tileFocus] while it is in
  /// view; out of view, [tileFocus] applies.
  final LatLng? tileFocusAt;

  VectorTileLayer(
      {super.key,
      this.controller,
      required this.tileProviders,
      required this.theme,
      this.sprites,
      this.fileCacheTtl = defaultCacheTtl,
      this.memoryTileCacheMaxSize = defaultTileCacheMaxSize,
      this.memoryTileDataCacheMaxSize = defaultTileDataCacheMaxSize,
      this.fileCacheMaximumSizeInBytes = defaultCacheMaxSize,
      this.textCacheMaxSize = defaultTextCacheMaxSize,
      this.concurrency = defaultConcurrency,
      this.tileOffset = TileOffset.DEFAULT,
      this.maximumTileSubstitutionDifference =
          defaultMaxTileSubstitutionDifference,
      this.backgroundTheme,
      this.showTileDebugInfo = false,
      this.logCacheStats = false,
      this.layerMode = VectorTileLayerMode.raster,
      this.maximumZoom,
      this.tileDelay = const Duration(milliseconds: 0),
      this.cacheFolder,
      this.tileUpdateTransformer,
      this.tileFocus = Alignment.center,
      this.tileFocusAt}) {
    assert(concurrency >= 0 && concurrency <= 100);
    final providers = theme.tileSources
        .map((source) => tileProviders.tileProviderBySource[source])
        .whereType<VectorTileProvider>();
    assert(
        providers.isNotEmpty,
        '''
tileProviders must provide at least one provider that matches the given theme. 
Usually this is an indication that TileProviders in the code doesn't match the sources
required by the theme. 
The theme uses the following sources: ${theme.tileSources.toList().sorted().join(', ')}.
'''
            .trim());
    assert(
        maximumTileSubstitutionDifference >= 0 &&
            maximumTileSubstitutionDifference <= 3,
        'maximumTileSubstitutionDifference must be >= 0 and <= 3');
    assert(memoryTileDataCacheMaxSize >= 0 && memoryTileDataCacheMaxSize < 100);
  }

  @override
  Widget build(BuildContext context) {
    final mapCamera = MapCamera.maybeOf(context)!;
    return VectorTileCompositeLayer(VectorTileLayerOptions(this), mapCamera);
  }
}
