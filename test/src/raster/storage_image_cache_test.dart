import 'dart:typed_data';
import 'dart:ui';

import 'package:test/test.dart';
import 'package:vector_map_tiles/src/cache/byte_storage.dart';
import 'package:vector_map_tiles/src/cache/storage_cache.dart';
import 'package:vector_map_tiles/src/raster/storage_image_cache.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

class _MemoryStorage implements ByteStorage {
  final files = <String, Uint8List>{};

  @override
  Future<void> write(String path, Uint8List bytes) async => files[path] = bytes;

  @override
  Future<Uint8List?> read(String path) async => files[path];

  @override
  Future<void> delete(String path) async => files.remove(path);

  @override
  Future<bool> exists(String key) async => files.containsKey(key);

  @override
  Future<List<ByteStorageEntry>> list() async => [];
}

Future<Image> _square(int side) {
  final recorder = PictureRecorder();
  Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      Paint()..color = const Color(0xFF336699));
  return recorder.endRecording().toImage(side, side);
}

void main() {
  final tile = TileIdentity(14, 5500, 9800);
  late _MemoryStorage storage;
  late StorageImageCache cache;

  setUp(() {
    storage = _MemoryStorage();
    cache = StorageImageCache(ProvidedThemes.lightTheme(),
        StorageCache(storage, const Duration(days: 1), 1 << 30));
  });

  test('a tile stored soft is found when it is asked for soft', () async {
    await cache.put(tile, await _square(256), 3, true);

    final soft = await cache.retrieve(tile, 3, 256);
    expect(soft?.width, 256);
    // Another label step is another image.
    expect(await cache.retrieve(tile, 2, 256), isNull);
  });

  test('a tile stored soft never stands in for the sharp one', () async {
    await cache.put(tile, await _square(256), 0, true);

    expect(await cache.retrieve(tile), isNull);
  });

  test('a tile stored sharp still serves a soft request', () async {
    await cache.put(tile, await _square(512));

    expect((await cache.retrieve(tile))?.width, 512);
    expect((await cache.retrieve(tile, 0, 256))?.width, 256);
    expect(storage.files.keys.single.contains('soft'), isFalse);
  });
}
