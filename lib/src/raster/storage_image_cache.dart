import 'dart:typed_data';
import 'dart:ui';

import 'images.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../cache/storage_cache.dart';

class StorageImageCache {
  late final String themeKey;
  final StorageCache delegate;

  StorageImageCache(Theme theme, this.delegate) {
    themeKey = '${theme.id}-v${theme.version}'
        .replaceAll(RegExp(r'[^a-zA-Z0-9.-]'), '-');
  }

  /// The stored image of [tile], decoded at [size] pixels square when given.
  ///
  /// With a [size] it is a soft tile that is asked for: the one stored soft
  /// comes first, already that size, and then the sharp one decoded smaller.
  Future<Image?> retrieve(TileIdentity tile,
      [int upStep = 0, int? size]) async {
    if (size != null) {
      final soft = await _retrieve(_key(tile, upStep, soft: true), size);
      if (soft != null) {
        return soft;
      }
    }
    return _retrieve(_key(tile, upStep), size);
  }

  Future<Image?> _retrieve(String key, int? size) async {
    final cached = await delegate.retrieve(key);
    if (cached != null) {
      try {
        return await imageFrom(bytes: cached, size: size);
      } catch (error, stack) {
        // in case the byte data is invalid, discard and remove the cached value
        // ignore: avoid_print
        print(error);
        // ignore: avoid_print
        print(stack);
        await _removeQuietly(key);
      }
    }
    return null;
  }

  /// Stores [image] as the image of [tile]; [soft] when it was drawn at less
  /// than full resolution, so that it never stands in for the sharp one.
  Future<void> put(TileIdentity tile, Image image,
      [int upStep = 0, bool soft = false]) async {
    final bytes = await encode(image);
    if (bytes != null) {
      await putBytes(tile, bytes, upStep, soft);
    }
  }

  /// [image] as it is stored. In two steps with [putBytes] so that the probe
  /// can tell encoding from writing.
  Future<Uint8List?> encode(Image image) async {
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  Future<void> putBytes(TileIdentity tile, Uint8List bytes,
          [int upStep = 0, bool soft = false]) =>
      delegate.put(_key(tile, upStep, soft: soft), bytes);

  String _key(TileIdentity tile, int upStep, {bool soft = false}) {
    final up = upStep == 0 ? '' : '-up$upStep';
    return '$themeKey-${tile.z}-${tile.x}-${tile.y}$up${soft ? '-soft' : ''}.png';
  }

  Future _removeQuietly(String key) async {
    try {
      delegate.remove(key);
    } catch (_) {}
  }
}
